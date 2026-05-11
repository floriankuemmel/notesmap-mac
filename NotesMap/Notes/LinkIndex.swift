// LinkIndex.swift: Graph-Aufbau aus zwei Quellen.
//
// 1. DB-Einträge (ZTYPEUTI1 = com.apple.notes.inlinetextattachment.link).
//    Die "echten" >> Links, die Apple Notes als inline-attachments speichert.
// 2. Protobuf-Scan: HTML-Links die programmatisch via AppleScript
//    eingefügt wurden (`<a href="applenotes:note/...">`). Sie landen nicht
//    in der Link-Attachment-Tabelle, sondern nur im Notiz-Rohtext.
//
// Beide Quellen werden dedupliziert gemerged.

import Foundation
import GRDB

struct LinkGraphNode: Hashable, Sendable {
    let uuid: String           // UUID (uppercase)
    let title: String
    let folderName: String     // "Unbekannt" wenn kein Ordner
    let noteId: Int64
    let createdAt: Date?
    let outgoingCount: Int
    let incomingCount: Int
    /// Hashtags der Notiz, inkl. führendem `#`, sortiert.
    /// Apple speichert Tags als inline-text-attachments vom Typ
    /// `com.apple.notes.inlinetextattachment.hashtag`, ZALTTEXT enthält
    /// den sichtbaren Text (z.B. `#projekt`).
    let tags: [String]

    var hubScore: Int { outgoingCount + incomingCount }

    /// applenotes:note/<UUID>
    var deepLink: URL? { URL(string: "applenotes:note/\(uuid)") }
}

struct LinkGraphEdge: Hashable, Sendable {
    let sourceUuid: String
    let targetUuid: String
}

struct LinkGraph: Sendable {
    let nodes: [LinkGraphNode]
    let edges: [LinkGraphEdge]

    var noteCount: Int { nodes.count }
    var linkedCount: Int { nodes.filter { $0.hubScore > 0 }.count }
    var orphanCount: Int { noteCount - linkedCount }
}

enum LinkIndexBuilder {

    /// Baut den Graph in einem einzigen `db.read`-Block.
    static func build(_ db: Database) throws -> LinkGraph {
        // --- 1. Alle Notizen als potenzielle Nodes registrieren
        // Trash-Ausschluss: ZFOLDERTYPE=1 ist "Zuletzt gelöscht". AppleScript-
        // Delete setzt ZMARKEDFORDELETION nicht, nur ZFOLDER auf den Trash;
        // deshalb müssen beide Filter her.
        let noteRows = try Row.fetchAll(db, sql: """
            SELECT
                c1.Z_PK            AS note_id,
                UPPER(c1.ZIDENTIFIER) AS uuid,
                c1.ZTITLE1         AS title,
                c1.ZCREATIONDATE3  AS created,
                c2.ZTITLE2         AS folder_name
            FROM ZICCLOUDSYNCINGOBJECT AS c1
            LEFT JOIN ZICCLOUDSYNCINGOBJECT AS c2 ON c2.Z_PK = c1.ZFOLDER
            WHERE c1.ZTITLE1 IS NOT NULL
              AND (c1.ZMARKEDFORDELETION IS NULL OR c1.ZMARKEDFORDELETION = 0)
              AND (c2.ZFOLDERTYPE IS NULL OR c2.ZFOLDERTYPE != 1)
              AND c1.Z_ENT = 12
            """)

        var uuidToNoteId: [String: Int64] = [:]
        var uuidToTitle: [String: String] = [:]
        var uuidToFolder: [String: String] = [:]
        var uuidToCreated: [String: Date?] = [:]

        for row in noteRows {
            guard let uuid: String = row["uuid"],
                  let id: Int64 = row["note_id"],
                  let title: String = row["title"]
            else { continue }
            uuidToNoteId[uuid] = id
            uuidToTitle[uuid] = title
            uuidToFolder[uuid] = row["folder_name"] ?? "Unbekannt"
            if let cocoa: Double = row["created"], cocoa > 0 {
                uuidToCreated[uuid] = Date(timeIntervalSince1970: cocoa + 978307200)
            } else {
                uuidToCreated[uuid] = nil
            }
        }

        // --- 1b. Hashtags pro Notiz fetchen.
        // Apple speichert Tags als inline-text-attachments vom Typ
        // `com.apple.notes.inlinetextattachment.hashtag`; ZALTTEXT enthält
        // den sichtbaren Text (z.B. `#projekt`). ZNOTE1 ist der FK auf die
        // Notiz. Trash-Filter wie bei allen anderen Queries.
        let tagRows = try Row.fetchAll(db, sql: """
            SELECT
                UPPER(c1.ZIDENTIFIER) AS note_uuid,
                tag.ZALTTEXT          AS tag
            FROM ZICCLOUDSYNCINGOBJECT AS tag
            JOIN ZICCLOUDSYNCINGOBJECT AS c1 ON c1.Z_PK = tag.ZNOTE1
            LEFT JOIN ZICCLOUDSYNCINGOBJECT AS c2 ON c2.Z_PK = c1.ZFOLDER
            WHERE tag.ZTYPEUTI1 = 'com.apple.notes.inlinetextattachment.hashtag'
              AND tag.ZALTTEXT IS NOT NULL
              AND (c1.ZMARKEDFORDELETION IS NULL OR c1.ZMARKEDFORDELETION = 0)
              AND (c2.ZFOLDERTYPE IS NULL OR c2.ZFOLDERTYPE != 1)
            """)

        var uuidToTags: [String: Set<String>] = [:]
        for row in tagRows {
            guard let uuid: String = row["note_uuid"],
                  let tag: String = row["tag"] else { continue }
            uuidToTags[uuid, default: []].insert(tag)
        }

        // --- 2. Outgoing-Sets vorbereiten (dedupliziert)
        var outgoing: [String: Set<String>] = [:]
        var incoming: [String: Set<String>] = [:]
        for uuid in uuidToTitle.keys {
            outgoing[uuid] = []
            incoming[uuid] = []
        }

        func addLink(from source: String, to target: String) {
            guard source != target,
                  uuidToTitle[source] != nil,
                  uuidToTitle[target] != nil
            else { return }
            outgoing[source]?.insert(target)
            incoming[target]?.insert(source)
        }

        // --- 3. Quelle A: Link-Attachments aus DB
        let linkRows = try Row.fetchAll(db, sql: """
            SELECT
                UPPER(c1.ZIDENTIFIER)       AS source_uuid,
                link.ZTOKENCONTENTIDENTIFIER AS target_url
            FROM ZICCLOUDSYNCINGOBJECT AS link
            JOIN ZICCLOUDSYNCINGOBJECT AS c1 ON c1.Z_PK = link.ZNOTE1
            LEFT JOIN ZICCLOUDSYNCINGOBJECT AS c2 ON c2.Z_PK = c1.ZFOLDER
            WHERE link.ZTYPEUTI1 = 'com.apple.notes.inlinetextattachment.link'
              AND link.ZTOKENCONTENTIDENTIFIER LIKE 'applenotes:note/%'
              AND (c1.ZMARKEDFORDELETION IS NULL OR c1.ZMARKEDFORDELETION = 0)
              AND (c2.ZFOLDERTYPE IS NULL OR c2.ZFOLDERTYPE != 1)
            """)

        for row in linkRows {
            guard let sourceUuid: String = row["source_uuid"],
                  let targetUrl: String = row["target_url"],
                  let match = noteLinkUuidRegex.firstMatch(
                    in: targetUrl,
                    range: NSRange(targetUrl.startIndex..<targetUrl.endIndex, in: targetUrl)
                  ),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: targetUrl)
            else { continue }
            let targetUuid = String(targetUrl[range]).uppercased()
            addLink(from: sourceUuid, to: targetUuid)
        }

        // --- 4. Quelle B: Links aus Protobuf (programmatische HTML-Links)
        let dataRows = try Row.fetchAll(db, sql: """
            SELECT
                UPPER(c1.ZIDENTIFIER) AS uuid,
                nd.ZDATA              AS data
            FROM ZICNOTEDATA AS nd
            JOIN ZICCLOUDSYNCINGOBJECT AS c1 ON c1.Z_PK = nd.ZNOTE
            LEFT JOIN ZICCLOUDSYNCINGOBJECT AS c2 ON c2.Z_PK = c1.ZFOLDER
            WHERE nd.ZDATA IS NOT NULL
              AND c1.ZTITLE1 IS NOT NULL
              AND (c1.ZMARKEDFORDELETION IS NULL OR c1.ZMARKEDFORDELETION = 0)
              AND (c2.ZFOLDERTYPE IS NULL OR c2.ZFOLDERTYPE != 1)
            """)

        for row in dataRows {
            guard let sourceUuid: String = row["uuid"],
                  let data: Data = row["data"]
            else { continue }
            for targetUuid in extractLinkUuids(fromGzippedData: data) {
                addLink(from: sourceUuid, to: targetUuid)
            }
        }

        // --- 5. Nodes zusammensetzen
        let nodes: [LinkGraphNode] = uuidToTitle.compactMap { (uuid, title) -> LinkGraphNode? in
            guard let id = uuidToNoteId[uuid] else { return nil }
            return LinkGraphNode(
                uuid: uuid,
                title: title,
                folderName: uuidToFolder[uuid] ?? "Unbekannt",
                noteId: id,
                createdAt: uuidToCreated[uuid] ?? nil,
                outgoingCount: outgoing[uuid]?.count ?? 0,
                incomingCount: incoming[uuid]?.count ?? 0,
                tags: (uuidToTags[uuid] ?? []).sorted()
            )
        }

        let edges: [LinkGraphEdge] = outgoing.flatMap { (source, targets) in
            targets.map { LinkGraphEdge(sourceUuid: source, targetUuid: $0) }
        }

        return LinkGraph(nodes: nodes, edges: edges)
    }

    // MARK: - Protobuf-Link-Scan

    /// Regex für applenotes:note/<UUID>; nicht capture-named, damit wir über NSRegex gehen können.
    private static let noteLinkUuidRegex = try! NSRegularExpression(
        pattern: "applenotes:note/([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})",
        options: [.caseInsensitive]
    )

    /// Entpackt gzip + sucht per Regex alle `applenotes:note/UUID`-Vorkommen im Klartext.
    /// Das ist deutlich einfacher als den Protobuf zu parsen; die Links stehen eh als
    /// UTF-8-Text im decompressten Stream.
    ///
    /// Wichtig: `String(decoding:as:UTF8.self)` ersetzt ungültige Bytes durch U+FFFD,
    /// statt nil zurückzugeben. Apple-Notes-Protobufs haben binär-Felder (Font-IDs,
    /// Bildverweise), die strict-UTF-8 sprengen würden; das darf uns die Link-Suche
    /// aber nicht kaputtmachen.
    private static func extractLinkUuids(fromGzippedData data: Data) -> [String] {
        guard let decompressed = GzipDecoder.decompress(data) else { return [] }
        let text = String(decoding: decompressed, as: UTF8.self)

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = noteLinkUuidRegex.matches(in: text, options: [], range: range)

        return matches.compactMap { match -> String? in
            guard match.numberOfRanges > 1,
                  let uuidRange = Range(match.range(at: 1), in: text)
            else { return nil }
            return String(text[uuidRange]).uppercased()
        }
    }
}

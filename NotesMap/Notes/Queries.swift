// Queries.swift: alle SQL-Queries gegen NoteStore.sqlite.
//
// Spalten-Mapping empirisch validiert für macOS 15 (Sequoia) / Notes 4.11:
//   Z_PK                 Primary key (int)
//   Z_ENT = 12          Notiz-Entity
//   ZIDENTIFIER         UUID (String, z.B. "ABC-1234-…")
//   ZTITLE1             Notiztitel
//   ZTITLE2             Ordnertitel
//   ZCREATIONDATE3      Erstellungsdatum (Cocoa timestamp, NICHT 1!)
//   ZMODIFICATIONDATE1  Änderungsdatum
//   ZFOLDER             FK auf Ordner-Row (ZICCLOUDSYNCINGOBJECT)
//   ZACCOUNT7           FK auf Account (NICHT 2!)
//   ZMARKEDFORDELETION  1 = endgültig gelöscht (nach Trash-Emptying)
//   ZFOLDERTYPE         0 = normaler Ordner, 1 = "Zuletzt gelöscht", 3 = Quick Notes
//
// Wichtig zum Papierkorb: Wenn eine Notiz via AppleScript `delete` (oder per UI)
// in den Papierkorb wandert, ändert Apple Notes NUR `ZFOLDER` auf den
// Trash-Ordner (Z_PK mit ZFOLDERTYPE=1). `ZMARKEDFORDELETION` bleibt 0 bis zum
// endgültigen Leeren. Deshalb reicht ZMARKEDFORDELETION als Filter nicht;
// wir müssen zusätzlich den Folder-Typ prüfen.
//
// Cocoa-Timestamps: Sekunden seit 2001-01-01 00:00:00 UTC.
// Unix-Offset: 978307200.

import Foundation
import GRDB

// MARK: - DTOs

struct NoteSummary: Identifiable, Hashable, Sendable {
    let id: Int64           // Z_PK
    let uuid: String
    let title: String
    let folderName: String?
    let createdAt: Date?

    /// applenotes:note/<UUID>: öffnet die Notiz in Apple Notes.app.
    var deepLink: URL? {
        URL(string: "applenotes:note/\(uuid)")
    }
}

// MARK: - Cocoa-Timestamp-Konversion

private let cocoaEpochOffset: TimeInterval = 978307200  // 2001-01-01 - 1970-01-01 in Sekunden

private func dateFromCocoa(_ cocoaSeconds: Double?) -> Date? {
    guard let seconds = cocoaSeconds, seconds > 0 else { return nil }
    return Date(timeIntervalSince1970: seconds + cocoaEpochOffset)
}

// MARK: - Queries

enum NoteStoreQueries {

    /// Alle nicht-gelöschten Notizen mit Titel und Ordnername.
    /// Sortierung: neueste zuerst.
    static func listAllNotes(_ db: Database) throws -> [NoteSummary] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT
                c1.Z_PK            AS note_id,
                c1.ZIDENTIFIER     AS uuid,
                c1.ZTITLE1         AS title,
                c1.ZCREATIONDATE3  AS created,
                c2.ZTITLE2         AS folder_name
            FROM ZICCLOUDSYNCINGOBJECT AS c1
            LEFT JOIN ZICCLOUDSYNCINGOBJECT AS c2 ON c2.Z_PK = c1.ZFOLDER
            WHERE c1.ZTITLE1 IS NOT NULL
              AND (c1.ZMARKEDFORDELETION IS NULL OR c1.ZMARKEDFORDELETION = 0)
              AND (c2.ZFOLDERTYPE IS NULL OR c2.ZFOLDERTYPE != 1)
              AND c1.Z_ENT = 12
            ORDER BY c1.ZCREATIONDATE3 DESC
            """)

        return rows.compactMap { row -> NoteSummary? in
            guard let id: Int64 = row["note_id"],
                  let uuid: String = row["uuid"],
                  let title: String = row["title"]
            else { return nil }

            return NoteSummary(
                id: id,
                uuid: uuid,
                title: title,
                folderName: row["folder_name"],
                createdAt: dateFromCocoa(row["created"])
            )
        }
    }

    /// Baut eine Map `Z_PK → Plaintext` für alle nicht-gelöschten Notizen.
    /// Macht die teure Arbeit (gunzip + Protobuf-Scan) hier; der Aufrufer
    /// kümmert sich nur um's Mergen mit der Notiz-Liste.
    ///
    /// Performance-Hinweis: 1184 Notizen brauchen grob ~500ms (ungecacht).
    /// Cache fügen wir in Slice 2c ein, wenn Re-Builds häufiger werden.
    static func fetchPlaintextMap(_ db: Database) throws -> [Int64: String] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT c1.Z_PK AS note_id, nd.ZDATA AS data
            FROM ZICNOTEDATA AS nd
            JOIN ZICCLOUDSYNCINGOBJECT AS c1 ON c1.Z_PK = nd.ZNOTE
            LEFT JOIN ZICCLOUDSYNCINGOBJECT AS c2 ON c2.Z_PK = c1.ZFOLDER
            WHERE nd.ZDATA IS NOT NULL
              AND c1.Z_ENT = 12
              AND (c1.ZMARKEDFORDELETION IS NULL OR c1.ZMARKEDFORDELETION = 0)
              AND (c2.ZFOLDERTYPE IS NULL OR c2.ZFOLDERTYPE != 1)
            """)

        var result: [Int64: String] = [:]
        result.reserveCapacity(rows.count)
        for row in rows {
            guard let id: Int64 = row["note_id"],
                  let data: Data = row["data"] else { continue }
            let text = PlaintextExtractor.extract(from: data)
            if !text.isEmpty {
                result[id] = text
            }
        }
        return result
    }

    /// Zählt nicht-gelöschte Notizen (ohne Papierkorb).
    static func countNotes(_ db: Database) throws -> Int {
        let count = try Int.fetchOne(db, sql: """
            SELECT COUNT(*)
            FROM ZICCLOUDSYNCINGOBJECT AS c1
            LEFT JOIN ZICCLOUDSYNCINGOBJECT AS c2 ON c2.Z_PK = c1.ZFOLDER
            WHERE c1.ZTITLE1 IS NOT NULL
              AND (c1.ZMARKEDFORDELETION IS NULL OR c1.ZMARKEDFORDELETION = 0)
              AND (c2.ZFOLDERTYPE IS NULL OR c2.ZFOLDERTYPE != 1)
              AND c1.Z_ENT = 12
            """) ?? 0
        return count
    }
}

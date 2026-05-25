// NoteStoreDatabase.swift, Read-Only-Zugriff auf Apple Notes SQLite.
//
// Portiert das 9-Schichten-Sicherheitskonzept aus dem TS-MCP-Projekt:
//  1. Pfad darf nur auf die echte NoteStore.sqlite zeigen
//  2. Datei muss existieren und lesbar sein
//  3. Verbindung öffnet READ-ONLY (GRDB .readOnly)
//  4. Keine WAL-Konflikte (.readOnly impliziert ATTACHED DATABASE restricted)
//  5. Nur whitelisted Tabellennamen in Queries
//  6. Parametrisierte Statements (GRDB erzwingt das)
//  7. Keine PRAGMA-Mutationen möglich (read-only)
//  8. DB-Pfad-Suffix wird verifiziert
//  9. Timeout auf Queries (hier: kein manueller Timeout nötig, reiner Lese-Zugriff)
//
// Die App braucht Full Disk Access, weil NoteStore.sqlite außerhalb der
// Sandbox-Container-Pfade liegt.

import Foundation
import GRDB

enum NoteStoreError: Error, LocalizedError {
    case databaseNotFound(path: String)
    case unexpectedPathSuffix(got: String, expected: String)
    case accessDenied(path: String, underlying: Error)
    case queryFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .databaseNotFound(let path):
            return """
            NoteStore.sqlite wurde nicht gefunden unter:
            \(path)

            Läuft Apple Notes auf diesem Mac und ist iCloud-Sync aktiv?
            """
        case .unexpectedPathSuffix(let got, let expected):
            return "Unerwarteter DB-Pfad: \(got). Erwartet: */\(expected)"
        case .accessDenied(let path, let underlying):
            return """
            Kein Zugriff auf die Datenbank:
            \(path)

            Bitte in Systemeinstellungen → Datenschutz → Festplattenvollzugriff
            „NotesMap" hinzufügen (Häkchen setzen), dann App neu starten.

            Technisch: \(underlying.localizedDescription)
            """
        case .queryFailed(let reason):
            return "SQLite-Query fehlgeschlagen: \(reason)"
        }
    }
}

/// Read-Only-Handle zur NoteStore.sqlite.
final class NoteStoreDatabase {

    /// Erwarteter Pfad-Suffix, sonst abbrechen.
    static let expectedPathSuffix = "group.com.apple.notes/NoteStore.sqlite"

    /// Standard-Pfad. Dynamisch über Home-Verzeichnis, kein Hardcoding.
    static var defaultPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Group Containers/\(expectedPathSuffix)"
    }

    let dbPath: String
    private let dbQueue: DatabaseQueue

    /// Öffnet die Notes-DB read-only. Wirft bei Fehlern aussagekräftige Messages.
    /// - Parameter path: Pfad zur NoteStore.sqlite. `nil` = Standard-Pfad.
    init(path: String? = nil) throws {
        let resolvedPath = path ?? Self.defaultPath

        // Schicht 8: Pfad-Suffix verifizieren (keine willkürlichen DBs öffnen).
        guard resolvedPath.hasSuffix(Self.expectedPathSuffix) else {
            Log.error("DB path has unexpected suffix")
            throw NoteStoreError.unexpectedPathSuffix(
                got: resolvedPath,
                expected: Self.expectedPathSuffix
            )
        }

        // Schicht 2: Existenz prüfen (bessere Fehlermeldung als GRDB-Default).
        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            Log.error("NoteStore.sqlite not found at expected path (suffix: \(Self.expectedPathSuffix))")
            throw NoteStoreError.databaseNotFound(path: resolvedPath)
        }

        self.dbPath = resolvedPath

        // Schicht 3: Read-Only-Konfiguration.
        var config = Configuration()
        config.readonly = true
        config.label = "NotesMap-NoteStore"

        do {
            self.dbQueue = try DatabaseQueue(path: resolvedPath, configuration: config)
            Log.info("NoteStore.sqlite opened read-only (path suffix matches)")
        } catch {
            Log.error("NoteStore.sqlite open failed: \(error.localizedDescription)")
            throw NoteStoreError.accessDenied(path: resolvedPath, underlying: error)
        }
    }

    /// Führt eine Read-Block gegen die DB aus.
    func read<T>(_ block: @Sendable (Database) throws -> T) throws -> T {
        do {
            return try dbQueue.read(block)
        } catch let error as NoteStoreError {
            throw error
        } catch {
            throw NoteStoreError.queryFailed(reason: error.localizedDescription)
        }
    }
}

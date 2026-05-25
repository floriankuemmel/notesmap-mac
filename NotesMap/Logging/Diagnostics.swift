// Diagnostics.swift, One-shot DB diagnostic queries for the log.
//
// Runs at startup right after the NoteStore.sqlite is first opened. Writes
// a snapshot of the user's DB shape (Z_ENT distribution, Z_PRIMARYKEY entity
// names, note counts with and without the Z_ENT filter) to the log so that
// a bug report with the log file alone is enough to pinpoint schema
// mismatches across macOS versions.
//
// Privacy: this module never reads note content, titles, or folder names.
// Only counts and CoreData entity metadata.

import Foundation
import GRDB

enum Diagnostics {

    private static let lock = NSLock()
    private static var hasDumped = false

    /// Dumps diagnostics to the log on first call within a session.
    /// Subsequent calls are no-ops (silent-refresh shouldn't re-dump).
    static func dumpOnceIfNeeded(_ db: NoteStoreDatabase) {
        lock.lock()
        let alreadyDumped = hasDumped
        hasDumped = true
        lock.unlock()
        guard !alreadyDumped else { return }
        dumpToLog(db)
    }

    private static func dumpToLog(_ db: NoteStoreDatabase) {
        let dbPath = db.dbPath
        Log.info("Diagnostics: dumping DB shape (one-shot per session)")

        // 1. File size + modification time of main + companion files
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: dbPath),
           let size = attrs[.size] as? Int64 {
            let sizeMB = Double(size) / 1_048_576
            Log.info(String(format: "DB main file: %.1f MB", sizeMB))
        }
        for suffix in ["-wal", "-shm"] {
            let p = dbPath + suffix
            if let attrs = try? fm.attributesOfItem(atPath: p),
               let size = attrs[.size] as? Int64 {
                Log.info("DB companion\(suffix): \(size / 1024) KB")
            }
        }

        // 2. Z_ENT distribution in ZICCLOUDSYNCINGOBJECT
        if let entCounts: [(Int, Int)] = try? db.read({ database in
            try Row.fetchAll(database, sql: """
                SELECT Z_ENT, COUNT(*) AS n FROM ZICCLOUDSYNCINGOBJECT
                GROUP BY Z_ENT ORDER BY n DESC
                """)
                .compactMap { row -> (Int, Int)? in
                    guard let ent: Int = row["Z_ENT"],
                          let n: Int = row["n"] else { return nil }
                    return (ent, n)
                }
        }) {
            let summary = entCounts.map { "\($0.0):\($0.1)" }.joined(separator: ", ")
            Log.info("Z_ENT distribution in ZICCLOUDSYNCINGOBJECT: { \(summary) }")
        } else {
            Log.warn("Could not query Z_ENT distribution")
        }

        // 3. Z_PRIMARYKEY: maps Z_ENT integers to CoreData entity names.
        // This is the canonical source of truth for which Z_ENT value means
        // "note" on the user's macOS version.
        if let entityMap: [(Int, String)] = try? db.read({ database in
            try Row.fetchAll(database, sql: """
                SELECT Z_ENT, Z_NAME FROM Z_PRIMARYKEY ORDER BY Z_ENT
                """)
                .compactMap { row -> (Int, String)? in
                    guard let ent: Int = row["Z_ENT"],
                          let name: String = row["Z_NAME"] else { return nil }
                    return (ent, name)
                }
        }) {
            let summary = entityMap.map { "\($0.0):\($0.1)" }.joined(separator: ", ")
            Log.info("Z_PRIMARYKEY entity map: { \(summary) }")

            // Surface the Z_ENT that maps to ICNote (or similar) explicitly,
            // since that's the one we hardcode in Queries.swift.
            let noteEntities = entityMap.filter { $0.1.contains("Note") || $0.1.contains("note") }
            if !noteEntities.isEmpty {
                let str = noteEntities.map { "\($0.0)=\($0.1)" }.joined(separator: ", ")
                Log.info("Note-related entities: \(str)")
            }
        } else {
            Log.warn("Could not query Z_PRIMARYKEY (table may not exist on this macOS version)")
        }

        // 4. Note count via our current query (with the hardcoded Z_ENT=12)
        let countWithFilter: Int = (try? db.read { try NoteStoreQueries.countNotes($0) }) ?? -1
        Log.info("Notes via current filter (Z_ENT=12): \(countWithFilter)")

        // 5. Note-like rows count without Z_ENT filter (sanity check)
        let countNoFilter: Int = (try? db.read { database in
            try Int.fetchOne(database, sql: """
                SELECT COUNT(*) FROM ZICCLOUDSYNCINGOBJECT
                WHERE ZTITLE1 IS NOT NULL
                  AND ZCREATIONDATE3 IS NOT NULL
                  AND (ZMARKEDFORDELETION IS NULL OR ZMARKEDFORDELETION = 0)
                """) ?? 0
        }) ?? -1
        Log.info("Notes without Z_ENT filter (sanity): \(countNoFilter)")

        // 6. Anomaly detection: if count is 0 with filter but >0 without, we
        // know the Z_ENT discriminator differs on this macOS version.
        if countWithFilter == 0 && countNoFilter > 0 {
            Log.error("⚠️ Z_ENT MISMATCH DETECTED: hardcoded filter Z_ENT=12 returned 0 notes, but \(countNoFilter) note-like rows exist without the filter. The 'note' entity has a different Z_ENT on this user's macOS version. Check the Z_PRIMARYKEY entity map above to find the correct value.")
        }

        // 7. Account info: how many accounts have notes (via ZACCOUNT7 FK)
        if let accountCount: Int = try? db.read({ database in
            try Int.fetchOne(database, sql: """
                SELECT COUNT(DISTINCT ZACCOUNT7) FROM ZICCLOUDSYNCINGOBJECT
                WHERE ZACCOUNT7 IS NOT NULL
                """) ?? 0
        }) {
            Log.info("Distinct accounts referenced by note rows: \(accountCount)")
        }
    }
}

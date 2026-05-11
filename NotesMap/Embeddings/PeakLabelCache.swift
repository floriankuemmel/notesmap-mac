// PeakLabelCache.swift, Disk-Persistenz für Ollama-generierte Peak-Labels.
//
// Ein Peak-Label via Ollama (z.B. gemma2:9b) kostet 2-5s. Bei 20 Peaks wären
// das ~60-100s pro Höhenkarten-Öffnung. Durch den Cache wird das beim zweiten
// Öffnen (oder nach Slider-Bewegungen) instant.
//
// Cache-Key pro Peak: SHA256(modelName + "|" + sorted_titles + "|" + sorted_snippets).
// Gleicher Cluster → gleiches Label. Titel- UND Snippet-sortiert, damit die
// Reihenfolge der Cluster-Mitglieder egal ist (Peak-Cluster werden räumlich
// gebildet und können sich bei leicht verschobener Bandwidth minimal verändern).
//
// Speicherort: ~/Library/Application Support/NotesMap/peak-labels.json
// Größe: ~40 Bytes pro Eintrag → bei 500 gecachten Peaks grob 20 KB. Vernachlässigbar.

import Foundation
import CryptoKit

/// Thread-sicherer Cache für Ollama-Peak-Labels.
/// - load() einmal beim App-Start (oder lazy).
/// - lookup(hash) / store(hash, label) während der Label-Generierung.
/// - save() debouncet, ruft 500 ms nach letztem store() die Platte.
actor PeakLabelCache {

    struct Entry: Codable, Sendable {
        let label: String
        let createdAt: Double
    }

    struct Payload: Codable, Sendable {
        var version: Int
        var entries: [String: Entry]  // Key: Cluster-Hash

        static let currentVersion = 1
    }

    /// Globaler Singleton, pro App nur ein Cache, damit konkurrierende
    /// Writes sich nicht gegenseitig überschreiben.
    static let shared = PeakLabelCache()

    private var payload: Payload = Payload(version: Payload.currentVersion, entries: [:])
    private var loaded = false
    private var saveTask: Task<Void, Never>?

    // MARK: - Pfad

    /// ~/Library/Application Support/NotesMap/peak-labels.json
    private static var storeURL: URL {
        let fm = FileManager.default
        let appSupport: URL
        if let url = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            appSupport = url
        } else {
            appSupport = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        }
        let dir = appSupport.appendingPathComponent("NotesMap", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // Owner-only directory permissions; siehe EmbeddingCache.storeURL für Begründung.
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir.appendingPathComponent("peak-labels.json", isDirectory: false)
    }

    // MARK: - Laden / Speichern

    /// Lazy-Load: erste Abfrage liest die Datei, alle weiteren sind in-memory.
    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        let url = Self.storeURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return }
        if let decoded = try? JSONDecoder().decode(Payload.self, from: data) {
            if decoded.version == Payload.currentVersion {
                self.payload = decoded
            }
            // Andere Version → ignorieren, starten leer (überschreiben beim
            // ersten Save). Kein explizites Löschen nötig.
        }
    }

    /// Synchrones Schreiben (JSON → Platte). Wird aus debouncedSave() gerufen.
    private func writeNow() {
        let url = Self.storeURL
        do {
            let data = try JSONEncoder().encode(payload)
            try data.write(to: url, options: .atomic)
            // Datei-Permissions: 0600. Peak-Labels enthalten LLM-generierte
            // Themenüberschriften aus Notiz-Inhalten und damit abgeleitete
            // private Information, deshalb owner-only.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            NSLog("[PeakLabelCache] Save fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    /// Verzögertes Schreiben: sammelt Stores innerhalb von 500 ms und schreibt
    /// dann einmal. Verhindert 20 sequentielle Disk-Writes bei einem Batch.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            await self?.writeNow()
        }
    }

    // MARK: - API

    /// Holt ein Label aus dem Cache. Nil = Cache-Miss.
    func lookup(hash: String) -> String? {
        ensureLoaded()
        return payload.entries[hash]?.label
    }

    /// Legt ein Label im Cache ab und plant einen asynchronen Save.
    func store(hash: String, label: String) {
        ensureLoaded()
        payload.entries[hash] = Entry(
            label: label,
            createdAt: Date().timeIntervalSince1970
        )
        scheduleSave()
    }

    /// Hash-Builder: SHA256 aus Modell + sortierten Titeln + sortierten Snippets.
    /// Statische Methode, damit Caller den Hash ohne Actor-Await bauen können
    /// (SHA256 ist pure computation, braucht kein Cache-Zustand).
    static func hash(
        modelName: String,
        titles: [String],
        snippets: [String]
    ) -> String {
        // Sort + join: Cluster-Mitglieder-Reihenfolge ist nicht stabil, also
        // normalisieren wir sie. Titel und Snippets getrennt, damit die
        // Trennung zwischen "zwei Cluster mit vertauschten Titel/Snippet-Rollen"
        // erhalten bleibt (praktisch unmöglich, aber sauber).
        let sortedTitles = titles.sorted().joined(separator: "\n")
        let sortedSnippets = snippets.sorted().joined(separator: "\n")
        let combined = modelName + "||" + sortedTitles + "||" + sortedSnippets
        let digest = SHA256.hash(data: Data(combined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

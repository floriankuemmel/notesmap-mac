// EmbeddingCache.swift: Disk-Persistenz für Embeddings.
//
// Ein Embedding via Ollama/bge-m3 kostet ~100ms. Bei 1.200 Notizen wären das
// ~2min Cold-Start, unzumutbar. Deshalb cachen wir die Vektoren auf Platte.
//
// Cache-Key pro Notiz: SHA256(title + snippet); ändert sich der Inhalt,
// ändert sich der Hash → Neuberechnung. Wechselt das Embedding-Modell,
// kippen wir den gesamten Cache (andere Dimension, andere Skala).
//
// Speicherort: ~/Library/Application Support/NotesMap/embeddings.json
// Größe: grob 12 MB für 1.200 × 1024-dim bge-m3 (JSON ist geschwätzig, passt).

import Foundation
import CryptoKit

enum EmbeddingCache {

    struct Entry: Codable, Sendable {
        let vec: [Float]       // 1024-dim bei bge-m3
        let hash: String       // SHA256 (gekürzt) des embed-Inputs
        let createdAt: Double  // Unix-Timestamp
    }

    struct Payload: Codable, Sendable {
        var model: String
        var version: Int
        var entries: [String: Entry]  // Key: Notiz-UUID (uppercase)

        static let currentVersion = 1
    }

    /// ~/Library/Application Support/NotesMap/embeddings.json
    static var storeURL: URL {
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
        // Verzeichnis-Permissions: 0700, nur Owner darf lesen/listen. Verhindert,
        // dass andere User-Accounts auf demselben Mac den Cache-Inhalt sehen.
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir.appendingPathComponent("embeddings.json", isDirectory: false)
    }

    /// Lädt den Cache. Bei fehlender/kaputter Datei oder Modell-Mismatch
    /// → leere Payload für das erwartete Modell.
    static func load(expectedModel: String) -> Payload {
        let url = storeURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url)
        else {
            return empty(model: expectedModel)
        }

        do {
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            // Andere Version ODER anderes Modell → verwerfen. Mixing von
            // Vektoren aus unterschiedlichen Embedding-Modellen führt zu
            // Gemüseladen-Clustern (andere Skala, andere Achsen).
            guard payload.version == Payload.currentVersion,
                  payload.model == expectedModel
            else {
                NSLog("[EmbeddingCache] Modell/Version-Mismatch (Cache: \(payload.model) v\(payload.version) vs. erwartet: \(expectedModel) v\(Payload.currentVersion)). Starte leer.")
                return empty(model: expectedModel)
            }
            return payload
        } catch {
            NSLog("[EmbeddingCache] Konnte Cache nicht laden: \(error.localizedDescription). Starte leer.")
            return empty(model: expectedModel)
        }
    }

    /// Schreibt den Cache atomar auf Platte.
    static func save(_ payload: Payload) throws {
        let enc = JSONEncoder()
        // Float-Ausgabe: JSONEncoder schreibt Double-Precision. Kein Setup nötig.
        let data = try enc.encode(payload)
        let url = storeURL
        try data.write(to: url, options: .atomic)
        // Datei-Permissions: 0600. Embedding-Vektoren sind ein abgeleiteter
        // Privacy-Artefakt (Topic-Reconstruction über Cosine-Similarity möglich),
        // daher dürfen weder Group noch Other lesen.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    /// Löscht den Cache, z.B. für den "Neu berechnen"-Menüpunkt.
    static func deleteAll() {
        try? FileManager.default.removeItem(at: storeURL)
    }

    /// SHA256(text) → 16 Hex-Zeichen. Reicht, um Content-Änderungen zu erkennen.
    /// (64 Bit Entropie → Kollisions-Wahrscheinlichkeit praktisch 0 bei 1.200 Items.)
    static func hash(_ text: String) -> String {
        guard let data = text.data(using: .utf8) else { return "" }
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    private static func empty(model: String) -> Payload {
        Payload(model: model, version: Payload.currentVersion, entries: [:])
    }
}

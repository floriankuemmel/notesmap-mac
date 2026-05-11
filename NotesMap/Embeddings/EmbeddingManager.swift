// EmbeddingManager.swift: Actor, orchestriert den Embedding-Batch-Run.
//
// Pipeline:
//   1. Cache laden (Modell-versioniert; Mismatch → leer)
//   2. Für jedes Item den Hash (SHA256 des Input-Texts) bilden
//   3. Cache-Hit: Entry direkt ins Ergebnis übernehmen
//   4. Cache-Miss: an EmbeddingService schicken, neue Entry anlegen
//   5. Verwaiste Cache-Entries aufräumen (Notiz gelöscht → Entry weg)
//   6. Cache auf Platte schreiben
//   7. [UUID: [Float]] an Caller liefern
//
// Concurrency: Actor serialisiert parallel laufende Batch-Runs, damit der
// Cache nicht durcheinandergerät. Einzelne Embedding-Requests gehen
// sequenziell an Ollama; der Service hat intern eine Queue, mehr
// Parallelität bringt nichts und macht die Error-Handhabung nur komplizierter.
//
// Progress-Callback (optional, @Sendable) feuert nach jedem fertig
// berechneten Embedding, damit die UI einen Fortschrittsbalken zeigen kann.
// Der Caller muss selbst auf MainActor hopsen, falls nötig.

import Foundation

actor EmbeddingManager {
    private let service: EmbeddingService

    init(service: EmbeddingService = EmbeddingService()) {
        self.service = service
    }

    struct Item: Sendable {
        let uuid: String    // Notiz-UUID (uppercase)
        let text: String    // Input, typisch "Titel\n\nSnippet"
    }

    struct Progress: Sendable {
        let done: Int        // gesamt abgehakt (cached + computed)
        let total: Int       // Anzahl Items
        let cached: Int      // aus Cache gelesen
        let computed: Int    // neu via Ollama berechnet

        var fraction: Double { total > 0 ? Double(done) / Double(total) : 1 }
    }

    /// Prüft Ollama-Verfügbarkeit, bevor wir einen teuren Batch starten.
    func checkAvailability() async -> Result<Void, EmbeddingService.ServiceError> {
        await service.checkAvailability()
    }

    /// Liefert Embeddings für alle Items. Nutzt Cache, wo möglich.
    /// - progress: Optionaler Fortschritts-Callback (Sendable).
    ///             Wird in Actor-Context gefeuert; Caller macht ggf. `Task { @MainActor ... }`.
    func embeddings(
        for items: [Item],
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> [String: [Float]] {
        var cache = EmbeddingCache.load(expectedModel: service.model)

        var result: [String: [Float]] = [:]
        var toCompute: [(item: Item, hash: String)] = []

        // Phase 1: Cache-Check, O(n), hash-Berechnung dominiert
        for item in items {
            let h = EmbeddingCache.hash(item.text)
            if let entry = cache.entries[item.uuid], entry.hash == h {
                result[item.uuid] = entry.vec
            } else {
                toCompute.append((item, h))
            }
        }

        let total = items.count
        let cached = result.count
        progress?(Progress(done: cached, total: total, cached: cached, computed: 0))

        // Phase 2: Neu berechnen, sequenziell, damit Ollama nicht überrannt wird
        var computed = 0
        for (item, hash) in toCompute {
            let vec = try await service.embed(item.text)
            result[item.uuid] = vec
            cache.entries[item.uuid] = EmbeddingCache.Entry(
                vec: vec,
                hash: hash,
                createdAt: Date().timeIntervalSince1970
            )
            computed += 1
            progress?(Progress(
                done: cached + computed,
                total: total,
                cached: cached,
                computed: computed
            ))
        }

        // Phase 3: Verwaiste Entries entfernen (Notizen, die gelöscht wurden)
        let activeUuids = Set(items.map(\.uuid))
        cache.entries = cache.entries.filter { activeUuids.contains($0.key) }

        // Phase 4: Cache schreiben, Fehler loggen, aber nicht eskalieren
        //         (Embeddings sind im Speicher schon da, Disk-Write ist Bonus)
        do {
            try EmbeddingCache.save(cache)
        } catch {
            NSLog("[EmbeddingManager] Cache speichern fehlgeschlagen: \(error.localizedDescription)")
        }

        return result
    }
}

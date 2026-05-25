// LinkMapModel.swift: ObservableObject, das die Link-Map-HTML baut und
// den UI-State (loading / error / ready / refreshing) verwaltet.
//
// Drei Refresh-Modi:
//   - `regenerate()`     : harter Reload. HTML wird geleert, LoadingView
//                          zeigt sich. Aufrufer: "Erneut versuchen" nach Fehler.
//   - `silentRefresh()`  : Routing. Wenn HTML noch nicht da ist → voller Build.
//                          Wenn HTML steht → inkrementelles Data-Update.
//                          Aufrufer: ⌘R, Header-Button, File-Watcher.
//   - `silentDataUpdate()` : baut nur den JSON-Payload, kein HTML. Schickt
//                             ihn via Notification an WebView.Coordinator,
//                             der ihn per evaluateJavaScript ins laufende JS
//                             einspeist. Graph bleibt auf Bildschirm, neue
//                             Knoten erscheinen lokal beim Nachbarn und
//                             pulsieren kurz.
//
// NoteStoreWatcher hängt sich an NoteStore.sqlite-wal und ruft bei
// Änderungen (1.5s debounced) `silentRefresh()` auf.

import Foundation
import SwiftUI

@MainActor
final class LinkMapModel: ObservableObject {
    @Published var html: String?
    @Published var errorMessage: String?
    /// True wenn der DB-Zugriff wegen fehlendem Festplattenvollzugriff
    /// scheiterte. ContentView zeigt dann statt der generischen ErrorView
    /// die OnboardingView (mit „Open System Settings"-Button + Auto-Recheck).
    @Published var needsFullDiskAccess: Bool = false
    @Published var statusMessage: String = Localized.string(\.loading)
    @Published var isRefreshing: Bool = false

    /// URL-Basis für Ressourcen (vendor/*.js aus dem App-Bundle).
    /// Wird an WKWebView.loadHTMLString übergeben.
    let baseURL: URL? = Bundle.main.resourceURL

    private var watcher: NoteStoreWatcher?
    private var pendingRefresh: Bool = false

    // MARK: - Heightmap-State
    /// True solange ein Embedding-Batch läuft. Zweite Clicks sind No-Op.
    private var isPreparingHeightmap: Bool = false
    /// Hat die JS-Seite schon einmal Embeddings erhalten? Wenn ja, wird nach
    /// einem Daten-Update (stille Refreshes) automatisch nachberechnet.
    private var heightmapDeliveredOnce: Bool = false

    // MARK: - Actions

    func initialLoad() async {
        await build(quiet: false)
        startWatching()
        // Prefetch: Heightmap (Embeddings → UMAP → Peaks → Ollama-Labels) im
        // Hintergrund vorbauen, sobald die 2D-Link-Map steht. Wenn der User
        // dann auf "Höhenkarte" klickt, ist das Ergebnis schon da; kein
        // 60-Sekunden-Wait.
        // Idempotent: klickt der User während des Prefetch selbst auf
        // Höhenkarte, erkennt `prepareHeightmap()` das via isPreparingHeightmap
        // und ignoriert den Zweit-Aufruf.
        // Stille Fehler (Ollama down): `postHeightmapError` posted nur an das
        // Heightmap-Overlay, das in der 2D-Ansicht noch unsichtbar ist. Beim
        // späteren Klick sieht der User den Fehler dort, identisches Verhalten
        // wie ohne Prefetch.
        if errorMessage == nil {
            prepareHeightmap()
        }
    }

    /// Harter Reload: HTML wird geleert → LoadingView zeigt sich → neu bauen.
    /// Use-Case: Menü ⌘R, "Erneut versuchen"-Button nach Fehler.
    func regenerate() {
        statusMessage = Localized.string(\.statusUpdating)
        html = nil
        errorMessage = nil
        Task { await build(quiet: false) }
    }

    /// Silent-Refresh: HTML bleibt sichtbar, Daten werden inkrementell aktualisiert.
    /// - Wenn HTML noch nicht da ist (Startup) → voller Build.
    /// - Wenn HTML steht → nur JSON-Payload neu bauen und via Notification
    ///   an die WebView schicken. Graph-Positionen, Zoom, Ordner-Auswahl bleiben.
    /// Use-Case: File-Watcher, Header-Refresh-Button, ⌘R.
    func silentRefresh() {
        if isRefreshing {
            // Schon am Bauen. Wir merken uns, dass nach Fertig nochmal
            // gebaut werden soll (damit keine Änderungen verloren gehen).
            pendingRefresh = true
            return
        }
        if html == nil {
            // Cold Start: Voller Build, damit die WebView überhaupt HTML bekommt.
            Task { await build(quiet: true) }
        } else {
            // Warm: nur das JSON-Payload neu schicken.
            Task { await silentDataUpdate() }
        }
    }

    /// Baut nur den JSON-Payload im Hintergrund und postet ihn via Notification.
    /// WebView.Coordinator schickt ihn per evaluateJavaScript an
    /// `window.__applyDataUpdate(...)`. Keine WebView-Reload, keine Fly-In-Animation.
    private func silentDataUpdate() async {
        isRefreshing = true
        do {
            let payload = try await Task.detached(priority: .userInitiated) {
                // autoreleasepool: graph + plaintext + JSON-Payload können bei
                // 1k+ Notizen kurzzeitig 5-15 MB an gebridge­ten NSObjects halten.
                try autoreleasepool {
                    let db = try NoteStoreDatabase()
                    let (graph, snippets) = try db.read {
                        database -> (LinkGraph, [Int64: String]) in
                        let g = try LinkIndexBuilder.build(database)
                        let plaintext = try NoteStoreQueries.fetchPlaintextMap(database)
                        return (g, plaintext)
                    }
                    return try LinkMapHTMLBuilder.buildDataPayload(
                        graph: graph,
                        snippetByNoteId: snippets
                    )
                }
            }.value

            NotificationCenter.default.post(
                name: .linkMapDataUpdated,
                object: nil,
                userInfo: ["payload": payload]
            )
            errorMessage = nil
        } catch {
            // Fehler bei Silent-Update → aktuelle HTML bleibt; wir loggen nur.
            NSLog("[LinkMapModel] Silent-Data-Update fehlgeschlagen: \(error.localizedDescription)")
        }

        isRefreshing = false

        // Während des Updates kam ein neues Signal rein → nochmal.
        if pendingRefresh {
            pendingRefresh = false
            silentRefresh()
        }
    }

    // MARK: - File-Watching

    private func startWatching() {
        guard watcher == nil else { return }
        let walPath = NoteStoreDatabase.defaultPath + "-wal"
        let w = NoteStoreWatcher(path: walPath) { [weak self] in
            // onChange kommt schon auf Main-Queue, aber wir müssen noch
            // in den MainActor-Kontext: kurzer Hop genügt.
            Task { @MainActor [weak self] in
                self?.silentRefresh()
            }
        }
        w.start()
        watcher = w
    }

    // MARK: - Build-Pipeline

    private func build(quiet: Bool) async {
        isRefreshing = true
        Log.info("Build started (quiet=\(quiet))")
        do {
            let rendered = try await Task.detached(priority: .userInitiated) {
                // autoreleasepool: das ist der größte Heap-Spike der App. Vendor-JS
                // (~2 MB), JSON-Payload (~3-5 MB), das fertige HTML (~10-50 MB)
                // plus alle GRDB-Row-Objekte landen kurzzeitig im Pool. Ohne
                // expliziten Drain sieht man im Activity Monitor 50-100 MB Spitze
                // für die Dauer des Builds; mit Pool sinkt das nach return sofort.
                try autoreleasepool {
                    let db = try NoteStoreDatabase()

                    // One-shot diagnostic dump auf den ersten Build. Schreibt
                    // Z_ENT-Verteilung, Z_PRIMARYKEY-Map und Notiz-Zähler in
                    // den Log, damit Bug-Reports mit Log-File reichen, ohne
                    // dass wir Console.app-Anleitungen geben müssen.
                    Diagnostics.dumpOnceIfNeeded(db)

                    let (graph, snippets) = try db.read {
                        database -> (LinkGraph, [Int64: String]) in
                        let g = try LinkIndexBuilder.build(database)
                        let plaintext = try NoteStoreQueries.fetchPlaintextMap(database)
                        return (g, plaintext)
                    }
                    Log.info("Build query OK: graph nodes=\(graph.nodes.count), edges=\(graph.edges.count), snippets=\(snippets.count)")
                    let lang = LanguagePreference.current.resolved
                    return try LinkMapHTMLBuilder.build(
                        graph: graph,
                        snippetByNoteId: snippets,
                        lang: lang
                    )
                }
            }.value
            Log.info("Build HTML rendered, length=\(rendered.count) chars")

            html = rendered
            errorMessage = nil
            needsFullDiskAccess = false
        } catch let error as NoteStoreError {
            // FDA-Fehler bekommen Sonderbehandlung: ContentView routet auf
            // OnboardingView statt der generischen ErrorView.
            if case .accessDenied = error {
                if !(quiet && html != nil) {
                    needsFullDiskAccess = true
                    errorMessage = nil
                    html = nil
                } else {
                    NSLog("[LinkMapModel] Silent-Refresh: FDA verloren. \(error.localizedDescription)")
                }
            } else {
                if quiet && html != nil {
                    NSLog("[LinkMapModel] Silent-Refresh fehlgeschlagen: \(error.localizedDescription)")
                } else {
                    errorMessage = error.localizedDescription
                    html = nil
                }
            }
        } catch {
            if quiet && html != nil {
                // Silent-Refresh-Fehler: aktuelle HTML bleibt sichtbar,
                // wir loggen nur. User merkt davon idealerweise nichts.
                NSLog("[LinkMapModel] Silent-Refresh fehlgeschlagen: \(error.localizedDescription)")
            } else {
                errorMessage = error.localizedDescription
                html = nil
            }
        }

        isRefreshing = false

        // Während des Builds kam ein neues Signal rein → über silentRefresh
        // rerouten, damit je nach Zustand voller Build oder Data-Update passiert.
        if pendingRefresh {
            pendingRefresh = false
            silentRefresh()
        }
    }

    // MARK: - Heightmap

    /// Startet den Embedding-Batch und schickt das Ergebnis per Notification
    /// an die WebView. Wird vom JS-Button getriggert (über WebView-Message →
    /// NotificationCenter.linkMapHeightmapRequested → ContentView).
    /// Idempotent: mehrfache Aufrufe während eines laufenden Batches sind No-Op.
    func prepareHeightmap() {
        guard !isPreparingHeightmap else { return }
        Task { await _prepareHeightmap() }
    }

    private func _prepareHeightmap() async {
        isPreparingHeightmap = true
        defer { isPreparingHeightmap = false }

        postHeightmapProgress(phase: "check", done: 0, total: 0,
                              message: Localized.string(\.statusCheckingOllama))

        // Embedder aus Settings (Cmd+,) oder Default `bge-m3`.
        let service = EmbeddingService(model: OllamaPreferences.embedderModel)
        let manager = EmbeddingManager(service: service)

        // 1. Ollama erreichbar + Modell geladen?
        switch await manager.checkAvailability() {
        case .failure(let err):
            postHeightmapError(err.localizedDescription)
            return
        case .success:
            break
        }

        // 2. Graph + Plaintext lesen und Items bauen (in Task.detached,
        //    damit wir die Main-Actor nicht blockieren).
        postHeightmapProgress(phase: "load", done: 0, total: 0,
                              message: Localized.string(\.statusLoadingNotes))

        let items: [EmbeddingManager.Item]
        do {
            items = try await Task.detached(priority: .userInitiated) {
                // autoreleasepool: graph + plaintext-map zusammen können bei großen
                // Notiz-Stores (1k+ Notizen) 5–20 MB transient halten (GRDB-Rows,
                // gunzip-Buffer, NSStrings für Snippets). Ohne expliziten Drain
                // verbleiben die Pools bis zum Task-Ende, was zusammen mit dem
                // späteren JSON-Encoding kurzzeitig 30–50 MB Heap-Spitze ergibt.
                try autoreleasepool {
                    let db = try NoteStoreDatabase()
                    return try db.read { database -> [EmbeddingManager.Item] in
                        let graph = try LinkIndexBuilder.build(database)
                        let plaintext = try NoteStoreQueries.fetchPlaintextMap(database)
                        return graph.nodes.map { node in
                            // 4000 Zeichen = grob 1000-1200 deutsche Tokens; bleibt
                            // komfortabel unter bge-m3's 8192-Token-Limit und liefert
                            // genug Kontext für lange Notizen (Rezepte, Meeting-Notes,
                            // Reise-Tagebücher, Artikel). Mit 1200 Zeichen wurden bei
                            // längeren Notizen 80% des Inhalts verschenkt und das
                            // Embedding hing am Intro-Abschnitt; das hat "Mischcluster"
                            // erzeugt, wenn der Hauptinhalt ab Zeichen ~1000 begann.
                            let snippet = plaintext[node.noteId] ?? ""
                            let combined = node.title + "\n\n" + snippet
                            let trimmed = combined.prefix(4000)
                            return EmbeddingManager.Item(
                                uuid: node.uuid,
                                text: String(trimmed)
                            )
                        }
                    }
                }
            }.value
        } catch {
            postHeightmapError(error.localizedDescription)
            return
        }

        guard !items.isEmpty else {
            postHeightmapError("Keine Notizen zum Embedden gefunden.")
            return
        }

        // 3. Embeddings holen (mit Progress-Callback an JS).
        let vecs: [String: [Float]]
        do {
            vecs = try await manager.embeddings(for: items) { [weak self] progress in
                Task { @MainActor in
                    self?.postHeightmapProgress(
                        phase: "embed",
                        done: progress.done,
                        total: progress.total,
                        message: "Embeddings: \(progress.done)/\(progress.total) " +
                                 "(Cache: \(progress.cached), Neu: \(progress.computed))"
                    )
                }
            }
        } catch {
            postHeightmapError(error.localizedDescription)
            return
        }

        // 4. JSON-Payload für JS zusammenbauen.
        // autoreleasepool: bei 1k+ Notizen × 768-1024 Floats × 4 B alloziert die
        // JSONEncoder-Pipeline kurzzeitig ~10–30 MB an NSData/NSString-Objekten
        // (Encoder, Output-Buffer, String-Bridge). Das Decode-Mid-Result wird mit
        // dem Pool-Drain sofort frei, statt erst beim nächsten Runloop-Tick.
        struct HeightmapPoint: Encodable { let uuid: String; let vec: [Float] }
        struct HeightmapPayload: Encodable {
            let model: String
            let dim: Int
            let points: [HeightmapPoint]
        }

        let pointCountForLog: Int
        let dimForLog: Int
        let jsonString: String
        do {
            (pointCountForLog, dimForLog, jsonString) = try autoreleasepool {
                let points = items.compactMap { item -> HeightmapPoint? in
                    guard let vec = vecs[item.uuid] else { return nil }
                    return HeightmapPoint(uuid: item.uuid, vec: vec)
                }
                let dim = points.first?.vec.count ?? 0
                let payload = HeightmapPayload(model: service.model, dim: dim, points: points)
                let data = try JSONEncoder().encode(payload)
                let str = String(data: data, encoding: .utf8) ?? ""
                return (points.count, dim, str)
            }
        } catch {
            postHeightmapError("Heightmap-JSON-Serialisierung fehlgeschlagen: \(error.localizedDescription)")
            return
        }

        // 5. Ab an die WebView.
        NotificationCenter.default.post(
            name: .linkMapHeightmapReady,
            object: nil,
            userInfo: ["payload": jsonString]
        )
        heightmapDeliveredOnce = true
        statusMessage = String(format: Localized.string(\.statusHeightmapReady),
                                pointCountForLog, dimForLog)
    }

    private func postHeightmapProgress(phase: String, done: Int, total: Int, message: String) {
        statusMessage = message
        NotificationCenter.default.post(
            name: .linkMapHeightmapProgress,
            object: nil,
            userInfo: [
                "phase": phase,
                "done": done,
                "total": total,
                "message": message
            ]
        )
    }

    private func postHeightmapError(_ message: String) {
        statusMessage = "Heightmap-Fehler: \(message)"
        NotificationCenter.default.post(
            name: .linkMapHeightmapError,
            object: nil,
            userInfo: ["message": message]
        )
    }

    // MARK: - Peak-Labels (Ollama /api/generate)

    /// Pro Ollama-Batch-Generation gültig: späte Antworten eines älteren Batches
    /// sollen nicht auf einen neueren Peak-Satz geschrieben werden. JS hat einen
    /// eigenen Epoch-Check; wir schicken die Epoch aus der JS-Payload 1:1 zurück.
    private var peakLabelsTask: Task<Void, Never>?

    /// Ein einzelner Peak-Cluster, der via Ollama beschriftet werden soll.
    private struct PeakJob: Sendable {
        let index: Int
        let fallback: String
        let samples: [OllamaLabelService.ClusterSample]
    }

    /// Empfängt die peaks-Payload aus der JS-3D-Ansicht und triggert pro Peak
    /// einen Ollama-Call. Antworten fließen inkrementell via
    /// `.linkMapHeightmapLabelsReady` in die WebView zurück.
    /// Idempotent: ein neuer Batch bricht den alten ab (Task-Cancel).
    func requestPeakLabels(userInfo: [AnyHashable: Any]) {
        // Payload → schwache Swift-Struct
        guard let peaksRaw = userInfo["peaks"] as? [[String: Any]] else { return }
        let epoch = (userInfo["epoch"] as? Int) ?? 0

        var jobs: [PeakJob] = []
        jobs.reserveCapacity(peaksRaw.count)
        for p in peaksRaw {
            guard let idx = p["i"] as? Int else { continue }
            let fb = (p["fallback"] as? String) ?? ""
            let notes = (p["notes"] as? [[String: Any]]) ?? []
            let samples: [OllamaLabelService.ClusterSample] = notes.compactMap { entry in
                let t = (entry["title"] as? String) ?? ""
                let s = (entry["snippet"] as? String) ?? ""
                if t.isEmpty && s.isEmpty { return nil }
                return OllamaLabelService.ClusterSample(title: t, snippet: s)
            }
            guard !samples.isEmpty else { continue }
            jobs.append(PeakJob(index: idx, fallback: fb, samples: samples))
        }
        guard !jobs.isEmpty else { return }

        // Alten Batch abbrechen und neuen starten.
        peakLabelsTask?.cancel()
        peakLabelsTask = Task { [weak self] in
            await self?._runPeakLabels(jobs: jobs, epoch: epoch)
        }
    }

    private func _runPeakLabels(jobs: [PeakJob], epoch: Int) async {
        // Generator-Modell aus Settings (Cmd+,). Leerer String = Auto-Pick aus
        // OllamaLabelService.preferredModels.
        let userPick = OllamaPreferences.generatorModel
        let service = OllamaLabelService(model: userPick.isEmpty ? nil : userPick)
        // Modell auflösen: nimmt das erste aus der Präferenzliste, das der User
        // installiert hat. Ollama läuft wahrscheinlich schon (Embeddings liefen
        // gerade), aber ein generatives Modell ist ein anderes als bge-m3.
        let modelName: String
        switch await service.resolveModel() {
        case .failure(let err):
            NSLog("[LinkMapModel] Peak-Labels: Kein Modell verfügbar. \(err.localizedDescription)")
            return
        case .success(let name):
            modelName = name
            NSLog("[LinkMapModel] Peak-Labels mit Modell '\(name)'.")
        }

        // Sequentiell durchlaufen. Parallelisieren könnte 16 Peaks auf 4 Tasks
        // splitten, aber ein 3B-Modell auf ein Ollama-Backend ist typischerweise
        // single-stream schneller als 4× parallel (GPU/Memory-Pressure). Bei
        // <10 Peaks reicht seriell locker.
        struct LabelOut: Encodable { let i: Int; let text: String }
        struct Payload: Encodable {
            let epoch: Int
            let labels: [LabelOut]
            // "done"-Signal am Ende des Batches → JS stellt noch-pending-Labels
            // auf 'failed' (dann sieht der User, dass Ollama hier nicht durchkam).
            let done: Bool?
        }

        // Inline-Helper: ein einzelnes Label (aus Cache oder frisch) an JS posten.
        // Entkoppelt die Post-Logik von der Cache-/Ollama-Entscheidung.
        @Sendable func postLabel(index: Int, text: String) async {
            let payload = Payload(
                epoch: epoch,
                labels: [LabelOut(i: index, text: text)],
                done: nil
            )
            guard let data = try? JSONEncoder().encode(payload),
                  let jsonString = String(data: data, encoding: .utf8) else { return }
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .linkMapHeightmapLabelsReady,
                    object: nil,
                    userInfo: ["payload": jsonString]
                )
            }
        }

        var cacheHits = 0
        var cacheMisses = 0

        for job in jobs {
            if Task.isCancelled { return }

            // Cache-Key: SHA256 über Modell + sortierte Titel + sortierte Snippets.
            // Pure computation, kein Actor-Await nötig.
            let cacheKey = PeakLabelCache.hash(
                modelName: modelName,
                titles: job.samples.map { $0.title },
                snippets: job.samples.map { $0.snippet }
            )

            // Cache-Hit: Label ist in-memory/auf Platte → direkt posten, kein Ollama-Call.
            if let cached = await PeakLabelCache.shared.lookup(hash: cacheKey) {
                cacheHits += 1
                await postLabel(index: job.index, text: cached)
                continue
            }

            // Cache-Miss: Ollama fragen, Ergebnis cachen.
            cacheMisses += 1
            do {
                let text = try await service.generateLabel(
                    for: job.samples, modelName: modelName
                )
                if Task.isCancelled { return }
                if text.isEmpty { continue }
                // Erst cachen, dann posten; Reihenfolge ist egal, aber so
                // stellen wir sicher, dass ein Crash direkt nach Post keinen
                // Cache-Verlust bedeutet (Store ist debouncet, nicht sofort).
                await PeakLabelCache.shared.store(hash: cacheKey, label: text)
                await postLabel(index: job.index, text: text)
            } catch {
                NSLog("[LinkMapModel] Peak-Label #\(job.index) fehlgeschlagen: \(error.localizedDescription)")
                // Weiter mit nächstem Peak. Fallback-Label bleibt sichtbar.
            }
        }

        NSLog("[LinkMapModel] Peak-Labels: \(cacheHits) Cache-Hit(s), \(cacheMisses) Ollama-Call(s).")

        // Batch fertig → JS markiert verbleibende pending-Labels als 'failed',
        // damit der User auf einen Blick sieht, wo Ollama nichts geliefert hat.
        if Task.isCancelled { return }
        let donePayload = Payload(epoch: epoch, labels: [], done: true)
        if let data = try? JSONEncoder().encode(donePayload),
           let jsonString = String(data: data, encoding: .utf8) {
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .linkMapHeightmapLabelsReady,
                    object: nil,
                    userInfo: ["payload": jsonString]
                )
            }
        }
    }
}

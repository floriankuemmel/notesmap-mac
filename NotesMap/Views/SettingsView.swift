// SettingsView.swift: Cmd+, Settings panel for NotesMap.
//
// In v1.0 fokussiert auf die Ollama-Konfiguration: Welcher Embedder, welcher
// Label-Generator? Beide Auswahlen werden in UserDefaults gespeichert und
// vom Embedding-/Label-Service beim nächsten Initialisieren gelesen.
//
// Nicht in v1.0:
//   • In-App-Modell-Pull (kommt in v1.1, ersetzt den Terminal-Schritt)
//   • Sprache-Picker (kommt mit kompletter Localization)
//   • Theme-Auswahl
//
// Die View lädt beim Erscheinen `GET /api/tags` und füllt die Pickers mit
// tatsächlich installierten Modellen. Wenn Ollama nicht läuft, zeigen wir
// einen Hinweis und deaktivieren die Pickers.

import SwiftUI
import AppKit

// MARK: - User Preferences

/// Globaler Wrapper um die NotesMap-bezogenen UserDefaults-Keys.
/// Alle Reads gehen über statische Property-Getter; Writes sind threadsafe
/// (UserDefaults ist auf Apple-Plattformen thread-sicher).
enum OllamaPreferences {
    private static let embedderKey = "ollamaEmbedderModel"
    private static let generatorKey = "ollamaGeneratorModel"

    static let defaultEmbedder = "bge-m3"
    static let defaultGenerator = "" // leer = Auto-Pick aus preferredModels

    static var embedderModel: String {
        get { UserDefaults.standard.string(forKey: embedderKey) ?? defaultEmbedder }
        set { UserDefaults.standard.set(newValue, forKey: embedderKey) }
    }

    /// Leerer String = Auto-Pick (Service nutzt seine preferredModels-Liste).
    static var generatorModel: String {
        get { UserDefaults.standard.string(forKey: generatorKey) ?? defaultGenerator }
        set { UserDefaults.standard.set(newValue, forKey: generatorKey) }
    }
}

// MARK: - Settings Model

@MainActor
final class SettingsModel: ObservableObject {
    enum OllamaState: Equatable {
        case checking
        case unreachable(String)
        case ready(installedModels: [String])
    }

    @Published var ollamaState: OllamaState = .checking
    @Published var embedderSelection: String = OllamaPreferences.embedderModel
    @Published var generatorSelection: String = OllamaPreferences.generatorModel
    @Published var savedAt: Date? = nil

    // MARK: Model pull
    @Published var pullState: PullState = .idle
    @Published var pullModelName: String = ""
    private var pullTask: Task<Void, Never>? = nil

    enum PullState: Equatable {
        case idle
        case pulling(name: String, status: String, fraction: Double, downloaded: Int64, total: Int64)
        case success(name: String)
        case failed(name: String, error: String)
    }

    /// Suggested models with rough size hints (purely cosmetic). The actual
    /// download size comes from Ollama. Embedders first, then label generators.
    static let suggestedModels: [(name: String, size: String, role: String)] = [
        ("nomic-embed-text", "~274 MB", "embedder"),
        ("bge-m3",           "~1.2 GB", "embedder"),
        ("gemma2:2b",        "~1.6 GB", "generator"),
        ("gemma2:9b",        "~5.4 GB", "generator"),
        ("qwen2.5:3b",       "~2 GB",   "generator"),
        ("llama3.2:3b",      "~2 GB",   "generator"),
    ]

    /// Embedder-Heuristik: Modelle, deren Name typischerweise auf Embedding-Use
    /// hinweist. Nicht perfekt, aber besser als alle 50 Modelle in einer Liste.
    private static let embedderHints = ["bge", "embed", "nomic", "minilm", "e5", "gte"]

    func isLikelyEmbedder(_ name: String) -> Bool {
        let lower = name.lowercased()
        return Self.embedderHints.contains { lower.contains($0) }
    }

    func filteredEmbedders(from models: [String]) -> [String] {
        let hits = models.filter { isLikelyEmbedder($0) }
        return hits.isEmpty ? models : hits
    }

    func filteredGenerators(from models: [String]) -> [String] {
        models.filter { !isLikelyEmbedder($0) }
    }

    func reload() async {
        ollamaState = .checking
        var request = URLRequest(url: URL(string: "http://localhost:11434/api/tags")!)
        request.timeoutInterval = 2.0
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                ollamaState = .unreachable("HTTP \( (response as? HTTPURLResponse)?.statusCode ?? 0 )")
                return
            }
            let parsed = try JSONDecoder().decode(TagsResponse.self, from: data)
            let names = parsed.models.map(\.name).sorted()
            ollamaState = .ready(installedModels: names)
        } catch {
            ollamaState = .unreachable(error.localizedDescription)
        }
    }

    func save() {
        OllamaPreferences.embedderModel = embedderSelection
        OllamaPreferences.generatorModel = generatorSelection
        savedAt = Date()
    }

    private struct TagsResponse: Decodable {
        struct Model: Decodable { let name: String }
        let models: [Model]
    }

    // MARK: - Pull endpoint

    /// Streams `POST /api/pull` and updates `pullState`. Each NDJSON line carries
    /// a `status` plus optional `total`/`completed` for download progress.
    /// Re-calling while a pull is active cancels the in-flight one first.
    func pullModel(_ rawName: String) async {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        pullTask?.cancel()
        let task = Task { @MainActor in
            await self.runPull(name: name)
        }
        pullTask = task
        await task.value
    }

    func cancelPull() {
        pullTask?.cancel()
        pullTask = nil
        if case .pulling(let name, _, _, _, _) = pullState {
            pullState = .failed(name: name, error: "Cancelled")
        }
    }

    private func runPull(name: String) async {
        pullState = .pulling(name: name, status: "Starting…", fraction: 0, downloaded: 0, total: 0)

        var request = URLRequest(url: URL(string: "http://localhost:11434/api/pull")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 3600 // bis zu 1h für große Modelle
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["name": name])

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                pullState = .failed(name: name, error: "Ollama HTTP \(http.statusCode)")
                return
            }
            for try await line in bytes.lines {
                if Task.isCancelled { break }
                guard let data = line.data(using: .utf8),
                      let progress = try? JSONDecoder().decode(PullChunk.self, from: data)
                else { continue }

                if let errorMsg = progress.error {
                    pullState = .failed(name: name, error: errorMsg)
                    return
                }

                let total = progress.total ?? 0
                let done = progress.completed ?? 0
                let frac = total > 0 ? Double(done) / Double(total) : 0
                pullState = .pulling(name: name,
                                     status: progress.status ?? "Downloading…",
                                     fraction: frac,
                                     downloaded: done,
                                     total: total)

                if progress.status == "success" {
                    pullState = .success(name: name)
                    await reload()
                    return
                }
            }
            // Stream ended without "success": treat last status as final.
            // Ollama sometimes terminates the stream after writing manifest.
            pullState = .success(name: name)
            await reload()
        } catch {
            if Task.isCancelled {
                pullState = .failed(name: name, error: "Cancelled")
            } else {
                pullState = .failed(name: name, error: error.localizedDescription)
            }
        }
    }

    private struct PullChunk: Decodable {
        let status: String?
        let digest: String?
        let total: Int64?
        let completed: Int64?
        let error: String?
    }
}

// MARK: - View

struct SettingsView: View {
    @StateObject private var model = SettingsModel()

    @State private var language: AppLanguage = LanguagePreference.current

    var body: some View {
        TabView {
            ollamaTab
                .tabItem { Label(Localized.string(\.settingsTab), systemImage: "cpu") }
            languageTab
                .tabItem { Label(Localized.string(\.settingsLanguageTab), systemImage: "globe") }
        }
        .frame(width: 560, height: 480)
        .task { await model.reload() }
    }

    /// Sprach-Picker. Änderung wird sofort persistiert. Settings + WebView reagieren
    /// nach dem nächsten Refresh; die macOS-Menüleiste wird von AppKit nur einmal
    /// beim App-Launch geladen und braucht daher einen Restart, um die neue Sprache
    /// anzunehmen. Wir zeigen einen Restart-Button, sobald der User die Sprache
    /// gegenüber dem Launch-Wert geändert hat.
    @State private var initialLanguageAtLaunch: AppLanguage = LanguagePreference.current

    private var languageTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            Form {
                Section(Localized.string(\.settingsLanguageLabel)) {
                    Picker("", selection: $language) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .onChange(of: language) { _, newValue in
                        LanguagePreference.current = newValue
                    }

                    // Erklärt verständlich, was sofort wechselt vs. was Neustart braucht.
                    Text(Localized.string(\.settingsLanguageRestartHint))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // Restart-Button erscheint nur, wenn die Sprache gegenüber dem
                    // Launch-Stand geändert wurde, also tatsächlich ein Restart was
                    // bringen würde.
                    if language != initialLanguageAtLaunch {
                        Button(Localized.string(\.settingsLanguageRestartButton)) {
                            relaunchApp()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }
            .formStyle(.grouped)
            Spacer()
        }
        .padding(20)
    }

    /// Re-launcht NotesMap. Läuft den aktuellen Prozess kurz weiter, damit das
    /// neue Bundle starten kann, dann beendet sich diese Instanz.
    private func relaunchApp() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    private var ollamaTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                statusBanner
                Divider()
                Form {
                    modelPickers
                    pullSection
                }
                .formStyle(.grouped)
                saveBar
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private var pullSection: some View {
        if case .ready = model.ollamaState {
            Section("Install a new model") {
                HStack(spacing: 8) {
                    TextField("Model name (e.g. nomic-embed-text)",
                              text: $model.pullModelName)
                        .textFieldStyle(.roundedBorder)
                    Button("Pull") {
                        Task { await model.pullModel(model.pullModelName) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.pullModelName.trimmingCharacters(in: .whitespaces).isEmpty
                              || isPulling)
                }
                Text(Localized.string(\.settingsSuggested))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(SettingsModel.suggestedModels, id: \.name) { m in
                        Button {
                            model.pullModelName = m.name
                            Task { await model.pullModel(m.name) }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: m.role == "embedder"
                                      ? "circle.hexagongrid"
                                      : "text.bubble")
                                    .font(.caption2)
                                Text(m.name).font(.caption)
                                Text(m.size).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isPulling)
                    }
                }

                // Progress / status of an active pull
                pullStatusView
            }
        }
    }

    private var isPulling: Bool {
        if case .pulling = model.pullState { return true }
        return false
    }

    @ViewBuilder
    private var pullStatusView: some View {
        switch model.pullState {
        case .idle:
            EmptyView()
        case .pulling(let name, let status, let fraction, let downloaded, let total):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Pulling **\(name)**: \(status)")
                        .font(.callout)
                        .lineLimit(1)
                    Spacer()
                    if total > 0 {
                        Text("\(formatBytes(downloaded)) / \(formatBytes(total)) (\(Int(fraction * 100))%)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Button("Cancel") { model.cancelPull() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
                ProgressView(value: total > 0 ? fraction : nil, total: 1.0)
                    .progressViewStyle(.linear)
            }
            .padding(.top, 4)
        case .success(let name):
            Label("\(name) installed.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
                .padding(.top, 4)
        case .failed(let name, let error):
            Label("\(name): \(error)", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.callout)
                .lineLimit(2)
                .padding(.top, 4)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch model.ollamaState {
        case .checking:
            HStack(spacing: 10) {
                ProgressView().scaleEffect(0.7)
                Text(Localized.string(\.settingsCheckingOllama))
            }
        case .unreachable(let reason):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(Localized.string(\.settingsOllamaUnreachable))
                        .fontWeight(.medium)
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(Localized.string(\.settingsOllamaUnreachableHint))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(Localized.string(\.onbRecheck)) { Task { await model.reload() } }
            }
        case .ready(let installedModels):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: Localized.string(\.settingsOllamaRunningWith), installedModels.count))
                        .fontWeight(.medium)
                    Text(installedModels.isEmpty
                         ? Localized.string(\.settingsNoModels)
                         : installedModels.prefix(6).joined(separator: ", ")
                         + (installedModels.count > 6 ? "…" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(Localized.string(\.onbRecheck)) { Task { await model.reload() } }
            }
        }
    }

    @ViewBuilder
    private var modelPickers: some View {
        if case .ready(let installedModels) = model.ollamaState {
            let embedders = model.filteredEmbedders(from: installedModels)
            let generators = model.filteredGenerators(from: installedModels)

            Section(Localized.string(\.settingsModelEmbedder)) {
                Picker("Model", selection: $model.embedderSelection) {
                    Text("\(Localized.string(\.settingsModelDefault)): \(OllamaPreferences.defaultEmbedder)")
                        .tag(OllamaPreferences.defaultEmbedder)
                    ForEach(embedders, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .pickerStyle(.menu)
                Text(Localized.string(\.settingsEmbedderHint))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(Localized.string(\.settingsModelGenerator)) {
                Picker("Model", selection: $model.generatorSelection) {
                    Text(Localized.string(\.settingsModelAutoPick)).tag("")
                    ForEach(generators, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .pickerStyle(.menu)
                Text(Localized.string(\.settingsGeneratorHint))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Section(Localized.string(\.settingsModelsHeader)) {
                Text(Localized.string(\.settingsInstallOllamaFirst))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var saveBar: some View {
        HStack {
            if let savedAt = model.savedAt {
                Text(String(format: Localized.string(\.settingsSavedAt),
                            savedAt.formatted(date: .omitted, time: .shortened)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(Localized.string(\.settingsSavedHint))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(Localized.string(\.settingsSave)) { model.save() }
                .buttonStyle(.borderedProminent)
                .disabled({
                    if case .ready = model.ollamaState { return false } else { return true }
                }())
        }
    }
}

// MARK: - FlowLayout

/// Simples Flow-Layout für die Suggested-Models-Buttons. SwiftUI hat keinen
/// eingebauten Flow vor macOS 14, und unsere Buttons sollen umbrechen ohne
/// in einer einzigen langen Zeile zu enden. Layout-Protokoll-API (macOS 13+).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x + s.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sv.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}

#Preview {
    SettingsView()
}

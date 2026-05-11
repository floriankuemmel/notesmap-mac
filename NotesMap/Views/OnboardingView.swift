// OnboardingView.swift: First-launch + FDA-fail Welcome screen.
//
// Wird gezeigt:
//   • Beim ersten App-Start (UserDefaults-Flag "onboardingDone" noch false)
//   • Bei jedem späteren Start, wenn der FDA-Check fehlschlägt (z.B. weil
//     der User die Berechtigung in den Systemeinstellungen entzogen hat)
//
// Schritte:
//   1. ✅ Required: Full Disk Access. App testet automatisch via
//      `tryOpenNoteStore()`. Button öffnet System Settings auf der
//      richtigen Seite. Nach Wechsel zurück zur App: erneuter Auto-Check.
//   2. ⚙️ Optional: Ollama für die Höhenkarte. Pingt localhost:11434/api/tags.
//      Skip-Button für User, die Höhenkarte nicht brauchen.
//   3. "Get Started"-Button, nur aktiv wenn FDA gewährt. Setzt UserDefaults-Flag.

import SwiftUI
import AppKit

/// Lightweight ObservableObject für den Onboarding-Flow.
/// Hält FDA + Ollama-Status, triggert Re-Checks bei App-Aktivierung.
@MainActor
final class OnboardingModel: ObservableObject {
    enum FDAStatus: Equatable { case unknown, granted, denied(message: String) }
    enum OllamaStatus: Equatable { case unknown, available, unavailable }

    @Published var fdaStatus: FDAStatus = .unknown
    @Published var ollamaStatus: OllamaStatus = .unknown
    @Published var isCheckingFDA: Bool = false
    @Published var isCheckingOllama: Bool = false

    private static let onboardingDoneKey = "onboardingDone"

    /// Wurde Onboarding mindestens einmal vollständig durchlaufen?
    /// Bei false → wir zeigen es immer beim Start. Bei true → nur wenn FDA fehlt.
    static var hasCompletedOnboarding: Bool {
        UserDefaults.standard.bool(forKey: onboardingDoneKey)
    }

    static func markCompleted() {
        UserDefaults.standard.set(true, forKey: onboardingDoneKey)
    }

    func runAllChecks() async {
        async let fda: () = checkFDA()
        async let oll: () = checkOllama()
        _ = await (fda, oll)
    }

    func checkFDA() async {
        isCheckingFDA = true
        defer { isCheckingFDA = false }
        let result = await Task.detached(priority: .userInitiated) {
            // Versuch, die Notes-DB read-only zu öffnen. Wirft bei FDA-Fehlen
            // .accessDenied, alles andere ist ein anderes Problem.
            do {
                _ = try NoteStoreDatabase()
                return FDAStatus.granted
            } catch let error as NoteStoreError {
                if case .accessDenied(_, _) = error {
                    return FDAStatus.denied(message: error.localizedDescription)
                }
                return FDAStatus.denied(message: error.localizedDescription)
            } catch {
                return FDAStatus.denied(message: error.localizedDescription)
            }
        }.value
        fdaStatus = result
    }

    func checkOllama() async {
        isCheckingOllama = true
        defer { isCheckingOllama = false }
        var request = URLRequest(url: URL(string: "http://localhost:11434/api/tags")!)
        request.timeoutInterval = 1.5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                ollamaStatus = .available
                return
            }
        } catch {
            // Network error / timeout → not running
        }
        ollamaStatus = .unavailable
    }

    func openFDASettings() {
        // Direkt zur Festplattenvollzugriff-Sektion springen
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }

    func openOllamaWebsite() {
        NSWorkspace.shared.open(URL(string: "https://ollama.com")!)
    }
}

// MARK: - Onboarding-View

struct OnboardingView: View {
    @StateObject private var model = OnboardingModel()
    let onComplete: () -> Void

    var canContinue: Bool {
        if case .granted = model.fdaStatus { return true }
        return false
    }

    var body: some View {
        // Kein ScrollView: wir geben dem Content eine ehrliche Größe und
        // lassen das Fenster (windowResizability(.contentSize)) entsprechend
        // wachsen. So kein Scrollbar im Onboarding.
        VStack(spacing: 20) {
            header
            fdaStep
            ollamaStep
            continueButton
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(maxWidth: 720, minHeight: 700, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await model.runAllChecks()
        }
        // Re-Check wenn der User von den System Settings zurück zur App wechselt
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            Task { await model.runAllChecks() }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "map.fill")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
            Text(Localized.string(\.onbWelcome))
                .font(.title)
                .fontWeight(.semibold)
            Text(Localized.string(\.onbSubtitle))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var fdaStep: some View {
        OnboardingStep(
            number: 1,
            title: Localized.string(\.onbFDATitle),
            isOptional: false,
            isComplete: canContinue,
            isChecking: model.isCheckingFDA
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text(Localized.string(\.onbFDADesc))
                    .foregroundStyle(.secondary)

                if !canContinue {
                    HStack(spacing: 12) {
                        Button(Localized.string(\.onbOpenSettings)) {
                            model.openFDASettings()
                        }
                        .buttonStyle(.borderedProminent)
                        Button(Localized.string(\.onbRecheck)) {
                            Task { await model.checkFDA() }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.top, 4)
                } else {
                    Text(Localized.string(\.onbFDAGranted))
                        .foregroundStyle(.green)
                        .font(.callout)
                }
            }
        }
    }

    private var ollamaStep: some View {
        OnboardingStep(
            number: 2,
            title: Localized.string(\.onbOllamaTitle),
            isOptional: true,
            isComplete: model.ollamaStatus == .available,
            isChecking: model.isCheckingOllama
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text(Localized.string(\.onbOllamaDesc))
                    .foregroundStyle(.secondary)

                // Privacy-Disclosure: macht klar, dass Ollama lokal läuft, was an
                // Ollama gesendet wird, und dass nichts das Gerät verlässt. Subtil
                // im Hintergrund (kleinerer Font, Schloss-Icon) damit es nicht den
                // Rest der UI dominiert, aber sichtbar genug, dass der User es
                // bei der Entscheidung "installieren ja/nein" mitliest.
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .padding(.top, 2)
                    Text(Localized.string(\.onbOllamaPrivacy))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 8))

                switch model.ollamaStatus {
                case .available:
                    Text(Localized.string(\.onbOllamaRunning))
                        .foregroundStyle(.green)
                        .font(.callout)
                case .unavailable, .unknown:
                    Text(Localized.string(\.onbOllamaInstallHint))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button(Localized.string(\.onbOpenOllamaCom)) {
                            model.openOllamaWebsite()
                        }
                        .buttonStyle(.bordered)
                        Button(Localized.string(\.onbRecheck)) {
                            Task { await model.checkOllama() }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private var continueButton: some View {
        Button(action: {
            OnboardingModel.markCompleted()
            onComplete()
        }) {
            Text(Localized.string(\.onbGetStarted))
                .font(.title3)
                .frame(minWidth: 200)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!canContinue)
        .help(canContinue
              ? Localized.string(\.onbContinueReady)
              : Localized.string(\.onbContinueHint))
        .padding(.top, 4)
    }
}

// MARK: - Step container

private struct OnboardingStep<Content: View>: View {
    let number: Int
    let title: String
    let isOptional: Bool
    let isComplete: Bool
    let isChecking: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            stepIndicator
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.headline)
                    if isOptional {
                        Text("OPTIONAL")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isComplete ? Color.green.opacity(0.4) : Color.gray.opacity(0.2), lineWidth: 1)
        )
    }

    private var stepIndicator: some View {
        ZStack {
            Circle()
                .fill(isComplete ? Color.green : Color.gray.opacity(0.2))
                .frame(width: 28, height: 28)
            if isChecking {
                ProgressView()
                    .scaleEffect(0.55)
            } else if isComplete {
                Image(systemName: "checkmark")
                    .foregroundStyle(.white)
                    .fontWeight(.bold)
                    .font(.callout)
            } else {
                Text("\(number)")
                    .foregroundStyle(.primary)
                    .fontWeight(.semibold)
            }
        }
    }
}

#Preview {
    OnboardingView(onComplete: {})
        .frame(width: 800, height: 700)
}

// ContentView.swift: Hauptfenster-Inhalt.
//
// Holt die Link-Map-HTML aus LinkMapBuilder und zeigt sie in einer WebView.
// Verwaltet den Loading-State und reagiert auf Refresh-Anfragen (⌘R / Menü).
//
// Beim ersten Start (oder wenn der User onboardingDone gelöscht hat) zeigt
// die View OnboardingView statt direkt die Karte zu laden, der User muss
// einmalig Full Disk Access erteilen.

import SwiftUI

struct ContentView: View {
    @StateObject private var model = LinkMapModel()
    @State private var showOnboarding = !OnboardingModel.hasCompletedOnboarding

    /// True wenn entweder First-Launch ODER FDA wurde nachträglich entzogen
    /// (App lief mal, dann hat der User in den Settings das Häkchen entfernt).
    /// In beiden Fällen wollen wir die schöne OnboardingView zeigen, nicht
    /// die generische ErrorView.
    var shouldShowOnboarding: Bool {
        showOnboarding || model.needsFullDiskAccess
    }

    var body: some View {
        ZStack {
            if shouldShowOnboarding {
                OnboardingView(onComplete: {
                    showOnboarding = false
                    // FDA wurde gerade gewährt, Build erneut anstoßen.
                    if model.needsFullDiskAccess {
                        model.regenerate()
                    }
                })
            } else if let html = model.html {
                WebView(html: html, baseURL: model.baseURL)
                    .ignoresSafeArea()
            } else if let error = model.errorMessage {
                ErrorView(message: error, retry: { model.regenerate() })
            } else {
                LoadingView(message: model.statusMessage)
            }
        }
        .task(id: shouldShowOnboarding) {
            // Erst nach Abschluss von Onboarding loslegen, sonst rennt der
            // initialLoad in einen FDA-Fehler bevor der User die Berechtigung
            // erteilt hat.
            if !shouldShowOnboarding && model.html == nil {
                await model.initialLoad()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .linkMapRefreshRequested)) { _ in
            // Silent-Refresh: HTML bleibt sichtbar, im Hintergrund neu laden.
            // Wenn noch kein HTML da ist (Startup), fällt silentRefresh
            // faktisch auf initialLoad zurück (Build setzt html beim Fertig).
            model.silentRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .linkMapHeightmapRequested)) { _ in
            // User hat die Heightmap-Ansicht angefordert. prepareHeightmap ist
            // idempotent, mehrfache Klicks während eines laufenden Batches
            // werden ignoriert.
            model.prepareHeightmap()
        }
        .onReceive(NotificationCenter.default.publisher(for: .linkMapHeightmapLabelsRequested)) { note in
            // 3D-View hat Peak-Cluster geschickt → Ollama-Labels generieren.
            guard let info = note.userInfo else { return }
            model.requestPeakLabels(userInfo: info)
        }
    }
}

// MARK: - LoadingView

private struct LoadingView: View {
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.4)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - ErrorView

private struct ErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text(Localized.string(\.errorTitle))
                .font(.title2)
                .fontWeight(.semibold)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .textSelection(.enabled)
            Button(Localized.string(\.errorRetry), action: retry)
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ContentView()
        .frame(width: 900, height: 600)
}

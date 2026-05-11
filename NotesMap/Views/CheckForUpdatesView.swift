// CheckForUpdatesView.swift, SwiftUI-Wrapper für Sparkles Update-Check-Aktion.
//
// Sparkles `SPUUpdater` exponiert `canCheckForUpdates` als KVO-Property,
// nicht als @Published. Daher braucht es diesen kleinen ViewModel-Indirect:
// wir publishen den Wert in einer ObservableObject-Klasse, damit das Menü-
// Item korrekt enabled/disabled wird (z.B. während ein Check läuft).
//
// Wird in NotesMapApp.swift in der `.commands { CommandGroup(after: .appInfo) }`
// eingehängt, landet damit als "Check for Updates…" direkt nach "About NotesMap"
// im App-Menü.

import SwiftUI
import Sparkle

struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button(Localized.string(\.menuCheckUpdates), action: updater.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates)
    }
}

@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

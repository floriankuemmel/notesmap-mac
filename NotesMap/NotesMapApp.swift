// NotesMapApp.swift: SwiftUI App-Entry-Point.
// Das ist der @main-Einstiegspunkt. Hält minimal, die gesamte Logik steckt
// in ContentView (UI) und den Services in Notes/ und HTML/.
//
// Sparkle Auto-Update: SPUStandardUpdaterController wird beim App-Start
// instantiiert und checkt periodisch (Default 24h via Info.plist
// SUScheduledCheckInterval) auf neue Versionen. Manueller Check über
// "Check for Updates…" im App-Menü.

import SwiftUI
import Sparkle

@main
struct NotesMapApp: App {
    /// SPUStandardUpdaterController hält den Updater lebendig und gibt uns
    /// die SwiftUI-kompatible API. `startingUpdater: true` startet den
    /// scheduled-check sofort beim App-Launch.
    ///
    /// Bewusst `let` + Init statt `@State`: bei `@State` würde der
    /// Default-Ausdruck (also `SPUStandardUpdaterController(...)`) bei jeder
    /// Rematerialisierung der App-Struct erneut ausgewertet, der neue
    /// Controller würde sofort einen Update-Check starten und SwiftUI würde
    /// die Instanz danach verwerfen. Mit `let` gibt es genau einen Controller
    /// für die gesamte App-Lebensdauer (siehe Sparkles offizielles SwiftUI-Beispiel).
    private let updaterController: SPUStandardUpdaterController

    init() {
        // Sprachpräferenz auf AppleLanguages spiegeln, BEVOR AppKit das System-Menü
        // initialisiert. Sonst rendert AppKit Ablage/Bearbeiten/etc. in der falschen
        // Sprache. SwiftUI's @main App.init läuft früh genug, dass AppKit den
        // Override bei der ersten NSApplication-Auflösung aufgreift.
        LanguagePreference.applyToAppleLanguages()

        // Diagnostic-Logger starten. Rotiert den vorherigen Session-Log, schreibt
        // Session-Header mit App-Version, macOS-Version, Architektur. Alle
        // weiteren Log-Punkte landen in ~/Library/Logs/NotesMap/NotesMap.log.
        Log.startSession()
        Log.info("App.init starting")

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        Log.info("App.init done")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowResizability(.contentSize)
        .commands {
            // App-Menü: "Check for Updates…" direkt nach "About NotesMap"
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
            // Refresh-Shortcut ⌘R
            CommandGroup(after: .toolbar) {
                Button(Localized.string(\.menuRefresh)) {
                    NotificationCenter.default.post(name: .linkMapRefreshRequested, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
            }
            // Hilfe-Menü: ersetzt SwiftUI's Default-Help-Item, das auf eine
            // nicht vorhandene HelpBook verlinken würde. Stattdessen öffnen wir
            // das eigene HelpView-Fenster (Window-Scene unten). ⌘? ist die
            // macOS-Standard-Tastenkombination für Hilfe.
            //
            // Zusätzlich: Diagnostic-Log-Menüpunkte. Privacy-sicher (kein
            // Inhalt, nur Counts + Status). User sieht den Log selbst, bevor
            // er ihn weiterschickt — keine versteckte Telemetrie.
            CommandGroup(replacing: .help) {
                OpenHelpMenuButton()
                Divider()
                Button("Show Diagnostic Log in Finder") {
                    Log.revealLogInFinder()
                }
                .keyboardShortcut("L", modifiers: [.command, .option])
                Button("Copy Diagnostic Log to Clipboard") {
                    Log.copyCurrentLogToClipboard()
                }
            }
        }
        // Cmd+, Settings: Ollama-Modell-Auswahl, später auch Sprache.
        Settings {
            SettingsView()
        }
        // Hilfe-Fenster: eigene Window-Scene mit fester ID. Wird vom Menü-Button
        // über @Environment(\.openWindow) angezeigt, das ist der saubere
        // SwiftUI-Pattern für sekundäre Fenster.
        Window(Localized.string(\.helpWindowTitle), id: NotesMapApp.helpWindowID) {
            HelpView()
        }
        .windowResizability(.contentSize)
    }

    static let helpWindowID = "notesmap-help"
}

/// Kleiner Button-Wrapper, damit `@Environment(\.openWindow)` aufgelöst werden
/// kann. SwiftUI ruft den Closure eines `Button` direkt im Click-Handler auf,
/// dort gibt es keinen Zugriff auf das Environment des umliegenden Command-
/// Blocks. Der Wrapper-View rendert den Button und reicht die Action durch.
private struct OpenHelpMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(Localized.string(\.menuHelp)) {
            openWindow(id: NotesMapApp.helpWindowID)
        }
        .keyboardShortcut("?", modifiers: [.command])
    }
}

extension Notification.Name {
    /// Wird vom Refresh-Menüpunkt gepostet, von ContentView/WebView empfangen.
    static let linkMapRefreshRequested = Notification.Name("linkMapRefreshRequested")

    /// Wird vom LinkMapModel nach einem inkrementellen Data-Update gepostet.
    /// userInfo["payload"]: String mit JSON für window.__applyDataUpdate(...).
    /// WebView.Coordinator hört zu und evaluiert das JS im laufenden WKWebView.
    static let linkMapDataUpdated = Notification.Name("linkMapDataUpdated")

    /// JS → Swift: User hat die Höhenkarte angefordert (erster Klick auf
    /// den Heightmap-Button). ContentView ruft daraufhin `prepareHeightmap()`.
    static let linkMapHeightmapRequested = Notification.Name("linkMapHeightmapRequested")

    /// Swift → JS: Zwischenstand der Embedding-Berechnung.
    /// userInfo: ["phase": String, "done": Int, "total": Int, "message": String]
    static let linkMapHeightmapProgress = Notification.Name("linkMapHeightmapProgress")

    /// Swift → JS: Embeddings sind fertig, Payload ist bereit zum Rendern.
    /// userInfo["payload"]: String mit JSON für window.__applyHeightmap(...).
    static let linkMapHeightmapReady = Notification.Name("linkMapHeightmapReady")

    /// Swift → JS: Fehler beim Embedding (Ollama nicht erreichbar,
    /// Modell fehlt, Netzwerk-Timeout).
    /// userInfo["message"]: String mit dem lokalisierten Fehler.
    static let linkMapHeightmapError = Notification.Name("linkMapHeightmapError")

    /// JS → Swift: Cluster-Notizen pro Peak, für Ollama-basierte Themen-Labels.
    /// userInfo["peaks"]: [[String: Any]] mit "i": Int, "fallback": String,
    ///                    "notes": [["title": String, "snippet": String]]
    /// userInfo["epoch"]: Int, identifiziert den Peak-Satz (stale-Schutz).
    static let linkMapHeightmapLabelsRequested = Notification.Name("linkMapHeightmapLabelsRequested")

    /// Swift → JS: Ein oder mehrere generierte Labels.
    /// userInfo["payload"]: String mit JSON `{"epoch":N, "labels":[{"i":..., "text":...}]}`.
    static let linkMapHeightmapLabelsReady = Notification.Name("linkMapHeightmapLabelsReady")
}

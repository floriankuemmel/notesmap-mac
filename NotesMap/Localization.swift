// Localization.swift: zentrale Übersetzungstabelle für NotesMap.
//
// Kein Localizable.xcstrings-File nötig: alle UI-Strings stehen in der
// `Translations`-Struct als (de, en)-Paare. Das hat zwei Vorteile:
//  1. Werte sind im Code nahe der Verwendung, leicht durchsuchbar
//  2. Der HTMLBuilder bekommt eine `Localized`-Instanz übergeben und kann
//     daraus pro Build die richtigen Strings ins HTML einsetzen, statt
//     selbst Bundle.localizedString(...) zu rufen
//
// User wählt Sprache in Settings → UserDefaults → AppLanguage. App liest
// das beim Start und propagiert es an alle Strings + den HTMLBuilder.

import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system = "system"
    case english = "en"
    case german = "de"

    var id: String { rawValue }

    /// Resolved locale: bei `.system` aus den User-Präferenzen ableiten.
    /// Wichtig: `Locale.current` zeigt die App-Bundle-Locale, nicht das echte
    /// System-Setting. Apps ohne dedizierte Localizable.xcstrings/Lproj-Resources
    /// bekommen über Locale.current immer "en", selbst auf einem deutschen Mac.
    /// `Locale.preferredLanguages.first` ist der vom User in den System-Settings
    /// präferierte Wert (z.B. "de-DE").
    var resolved: Localized.Lang {
        switch self {
        case .english: return .en
        case .german: return .de
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "en"
            let primary = preferred.split(separator: "-").first.map(String.init) ?? "en"
            return primary.lowercased() == "de" ? .de : .en
        }
    }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .english: return "English"
        case .german: return "Deutsch"
        }
    }
}

/// Globale Sprachpräferenz, persistiert in UserDefaults. Default: system.
enum LanguagePreference {
    private static let key = "appLanguage"

    /// Apples eigene UserDefaults-Konvention für Bundle-Localization.
    /// AppKit liest diesen Schlüssel beim Bundle-Init, um zu entscheiden
    /// welche Sprache für das System-Menü (Ablage/File, Bearbeiten/Edit,
    /// Darstellung/View, Fenster/Window, Hilfe/Help) und alle Standard-
    /// Dialog-Buttons (Cancel/Abbrechen, OK, Save/Sichern, ...) verwendet wird.
    private static let appleLanguagesKey = "AppleLanguages"

    static var current: AppLanguage {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key),
                  let lang = AppLanguage(rawValue: raw) else {
                return .system
            }
            return lang
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            applyToAppleLanguages()
        }
    }

    /// Schreibt die aktuelle Sprachpräferenz in den `AppleLanguages`-Schlüssel,
    /// damit AppKit sie beim nächsten App-Launch aufgreift. Muss in
    /// `NotesMapApp.init()` einmal aufgerufen werden, bevor SwiftUI das erste
    /// Window aufbaut, sonst liest AppKit den alten Stand.
    ///
    /// Achtung: AppKit lädt das Menü nur einmal beim App-Launch. Eine Laufzeit-
    /// Änderung der Sprache wirkt erst nach Neustart auf das System-Menü
    /// (auf unsere eigenen Localized.string-Aufrufe wirkt sie sofort).
    static func applyToAppleLanguages() {
        switch current {
        case .system:
            // Kein Override, System-Default greift.
            UserDefaults.standard.removeObject(forKey: appleLanguagesKey)
        case .english:
            UserDefaults.standard.set(["en"], forKey: appleLanguagesKey)
        case .german:
            UserDefaults.standard.set(["de"], forKey: appleLanguagesKey)
        }
    }
}

/// Zentrale Übersetzungstabelle. Alle UI-Strings als `(de, en)`-Paare.
/// Aufruf: `Localized.string(\.refreshMenu)` (nutzt aktuelle Pref) oder
/// `Localized.string(\.refreshMenu, in: .en)` (explizit).
struct Localized {
    enum Lang { case de, en }

    typealias T2 = (String, String)

    /// Convenience-Lookup für die aktuelle UserDefaults-Sprache.
    static func string(_ keyPath: KeyPath<Localized, T2>) -> String {
        let lang = LanguagePreference.current.resolved
        let pair = Localized()[keyPath: keyPath]
        return lang == .de ? pair.0 : pair.1
    }

    /// Direkter Lookup mit explizitem Locale (für HTMLBuilder).
    static func string(_ keyPath: KeyPath<Localized, T2>, in lang: Lang) -> String {
        let pair = Localized()[keyPath: keyPath]
        return lang == .de ? pair.0 : pair.1
    }

    // MARK: - App-Shell / SwiftUI

    let menuRefresh: T2 = ("Neu laden aus Apple Notes", "Reload from Apple Notes")
    let menuCheckUpdates: T2 = ("Nach Updates suchen…", "Check for Updates…")
    let menuHelp: T2 = ("NotesMap-Hilfe", "NotesMap Help")
    let helpWindowTitle: T2 = ("NotesMap-Hilfe", "NotesMap Help")
    let helpSidebarOverview: T2 = ("Übersicht", "Overview")
    let helpSidebarViews: T2 = ("Ansichten", "Views")
    let helpSidebarControls: T2 = ("Bedienung", "Controls")
    let helpSidebarShortcuts: T2 = ("Tastenkürzel", "Keyboard Shortcuts")
    let helpSidebarHeightmap: T2 = ("Höhenkarte", "Heightmap")
    let helpSidebarPrivacy: T2 = ("Datenschutz", "Privacy")
    let helpSidebarTroubleshooting: T2 = ("Probleme lösen", "Troubleshooting")
    let helpSidebarAbout: T2 = ("Über NotesMap", "About NotesMap")
    let helpReportBug: T2 = ("Fehler melden", "Report a Bug")
    let helpOpenRepo: T2 = ("Quellcode auf GitHub", "Source on GitHub")
    let helpOpenLicense: T2 = ("Lizenz öffnen", "Open License")

    let errorTitle: T2 = ("Konnte Notizen nicht laden", "Couldn't load notes")
    let errorRetry: T2 = ("Erneut versuchen", "Retry")
    let loading: T2 = ("Lade Apple Notes…", "Loading Apple Notes…")

    // Status-Messages (Pipeline)
    let statusUpdating: T2 = ("Aktualisiere…", "Updating…")
    let statusCheckingOllama: T2 = ("Prüfe Ollama-Verfügbarkeit…", "Checking Ollama availability…")
    let statusLoadingNotes: T2 = ("Lade Notizen & Snippets…", "Loading notes & snippets…")
    /// Format-String mit zwei %d für Punkte + Dimensionen.
    let statusHeightmapReady: T2 = ("Höhenkarte bereit (%d Punkte, %d-dim).", "Heightmap ready (%d points, %d-dim).")

    // MARK: - Onboarding

    let onbWelcome: T2 = ("Willkommen bei NotesMap", "Welcome to NotesMap")
    let onbSubtitle: T2 = (
        "Lass uns NotesMap einrichten. Dauert ungefähr eine Minute.",
        "Let's get you set up. This takes about a minute."
    )
    let onbFDATitle: T2 = ("Festplattenvollzugriff erteilen", "Grant Full Disk Access")
    let onbFDADesc: T2 = (
        "NotesMap liest die Apple-Notes-Datenbank direkt (read-only). macOS schützt diese Datei mit Festplattenvollzugriff.",
        "NotesMap reads your Apple Notes database directly (read-only). macOS protects this file behind Full Disk Access."
    )
    let onbFDAGranted: T2 = (
        "Festplattenvollzugriff erteilt. NotesMap kann deine Notizen lesen.",
        "Full Disk Access granted. NotesMap can read your Notes."
    )
    let onbOpenSettings: T2 = ("Systemeinstellungen öffnen", "Open System Settings")
    let onbRecheck: T2 = ("Erneut prüfen", "Re-check")
    let onbOptional: T2 = ("OPTIONAL", "OPTIONAL")
    let onbOllamaTitle: T2 = ("Optional: Ollama installieren", "Optional: Install Ollama")
    let onbOllamaDesc: T2 = (
        "Ollama wird nur für die KI-Cluster-Labels in der Höhenkarte gebraucht. NotesMap funktioniert auch ohne; die anderen 7 Ansichten sind unabhängig davon.",
        "Ollama is needed only for the Heightmap view's AI cluster labels. NotesMap works fully without it; the other 7 views are unaffected."
    )
    let onbOllamaPrivacy: T2 = (
        "Datenschutz: Ollama läuft lokal auf deinem Mac (localhost:11434), kein Cloud-Service. Beim Öffnen der Höhenkarte schickt NotesMap pro Notiz den Titel + die ersten ~4000 Zeichen an Ollama für Embeddings und Cluster-Labels. Alles bleibt auf deinem Gerät; Embeddings werden in ~/Library/Application Support/NotesMap/ gecacht (owner-only, 0600).",
        "Privacy: Ollama runs locally on your Mac (localhost:11434), it is not a cloud service. When you open the Heightmap, NotesMap sends each note's title and first ~4000 characters to Ollama to compute embeddings and cluster labels. Everything stays on your device; embeddings are cached in ~/Library/Application Support/NotesMap/ (owner-only, 0600)."
    )
    let onbOllamaRunning: T2 = (
        "Ollama läuft. Die Höhenkarte kann KI-generierte Cluster-Labels nutzen.",
        "Ollama is running. The Heightmap view can use AI-generated cluster labels."
    )
    let onbOllamaInstallHint: T2 = (
        "Wenn du später Labels willst: Ollama installieren, dann „ollama pull bge-m3\" und „ollama pull gemma2:2b\" im Terminal ausführen. Kleinere Modelle gehen auch, siehe README.",
        "If you want labels later: install Ollama, then run \"ollama pull bge-m3\" and \"ollama pull gemma2:2b\" in Terminal. Smaller models work too, see the README."
    )
    let onbOpenOllamaCom: T2 = ("ollama.com öffnen", "Open ollama.com")
    let onbGetStarted: T2 = ("Los geht's", "Get Started")
    let onbContinueHint: T2 = (
        "Erteile zuerst Festplattenvollzugriff",
        "Grant Full Disk Access first"
    )
    let onbContinueReady: T2 = ("Weiter zu NotesMap", "Continue to NotesMap")

    // MARK: - Settings

    let settingsTab: T2 = ("Ollama", "Ollama")
    let settingsLanguageTab: T2 = ("Sprache", "Language")
    let settingsLanguageLabel: T2 = ("Sprache", "Language")
    let settingsCheckingOllama: T2 = ("Prüfe Ollama…", "Checking Ollama…")
    let settingsOllamaUnreachable: T2 = ("Ollama nicht erreichbar", "Ollama not reachable")
    let settingsOllamaRunning: T2 = ("Ollama läuft", "Ollama running")
    let settingsModelEmbedder: T2 = ("Embedding-Modell (Höhenkarte-Clustering)", "Embedding model (Heightmap clustering)")
    let settingsModelGenerator: T2 = ("Label-Generator-Modell (Peak-Beschriftungen)", "Label-generator model (Heightmap peaks)")
    let settingsModelDefault: T2 = ("Standard", "Default")
    let settingsModelAutoPick: T2 = ("Auto-Auswahl (empfohlen)", "Auto-pick (recommended)")
    let settingsInstallNew: T2 = ("Neues Modell installieren", "Install a new model")
    let settingsModelNamePlaceholder: T2 = ("Modellname (z.B. nomic-embed-text)", "Model name (e.g. nomic-embed-text)")
    let settingsPull: T2 = ("Pullen", "Pull")
    let settingsCancel: T2 = ("Abbrechen", "Cancel")
    let settingsSuggested: T2 = ("Vorschläge:", "Suggested:")
    let settingsSave: T2 = ("Speichern", "Save")
    let settingsSavedHint: T2 = (
        "App neu starten, damit die Änderungen wirksam werden.",
        "Restart the app for changes to take effect."
    )
    let settingsLanguageRestartHint: T2 = (
        "Die meisten Bereiche wechseln sofort. Die macOS-Menüleiste oben (Ablage, Bearbeiten, Darstellung, Fenster, Hilfe) übernimmt die neue Sprache erst nach einem Neustart der App.",
        "Most areas switch immediately. The macOS menu bar at the top (File, Edit, View, Window, Help) only picks up the new language after restarting the app."
    )
    let settingsLanguageRestartButton: T2 = (
        "Jetzt neu starten",
        "Restart now"
    )
    let settingsOllamaUnreachableHint: T2 = (
        "Starte die Ollama-Menüleisten-App, oder installiere sie von ollama.com falls nicht vorhanden. Die KI-Labels der Höhenkarte brauchen Ollama; alles andere funktioniert ohne.",
        "Start the Ollama menu-bar app, or install it from ollama.com if missing. The Heightmap view's AI labels need Ollama; everything else works without it."
    )
    let settingsOllamaRunningWith: T2 = (
        "Ollama läuft, %d Modell(e) installiert",
        "Ollama running, %d model(s) installed"
    )
    let settingsNoModels: T2 = (
        "Noch keine Modelle installiert. Pull eines mit `ollama pull bge-m3`",
        "No models installed yet. Pull one with `ollama pull bge-m3`"
    )
    let settingsEmbedderHint: T2 = (
        "Wird verwendet um Notizen-Ähnlichkeit für die Höhenkarte zu berechnen. Kleinere Alternativen wie `nomic-embed-text` (~274 MB) sind super wenn Plattenplatz wichtig ist.",
        "Used to compute note similarities for the heightmap. Smaller alternatives like `nomic-embed-text` (~274 MB) are great if disk space matters."
    )
    let settingsGeneratorHint: T2 = (
        "Generiert kurze Labels für Notiz-Cluster. Auto-Auswahl arbeitet eine Präferenzliste ab und wählt das hochwertigste verfügbare Modell.",
        "Generates short labels for note clusters. Auto-pick walks a preference list and chooses the highest-quality model that's installed."
    )
    /// "Saved at HH:MM. Restart…", Format-String mit einem %@
    let settingsSavedAt: T2 = (
        "Gespeichert um %@. App neu starten, damit die Änderungen wirksam werden.",
        "Saved at %@. Restart the app for changes to take effect."
    )
    let settingsModelsHeader: T2 = ("Modelle", "Models")
    let settingsInstallOllamaFirst: T2 = (
        "Installiere und starte Ollama, um Modelle zu konfigurieren.",
        "Install Ollama and start it to configure models."
    )
    /// "Pulling NAME, STATUS"; der Caller füllt die Platzhalter selbst.
    let settingsPullingPrefix: T2 = ("Pulle", "Pulling")
    let settingsPullSuccess: T2 = ("installiert.", "installed.")

    // MARK: - HTML / WebView

    let appTitle: T2 = ("NotesMap", "NotesMap")
    let viewLabel2D: T2 = ("2D", "2D")
    let viewLabelRadial: T2 = ("Radial", "Radial")
    let viewLabelRadial2: T2 = ("Radial 2", "Radial 2")
    let viewLabelCircos: T2 = ("Circos", "Circos")
    let viewLabelCalendar: T2 = ("Tage", "Days")
    let viewLabelMonthly: T2 = ("Monate", "Months")
    let viewLabelHeightmap: T2 = ("Höhenkarte", "Heightmap")
    let viewLabel3D: T2 = ("3D", "3D")

    let filterAll: T2 = ("Alle", "All")
    let filterFolders: T2 = ("Ordner", "Folders")
    let filterTags: T2 = ("Tags", "Tags")
    let filterReset: T2 = ("Auswahl zurücksetzen (Esc)", "Reset selection (Esc)")
    let filterEmpty: T2 = ("Keine Tags vorhanden", "No tags available")

    let timelineToday: T2 = ("heute", "today")
    let timelinePlay: T2 = ("Abspielen", "Play")
    let timelinePause: T2 = ("Pause", "Pause")

    let panelOpenInNotes: T2 = ("In Notes öffnen", "Open in Notes")
    let panelLinks: T2 = ("Verlinkungen", "Links")
    let panelOrphans: T2 = ("Unverlinkt", "Orphans")
    let panelHubs: T2 = ("Hubs", "Hubs")

    let heightmapEmbedding: T2 = ("Berechne Embeddings…", "Computing embeddings…")
    let heightmapClustering: T2 = ("Erkenne Cluster…", "Detecting clusters…")
    let heightmapLabeling: T2 = ("Generiere Labels…", "Generating labels…")
    let heightmapDone: T2 = ("Fertig", "Done")

    let updateAvailable: T2 = ("Update verfügbar", "Update available")

    // MARK: - Service-Errors (Embedding + Label)

    /// Format: "Ollama nicht erreichbar (...). REASON". Caller hängt reason an.
    let errOllamaUnreachable: T2 = (
        "Ollama nicht erreichbar (http://localhost:11434).",
        "Ollama not reachable (http://localhost:11434)."
    )
    /// Format-String mit einem %@ für Modellnamen.
    let errModelNotLoaded: T2 = (
        "Modell „%@\" nicht in Ollama vorhanden. Terminal: `ollama pull %@`",
        "Model \"%@\" not in Ollama. Terminal: `ollama pull %@`"
    )
    /// Format mit %d (HTTP-Code) und %@ (Body).
    let errOllamaHTTP: T2 = (
        "Ollama-HTTP-Fehler %d: %@",
        "Ollama HTTP error %d: %@"
    )
    let errEmbeddingDecodeFail: T2 = (
        "Konnte Ollama-Antwort nicht parsen (kein `embedding`-Feld).",
        "Couldn't parse Ollama response (no `embedding` field)."
    )
    let errLabelDecodeFail: T2 = (
        "Konnte Ollama-Antwort nicht parsen.",
        "Couldn't parse Ollama response."
    )
    let errEmptyEmbedding: T2 = (
        "Ollama lieferte ein leeres Embedding zurück.",
        "Ollama returned an empty embedding."
    )
    let errEmptyResponse: T2 = (
        "Ollama lieferte eine leere Antwort.",
        "Ollama returned an empty response."
    )
    let errInvalidHTTP: T2 = (
        "Ungültige HTTP-Antwort.",
        "Invalid HTTP response."
    )
    let errNoModelHint: T2 = (
        "Empfehlung: `ollama pull llama3.2:3b` (klein, schnell).",
        "Suggestion: `ollama pull llama3.2:3b` (small, fast)."
    )
    /// Format mit einem %@ (hint).
    let errNoGenerativeModel: T2 = (
        "Kein generatives Modell in Ollama gefunden. %@",
        "No generative model found in Ollama. %@"
    )
    /// Format mit zwei %@ (verfügbare Modelle, hint).
    let errNoPreferredModel: T2 = (
        "Keins der bevorzugten Modelle gefunden. Verfügbar: %@. %@",
        "None of the preferred models found. Available: %@. %@"
    )

    // MARK: - WebView-Tooltips & Buttons (alle remaining)

    let wvHeaderRefresh: T2 = (
        "Neu laden (Ordner-Auswahl bleibt)",
        "Reload (folder selection persists)"
    )
    let wvLiveDot: T2 = (
        "Live-Sync mit Apple Notes aktiv",
        "Live-sync with Apple Notes active"
    )
    let wvMonthlyToggleNumbers: T2 = (
        "Zahlen in den Zellen ein-/ausblenden",
        "Show/hide numbers in cells"
    )
    let wvMonthlyNumbersOn: T2 = ("Zahlen: an", "Numbers: on")
    let wvMonthlyNumbersOff: T2 = ("Zahlen: aus", "Numbers: off")

    // Heightmap color
    let wvHmColorFolder: T2 = ("Ordner", "Folder")
    let wvHmColorHub: T2 = ("Hubs", "Hubs")
    let wvHmColorFolderTitle: T2 = (
        "Farbe nach Ordner (wie im 2D-Graph)",
        "Color by folder (same as the 2D graph)"
    )
    let wvHmColorHubTitle: T2 = (
        "Gradient nach Hub-Score (viele Links = hell)",
        "Gradient by hub-score (more links = brighter)"
    )
    let wvHmColorCreatedTitle: T2 = (
        "Gradient nach Erstellungsdatum (alt = dunkel, neu = hell)",
        "Gradient by creation date (older = darker, newer = brighter)"
    )
    let wvHmColorCreated: T2 = ("Alter", "Age")
    let wvHmLabelColor: T2 = ("Farbe:", "Color:")
    let wvHmLabelView: T2 = ("Ansicht:", "View:")
    let wvHmLabelDetail: T2 = ("Detail:", "Detail:")
    let wvHmContour: T2 = ("Höhenlinien", "Contour lines")

    // Help-Panel (ⓘ-Button öffnet kontext-sensitives Panel pro View)
    let wvHelpButtonTitle: T2 = ("Hilfe zur aktuellen Ansicht", "Help for the current view")
    let wvHelpInteractions: T2 = ("Maus & Tastatur", "Mouse & keyboard")
    let wvHelpTip: T2 = ("Tipp", "Tip")
    let wvHelpClose: T2 = ("Schließen", "Close")

    // Suche im Header
    let wvSearchPlaceholder: T2 = ("Notiz suchen…", "Search notes…")
    let wvSearchTooltip: T2 = (
        "Filtert alle Ansichten nach Titel-Substring (Klick: nur Treffer hell)",
        "Filters all views by title substring (only matches stay bright)"
    )

    // View-Button-Tooltips
    let wvTipRadial: T2 = (
        "Radial-Layout: Ordner als Tortenstücke, Hubs in der Mitte",
        "Radial layout: folders as pie sectors, hubs at center"
    )
    let wvTipRadial2: T2 = (
        "Radial 2: Unverlinkte am Außenring, vernetzte Cluster bekommen den ganzen Innenraum",
        "Radial 2: orphans on outer halo, linked clusters get the full inner space"
    )
    let wvTipCircos: T2 = (
        "Circos-Plot: Ordner als Bogensegmente, Notizen als radiale Balken (Länge = Hub-Score), Links als Bezier-Bündel durchs Zentrum (Genomik-Stil)",
        "Circos plot: folders as arc segments, notes as radial bars (length = hub-score), links as Bezier bundles through the center (genomics-style)"
    )
    let wvTipCalendar: T2 = (
        "Kalender-Heatmap: eine Zelle pro Tag, Jahre untereinander gestapelt",
        "Calendar heatmap: one cell per day, years stacked"
    )
    let wvTipMonthly: T2 = (
        "Monats-Heatmap: eine Zelle pro Monat, Jahre als Zeilen",
        "Monthly heatmap: one cell per month, years as rows"
    )
    let wvTipHeightmap: T2 = (
        "Höhenkarte: Themen-Landschaft via Embeddings. Semantisch ähnliche Notizen clustern räumlich. Berechnung lokal via Ollama (bge-m3). Erstaufruf dauert kurz, danach gecacht.",
        "Heightmap: topic landscape via embeddings. Semantically similar notes cluster spatially. Computed locally via Ollama (bge-m3). First run takes a moment, then cached."
    )
    let wvTip2D: T2 = (
        "2D Force-Graph: physik-basiertes Netz mit Hubs in der Mitte und Unverlinkten am Rand. Standard-Ansicht.",
        "2D force graph: physics-based web with hubs at center and orphans at the edge. Default view."
    )
    let wvTip3D: T2 = (
        "3D Force-Graph: Knotenwolke um Cluster-Centroids auf einer Kugel. Maus links = rotieren, rechts = pan, Rad = zoom.",
        "3D force graph: node cloud around cluster centroids on a sphere. Mouse left = rotate, right = pan, wheel = zoom."
    )

    // „Generiert: …" oben rechts
    let wvGeneratedAt: T2 = ("Generiert: %@", "Generated: %@")

    // Heightmap views
    let wvHm2DTitle: T2 = (
        "Flache 2D-Karte mit Höhenlinien",
        "Flat 2D map with contour lines"
    )
    let wvHm3DTitle: T2 = (
        "3D-Relief (Maus: links=rotieren, rechts=schieben, Rad=zoom)",
        "3D relief (mouse: left=rotate, right=pan, wheel=zoom)"
    )
    let wvHmBandwidthTitle: T2 = (
        "Wie zerklüftet soll die Landschaft sein? Links = wenige breite Hügel (Übersicht), rechts = viele scharfe Spitzen (Detail). Bandwidth der KDE; Terrain wird neu berechnet.",
        "How rugged should the landscape be? Left = few broad hills (overview), right = many sharp peaks (detail). KDE bandwidth; terrain is recomputed."
    )

    // Timeline
    let wvPlayTitle: T2 = ("Abspielen", "Play")
    let wvHeatmapTitle: T2 = (
        "Aktivität pro Monat. Klicken zum Springen",
        "Activity per month. Click to jump"
    )

    // Stats
    let wvStatsNotes: T2 = ("Notizen", "Notes")
    let wvStatsLinks: T2 = ("Verlinkungen", "Links")
    let wvStatsOrphans: T2 = ("Unverlinkt", "Orphans")

    // JS-side dynamic messages (injected as window.NM_LOC.*)
    let jsHmEmbedding: T2 = ("Berechne Embeddings…", "Computing embeddings…")
    let jsHmClustering: T2 = ("Erkenne Cluster…", "Detecting clusters…")
    let jsHmLabeling: T2 = ("Generiere Labels…", "Generating labels…")
    let jsHmDone: T2 = ("Fertig", "Done")
    let jsHmFailed: T2 = ("Höhenkarte fehlgeschlagen", "Heightmap failed")
    let jsLoadingMore: T2 = ("Lade weitere Daten…", "Loading more…")
    let jsNoSelection: T2 = ("Nichts ausgewählt", "Nothing selected")
    let jsTimeAgoToday: T2 = ("heute", "today")
    let jsTimeAgoYesterday: T2 = ("gestern", "yesterday")
    /// Format mit %d (Tage)
    let jsTimeAgoDays: T2 = ("vor %d Tagen", "%d days ago")
    let jsClickToOpen: T2 = ("Klicken zum Öffnen", "Click to open")
    let jsLoadingNotes: T2 = ("Lade Notizen…", "Loading notes…")
    let jsRefreshing: T2 = ("Aktualisiere…", "Refreshing…")
    let jsBacklinks: T2 = ("Backlinks", "Backlinks")
    let jsOutgoing: T2 = ("Ausgehend", "Outgoing")
    let jsTotal: T2 = ("Gesamt", "Total")
    let jsSelected: T2 = ("ausgewählt", "selected")
    let jsCreated: T2 = ("Erstellt", "Created")
    let jsModified: T2 = ("Bearbeitet", "Modified")
    let jsFolder: T2 = ("Ordner", "Folder")
    let jsTags: T2 = ("Tags", "Tags")
    let jsPeak: T2 = ("Peak", "Peak")
    let jsHeightmapHelp: T2 = (
        "Höhenkarte zeigt thematische Cluster. Höhere Spitzen = mehr Notizen zum gleichen Thema.",
        "Heightmap shows thematic clusters. Higher peaks = more notes on the same topic."
    )
    let jsLinked: T2 = ("verlinkt", "linked")
    let jsFiltered: T2 = ("gefiltert", "filtered")

    // Heightmap status messages (in JS-engine, dynamisch erzeugt)
    let jsHmPreparing: T2 = (
        "Höhenkarte wird vorbereitet…",
        "Preparing heightmap…"
    )
    let jsHmUnavailable: T2 = (
        "Höhenkarte nicht verfügbar",
        "Heightmap unavailable"
    )
    let jsHmEmpty: T2 = ("Höhenkarte leer", "Heightmap empty")
    let jsHmEmptyMsg: T2 = (
        "Es wurden keine Embeddings zurückgeliefert.",
        "No embeddings were returned."
    )
    let jsHmTooFew: T2 = (
        "Die Höhenkarte braucht mindestens 2 Notizen mit Embeddings.",
        "Heightmap needs at least 2 notes with embeddings."
    )
    let jsHmUmapRunning: T2 = (
        "UMAP läuft lokal im Browser (dauert bei ~1200 Notizen wenige Sekunden).",
        "UMAP runs locally in the browser (takes a few seconds for ~1200 notes)."
    )
    let jsHmProgress: T2 = ("Fortschritt läuft…", "In progress…")
    let jsHmEmbeddingHint: T2 = (
        "Embeddings werden via Ollama (bge-m3) berechnet. Beim ersten Mal dauert das 1-3 Minuten, danach ist der Cache auf Platte und es geht sofort.",
        "Embeddings are computed via Ollama (bge-m3). First run takes 1-3 minutes, then it's cached to disk and instant."
    )
    let jsHmStarting: T2 = ("Starte…", "Starting…")
    let jsHmBridgeMissing: T2 = (
        "Die native Brücke zu Swift/Ollama ist nicht erreichbar (läuft die App im WKWebView?).",
        "Native bridge to Swift/Ollama unavailable (is the app running inside WKWebView?)."
    )
    let jsHmCheckOllama: T2 = ("Prüfe Ollama…", "Checking Ollama…")
    let jsHmLoadingNotesShort: T2 = ("Lade Notizen…", "Loading notes…")
    let jsUnknownError: T2 = ("Unbekannter Fehler.", "Unknown error.")
    let jsHmRetryHint: T2 = (
        "Tipp: `ollama serve` starten und `ollama pull bge-m3`, dann Höhenkarte erneut klicken.",
        "Tip: run `ollama serve` and `ollama pull bge-m3`, then click Heightmap again."
    )
    let jsHmTooFewTitle: T2 = ("Zu wenige Notizen", "Too few notes")
    let jsHmReducing: T2 = ("Reduziere auf 2D…", "Reducing to 2D…")
    /// Format mit %d (Epoch).
    let jsHmEpoch: T2 = ("Epoche %d …", "Epoch %d …")

    // Pluralisierung & Day-Panel Strings
    let jsNoteSingular: T2 = ("Notiz", "note")
    let jsNotePlural: T2 = ("Notizen", "notes")
    let jsNoNotes: T2 = ("keine Notizen", "no notes")
    let jsCreatedSuffix: T2 = ("erstellt", "created")
    let jsInThisMonth: T2 = ("in diesem Monat", "in this month")
    let jsNoTitle: T2 = ("(ohne Titel)", "(no title)")
    let jsNoText: T2 = ("(kein Textinhalt extrahiert)", "(no text extracted)")
    let jsNoNotesWithDate: T2 = (
        "Keine Notizen mit bekanntem Erstelldatum.",
        "No notes with a known creation date."
    )
    /// Heatmap-Legende: low/high und Max-Suffix.
    let jsLegendLow: T2 = ("wenig", "low")
    let jsLegendHigh: T2 = ("viel", "high")
    let jsLegendMaxPerDay: T2 = ("Max: %d / Tag", "Max: %d / day")
    let jsLegendMaxPerMonth: T2 = ("Max: %d / Monat", "Max: %d / month")
    /// Monthly-View Toggle-Button-Text bei aktivem/inaktivem Zustand.
    let jsNumbersOn: T2 = ("Zahlen: an", "Numbers: on")
    let jsNumbersOff: T2 = ("Zahlen: aus", "Numbers: off")

    // Matrix tooltip
    let jsBacklinkOnly: T2 = ("← nur Rückverlinkung", "← back-link only")

    // Month name arrays for calendar/monthly views
    private static let monthsShortDE = "Jan,Feb,Mär,Apr,Mai,Jun,Jul,Aug,Sep,Okt,Nov,Dez"
    private static let monthsShortEN = "Jan,Feb,Mar,Apr,May,Jun,Jul,Aug,Sep,Oct,Nov,Dec"
    private static let monthsLongDE = "Januar,Februar,März,April,Mai,Juni,Juli,August,September,Oktober,November,Dezember"
    private static let monthsLongEN = "January,February,March,April,May,June,July,August,September,October,November,December"
    private static let weekdaysShortDE = "Mo,Di,Mi,Do,Fr,Sa,So"
    private static let weekdaysShortEN = "Mon,Tue,Wed,Thu,Fri,Sat,Sun"
    /// JS-Order: Sonntag=0..Samstag=6 (matches Date.getDay()).
    private static let weekdaysShort7DE = "So,Mo,Di,Mi,Do,Fr,Sa"
    private static let weekdaysShort7EN = "Sun,Mon,Tue,Wed,Thu,Fri,Sat"
    private static let weekdaysLongDE = "Sonntag,Montag,Dienstag,Mittwoch,Donnerstag,Freitag,Samstag"
    private static let weekdaysLongEN = "Sunday,Monday,Tuesday,Wednesday,Thursday,Friday,Saturday"

    /// Build a JSON object for window.NM_LOC injection.
    /// Wird in renderHTML genutzt, um die JS-side localized strings ins
    /// HTML-Dokument einzubetten. Reihenfolge der Keys ist deterministisch.
    static func jsLocaleObject(in lang: Lang) -> String {
        let l = Localized()
        func s(_ kp: KeyPath<Localized, T2>) -> String {
            let pair = l[keyPath: kp]
            let str = lang == .de ? pair.0 : pair.1
            // JS-string-escapen
            return str
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
        }
        return """
        {
            "hmEmbedding": "\(s(\.jsHmEmbedding))",
            "hmClustering": "\(s(\.jsHmClustering))",
            "hmLabeling": "\(s(\.jsHmLabeling))",
            "hmDone": "\(s(\.jsHmDone))",
            "hmFailed": "\(s(\.jsHmFailed))",
            "hmHelp": "\(s(\.jsHeightmapHelp))",
            "loadingMore": "\(s(\.jsLoadingMore))",
            "loadingNotes": "\(s(\.jsLoadingNotes))",
            "refreshing": "\(s(\.jsRefreshing))",
            "noSelection": "\(s(\.jsNoSelection))",
            "today": "\(s(\.jsTimeAgoToday))",
            "yesterday": "\(s(\.jsTimeAgoYesterday))",
            "daysAgo": "\(s(\.jsTimeAgoDays))",
            "clickToOpen": "\(s(\.jsClickToOpen))",
            "backlinks": "\(s(\.jsBacklinks))",
            "outgoing": "\(s(\.jsOutgoing))",
            "total": "\(s(\.jsTotal))",
            "selected": "\(s(\.jsSelected))",
            "created": "\(s(\.jsCreated))",
            "modified": "\(s(\.jsModified))",
            "folder": "\(s(\.jsFolder))",
            "tags": "\(s(\.jsTags))",
            "peak": "\(s(\.jsPeak))",
            "statsNotes": "\(s(\.wvStatsNotes))",
            "statsLinks": "\(s(\.wvStatsLinks))",
            "statsOrphans": "\(s(\.wvStatsOrphans))",
            "linked": "\(s(\.jsLinked))",
            "filtered": "\(s(\.jsFiltered))",
            "hmPreparing": "\(s(\.jsHmPreparing))",
            "hmUnavailable": "\(s(\.jsHmUnavailable))",
            "hmEmpty": "\(s(\.jsHmEmpty))",
            "hmEmptyMsg": "\(s(\.jsHmEmptyMsg))",
            "hmTooFew": "\(s(\.jsHmTooFew))",
            "hmUmapRunning": "\(s(\.jsHmUmapRunning))",
            "hmProgress": "\(s(\.jsHmProgress))",
            "backlinkOnly": "\(s(\.jsBacklinkOnly))",
            "monthsShort": [\(splitToJsArray(lang == .de ? monthsShortDE : monthsShortEN))],
            "monthsLong": [\(splitToJsArray(lang == .de ? monthsLongDE : monthsLongEN))],
            "weekdaysShort": [\(splitToJsArray(lang == .de ? weekdaysShortDE : weekdaysShortEN))],
            "hmEmbeddingHint": "\(s(\.jsHmEmbeddingHint))",
            "hmStarting": "\(s(\.jsHmStarting))",
            "hmBridgeMissing": "\(s(\.jsHmBridgeMissing))",
            "hmCheckOllama": "\(s(\.jsHmCheckOllama))",
            "hmLoadingNotesShort": "\(s(\.jsHmLoadingNotesShort))",
            "unknownError": "\(s(\.jsUnknownError))",
            "hmRetryHint": "\(s(\.jsHmRetryHint))",
            "hmTooFewTitle": "\(s(\.jsHmTooFewTitle))",
            "hmReducing": "\(s(\.jsHmReducing))",
            "hmEpoch": "\(s(\.jsHmEpoch))",
            "localeTag": "\(lang == .de ? "de-DE" : "en-US")",
            "weekdaysShort7": [\(splitToJsArray(lang == .de ? weekdaysShort7DE : weekdaysShort7EN))],
            "weekdaysLong": [\(splitToJsArray(lang == .de ? weekdaysLongDE : weekdaysLongEN))],
            "noteSingular": "\(s(\.jsNoteSingular))",
            "notePlural": "\(s(\.jsNotePlural))",
            "noNotes": "\(s(\.jsNoNotes))",
            "createdSuffix": "\(s(\.jsCreatedSuffix))",
            "inThisMonth": "\(s(\.jsInThisMonth))",
            "noTitle": "\(s(\.jsNoTitle))",
            "noText": "\(s(\.jsNoText))",
            "noNotesWithDate": "\(s(\.jsNoNotesWithDate))",
            "legendLow": "\(s(\.jsLegendLow))",
            "legendHigh": "\(s(\.jsLegendHigh))",
            "legendMaxPerDay": "\(s(\.jsLegendMaxPerDay))",
            "legendMaxPerMonth": "\(s(\.jsLegendMaxPerMonth))",
            "numbersOn": "\(s(\.jsNumbersOn))",
            "numbersOff": "\(s(\.jsNumbersOff))"
        }
        """
    }

    /// Helper: "Jan,Feb,..." → '"Jan","Feb",...'
    private static func splitToJsArray(_ csv: String) -> String {
        csv.split(separator: ",").map { "\"\($0)\"" }.joined(separator: ",")
    }
}

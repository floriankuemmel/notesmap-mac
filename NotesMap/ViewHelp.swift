// ViewHelp.swift: inhaltliche Beschreibungen für jede der 8 Views.
//
// Wird beim Klick auf den ⓘ-Button im Header als Help-Panel angezeigt.
// Inhalt ist kontext-sensitiv: wir zeigen die Hilfe der aktuell aktiven View.
//
// Daten werden als JSON ins HTML injiziert (window.NM_HELP). Das JS-seitige
// Help-Panel rendert daraus dynamisch, ohne DOM-Vorbau pro View.

import Foundation

struct ViewHelpEntry {
    let title: String
    let description: String
    let interactions: [String]
    let tip: String?

    func toJSON() -> String {
        let title = Self.escape(title)
        let description = Self.escape(description)
        let inters = interactions.map { "\"\(Self.escape($0))\"" }.joined(separator: ",")
        let tipPart = tip.map { ",\"tip\":\"\(Self.escape($0))\"" } ?? ""
        return "{\"title\":\"\(title)\",\"description\":\"\(description)\",\"interactions\":[\(inters)]\(tipPart)}"
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

enum ViewHelp {

    /// Liefert das gesamte Help-Content als JSON-Objekt:
    /// `{ "2d": {...}, "radial": {...}, ... }`
    /// Wird in HTMLBuilder ins HTML eingebettet als `window.NM_HELP`.
    static func allAsJSON(in lang: Localized.Lang) -> String {
        let entries = lang == .de ? helpDE : helpEN
        var pairs: [String] = []
        for (key, entry) in entries {
            pairs.append("\"\(key)\":\(entry.toJSON())")
        }
        return "{" + pairs.joined(separator: ",") + "}"
    }

    // MARK: - Deutsche Inhalte

    private static let helpDE: [(String, ViewHelpEntry)] = [
        ("2d", ViewHelpEntry(
            title: "2D Force-Graph",
            description: "Klassischer physik-basierter Graph: Notizen sind Knoten, Verlinkungen sind Federn. Verlinkte Notizen ziehen sich an, unverlinkte driften nach außen. Die Standard-Ansicht für „wie hängt alles zusammen?\".",
            interactions: [
                "Hover über Knoten: hebt direkt verbundene Notizen hervor, dimmt den Rest",
                "Klick auf Knoten: öffnet das Detail-Panel mit Snippet und Backlinks",
                "⌘+Klick: öffnet die Notiz direkt in Apple Notes",
                "Ziehen eines Knotens: verschiebt ihn (sticky, bleibt wo du loslässt)",
                "Mausrad / Trackpad-Pinch: Zoom rein/raus",
                "Klick+Ziehen auf leere Fläche: verschiebt die ganze Karte (Pan)",
                "Suche oben: filtert Knoten nach Titel-Substring",
                "Ordner-Panel unten links: aktivierte Ordner werden hell, der Rest dimmt",
                "Tag-Panel unten rechts: gleiche Logik mit Hashtags",
                "Timeline unten: zeigt nur Notizen die bis zum Datum existierten (Time-Machine)"
            ],
            tip: "Größere Knoten = mehr Verlinkungen (Hubs). Knoten die ganz außen schweben sind oft unverlinkte Solo-Notizen, Kandidaten zum Verlinken."
        )),

        ("radial", ViewHelpEntry(
            title: "Radial-Layout",
            description: "Notizen werden in Tortenstücken nach Ordner gruppiert. Je größer der Ordner, desto breiter das Sektor. Hubs (vielfach verlinkte Notizen) sitzen näher am Zentrum, schwach verlinkte am Rand.",
            interactions: [
                "Hover über Knoten: hebt Notiz und ihre Verbindungen hervor",
                "Klick: Detail-Panel + Verbindungen werden gelb",
                "⌘+Klick: in Apple Notes öffnen",
                "Ziehen: Knoten manuell positionieren",
                "Mausrad: zoomen",
                "Ordner-Panel: Sektoren ausblenden, der Rest bleibt am Platz",
                "Wechsel zu 2D: Layout schmilzt in den Force-Graph"
            ],
            tip: "Lange Bezier-Linien quer durch die Mitte zeigen Cluster-Brücken: Notizen die zwei verschiedene Ordner inhaltlich verbinden."
        )),

        ("radial2", ViewHelpEntry(
            title: "Radial 2: Halo & Cluster",
            description: "Variante des Radial-Layouts: Unverlinkte Notizen sitzen auf einem festen Außenring (Halo), verlinkte Cluster bekommen den vollen Innenraum. Macht Verbindungs-Strukturen extrem deutlich, weil der Innenraum komplett für die vernetzten Notizen reserviert ist.",
            interactions: [
                "Identisch zu Radial: Hover, Klick, ⌘+Klick, Zoom, Pan",
                "Außenring-Notizen sind die Unverlinkten: Kandidaten für Aufräum-Aktionen",
                "Innenraum-Cluster: Notizen die Verbindungen zueinander haben"
            ],
            tip: "Wenn der Außenring sehr dick ist, hast du viele isolierte Notizen. Gut zu sehen welche Themen noch nicht verknüpft sind."
        )),

        ("circos", ViewHelpEntry(
            title: "Circos-Plot",
            description: "Aus der Genomik geliehen: Ordner werden zu Bogensegmenten am Rand eines Kreises. Verlinkungen sind Bezier-Kurven durchs Zentrum (gleicher Ordner = flache Bögen, anderer Ordner = tiefe Bögen quer durchs Zentrum). Die Notizen liegen als radiale Balken auf dem inneren Ring; Balkenlänge = Hub-Score.",
            interactions: [
                "Hover über Notiz-Balken: Detail-Tooltip mit Titel und Verlinkungen",
                "Hover über Ordner-Segment: alle Notizen + Bögen des Ordners hell, Rest dimmt",
                "Klick: Detail-Panel öffnen",
                "⌘+Klick: in Apple Notes öffnen",
                "Mausrad: zoomen",
                "Klick+Ziehen leere Fläche: Pan"
            ],
            tip: "Mehr lange Bögen quer durchs Zentrum = mehr ordnerübergreifende Verlinkung. Inhaltlich „verwobene\" Vaults sehen so aus."
        )),

        ("calendar", ViewHelpEntry(
            title: "Tage: Kalender-Heatmap",
            description: "Eine Zelle pro Tag, Jahre untereinander gestapelt, wie das GitHub-Contribution-Grid. Helligkeit der Zelle = Anzahl der an dem Tag erstellten Notizen. Zeigt deine persönlichen Schreib-Rhythmen.",
            interactions: [
                "Hover über Tag: Tooltip mit Datum + Anzahl + bis zu 3 Notiztiteln",
                "Klick auf Tag: Day-Panel rechts mit allen Notizen des Tages",
                "Klick auf Notiz im Panel: in Apple Notes öffnen",
                "Esc oder × im Panel: Auswahl zurücksetzen"
            ],
            tip: "Helle Cluster verraten produktive Phasen, dunkle Blöcke sind Pausen. Wochenenden vs Werktage werden oft visuell sichtbar."
        )),

        ("monthly", ViewHelpEntry(
            title: "Monate: Monats-Heatmap",
            description: "Eine Ebene über der Tages-Heatmap: ein Feld pro Monat, Jahre als Zeilen. Gut für langfristige Trends wie Lebensphasen, Projekt-Zyklen, „intensive Zeiten\".",
            interactions: [
                "Hover über Monatszelle: Tooltip mit Monat/Jahr + Anzahl",
                "Klick: Panel mit allen Notizen des Monats",
                "Toggle „Zahlen: an/aus\" oben: zeigt/versteckt Counts in den Zellen"
            ],
            tip: "Fast alle Notizen aus 2024? Gut zu sehen welches Jahr produktiv war oder wann ein neues Themenfeld eröffnet wurde."
        )),

        ("heightmap", ViewHelpEntry(
            title: "Höhenkarte: Themen-Landschaft",
            description: "Experimentelle Ansicht. Notizen werden via Embeddings (Ollama bge-m3) auf einen 2D-Raum reduziert (UMAP), dann wird via KDE eine Höhenfunktion berechnet. Hügel = dichte Cluster ähnlicher Themen, Täler = isolierte Notizen. Erstaufruf braucht Ollama und dauert ~1-3 min, danach gecacht.",
            interactions: [
                "2D-Modus: flache Karte mit Höhenlinien; Klick auf einen Peak öffnet Cluster-Notizen",
                "3D-Modus: Maus links = rotieren, Maus rechts = pan, Mausrad = zoom",
                "Farbmodus „Ordner\": Punkte in Ordner-Farbe (gleich wie 2D)",
                "Farbmodus „Hubs\": Gradient, viele Verlinkungen = hell",
                "Farbmodus „Alter\": Gradient nach Erstelldatum",
                "Detail-Slider: wie zerklüftet die Landschaft ist (links = wenige breite Hügel, rechts = viele scharfe Spitzen)",
                "Höhenlinien-Toggle: Konturen ein/aus",
                "Peak-Labels werden via Ollama (gemma2) generiert und dauerhaft gecacht"
            ],
            tip: "Notizen die nahe beisammen liegen sind semantisch ähnlich, auch wenn sie nicht verlinkt sind. Ideal um „das hatte ich doch schon mal geschrieben\"-Momente zu finden."
        )),

        ("3d", ViewHelpEntry(
            title: "3D Force-Graph",
            description: "Der Graph in drei Dimensionen via Three.js. Knoten verteilen sich um Cluster-Centroids auf einer Kugeloberfläche (Fibonacci-Sphere). Räumliche Cluster werden plastisch erfahrbar, jedes Cluster bekommt sein eigenes Volumen statt sich in 2D mit anderen zu überlagern.",
            interactions: [
                "Maus links + ziehen: Kamera rotieren",
                "Maus rechts + ziehen: Kamera pannen",
                "Mausrad: zoom",
                "Hover über Knoten: hebt direkt verbundene Knoten hervor",
                "Klick auf Knoten: Detail-Panel mit Snippet und Backlinks",
                "⌘+Klick: in Apple Notes öffnen"
            ],
            tip: "Mit gehaltener Maus den Graphen langsam rotieren lassen, um Cluster aus verschiedenen Blickwinkeln zu sehen, oft tauchen so Verbindungen auf, die in 2D verdeckt waren."
        ))
    ]

    // MARK: - English content

    private static let helpEN: [(String, ViewHelpEntry)] = [
        ("2d", ViewHelpEntry(
            title: "2D Force Graph",
            description: "Classic physics-based graph: notes are nodes, links are springs. Linked notes attract each other, unlinked ones drift outward. The default view for \"how does everything connect?\".",
            interactions: [
                "Hover a node: highlights directly connected notes, dims the rest",
                "Click a node: opens the detail panel with snippet and backlinks",
                "⌘+Click: opens the note in Apple Notes",
                "Drag a node: moves it (sticky, stays where you drop it)",
                "Mouse wheel / trackpad pinch: zoom in/out",
                "Click+drag empty area: pans the whole map",
                "Search box at top: filters nodes by title substring",
                "Folder panel bottom-left: only active folders stay bright, rest dim",
                "Tag panel bottom-right: same logic with hashtags",
                "Timeline at bottom: shows only notes that existed up to that date (time machine)"
            ],
            tip: "Bigger nodes = more links (hubs). Nodes drifting far at the edge are usually orphans, candidates for linking."
        )),

        ("radial", ViewHelpEntry(
            title: "Radial layout",
            description: "Notes grouped into pie sectors per folder. Larger folder = wider sector. Hubs (heavily linked notes) sit closer to the center, sparsely linked ones go to the edge.",
            interactions: [
                "Hover a node: highlights the note and its connections",
                "Click: detail panel + connections turn yellow",
                "⌘+Click: open in Apple Notes",
                "Drag: position a node manually",
                "Mouse wheel: zoom",
                "Folder panel: hide sectors, the rest stays in place",
                "Switch to 2D: layout melts into the force graph"
            ],
            tip: "Long Bezier lines crossing the center reveal cluster bridges: notes that connect two different folders thematically."
        )),

        ("radial2", ViewHelpEntry(
            title: "Radial 2: Halo & clusters",
            description: "Variant of the radial layout: orphan notes (no links) sit on a fixed outer halo, linked clusters get the full inner space. Makes connection structures extremely visible because the inner space is dedicated entirely to the linked notes.",
            interactions: [
                "Identical to Radial: hover, click, ⌘+click, zoom, pan",
                "Outer ring nodes are the orphans: candidates for cleanup",
                "Inner clusters: notes that have connections to each other"
            ],
            tip: "If the outer ring is very thick, you have many isolated notes. Good for spotting topics that aren't yet connected."
        )),

        ("circos", ViewHelpEntry(
            title: "Circos plot",
            description: "Borrowed from genomics: folders become arc segments around a circle. Links are Bezier curves through the center (same folder = flat curves, different folders = deep curves crossing the middle). Notes sit as radial bars on the inner ring; bar length = hub score.",
            interactions: [
                "Hover a note bar: detail tooltip with title and link count",
                "Hover a folder segment: all notes + arcs of that folder highlight, rest dims",
                "Click: open detail panel",
                "⌘+Click: open in Apple Notes",
                "Mouse wheel: zoom",
                "Click+drag empty area: pan"
            ],
            tip: "More long arcs across the center = more cross-folder linking. Heavily \"woven\" vaults look like this."
        )),

        ("calendar", ViewHelpEntry(
            title: "Days: calendar heatmap",
            description: "One cell per day, years stacked, like the GitHub contribution grid. Cell brightness = number of notes created that day. Reveals your personal writing rhythms.",
            interactions: [
                "Hover a day: tooltip with date + count + up to 3 note titles",
                "Click a day: day panel on the right with all notes from that day",
                "Click a note in the panel: opens in Apple Notes",
                "Esc or × in the panel: clears the selection"
            ],
            tip: "Bright clusters expose productive phases, dark blocks are gaps. Weekends vs weekdays often pop visually."
        )),

        ("monthly", ViewHelpEntry(
            title: "Months: monthly heatmap",
            description: "One level above the daily heatmap: one cell per month, years as rows. Good for long-term trends like life chapters, project cycles, \"intense periods\".",
            interactions: [
                "Hover a month cell: tooltip with month/year + count",
                "Click: panel with all notes from that month",
                "\"Numbers on/off\" toggle: shows/hides counts inside cells"
            ],
            tip: "Mostly notes from 2024? Easy to see which year was productive or when a new topic took off."
        )),

        ("heightmap", ViewHelpEntry(
            title: "Heightmap: topic landscape",
            description: "Experimental view. Notes are reduced to 2D space via embeddings (Ollama bge-m3) and UMAP, then a height field is computed via KDE. Hills = dense clusters of similar topics, valleys = isolated notes. First run needs Ollama and takes ~1-3 minutes, then it's cached.",
            interactions: [
                "2D mode: flat map with contour lines; click a peak to see cluster notes",
                "3D mode: mouse left = rotate, mouse right = pan, wheel = zoom",
                "Color mode \"Folder\": dots in folder color (same as 2D)",
                "Color mode \"Hubs\": gradient, more links = brighter",
                "Color mode \"Age\": gradient by creation date",
                "Detail slider: how rugged the landscape is (left = few broad hills, right = many sharp peaks)",
                "Contour lines toggle: turn outlines on/off",
                "Peak labels are generated via Ollama (gemma2) and cached permanently"
            ],
            tip: "Notes that lie close together are semantically similar, even if not linked. Perfect for \"didn't I write this already?\" moments."
        )),

        ("3d", ViewHelpEntry(
            title: "3D force graph",
            description: "The graph in three dimensions via Three.js. Nodes scatter around cluster centroids on a sphere surface (Fibonacci sphere). Spatial clusters become tangible, each cluster gets its own volume instead of overlapping others as in 2D.",
            interactions: [
                "Mouse left + drag: rotate camera",
                "Mouse right + drag: pan camera",
                "Mouse wheel: zoom",
                "Hover a node: highlights directly connected nodes",
                "Click a node: detail panel with snippet and backlinks",
                "⌘+Click: open in Apple Notes"
            ],
            tip: "Slowly rotate the graph while holding the mouse to view clusters from different angles, hidden connections often surface that were occluded in the 2D projection."
        ))
    ]
}

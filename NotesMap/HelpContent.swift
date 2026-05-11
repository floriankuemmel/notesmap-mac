// HelpContent.swift, Inhalte der App-internen Hilfe.
//
// Wird in HelpView.swift gerendert. Pattern wie ViewHelp.swift: bilingual
// (DE/EN) mit derselben Struktur, Auswahl beim Aufruf via Localized.Lang.
//
// Content-Modell: jede Sektion ist eine Liste von Blöcken (Paragraph,
// Bullet-Liste, Shortcut-Tabelle, Hinweis, Link). Damit kann HelpView
// einfach drüberschalten und für jeden Block-Typ ein passendes UI-Element
// emittieren, ohne dass wir uns mit AttributedStrings rumschlagen.

import Foundation

enum HelpContent {

    // MARK: - Blocks

    /// Ein Inhaltsblock einer Hilfe-Sektion.
    enum Block {
        /// Ein Absatz Fließtext. Zeilenumbrüche werden gerendert.
        case paragraph(String)
        /// Eine Zwischenüberschrift innerhalb einer Sektion.
        case heading(String)
        /// Eine Bullet-Liste.
        case bullets([String])
        /// Eine zweispaltige Liste, links Tastenkürzel, rechts Beschreibung.
        case shortcuts([(keys: String, desc: String)])
        /// Hervorgehobener Hinweis-Block (in der UI mit Icon + farbigem Hintergrund).
        case note(String)
        /// Externer Link, wird im System-Browser geöffnet.
        case link(text: String, url: String)
        /// Bild aus dem App-Bundle (Resources/screenshots/<filename>).
        /// Wird mit aspect-fit gerendert und füllt die Content-Breite.
        case image(filename: String, caption: String?)
    }

    // MARK: - Sections

    /// Liefert die Übersichts-Sektion (Was ist NotesMap, was kann es).
    static func overview(in lang: Localized.Lang) -> [Block] {
        switch lang {
        case .de: return [
            .paragraph("NotesMap visualisiert deine Apple-Notes als interaktive Karte. Jede Notiz wird zu einem Knoten, jede [[Link]]-Verlinkung zwischen Notizen zu einer Kante. Du siehst Hubs (oft verlinkte Notizen), Cluster (verbundene Themen) und unverlinkte Solo-Notizen auf einen Blick."),
            .heading("Was die App macht"),
            .bullets([
                "Liest die Apple-Notes-Datenbank read-only über Festplattenvollzugriff.",
                "Baut den Verlink-Graphen aus den eingebetteten applenotes:-URLs in deinen Notizen.",
                "Bietet 8 Visualisierungen für unterschiedliche Fragestellungen (siehe „Ansichten\").",
                "Optional: Berechnet thematische Cluster über lokale KI (Ollama) für die Höhenkarte."
            ]),
            .heading("Was die App nicht macht"),
            .bullets([
                "Sie verändert deine Notizen nicht. Apple Notes selbst wird nicht angefasst.",
                "Sie schickt nichts ins Internet. Keine Telemetrie, keine Analytics, kein Cloud-LLM.",
                "Sie liest nicht den Inhalt von verschlüsselten Notizen (passwortgeschützt). Die werden in der Karte ausgegraut angezeigt."
            ]),
            .note("Voraussetzungen: macOS 14+, Festplattenvollzugriff in den Systemeinstellungen, Apple Notes als App benutzt (iCloud-Notes funktionieren). Ollama ist optional und nur für die Höhenkarte nötig.")
        ]
        case .en: return [
            .paragraph("NotesMap turns your Apple Notes into an interactive map. Each note is a node, each [[wiki-link]] between notes is an edge. You see hubs (often-linked notes), clusters (connected topics), and orphans (isolated notes) at a glance."),
            .heading("What the app does"),
            .bullets([
                "Reads the Apple Notes database read-only via Full Disk Access.",
                "Builds the link graph from embedded applenotes: URLs inside your notes.",
                "Offers 8 visualizations for different questions (see \"Views\").",
                "Optional: computes thematic clusters via local AI (Ollama) for the heightmap."
            ]),
            .heading("What the app does not do"),
            .bullets([
                "It never modifies your notes. Apple Notes is not touched.",
                "It never talks to the internet. No telemetry, no analytics, no cloud LLM.",
                "It cannot read password-protected notes; those appear dimmed on the map."
            ]),
            .note("Requirements: macOS 14+, Full Disk Access in System Settings, Apple Notes used as your notes app (iCloud notes work). Ollama is optional, only needed for the Heightmap.")
        ]
        }
    }

    /// Sektion: die 8 Ansichten, jede mit ausführlicher Erklärung.
    static func views(in lang: Localized.Lang) -> [Block] {
        switch lang {
        case .de: return [
            .paragraph("NotesMap hat 8 Ansichten. Im Header oben kannst du zwischen ihnen wechseln. Jede betont eine andere Frage. Unten ist jede Ansicht ausführlich beschrieben, dazu der konkrete Use-Case und wie sie technisch funktioniert."),
            .note("Jede Ansicht hat oben rechts ein ⓘ-Help-Icon, das die wichtigsten Maus- und Tastatur-Aktionen für genau diese Ansicht zeigt. Hier in der Hilfe steht der Überblick: was macht jede Ansicht und wann nutzt du sie."),

            .heading("2D Force-Graph"),
            .image(filename: "01-2d-force-graph.jpg", caption: nil),
            .paragraph("Die Standardansicht. Notizen sind Knoten, [[Verlinkungen]] sind Federn. Eine Physik-Simulation läuft live im Hintergrund: verlinkte Notizen ziehen sich gegenseitig an, unverlinkte werden nach außen gedrängt. Die Knotengröße zeigt den Hub-Score, also wie viele andere Notizen mit dieser verlinkt sind. Die Knotenfarbe entspricht dem Ordner."),
            .paragraph("Wofür: schnelle Antwort auf „wie hängt alles zusammen?\". Du erkennst auf einen Blick zentrale Hubs (große Knoten in der Mitte), thematische Cluster (Knoten, die sich zusammenballen) und unverlinkte Solo-Notizen (treiben am Rand). Beim Hover über einen Knoten werden seine direkt verbundenen Nachbarn hervorgehoben, der Rest dimmt. Mit Klick öffnest du das Detail-Panel, mit ⌘+Klick die Notiz direkt in Apple Notes."),

            .heading("Radial"),
            .image(filename: "02-radial.jpg", caption: nil),
            .paragraph("Notizen sind in Tortenstücken nach Ordner gruppiert. Je größer der Ordner, desto breiter sein Sektor. Innerhalb jedes Sektors sitzen Hubs (vielfach verlinkte Notizen) näher am Zentrum, schwach verlinkte am Rand."),
            .paragraph("Wofür: gut um zu sehen, welche Ordner deine „Schwergewichte\" sind und wo die wichtigsten Notizen pro Ordner liegen. Lange Bezier-Linien quer durch die Mitte sind besonders interessant: sie zeigen Brücken, also Notizen, die zwei verschiedene Ordner inhaltlich verbinden."),

            .heading("Radial 2 (Halo)"),
            .image(filename: "03-radial-2.jpg", caption: nil),
            .paragraph("Variante von Radial: alle unverlinkten Notizen sitzen auf einem festen Außenring (dem „Halo\"), die verlinkten Cluster bekommen den vollen Innenraum. Macht Verbindungs-Strukturen extrem deutlich, weil der Innenraum komplett für die vernetzten Notizen reserviert ist."),
            .paragraph("Wofür: ideal, wenn du Notizen zum Aufräumen oder Verlinken finden willst. Die Notizen am Halo-Außenring sind alle Solo-Notizen ohne eingehende oder ausgehende Verlinkung, also Kandidaten zum Wegwerfen oder Anbinden. Wenn der Halo dick ist, hast du viel Solo-Material."),

            .heading("Circos-Plot"),
            .image(filename: "04-circos.jpg", caption: nil),
            .paragraph("Aus der Genomik geliehen: Ordner werden zu Bogensegmenten am Rand eines Kreises, jede Notiz ist ein radialer Strich auf dem Innenring (Strich-Länge proportional zum Hub-Score). Die Verlinkungen werden als Bezier-Kurven durch das Zentrum gezeichnet. Notizen im selben Ordner: flache Bögen, die nahe am Rand verlaufen. Notizen in unterschiedlichen Ordnern: tiefe Bögen, die quer durchs Zentrum tauchen."),
            .paragraph("Wofür: zeigt sehr gut, wie stark deine Notizen ordnerübergreifend verbunden sind. Viele tiefe Bögen quer durchs Zentrum bedeuten ein „verwobenes\" Wissensnetz, in dem Themen sich nicht an Ordnergrenzen halten. Wenig durchgehende Bögen bedeutet, dass deine Ordner inhaltlich unabhängige Silos sind."),

            .heading("Tage: Kalender-Heatmap"),
            .image(filename: "05-days.jpg", caption: nil),
            .paragraph("Eine Zelle pro Tag, Jahre untereinander gestapelt, wie das GitHub-Contribution-Grid. Die Helligkeit der Zelle zeigt, wie viele Notizen an diesem Tag erstellt wurden."),
            .paragraph("Wofür: zeigt deine persönlichen Schreib-Rhythmen. Helle Cluster = produktive Phasen, dunkle Blöcke = Pausen. Wochenenden vs. Werktage werden oft visuell sichtbar. Klick auf einen Tag öffnet rechts ein Panel mit allen Notizen dieses Tages, von dort kannst du sie direkt in Apple Notes öffnen."),

            .heading("Monate: Monats-Heatmap"),
            .image(filename: "06-months.jpg", caption: nil),
            .paragraph("Eine Ebene über der Tages-Heatmap: ein Feld pro Monat, Jahre als Zeilen, Helligkeit nach Anzahl der erstellten Notizen. Mit dem Toggle „Zahlen: an/aus\" oben kannst du die Counts in den Zellen ein- oder ausblenden."),
            .paragraph("Wofür: langfristige Trends. Lebensphasen, Projekt-Zyklen, „intensive Zeiten\". Wenn fast alle deine Notizen aus einem Jahr stammen, oder ein neues Themenfeld einen klar abgrenzten Monatsblock erzeugt, sieht man das hier sofort."),

            .heading("Höhenkarte"),
            .image(filename: "07-heightmap-2d.jpg", caption: "Höhenkarte in 2D mit Konturlinien und KI-generierten Cluster-Labels."),
            .image(filename: "08-heightmap-3d.jpg", caption: "Dieselben Daten in 3D — Berge sind dichte Themen-Cluster, Täler sind isolierte Notizen."),
            .paragraph("Die einzige Ansicht, in der KI ins Spiel kommt. Jede Notiz wird via Embedding-Modell (Ollama bge-m3) in einen 1024-dimensionalen Vektor umgewandelt, der den semantischen Inhalt erfasst. Diese Vektoren werden dann via UMAP auf eine 2D-Ebene reduziert, sodass inhaltlich ähnliche Notizen nah beieinander landen, unabhängig davon, ob du sie verlinkt hast oder in welchen Ordner du sie gepackt hast. Aus der Punkt-Dichte wird via KDE eine Höhenfunktion berechnet: Hügel sind dichte Cluster ähnlicher Themen, Täler sind isolierte Notizen."),
            .paragraph("Wofür: deckt thematische Verwandtschaften auf, die du beim Schreiben gar nicht aktiv verlinkt hast. „Das hatte ich schon mal aufgeschrieben, aber wo?\"-Momente. In 3D wird das Höhenrelief plastisch, du kannst die Berge umkreisen. Die Cluster-Labels („Reisen 2024\", „Code-Snippets\" etc.) generiert Ollama mit gemma2 und cached sie. Eigene Sektion siehe „Höhenkarte\" für Setup und Privacy."),

            .heading("3D Force-Graph"),
            .image(filename: "09-3d-force-graph.jpg", caption: nil),
            .paragraph("Derselbe Verlink-Graph wie 2D, in drei Dimensionen via Three.js gerendert. Knoten verteilen sich um Cluster-Centroids auf einer Kugeloberfläche (Fibonacci-Sphere), die Verbindungen sind echte 3D-Linien. Mit der Maus kannst du die Kamera frei um den Graphen rotieren."),
            .paragraph("Wofür: räumliche Cluster-Strukturen werden plastisch erfahrbar. Du siehst auf einen Blick, welche Themen einen eigenen Ast bilden und wie die Cluster im Raum zueinander stehen. Besonders schön bei großen Vaults, wo die 2D-Projektion die Cluster zwangsläufig flach übereinanderlegt, in 3D bekommt jedes Cluster seinen eigenen Volumenbereich.")
        ]
        case .en: return [
            .paragraph("NotesMap has 8 views. Switch between them in the top header. Each one highlights a different question. Below, every view is described in detail, including its concrete use case and how it works under the hood."),
            .note("Every view has a ⓘ help icon in the top-right that shows the most important mouse and keyboard actions for that specific view. This help here gives the overview: what each view does and when to use it."),

            .heading("2D Force-Graph"),
            .image(filename: "01-2d-force-graph.jpg", caption: nil),
            .paragraph("The default view. Notes are nodes, [[wiki-links]] are springs. A live physics simulation runs in the background: linked notes attract each other, unlinked ones drift outward. Node size reflects the hub score (how many other notes link to it). Node color matches the folder."),
            .paragraph("What it's for: a quick answer to \"how does everything connect?\". You see at a glance the central hubs (big nodes in the middle), thematic clusters (nodes that ball up together), and isolated solo notes (drifting at the edge). Hover a node to highlight its directly connected neighbors and dim the rest. Click opens the detail panel; ⌘+Click opens the note in Apple Notes."),

            .heading("Radial"),
            .image(filename: "02-radial.jpg", caption: nil),
            .paragraph("Notes are grouped into pie slices by folder. The bigger the folder, the wider its sector. Within each sector, hubs (heavily-linked notes) sit near the center; weakly-linked notes sit near the edge."),
            .paragraph("What it's for: shows which folders are your \"heavyweights\" and where the most important notes inside each folder are. Long Bezier lines crossing the center are especially interesting: they're bridges, notes that link two different folders, often the conceptually richest items in your vault."),

            .heading("Radial 2 (Halo)"),
            .image(filename: "03-radial-2.jpg", caption: nil),
            .paragraph("Variant of Radial: all unlinked notes sit on a fixed outer ring (the \"halo\"); linked clusters get the full inner space. Makes connection structures extremely visible because the inner space is dedicated entirely to the linked notes."),
            .paragraph("What it's for: ideal when you want to find notes that need cleanup or linking. The halo-ring nodes are all solo notes with no incoming or outgoing links, prime candidates to delete or to attach to existing clusters. A thick halo means a lot of disconnected material in your vault."),

            .heading("Circos plot"),
            .image(filename: "04-circos.jpg", caption: nil),
            .paragraph("Borrowed from genomics. Folders become arc segments around the rim of a circle; each note is a radial bar on the inner ring (bar length proportional to hub score). Links are drawn as Bezier curves through the center. Same-folder links: shallow arcs hugging the rim. Cross-folder links: deep arcs diving through the middle."),
            .paragraph("What it's for: shows how strongly your notes link across folder boundaries. Lots of deep arcs through the center means an \"interwoven\" knowledge web where topics ignore folder boundaries. Few cross-arcs means your folders are independent silos in terms of content."),

            .heading("Days: calendar heatmap"),
            .image(filename: "05-days.jpg", caption: nil),
            .paragraph("One cell per day, years stacked, like the GitHub contribution grid. Cell brightness shows how many notes were created that day."),
            .paragraph("What it's for: reveals your personal writing rhythms. Bright clusters = productive stretches; dark blocks = breaks. Weekday-vs-weekend patterns often pop visually. Click a day to open a side panel with all notes from that day; from there you can jump straight into Apple Notes."),

            .heading("Months: monthly heatmap"),
            .image(filename: "06-months.jpg", caption: nil),
            .paragraph("One level above the daily heatmap: one cell per month, years as rows, brightness by note count. The \"Numbers: on/off\" toggle at the top shows or hides the per-cell counts."),
            .paragraph("What it's for: long-term trends. Life phases, project cycles, intensive periods. If almost all your notes come from one year, or a new topic creates a sharply-bounded month-block, you'll see it instantly."),

            .heading("Heightmap"),
            .image(filename: "07-heightmap-2d.jpg", caption: "Heightmap in 2D with contour lines and AI-generated cluster labels."),
            .image(filename: "08-heightmap-3d.jpg", caption: "Same data rotated into a 3D landscape — mountains are dense topic clusters, valleys are isolated notes."),
            .paragraph("The only view that pulls in AI. Each note is turned into a 1024-dimensional vector via an embedding model (Ollama's bge-m3), capturing semantic content. UMAP then reduces those vectors onto a 2D plane so notes with similar content land near each other, regardless of whether you've linked them or which folder they live in. From the point density a height function is computed via KDE: peaks are dense clusters of similar topics; valleys are isolated notes."),
            .paragraph("What it's for: surfaces thematic kinship that you never explicitly linked. \"I wrote about this before, but where?\" moments. In 3D the height relief becomes solid, you can rotate around the mountains. Cluster labels (\"Travel 2024\", \"Code snippets\", etc.) are generated by Ollama with gemma2 and cached. See the dedicated \"Heightmap\" section for setup and privacy details."),

            .heading("3D Force-Graph"),
            .image(filename: "09-3d-force-graph.jpg", caption: nil),
            .paragraph("The same link graph as 2D, rendered in three dimensions via Three.js. Nodes spread around cluster centroids on a Fibonacci sphere; edges are real 3D lines. You can rotate the camera freely around the graph with the mouse."),
            .paragraph("What it's for: spatial cluster structure becomes tangible. You see at a glance which topics form their own branch and how clusters sit relative to each other in space. Particularly nice with large vaults: the 2D projection inevitably overlaps clusters, in 3D each cluster gets its own volume.")
        ]
        }
    }

    /// Sektion: Bedienung (Suche, Filter, Klick-Verhalten, Refresh).
    static func controls(in lang: Localized.Lang) -> [Block] {
        switch lang {
        case .de: return [
            .heading("Suche"),
            .paragraph("Oben in jeder Ansicht ist ein Suchfeld. Es filtert die Knoten nach Titel-Substring (live, ohne Enter-Taste). Knoten, die nicht zur Suche passen, werden ausgegraut."),
            .heading("Klick-Verhalten"),
            .bullets([
                "Klick auf einen Knoten: öffnet das Detail-Panel (Snippet, Backlinks, ausgehende Links).",
                "⌘ + Klick: öffnet die Notiz direkt in Apple Notes.",
                "Klick + Ziehen auf leere Fläche: verschiebt die ganze Karte (Pan).",
                "Hover über einen Knoten: hebt seine direkten Verbindungen hervor, dimmt alles andere."
            ]),
            .heading("Filter unten"),
            .bullets([
                "Ordner-Panel (links): Aktivierte Ordner werden hell, der Rest dimmt. Mehrfach-Auswahl möglich.",
                "Tag-Panel (rechts): Gleiche Logik mit Hashtags aus deinen Notizen.",
                "Timeline (Mitte): Schiebe das Datum, um nur Notizen zu sehen, die bis zu diesem Zeitpunkt existierten („Time-Machine\")."
            ]),
            .heading("Refresh"),
            .paragraph("Wenn du in Apple Notes etwas änderst, kommt das Update meistens automatisch in NotesMap an (Datei-Watcher auf der SQLite-WAL). Falls nicht: ⌘R löst manuell ein Reload aus."),
            .heading("Settings"),
            .paragraph("⌘, öffnet die Einstellungen. Dort kannst du die Sprache (System / Deutsch / Englisch) und das Ollama-Modell wählen, das für die Höhenkarte genutzt wird.")
        ]
        case .en: return [
            .heading("Search"),
            .paragraph("Every view has a search field at the top. It filters nodes by title substring (live, no Enter needed). Nodes not matching the search are dimmed."),
            .heading("Click behavior"),
            .bullets([
                "Click a node: opens the detail panel (snippet, backlinks, outgoing links).",
                "⌘ + Click: opens the note directly in Apple Notes.",
                "Click + drag on empty space: pans the whole map.",
                "Hover a node: highlights its direct connections and dims the rest."
            ]),
            .heading("Filters at the bottom"),
            .bullets([
                "Folder panel (left): activated folders stay bright, the rest dims. Multi-select supported.",
                "Tag panel (right): same logic, but with hashtags from your notes.",
                "Timeline (middle): drag the date to see only notes that existed up to that moment (\"time machine\")."
            ]),
            .heading("Refresh"),
            .paragraph("When you change something in Apple Notes, the update usually flows into NotesMap automatically (a file watcher on the SQLite WAL). If not: ⌘R triggers a manual reload."),
            .heading("Settings"),
            .paragraph("⌘, opens Settings. You can pick the language (System / German / English) and the Ollama model used for the heightmap.")
        ]
        }
    }

    /// Sektion: Tastenkürzel als Tabelle.
    static func shortcuts(in lang: Localized.Lang) -> [Block] {
        switch lang {
        case .de: return [
            .heading("App-weit"),
            .shortcuts([
                ("⌘R", "Karte aus Apple Notes neu laden"),
                ("⌘,", "Einstellungen öffnen"),
                ("⌘?", "Diese Hilfe öffnen"),
                ("⌘W", "Fenster schließen"),
                ("⌘Q", "NotesMap beenden")
            ]),
            .heading("Im Karten-Bereich"),
            .shortcuts([
                ("Klick", "Notiz auswählen, Detail-Panel öffnen"),
                ("⌘ + Klick", "Notiz in Apple Notes öffnen"),
                ("Mausrad / Trackpad-Pinch", "Zoom rein/raus"),
                ("Klick + Ziehen leer", "Karte verschieben (Pan)"),
                ("Knoten ziehen", "Knoten manuell positionieren (sticky)"),
                ("Esc", "Aktuelles Detail-Panel schließen / Fokus zurücksetzen")
            ])
        ]
        case .en: return [
            .heading("App-wide"),
            .shortcuts([
                ("⌘R", "Reload the map from Apple Notes"),
                ("⌘,", "Open Settings"),
                ("⌘?", "Open this Help"),
                ("⌘W", "Close window"),
                ("⌘Q", "Quit NotesMap")
            ]),
            .heading("Inside the map"),
            .shortcuts([
                ("Click", "Select a note, open the detail panel"),
                ("⌘ + Click", "Open the note in Apple Notes"),
                ("Scroll wheel / pinch", "Zoom in/out"),
                ("Click + drag empty space", "Pan the whole map"),
                ("Drag a node", "Manually position a node (sticky)"),
                ("Esc", "Close the current detail panel / reset focus")
            ])
        ]
        }
    }

    /// Sektion: Höhenkarte mit Privacy-Hinweis.
    static func heightmap(in lang: Localized.Lang) -> [Block] {
        switch lang {
        case .de: return [
            .heading("Was ist die Höhenkarte?"),
            .paragraph("Die Höhenkarte ist eine 3D-Ansicht, die thematische Verwandtschaften sichtbar macht. Jede Notiz wird zu einem Punkt im Raum, dessen Position aus einem KI-Embedding ihres Inhalts kommt. Inhaltlich ähnliche Notizen liegen nah beieinander. Die Höhe (Z-Achse) zeigt die Cluster-Dichte: Berge sind Themen mit vielen Notizen, Täler sind dünn besiedelt."),
            .heading("Voraussetzung: Ollama"),
            .paragraph("Die Höhenkarte braucht Ollama als lokale KI. Ollama ist eine separate App, die du auf deinem Mac installierst. Sie läuft auf localhost:11434 (kein Cloud-Service)."),
            .bullets([
                "Ollama installieren von ollama.com",
                "Im Terminal: `ollama pull bge-m3` (Embedding-Modell, ~2 GB) und optional `ollama pull gemma2:2b` (für Cluster-Labels, ~1.5 GB)",
                "Wenn beide Modelle da sind, klick im NotesMap-Header auf „Höhenkarte\"."
            ]),
            .heading("Was zur Höhenkarte gehört"),
            .bullets([
                "Embedding-Berechnung: 1× pro Notiz beim ersten Mal (~100 ms pro Notiz, also bei 1000 Notizen rund 2 Minuten). Wird gecacht.",
                "Bandwidth-Slider: regelt die „Glätte\" des Reliefs. Größerer Wert = weichere Hügel, kleinerer = mehr Detail-Spitzen.",
                "Cluster-Labels: Ollama bekommt die Notizen pro Berg-Cluster und schreibt eine Themenüberschrift (z.B. „Reisen 2024\")."
            ]),
            .note("Datenschutz: Beim Berechnen schickt NotesMap pro Notiz Titel + die ersten ~4000 Zeichen an Ollama auf deinem Mac. Nichts geht ins Internet. Embeddings werden lokal in ~/Library/Application Support/NotesMap/ gespeichert (owner-only, 0600).")
        ]
        case .en: return [
            .heading("What is the Heightmap?"),
            .paragraph("The Heightmap is a 3D view that surfaces thematic kinship between notes. Each note becomes a point in space whose position comes from an AI embedding of its content. Notes with similar content sit close together. Height (Z-axis) shows cluster density: mountains are topics with many notes, valleys are sparse."),
            .heading("Prerequisite: Ollama"),
            .paragraph("The Heightmap needs Ollama as its local AI. Ollama is a separate app you install on your Mac. It runs on localhost:11434, not a cloud service."),
            .bullets([
                "Install Ollama from ollama.com.",
                "In Terminal: `ollama pull bge-m3` (embedding model, ~2 GB), and optionally `ollama pull gemma2:2b` (for cluster labels, ~1.5 GB).",
                "Once both models are present, click \"Heightmap\" in the NotesMap header."
            ]),
            .heading("What's part of the Heightmap"),
            .bullets([
                "Embedding computation: once per note on first run (~100 ms per note, so ~2 minutes for 1000 notes). Cached afterwards.",
                "Bandwidth slider: controls the smoothness of the relief. Larger = softer hills, smaller = more detailed peaks.",
                "Cluster labels: Ollama is asked to summarize the notes inside a peak into a title (e.g. \"Travel 2024\")."
            ]),
            .note("Privacy: per note, NotesMap sends title + first ~4000 characters to Ollama running on your Mac. Nothing leaves the device. Embeddings are cached locally in ~/Library/Application Support/NotesMap/ (owner-only, 0600).")
        ]
        }
    }

    /// Sektion: Datenschutz, Pfade, Permissions.
    static func privacy(in lang: Localized.Lang) -> [Block] {
        switch lang {
        case .de: return [
            .heading("Datenflüsse, einmal sauber aufgereiht"),
            .bullets([
                "NotesMap → Apple-Notes-DB: read-only Lesezugriff über Festplattenvollzugriff. Pfad: ~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite",
                "NotesMap → localhost:11434 (Ollama): nur wenn du die Höhenkarte nutzt. Pro Notiz Titel + ~4000 Zeichen Inhalt.",
                "NotesMap → Internet: nur Sparkle-Auto-Update prüft alle 24h die appcast.xml im GitHub-Repo. Keine User-Daten dabei.",
                "Apple Notes → NotesMap: nichts. NotesMap kann Apple Notes nicht ansprechen oder schreiben."
            ]),
            .heading("Wo Daten landen"),
            .bullets([
                "Embedding-Cache: ~/Library/Application Support/NotesMap/embeddings.json (Datei 0600, Verzeichnis 0700)",
                "Cluster-Label-Cache: ~/Library/Application Support/NotesMap/peak-labels.json (selbe Permissions)",
                "Spracheinstellung + Modell-Wahl: in UserDefaults der App",
                "Crash-Reports: nichts, NotesMap hat keinen Crash-Reporter eingebaut"
            ]),
            .heading("Was es nicht gibt"),
            .bullets([
                "Keine Telemetrie. Kein „anonymisiertes Nutzungs-Feedback\". Keine Analytics-SDK.",
                "Keine Cloud-LLMs. Keine OpenAI-, Anthropic-, Google-Integration.",
                "Keine Anmeldung. Kein Account."
            ]),
            .heading("Sandbox"),
            .paragraph("NotesMap läuft mit aktiver Hardened Runtime, aber bewusst ohne Apple Sandbox. Grund: die Apple-Notes-Datenbank liegt im Group-Container von Apple, sandboxed Drittanbieter-Apps können da nicht ran. macOS' Festplattenvollzugriff (mit Userprompt) ist statt­dessen die Vertrauensgrenze."),
            .link(text: "SECURITY.md im Repo", url: "https://github.com/floriankuemmel/notesmap-mac/blob/main/SECURITY.md")
        ]
        case .en: return [
            .heading("Data flows, in plain English"),
            .bullets([
                "NotesMap → Apple Notes DB: read-only access via Full Disk Access. Path: ~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite.",
                "NotesMap → localhost:11434 (Ollama): only when you use the Heightmap. Per note: title + first ~4000 characters.",
                "NotesMap → the Internet: only Sparkle's auto-update checks the appcast.xml in the GitHub repo every 24h. No user data attached.",
                "Apple Notes → NotesMap: nothing. NotesMap cannot talk to or write into Apple Notes."
            ]),
            .heading("Where data lives"),
            .bullets([
                "Embedding cache: ~/Library/Application Support/NotesMap/embeddings.json (file 0600, directory 0700)",
                "Cluster-label cache: ~/Library/Application Support/NotesMap/peak-labels.json (same permissions)",
                "Language + model preferences: in UserDefaults",
                "Crash reports: none. NotesMap has no crash reporter built in."
            ]),
            .heading("What's deliberately missing"),
            .bullets([
                "No telemetry. No \"anonymous usage data\". No analytics SDK.",
                "No cloud LLMs. No OpenAI, Anthropic, or Google integration.",
                "No sign-in. No account."
            ]),
            .heading("Sandbox"),
            .paragraph("NotesMap runs with the Hardened Runtime enabled, but deliberately without Apple's App Sandbox. Reason: the Apple Notes database lives in Apple's group container; sandboxed third-party apps cannot reach it. The Full Disk Access prompt (with explicit user consent) is the trust boundary instead."),
            .link(text: "SECURITY.md in the repo", url: "https://github.com/floriankuemmel/notesmap-mac/blob/main/SECURITY.md")
        ]
        }
    }

    /// Sektion: Probleme lösen / FAQ.
    static func troubleshooting(in lang: Localized.Lang) -> [Block] {
        switch lang {
        case .de: return [
            .heading("„Die Karte ist leer\""),
            .paragraph("Häufigste Ursache: Festplattenvollzugriff fehlt. NotesMap zeigt dann das Onboarding mit einem Button „Systemeinstellungen öffnen\". Schalte NotesMap dort ein und kehre zur App zurück, der Re-Check läuft automatisch."),
            .heading("„Die Karte zeigt zu wenige Notizen\""),
            .paragraph("Passwortgeschützte Notizen können nicht gelesen werden, sie tauchen ausgegraut auf. Notizen im Papierkorb werden ausgeblendet (im Such-Modus aber gefunden und mit Hinweis markiert)."),
            .heading("„Höhenkarte sagt: Ollama nicht erreichbar\""),
            .bullets([
                "Ollama-App offen? In der Menüleiste sollte das Ollama-Icon sichtbar sein.",
                "Modell vorhanden? Im Terminal: `ollama list`. Erwartet: bge-m3 (für Embeddings), optional gemma2:2b (für Labels).",
                "Modell ziehen falls nicht da: `ollama pull bge-m3`",
                "Anderer Port? NotesMap erwartet localhost:11434 (Ollama-Default)."
            ]),
            .heading("„Updates kommen nicht an, obwohl ich in Apple Notes was geändert hab\""),
            .paragraph("⌘R erzwingt einen Reload. Wenn das hilft, war das Auto-Update beim WAL-Watcher hängen geblieben (kommt vor wenn Apple Notes selber gerade synct)."),
            .heading("„Mac wird laut, Lüfter dreht hoch\""),
            .paragraph("Vermutlich läuft die Höhenkarte gerade Embeddings durch Ollama. Erste Berechnung bei 1000 Notizen: 1-3 Minuten. Danach wird gecacht und ist instant. Wenn du es vorzeitig stoppen willst: zur 2D-Ansicht zurückwechseln."),
            .heading("„Auto-Update findet keine neue Version\""),
            .paragraph("NotesMap-Menü → „Nach Updates suchen…\" erzwingt einen Check. Wenn auch das nichts findet, ist tatsächlich keine neue Version draußen."),
            .heading("„Ich will den Cache löschen\""),
            .paragraph("Im Terminal: `rm -rf ~/Library/Application\\ Support/NotesMap`. Beim nächsten Start wird neu aufgebaut. Sicher, kein Datenverlust außer zu Embeddings (werden neu berechnet).")
        ]
        case .en: return [
            .heading("\"The map is empty\""),
            .paragraph("Most common cause: Full Disk Access is missing. NotesMap shows the onboarding screen with an \"Open System Settings\" button. Turn NotesMap on there and switch back, the re-check runs automatically."),
            .heading("\"The map shows too few notes\""),
            .paragraph("Password-protected notes cannot be read, they appear dimmed. Notes in the trash are hidden (search mode finds them and marks them as deleted)."),
            .heading("\"Heightmap says Ollama unreachable\""),
            .bullets([
                "Is the Ollama app open? You should see its icon in the menu bar.",
                "Are the models there? In Terminal: `ollama list`. Expected: bge-m3 (for embeddings), optional gemma2:2b (for labels).",
                "Pull a missing model: `ollama pull bge-m3`",
                "Different port? NotesMap expects localhost:11434 (Ollama's default)."
            ]),
            .heading("\"Updates aren't arriving even though I changed something in Apple Notes\""),
            .paragraph("⌘R forces a reload. If that helps, the auto-update WAL watcher had stalled (happens when Apple Notes is mid-sync)."),
            .heading("\"My Mac is loud, fans spinning up\""),
            .paragraph("Most likely the heightmap is computing embeddings via Ollama. First run on 1000 notes: 1-3 minutes. After that everything is cached and instant. To stop it early: switch back to the 2D view."),
            .heading("\"Auto-update finds no new version\""),
            .paragraph("NotesMap menu → \"Check for Updates…\" forces a check. If that also finds nothing, there really is no newer version out."),
            .heading("\"I want to wipe the cache\""),
            .paragraph("In Terminal: `rm -rf ~/Library/Application\\ Support/NotesMap`. The next start rebuilds. Safe, no data loss except embeddings (will be recomputed).")
        ]
        }
    }

    /// Sektion: Über NotesMap, Lizenzen, Repo.
    static func about(in lang: Localized.Lang) -> [Block] {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        switch lang {
        case .de: return [
            .paragraph("NotesMap \(version) (Build \(build))"),
            .heading("In der App enthaltene Open-Source-Komponenten"),
            .bullets([
                "GRDB.swift (MIT), https://github.com/groue/GRDB.swift, SQLite-Layer für die Notes-DB",
                "Sparkle (MIT), https://github.com/sparkle-project/Sparkle, Auto-Update-System",
                "D3.js v7 (ISC), https://d3js.org, 2D-Visualisierungen",
                "Three.js (MIT), https://threejs.org, 3D-Rendering",
                "3d-force-graph (MIT), https://github.com/vasturiano/3d-force-graph, 3D-Graph-Layout",
                "umap-js (Apache-2.0), https://github.com/PAIR-code/umap-js, Dimensionsreduktion für die Höhenkarte"
            ]),
            .heading("Apple-System-Ressourcen"),
            .bullets([
                "SF Symbols, Apples Icon-Set, mit der App ausgeliefert (Apple Developer Agreement)"
            ]),
            .heading("Optional zur Laufzeit (extern installiert)"),
            .bullets([
                "Ollama (MIT), https://ollama.com, lokaler LLM-Runner",
                "bge-m3 (MIT), Embedding-Modell von BAAI, https://huggingface.co/BAAI/bge-m3",
                "gemma2 (Gemma Terms of Use), Sprachmodell von Google, https://ai.google.dev/gemma/terms"
            ]),
            .heading("Build-Tools (nicht in der App enthalten)"),
            .bullets([
                "XcodeGen (MIT), https://github.com/yonaskolb/XcodeGen, generiert das Xcode-Projekt aus project.yml"
            ]),
            .heading("Apple-Notes-Format"),
            .paragraph("Die Reverse-Engineering-Community hinter dem gzip-Protobuf-Format des Notes-Body-Felds. Ohne deren öffentliche Dokumentation wäre der Plaintext-Extraktor nicht möglich gewesen."),
            .heading("Wissenschaftliche Grundlagen"),
            .paragraph("Die zugrundeliegenden Techniken sind veröffentlichte Forschung, rechtlich nicht zitierpflichtig, aber wer sie nachlesen will:"),
            .link(
                text: "McInnes, Healy, Melville (2018) — UMAP: Uniform Manifold Approximation and Projection for Dimension Reduction (Höhenkarten-Layout)",
                url: "https://arxiv.org/abs/1802.03426"
            ),
            .link(
                text: "Krzywinski et al. (2009) — Circos: An information aesthetic for comparative genomics (Circos-Plot)",
                url: "https://genome.cshlp.org/content/19/9/1639"
            ),
            .link(
                text: "Fruchterman, Reingold (1991) — Graph drawing by force-directed placement (2D/3D Force-Graph)",
                url: "https://onlinelibrary.wiley.com/doi/10.1002/spe.4380211102"
            ),
            .link(
                text: "Chen et al. (2024) — BGE M3-Embedding: Multi-Lingual, Multi-Functionality, Multi-Granularity Text Embeddings (Embedding-Architektur)",
                url: "https://arxiv.org/abs/2402.03216"
            ),
            .heading("Lizenz"),
            .paragraph("NotesMap selbst ist unter MIT lizensiert. Kompletten Lizenz-Text findest du im Repo unter LICENSE."),
            .link(text: "Quellcode auf GitHub", url: "https://github.com/floriankuemmel/notesmap-mac"),
            .link(text: "Bug oder Feature melden", url: "https://github.com/floriankuemmel/notesmap-mac/issues/new")
        ]
        case .en: return [
            .paragraph("NotesMap \(version) (Build \(build))"),
            .heading("Bundled open-source components"),
            .bullets([
                "GRDB.swift (MIT), https://github.com/groue/GRDB.swift, SQLite layer for the Notes DB",
                "Sparkle (MIT), https://github.com/sparkle-project/Sparkle, auto-update system",
                "D3.js v7 (ISC), https://d3js.org, 2D visualizations",
                "Three.js (MIT), https://threejs.org, 3D rendering",
                "3d-force-graph (MIT), https://github.com/vasturiano/3d-force-graph, 3D graph layout",
                "umap-js (Apache-2.0), https://github.com/PAIR-code/umap-js, dimensionality reduction for the heightmap"
            ]),
            .heading("Apple system resources"),
            .bullets([
                "SF Symbols, Apple's icon set, distributed with the app (Apple Developer Agreement)"
            ]),
            .heading("Optional at runtime (installed separately)"),
            .bullets([
                "Ollama (MIT), https://ollama.com, local LLM runner",
                "bge-m3 (MIT), embedding model by BAAI, https://huggingface.co/BAAI/bge-m3",
                "gemma2 (Gemma Terms of Use), language model by Google, https://ai.google.dev/gemma/terms"
            ]),
            .heading("Build tools (not bundled)"),
            .bullets([
                "XcodeGen (MIT), https://github.com/yonaskolb/XcodeGen, generates the Xcode project from project.yml"
            ]),
            .heading("Apple Notes format"),
            .paragraph("The reverse-engineering community behind the gzip-protobuf format of the Notes body field. Without their public documentation the plaintext extractor would not have been possible."),
            .heading("Academic foundations"),
            .paragraph("The underlying techniques are published research, not legally required to cite, but if you want to read the originals:"),
            .link(
                text: "McInnes, Healy, Melville (2018) — UMAP: Uniform Manifold Approximation and Projection for Dimension Reduction (heightmap layout)",
                url: "https://arxiv.org/abs/1802.03426"
            ),
            .link(
                text: "Krzywinski et al. (2009) — Circos: An information aesthetic for comparative genomics (Circos plot)",
                url: "https://genome.cshlp.org/content/19/9/1639"
            ),
            .link(
                text: "Fruchterman, Reingold (1991) — Graph drawing by force-directed placement (2D/3D force graph)",
                url: "https://onlinelibrary.wiley.com/doi/10.1002/spe.4380211102"
            ),
            .link(
                text: "Chen et al. (2024) — BGE M3-Embedding: Multi-Lingual, Multi-Functionality, Multi-Granularity Text Embeddings (embedding architecture)",
                url: "https://arxiv.org/abs/2402.03216"
            ),
            .heading("License"),
            .paragraph("NotesMap itself is MIT-licensed. The full license text is in the repo at LICENSE."),
            .link(text: "Source on GitHub", url: "https://github.com/floriankuemmel/notesmap-mac"),
            .link(text: "Report a bug or request a feature", url: "https://github.com/floriankuemmel/notesmap-mac/issues/new")
        ]
        }
    }
}

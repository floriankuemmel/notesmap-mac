// LinkMapHTMLBuilder.swift, baut die Link-Map-HTML.
//
// MVP-Stand: buildPlaceholder() liefert eine dunkle "Hello from Swift"-Page,
// damit die Pipeline End-to-End steht (SwiftUI → WKWebView → HTML sichtbar).
//
// Nächste Schritte (Phase 2):
// - build(from: LinkIndex, snippets: [UUID: String]) -> String
//   portiert generateLinkMapHtml() aus dem TS-Projekt
// - Vendor-JS (d3.v7.min.js, 3d-force-graph.min.js) aus dem Bundle laden
//   und inline einbetten

import Foundation
import AppKit
import CryptoKit

enum LinkMapHTMLBuilderError: Error, LocalizedError {
    case vendorFileMissing(String)
    case vendorFileTampered(String, expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .vendorFileMissing(let name):
            return "Vendor-Datei fehlt im Bundle: \(name)"
        case .vendorFileTampered(let name, let expected, let actual):
            return "Vendor-Datei \(name) hat unerwarteten SHA-256-Hash. " +
                   "Erwartet: \(expected.prefix(12))…, gefunden: \(actual.prefix(12))…. " +
                   "Vermutlich wurde die Datei nach dem Build manipuliert."
        }
    }
}

enum LinkMapHTMLBuilder {

    /// Lädt das App-Icon aus dem Bundle, rendert es in 64x64 (für Retina)
    /// und liefert eine `data:image/png;base64,…`-URL zurück. Wird im Header
    /// statt des Karten-Emojis verwendet.
    /// Nil wenn das Icon nicht gefunden / nicht renderbar ist (Header-h1
    /// fällt dann ohne Icon zurück, statt zu crashen).
    private static func appIconDataURL() -> String? {
        guard let icon = NSImage(named: "AppIcon") else { return nil }
        let target = NSSize(width: 64, height: 64)  // 2x für 32px CSS auf Retina
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(target.width),
            pixelsHigh: Int(target.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let bitmap = bitmap else { return nil }
        bitmap.size = target

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.current = ctx
        icon.draw(in: NSRect(origin: .zero, size: target),
                  from: .zero, operation: .copy, fraction: 1.0)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }

    /// Rendert ein SF Symbol als PNG-data-URL für direkten Einsatz im HTML
    /// (`<img src="...">`). Wir nehmen den NSImage-Pfad mit
    /// `NSImage(systemSymbolName:)` und zeichnen ihn auf einen 2x-bitmap (für Retina).
    ///
    /// - parameters:
    ///   - name: SF-Symbol-Name (z.B. "rays", "mountain.2.fill")
    ///   - pointSize: gewünschte CSS-Pixel-Größe. Wir rendern 2x, also tatsächlich
    ///                doppelt so viele Bitmap-Pixel.
    ///   - weight: Symbol-Strichstärke. `.regular` ist der Standard für Toolbar-Icons.
    /// - returns: `data:image/png;base64,...` String, oder nil falls Symbol oder
    ///            Render-Pfad fehlschlägt (kann passieren wenn ein Symbol erst in
    ///            einer neueren macOS-Version verfügbar ist als unsere Deployment-Target).
    /// Rendert ein SF Symbol in eine PNG-data-URL plus liefert die natürliche Pixelgröße
    /// zurück. Höhe ist genau `pointSize` (Hochskaliert via SymbolConfiguration), Breite
    /// folgt dem natürlichen Seitenverhältnis des Symbols (z.B. mountain.2.fill ist
    /// breiter als tall, calendar ist quadratisch).
    static func sfSymbolDataURL(
        name: String,
        pointSize: CGFloat = 14,
        weight: NSFont.Weight = .regular
    ) -> (url: String, width: CGFloat, height: CGFloat)? {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }
        // Symbol-Konfiguration: Größe + Gewicht. Skaliert das Vektor-Symbol auf
        // pointSize-Höhe, Breite ergibt sich aus dem nativen Seitenverhältnis.
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard let configured = symbol.withSymbolConfiguration(config) else { return nil }

        let logicalW = configured.size.width
        let logicalH = configured.size.height
        let scale: CGFloat = 2  // 2x für Retina
        let pixelW = max(1, Int((logicalW * scale).rounded()))
        let pixelH = max(1, Int((logicalH * scale).rounded()))

        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelW,
            pixelsHigh: pixelH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let bitmap = bitmap else { return nil }
        bitmap.size = NSSize(width: logicalW, height: logicalH)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.current = ctx

        configured.draw(
            in: NSRect(origin: .zero, size: NSSize(width: logicalW, height: logicalH)),
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )

        // Weiß einfärben: das Header-Theme ist hardgecoded dunkel (#1a1a2e),
        // also brauchen wir weiße Icons. `NSCompositingOperation.sourceIn` nimmt
        // das Alpha-Profil aus dem Symbol und ersetzt die Farbe durch die aktuelle
        // Fülle, ohne das transparente Drumherum mitzufärben.
        NSColor.white.set()
        NSRect(origin: .zero, size: NSSize(width: logicalW, height: logicalH))
            .fill(using: .sourceIn)

        guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        let url = "data:image/png;base64," + png.base64EncodedString()
        return (url: url, width: logicalW, height: logicalH)
    }

    /// Komfort-Wrapper: liefert das fertige `<img>`-Tag für den View-Switcher.
    /// Breite und Höhe folgen dem natürlichen Seitenverhältnis des Symbols (z.B.
    /// mountain.2.fill ist nativ breiter als hoch). Vertikale Ausrichtung und
    /// horizontaler Abstand zum Label übernimmt das umgebende `display: inline-flex`
    /// im Button-CSS, hier brauchen wir keine Inline-Styles.
    /// Falls das Symbol nicht aufgelöst werden kann, wird ein leerer String
    /// zurückgegeben, damit der Button ohne Icon-Lücke angezeigt wird.
    static func sfSymbolIMG(_ name: String, pointSize: CGFloat = 14) -> String {
        guard let result = sfSymbolDataURL(name: name, pointSize: pointSize) else {
            return ""
        }
        let cssW = Int(result.width.rounded())
        let cssH = Int(result.height.rounded())
        return "<img src=\"\(result.url)\" width=\"\(cssW)\" height=\"\(cssH)\" alt=\"\">"
    }


    /// Platzhalter für den MVP, zeigt dass die Pipeline funktioniert.
    static func buildPlaceholder() throws -> String {
        let generatedAt = ISO8601DateFormatter().string(from: Date())

        return """
        <!DOCTYPE html>
        <html lang="de">
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(Self.contentSecurityPolicy)">
        <title>NotesMap</title>
        <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        html, body { height: 100%; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'SF Pro', system-ui, sans-serif;
            background: #1a1a2e;
            color: #e0e0e0;
            display: flex;
            align-items: center;
            justify-content: center;
            text-align: center;
        }
        .card {
            padding: 40px 48px;
            background: rgba(30, 30, 55, 0.6);
            border: 1px solid #333;
            border-radius: 16px;
            max-width: 560px;
        }
        h1 { font-size: 28px; margin-bottom: 12px; font-weight: 600; }
        .badge {
            display: inline-block;
            padding: 3px 10px;
            background: #4A90D9;
            color: white;
            border-radius: 999px;
            font-size: 11px;
            font-weight: 600;
            letter-spacing: 0.5px;
            text-transform: uppercase;
            margin-bottom: 20px;
        }
        p { color: #aaa; line-height: 1.6; margin-bottom: 12px; }
        code { background: rgba(255,255,255,0.06); padding: 2px 6px; border-radius: 4px; font-size: 13px; }
        .meta { margin-top: 24px; font-size: 11px; color: #666; font-variant-numeric: tabular-nums; }
        </style>
        </head>
        <body>
        <div class="card">
            <div class="badge">MVP</div>
            <h1>NotesMap</h1>
            <p>Native macOS-App, Pipeline steht.</p>
            <p>SwiftUI → <code>WKWebView</code> → HTML wird korrekt gerendert.</p>
            <p style="margin-top: 20px; font-size: 13px;">Nächste Schritte: SQLite-Reader (GRDB),
            Protobuf-Parser für Notiz-Inhalte, D3.js-Graph einbinden.</p>
            <div class="meta">Generiert: \(generatedAt)</div>
        </div>
        </body>
        </html>
        """
    }

    /// Slice-2b: Notiz-Liste mit Plaintext-Snippet (aus ZDATA extrahiert).
    static func buildNoteList(
        notes: [NoteSummary],
        snippetByNoteId: [Int64: String],
        totalCount: Int,
        limit: Int = 30
    ) -> String {
        let generatedAt = ISO8601DateFormatter().string(from: Date())
        let visible = Array(notes.prefix(limit))

        let dateFmt = DateFormatter()
        dateFmt.locale = Locale(identifier: "de_DE")
        dateFmt.dateFormat = "dd.MM.yyyy"

        let withSnippetCount = snippetByNoteId.count

        let items = visible.map { note -> String in
            let title = escapeHTML(note.title)
            let folder = note.folderName.map { " · " + escapeHTML($0) } ?? ""
            let date = note.createdAt.map { " · " + dateFmt.string(from: $0) } ?? ""
            let href = note.deepLink?.absoluteString ?? "#"

            let snippetHTML: String
            let body: String = {
                guard let snip = snippetByNoteId[note.id], !snip.isEmpty else { return "" }
                return stripTitlePrefix(snip, title: note.title)
            }()
            if body.isEmpty {
                snippetHTML = "<p class=\"snippet empty\">(kein weiterer Text)</p>"
            } else {
                snippetHTML = "<p class=\"snippet\">\(escapeHTML(truncate(body, to: 180)))</p>"
            }

            return """
            <li>
                <div class="row-head">
                    <a href="\(href)">\(title)</a>
                    <span class="meta-row">\(folder)\(date)</span>
                </div>
                \(snippetHTML)
            </li>
            """
        }.joined(separator: "\n")

        let moreHint = totalCount > visible.count
            ? "<p class=\"hint\">… und \(totalCount - visible.count) weitere Notizen.</p>"
            : ""

        return """
        <!DOCTYPE html>
        <html lang="de">
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(Self.contentSecurityPolicy)">
        <title>NotesMap</title>
        <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'SF Pro', system-ui, sans-serif;
            background: #1a1a2e;
            color: #e0e0e0;
            padding: 32px 40px;
            line-height: 1.5;
        }
        h1 { font-size: 24px; margin-bottom: 4px; font-weight: 600; }
        .badge {
            display: inline-block; padding: 3px 10px; background: #4A90D9; color: white;
            border-radius: 999px; font-size: 11px; font-weight: 600;
            letter-spacing: 0.5px; text-transform: uppercase; margin-bottom: 16px;
        }
        .count { color: #4A90D9; font-size: 14px; margin-bottom: 20px; font-variant-numeric: tabular-nums; }
        ul { list-style: none; max-width: 860px; }
        li {
            padding: 12px 16px; border-bottom: 1px solid rgba(255,255,255,0.06);
        }
        li:hover { background: rgba(255,255,255,0.02); }
        .row-head {
            display: flex; justify-content: space-between; align-items: baseline;
            gap: 16px; margin-bottom: 4px;
        }
        .row-head a { color: #e0e0e0; text-decoration: none; font-weight: 500; flex: 1; min-width: 0;
               overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .row-head a:hover { color: #4A90D9; }
        .meta-row { color: #666; font-size: 12px; flex-shrink: 0; font-variant-numeric: tabular-nums; }
        .snippet { color: #888; font-size: 13px; line-height: 1.4; }
        .snippet.empty { color: #555; font-style: italic; }
        .hint { color: #888; font-size: 13px; margin-top: 16px; }
        .meta { margin-top: 24px; font-size: 11px; color: #555; font-variant-numeric: tabular-nums; }
        </style>
        </head>
        <body>
        <div class="badge">Slice 2b</div>
        <h1>NotesMap</h1>
        <p class="count">\(totalCount) Notizen · \(withSnippetCount) mit extrahiertem Text · zeige \(visible.count)</p>
        <ul>
        \(items)
        </ul>
        \(moreHint)
        <div class="meta">Generiert: \(generatedAt)</div>
        </body>
        </html>
        """
    }

    /// Schneidet Text auf `max` Zeichen, hängt Ellipse an.
    private static func truncate(_ text: String, to max: Int) -> String {
        guard text.count > max else { return text }
        let cut = text.prefix(max)
        if let lastSpace = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: lastSpace) > max - 30 {
            return cut[..<lastSpace] + "…"
        }
        return cut + "…"
    }

    /// Wenn der Plaintext mit dem Notiz-Titel beginnt, den Titel-Prefix abziehen.
    /// (Apple Notes speichert Titel als erste Zeile im Body-Protobuf.)
    private static func stripTitlePrefix(_ text: String, title: String) -> String {
        guard !title.isEmpty, text.hasPrefix(title) else { return text }
        let rest = text.dropFirst(title.count)
        return String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func escapeHTML(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        out = out.replacingOccurrences(of: "'", with: "&#39;")
        return out
    }

    // MARK: - Vendor-Ressourcen

    /// Erwartete SHA-256-Hashes der mitgelieferten Vendor-JS-Dateien.
    ///
    /// Werden bei jedem `loadVendorScript` gegen den Datei-Inhalt verglichen. Wenn ein
    /// Hash nicht passt, bricht der Build ab statt den manipulierten Inhalt in den
    /// WebView zu injizieren. Schützt gegen einen Angreifer, der mit Schreibzugriff
    /// auf das App-Bundle (z.B. nach Gatekeeper-Bypass) eine der minified-JS-Dateien
    /// austauschen will.
    ///
    /// Aktualisierung: nach Update einer Vendor-Datei `scripts/update-vendor-hashes.sh`
    /// laufen lassen, der Output ersetzt diese Tabelle.
    private static let vendorScriptSHA256: [String: String] = [
        "3d-force-graph.min.js": "d96e738edcca580edd524730c1c6b05ed2efce028c23ca95db1bf43033a72e42",
        "d3.v7.min.js":          "f2094bbf6141b359722c4fe454eb6c4b0f0e42cc10cc7af921fc158fceb86539",
        "three.min.js":          "8a5f7249903b54d30f79f708699d2fed2d6a1d0741a4cd41377d1f01bb5a2271",
        "umap-js.min.js":        "9d226db25cc57eae1e1843765eac64c90f6bccfdeb2c2be2520b2e310abc3ded",
    ]

    /// Lädt eine Vendor-JS-Datei aus dem App-Bundle (Resources/vendor/) und verifiziert
    /// ihren SHA-256-Hash gegen den eingebackenen Wert in `vendorScriptSHA256`.
    /// Durchsucht beide möglichen Bundle-Layouts: mit und ohne "vendor/"-Prefix.
    static func loadVendorScript(named filename: String) throws -> String {
        let url: URL
        if let u = Bundle.main.url(forResource: filename, withExtension: nil, subdirectory: "vendor") {
            url = u
        } else if let u = Bundle.main.url(forResource: filename, withExtension: nil) {
            url = u
        } else {
            throw LinkMapHTMLBuilderError.vendorFileMissing(filename)
        }

        let data = try Data(contentsOf: url)

        if let expectedHash = vendorScriptSHA256[filename] {
            let actualHash = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
            if actualHash != expectedHash {
                throw LinkMapHTMLBuilderError.vendorFileTampered(
                    filename, expected: expectedHash, actual: actualHash
                )
            }
        }
        // Files ohne Eintrag in vendorScriptSHA256 werden ungeprüft geladen, kommt
        // praktisch nicht vor (alle vier shippen mit Hash), aber rufseitig sichtbar.

        guard let script = String(data: data, encoding: .utf8) else {
            throw LinkMapHTMLBuilderError.vendorFileMissing(filename)
        }
        return script
    }

    // MARK: - Slice-2c: echter D3-Force-Graph

    /// Shell-Folder: Default-Inbox + Papierkorb. Werden als kleine Punkte auf
    /// einer äußeren Schale gerendert statt als thematischer Cluster, damit die
    /// "echten" Ordner-Cluster visuell dominieren können.
    private static let shellFolders: Set<String> = [
        "Notes", "Notizen", "Recently Deleted", "Zuletzt gelöscht"
    ]

    /// Baut die interaktive Link-Map-HTML aus dem fertigen Graph + Snippets.
    /// `lang` steuert die UI-Sprache der WebView (Default = .de für Backwards-Compat).
    static func build(
        graph: LinkGraph,
        snippetByNoteId: [Int64: String],
        lang: Localized.Lang = .de
    ) throws -> String {
        let d3Script = try loadVendorScript(named: "d3.v7.min.js")
        let forceGraph3dScript = try loadVendorScript(named: "3d-force-graph.min.js")
        let umapScript = try loadVendorScript(named: "umap-js.min.js")
        let threeScript = try loadVendorScript(named: "three.min.js")

        let payloadString = try buildDataPayload(graph: graph, snippetByNoteId: snippetByNoteId)
        let generatedAt = shortDateTimeFormatter.string(from: Date())

        return renderHTML(
            d3Script: d3Script,
            forceGraph3dScript: forceGraph3dScript,
            umapScript: umapScript,
            threeScript: threeScript,
            payloadJSON: payloadString,
            generatedAt: generatedAt,
            lang: lang
        )
    }

    /// Lokalisierungs-Helper: kürzeres `t(\.key)` für inline-Verwendung im HTML-String.
    /// Wird in renderHTML(...) als Closure übergeben.
    typealias L = (KeyPath<Localized, Localized.T2>) -> String

    /// Baut nur den JSON-Payload (nodes/edges/folders/stats), ohne HTML-Rahmen.
    /// Wird für inkrementelle Updates genutzt: statt die ganze Seite neu zu laden,
    /// schickt LinkMapModel diesen JSON-String via `evaluateJavaScript` an
    /// `window.__applyDataUpdate(...)` im laufenden JS.
    static func buildDataPayload(
        graph: LinkGraph,
        snippetByNoteId: [Int64: String]
    ) throws -> String {
        // Folder-Palette (wie im TS, aber feste Zuweisung nach sortiertem Namen)
        let folders = Set(graph.nodes.map { $0.folderName }).sorted()
        var folderColors: [String: String] = [:]
        for (idx, folder) in folders.enumerated() {
            folderColors[folder] = folderPalette[idx % folderPalette.count]
        }

        let nodesJSON: [[String: Any]] = graph.nodes.map { node in
            let snippet = (snippetByNoteId[node.noteId] ?? "")
                .replacingOccurrences(of: "\n", with: " ")
            let trimmed = snippet.count > 500 ? String(snippet.prefix(500)) + "…" : snippet
            // Unix-Millisekunden für JS-Date(). 0 = unbekannt → von Time-Filter ausgeschlossen.
            let createdMs = node.createdAt.map { Int($0.timeIntervalSince1970 * 1000) } ?? 0
            return [
                "id": node.uuid,
                "title": node.title,
                "folder": node.folderName,
                "color": folderColors[node.folderName] ?? "#888888",
                "incoming": node.incomingCount,
                "outgoing": node.outgoingCount,
                "hubScore": node.hubScore,
                "isShell": shellFolders.contains(node.folderName),
                "created": createdMs,
                "snippet": trimmed,
                "link": "applenotes:note/\(node.uuid)",
                "tags": node.tags
            ]
        }
        let edgesJSON: [[String: String]] = graph.edges.map { edge in
            ["source": edge.sourceUuid, "target": edge.targetUuid]
        }
        let folderLegendJSON: [[String: String]] = folders.map { folder in
            ["name": folder, "color": folderColors[folder] ?? "#888888"]
        }

        // Globale Tag-Liste mit Häufigkeit. Zählt pro Notiz, nicht pro Vorkommen
        //, eine Notiz mit mehrfach gleichem `#tag` zählt einmal (dedupliziert
        // schon in LinkIndex über Set).
        var tagCounts: [String: Int] = [:]
        for node in graph.nodes {
            for tag in node.tags {
                tagCounts[tag, default: 0] += 1
            }
        }
        // Sortierung: nach Count desc, bei Gleichstand alphabetisch asc.
        let tagsListJSON: [[String: Any]] = tagCounts
            .sorted { a, b in
                if a.value != b.value { return a.value > b.value }
                return a.key < b.key
            }
            .map { ["tag": $0.key, "count": $0.value] }

        let payload: [String: Any] = [
            "nodes": nodesJSON,
            "edges": edgesJSON,
            "folders": folderLegendJSON,
            "tagsList": tagsListJSON,
            "stats": [
                "total": graph.noteCount,
                "linked": graph.linkedCount,
                "orphans": graph.orphanCount,
                "edges": graph.edges.count
            ] as [String: Any]
        ]
        let payloadJSON = try JSONSerialization.data(withJSONObject: payload, options: [])
        let raw = String(data: payloadJSON, encoding: .utf8) ?? "{}"
        return Self.escapeJSONForScriptInline(raw)
    }

    /// Härtet einen JSON-String gegen DOM-XSS, wenn er direkt in ein `<script>`-Tag
    /// oder via `evaluateJavaScript` in den WKWebView eingebettet wird.
    ///
    /// `JSONSerialization` escaped Steuerzeichen, Backslashes und Anführungszeichen, aber
    /// **nicht** `<`. Eine Notiz mit dem Titel `</script><img src=x onerror=alert(1)>`
    /// würde sonst als HTML aus dem `<script>`-Block ausbrechen.
    ///
    /// Lösung: jedes `<` wird in seine 6-Zeichen-Unicode-Escape-Form (Backslash, u, 003C)
    /// umgewandelt, gültig in JSON und in JS-String-Literalen. JSON.parse und der
    /// JS-Source-Parser dekodieren das transparent zurück zu `<`, der HTML-Parser sieht
    /// aber nie das Pattern `</script>` und beendet das Script-Element nicht vorzeitig.
    /// U+2028/U+2029 werden zusätzlich escaped, weil JS-Engines vor ES2019 sie als
    /// Zeilenumbruch interpretieren und Source-Parsing brechen kann.
    static func escapeJSONForScriptInline(_ json: String) -> String {
        json
            .replacingOccurrences(of: "<", with: "\\u003C")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    // MARK: - Folder-Palette (21 Farben wie im TS-Projekt)

    private static let folderPalette: [String] = [
        "#4A90D9", "#E67E22", "#27AE60", "#9B59B6", "#E74C3C",
        "#1ABC9C", "#F39C12", "#34495E", "#D35400", "#16A085",
        "#8E44AD", "#2ECC71", "#C0392B", "#2980B9", "#F1C40F",
        "#7F8C8D", "#E91E63", "#00BCD4", "#795548", "#607D8B",
        "#FF5722"
    ]

    private static let shortDateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "dd.MM.yyyy HH:mm"
        return f
    }()

    /// Content-Security-Policy für die WebView-Pages.
    ///
    /// `default-src 'none'` verbietet erstmal alles und whitelist-et dann gezielt
    /// nur was die Map wirklich braucht:
    /// - `script-src 'unsafe-inline' 'unsafe-eval'`: alles JS ist inline gebaut
    ///   (Vendor-JS wird zur Build-Zeit als String injiziert, nicht als externe URL
    ///   geladen). `unsafe-inline` ist nötig, weil Inline-Scripts ohne Hash/Nonce sonst
    ///   blockiert würden. `unsafe-eval` ist nötig, weil 3d-force-graph (6×) und d3
    ///   (1×) `new Function(...)` zum JIT-Kompilieren von Accessoren verwenden.
    /// - `style-src 'unsafe-inline'`: alle Styles sind inline `<style>`-Blöcke.
    /// - `img-src data:`: das Header-Logo wird als data-URL eingebettet.
    /// - `font-src data:`: defensiv, falls jemand mal eine Webfont als data-URI einbettet.
    /// - `connect-src 'none'`: blockt fetch/XHR/WebSocket. Die Swift-Seite spricht
    ///   ausschließlich via `window.webkit.messageHandlers` — das ist eine WebKit-interne
    ///   Bridge und wird von CSP nicht kontrolliert.
    /// - `object-src`, `base-uri`, `form-action 'none'`: schließt die typischen
    ///   Auxiliar-Vektoren (Plugins, base href Hijacking, Form-Submission).
    ///
    /// Threat-Model: selbst falls ein zukünftiger Bug XSS erlaubt, kann der Angreifer
    /// trotz `unsafe-inline` + `unsafe-eval` keine Daten abziehen (kein fetch, kein
    /// Image-Beacon, kein Form-Submit, kein iframe).
    static let contentSecurityPolicy: String = [
        "default-src 'none'",
        "script-src 'unsafe-inline' 'unsafe-eval'",
        "style-src 'unsafe-inline'",
        "img-src data:",
        "font-src data:",
        "connect-src 'none'",
        "object-src 'none'",
        "base-uri 'none'",
        "form-action 'none'",
    ].joined(separator: "; ")

    // MARK: - Die eigentliche HTML-Seite

    private static func renderHTML(
        d3Script: String,
        forceGraph3dScript: String,
        umapScript: String,
        threeScript: String,
        payloadJSON: String,
        generatedAt: String,
        lang: Localized.Lang
    ) -> String {
        // Lokalisierte Strings als Inline-Variablen, werden via String-Interpolation
        // in den HTML-Block eingefügt. Backwards-kompatibel: ohne Locale = de.
        func t(_ kp: KeyPath<Localized, Localized.T2>) -> String {
            Localized.string(kp, in: lang)
        }
        let htmlLang = lang == .de ? "de" : "en"
        let pageTitle = t(\.appTitle) + ": Link-Map"
        let labelDays = t(\.viewLabelCalendar)
        let labelMonths = t(\.viewLabelMonthly)
        let labelHeightmap = t(\.viewLabelHeightmap)
        let labelFolders = t(\.filterFolders)
        let labelTags = t(\.filterTags)
        let labelTagsEmpty = t(\.filterEmpty)
        let labelResetTooltip = t(\.filterReset)
        let labelOpenInNotes = t(\.panelOpenInNotes)
        let labelToday = t(\.timelineToday)

        // Header- und Toolbar-Strings
        let titleHeaderRefresh = t(\.wvHeaderRefresh)
        let titleLiveDot = t(\.wvLiveDot)

        // Calendar/Monthly toggles
        let titleMonthlyToggleNumbers = t(\.wvMonthlyToggleNumbers)
        let labelMonthlyNumbersOn = t(\.wvMonthlyNumbersOn)

        // Heightmap color toggles
        let titleHmColorFolder = t(\.wvHmColorFolderTitle)
        let labelHmColorFolder = t(\.wvHmColorFolder)
        let titleHmColorHub = t(\.wvHmColorHubTitle)
        let labelHmColorHub = t(\.wvHmColorHub)
        let titleHmColorCreated = t(\.wvHmColorCreatedTitle)
        let labelHmColorCreated = t(\.wvHmColorCreated)

        // Heightmap view toggles
        let titleHm2D = t(\.wvHm2DTitle)
        let titleHm3D = t(\.wvHm3DTitle)
        let titleHmBandwidth = t(\.wvHmBandwidthTitle)

        // Timeline
        let titlePlay = t(\.wvPlayTitle)
        let titleHeatmap = t(\.wvHeatmapTitle)

        // Heightmap-Bottom-Bar Labels
        let labelHmFarbe = t(\.wvHmLabelColor)
        let labelHmAnsicht = t(\.wvHmLabelView)
        let labelHmDetail = t(\.wvHmLabelDetail)
        let labelHmContour = t(\.wvHmContour)

        // View-Button-Tooltips
        let tip2D = t(\.wvTip2D)
        let tipRadial = t(\.wvTipRadial)
        let tipRadial2 = t(\.wvTipRadial2)
        let tipCircos = t(\.wvTipCircos)
        let tipCalendar = t(\.wvTipCalendar)
        let tipMonthly = t(\.wvTipMonthly)
        let tipHeightmap = t(\.wvTipHeightmap)
        let tip3D = t(\.wvTip3D)

        // SF-Symbol-Icons für den View-Switcher. Werden als data-URL-PNGs ins HTML
        // eingebettet, weil WebKit/HTML keinen direkten SF-Symbols-Zugriff hat.
        // Auswahl: jedes Icon bildet die Mechanik der Ansicht visuell ab.
        let icon2D = Self.sfSymbolIMG("network")                  // verbundene Knoten
        let iconRadial = Self.sfSymbolIMG("rays")                 // Linien aus dem Zentrum
        let iconRadial2 = Self.sfSymbolIMG("circle.dashed")       // Halo-Außenring
        let iconCircos = Self.sfSymbolIMG("circle.hexagonpath")   // Bögen am Kreisrand
        let iconCalendar = Self.sfSymbolIMG("calendar")           // Tages-Heatmap
        let iconMonthly = Self.sfSymbolIMG("rectangle.grid.2x2")  // Monats-Grid
        let iconHeightmap = Self.sfSymbolIMG("mountain.2.fill")   // Berge
        let icon3D = Self.sfSymbolIMG("cube")                     // 3D-Würfel

        // Suche
        let searchPlaceholder = t(\.wvSearchPlaceholder)
        let searchTooltip = t(\.wvSearchTooltip)

        // Help-Panel
        let helpButtonTitle = t(\.wvHelpButtonTitle)
        let helpInteractionsLabel = t(\.wvHelpInteractions)
        let helpTipLabel = t(\.wvHelpTip)
        let helpCloseLabel = t(\.wvHelpClose)
        let helpJSON = ViewHelp.allAsJSON(in: lang)

        // „Generiert"-Label oben rechts
        let generatedLabel = String(format: t(\.wvGeneratedAt), generatedAt)

        // App-Icon als data-URL für den Header (statt 🗺-Emoji).
        // Fallback auf das Emoji wenn das Icon-Asset nicht geladen werden kann.
        let appIconDataURL = Self.appIconDataURL()
        let headerIcon: String = appIconDataURL.map {
            "<img src=\"\($0)\" width=\"22\" height=\"22\" alt=\"\" style=\"vertical-align:-5px;margin-right:6px;border-radius:5px\">"
        } ?? "🗺 "

        // Stats
        let labelStatsNotes = t(\.wvStatsNotes)
        let labelStatsLinks = t(\.wvStatsLinks)
        let labelStatsOrphans = t(\.wvStatsOrphans)

        // JS-side localized strings als JSON-Objekt für window.NM_LOC.*
        let jsLocaleObject = Localized.jsLocaleObject(in: lang)

        return #"""
        <!DOCTYPE html>
        <html lang="\#(htmlLang)">
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\#(Self.contentSecurityPolicy)">
        <title>\#(pageTitle)</title>
        <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, BlinkMacSystemFont, 'SF Pro', system-ui, sans-serif; background: #1a1a2e; color: #e0e0e0; overflow: hidden; }

        #header { position: fixed; top: 0; left: 0; right: 0; z-index: 100; background: rgba(26,26,46,0.92); backdrop-filter: blur(10px); border-bottom: 1px solid #333; padding: 10px 18px; display: flex; align-items: center; gap: 16px; height: 50px; }
        #header h1 { font-size: 15px; font-weight: 600; white-space: nowrap; }
        #stats { font-size: 12px; color: #888; display: flex; gap: 14px; }
        .stat-value { color: #4A90D9; font-weight: 600; }

        #mode-toggle { display: flex; border-radius: 8px; overflow: hidden; border: 1px solid #444; margin-left: 6px; flex-shrink: 0; }
        /* inline-flex + nowrap stellt sicher, dass Icon und Label garantiert in einer
           Zeile bleiben und vertikal zur Mitte ausgerichtet sind. Ohne das brach das
           Inline-Img bei schmalen Buttons (z.B. „Radial 2") in eine zweite Textzeile. */
        #mode-toggle button { display: inline-flex; align-items: center; gap: 5px; padding: 6px 10px; border: none; background: #2a2a4a; color: #888; font-size: 12px; cursor: pointer; font-family: inherit; transition: all 0.15s; white-space: nowrap; }
        #mode-toggle button img { display: block; flex-shrink: 0; }
        #mode-toggle button.active { background: #4A90D9; color: white; }
        #mode-toggle button:hover:not(.active) { background: #3a3a5a; color: #ccc; }
        /* Progressive Collapse beim Verschmälern des Fensters. Reihenfolge: zuerst
           geht der Timestamp weg, dann die View-Labels (Icons reichen + Tooltip),
           erst ganz zum Schluss die Stats (informativste Daten zuletzt).
           Inhaltsbreiten-Berechnung: Title 140 + Toggle (700/300) + Suche 120 +
           Refresh+Info 80 + Live-Dot 14 + Stats 280 + Timestamp 80 + Gaps 140 +
           Padding 36 = 1590 (alles) / 1190 (ohne Labels) / 910 (auch ohne Stats).
           Breakpoints sind je 50px Buffer über dem Pflichtminimum. */
        @media (max-width: 1550px) {
            #generated-at { display: none; }
        }
        @media (max-width: 1450px) {
            #mode-toggle button { padding: 6px 8px; }
            #mode-toggle button .lbl { display: none; }
        }

        #btn-refresh { margin-left: 10px; display: inline-flex; align-items: center; justify-content: center; width: 28px; height: 28px; border: 1px solid #444; border-radius: 6px; background: #2a2a4a; color: #aaa; cursor: pointer; font-family: inherit; font-size: 14px; transition: all 0.15s; padding: 0; }
        #btn-refresh:hover { color: #fff; background: #3a3a5a; border-color: #4A90D9; }
        #btn-refresh.spinning { color: #4A90D9; pointer-events: none; }
        #btn-refresh.spinning svg { animation: spin 1s linear infinite; }
        @keyframes spin { to { transform: rotate(360deg); } }

        /* Suche im Header — schmaler Input mit Lupen-Icon. Filtert ALLE Views
           über nodeMatches() (zusammen mit Folder + Tag Filter). */
        #search-wrap { position: relative; margin-left: 8px; flex-shrink: 1; min-width: 120px; }
        #search-input { width: 180px; max-width: 100%; padding: 5px 10px 5px 28px; border-radius: 6px; border: 1px solid #444; background: #2a2a4a; color: #e0e0e0; font-size: 12px; font-family: inherit; outline: none; transition: border-color 0.15s, background 0.15s; }
        #search-input::placeholder { color: #666; }
        #search-input:hover { border-color: #555; }
        #search-input:focus { border-color: #4A90D9; background: #2f2f55; }
        #search-icon { position: absolute; left: 9px; top: 50%; transform: translateY(-50%); color: #666; pointer-events: none; }
        #search-clear { position: absolute; right: 7px; top: 50%; transform: translateY(-50%); width: 16px; height: 16px; display: none; align-items: center; justify-content: center; border-radius: 50%; background: #555; color: #fff; cursor: pointer; font-size: 11px; line-height: 1; padding: 0; border: none; }
        #search-wrap.has-text #search-clear { display: flex; }
        #search-clear:hover { background: #777; }

        /* Info-Button (ⓘ), gleicher Stil wie Refresh */
        #btn-info { margin-left: 6px; display: inline-flex; align-items: center; justify-content: center; width: 28px; height: 28px; border: 1px solid #444; border-radius: 6px; background: #2a2a4a; color: #aaa; cursor: pointer; font-family: inherit; transition: all 0.15s; padding: 0; }
        #btn-info:hover { color: #fff; background: #3a3a5a; border-color: #4A90D9; }
        #btn-info.active { color: #fff; background: #4A90D9; border-color: #4A90D9; }

        /* Instant-Tooltip, zeigt sofort bei Hover (kein native title-Delay).
           Wird in JS auf Elemente mit data-tip aufgesetzt. */
        #instant-tooltip { position: fixed; z-index: 1000; padding: 6px 10px; background: rgba(20,20,30,0.97); color: #fff; border: 1px solid #444; border-radius: 6px; font-size: 12px; line-height: 1.4; max-width: 360px; pointer-events: none; opacity: 0; transition: opacity 0.08s; box-shadow: 0 4px 14px rgba(0,0,0,0.45); }
        #instant-tooltip.visible { opacity: 1; }

        /* Help-Modal */
        #help-modal { display: none; position: fixed; inset: 0; z-index: 200; background: rgba(0,0,0,0.55); backdrop-filter: blur(6px); align-items: center; justify-content: center; padding: 40px; animation: hm-fade-in 0.18s ease; }
        #help-modal.visible { display: flex; }
        @keyframes hm-fade-in { from { opacity: 0 } to { opacity: 1 } }
        #help-modal-card { background: rgb(34,34,58); border: 1px solid #3a3a5a; border-radius: 16px; padding: 28px 32px; max-width: 680px; width: 100%; max-height: 100%; overflow-y: auto; box-shadow: 0 20px 60px rgba(0,0,0,0.55); position: relative; animation: hm-pop 0.2s cubic-bezier(0.2, 0.8, 0.3, 1.1); }
        @keyframes hm-pop { from { transform: scale(0.96) translateY(8px); opacity: 0 } to { transform: none; opacity: 1 } }
        #help-modal-card h2 { font-size: 20px; font-weight: 600; color: #fff; margin: 0 0 12px 0; padding-right: 32px; }
        #help-modal-card h3 { font-size: 11px; font-weight: 700; color: #888; text-transform: uppercase; letter-spacing: 0.5px; margin: 20px 0 8px 0; }
        #help-modal-card p { font-size: 13.5px; line-height: 1.55; color: #d8d8e8; margin: 0 0 6px 0; }
        #help-modal-card ul { margin: 0; padding-left: 20px; }
        #help-modal-card li { font-size: 13px; line-height: 1.5; color: #c8c8d8; margin-bottom: 5px; }
        #help-modal-card #help-tip { font-size: 13px; color: #ffcc66; background: rgba(230,160,40,0.08); border-left: 3px solid #ffcc66; padding: 10px 14px; border-radius: 4px; line-height: 1.5; }
        #help-modal-close { position: absolute; top: 14px; right: 14px; width: 28px; height: 28px; border: none; background: rgba(255,255,255,0.06); color: #aaa; font-size: 20px; line-height: 1; cursor: pointer; border-radius: 6px; padding: 0; transition: all 0.12s; }
        #help-modal-close:hover { color: #fff; background: rgba(255,255,255,0.14); }
        #live-dot { width: 6px; height: 6px; border-radius: 50%; background: #4ade80; margin-left: 8px; display: inline-block; box-shadow: 0 0 4px #4ade80; transition: background 0.3s, box-shadow 0.3s; }
        #live-dot.offline { background: #555; box-shadow: none; }

        /* Default: Graph reicht bis ganz unten. Nur in 2D-Force und 3D wird
           70px für die Timeline reserviert, sonst klafft sonst da ein leerer
           dunkler Streifen unter Radial/Radial 2/Circos/Calendar/Monthly/etc. */
        #graph-2d, #graph-3d, #graph-circos, #graph-calendar, #graph-monthly, #graph-heightmap { position: fixed; top: 50px; left: 0; right: 0; bottom: 0; }
        body[data-mode="2d"][data-layout="force"] #graph-2d,
        body[data-mode="3d"] #graph-3d { bottom: 70px; }
        #graph-3d, #graph-circos, #graph-calendar, #graph-monthly, #graph-heightmap { display: none; }
        #graph-2d svg, #graph-circos svg { width: 100%; height: 100%; cursor: grab; }
        #graph-2d svg:active, #graph-circos svg:active { cursor: grabbing; }
        /* --- Calendar-Heatmap (GitHub-Style) --- */
        #graph-calendar { overflow: hidden; }
        #calendar-scroll { position: absolute; inset: 0; overflow-y: auto; overflow-x: auto; padding: 24px 32px 40px 32px; }
        #graph-calendar .cal-year { margin-bottom: 28px; }
        #graph-calendar .cal-year-header { display: flex; align-items: baseline; justify-content: space-between; margin-bottom: 8px; padding-right: 8px; }
        #graph-calendar .cal-year-title { font-size: 16px; font-weight: 600; color: #e0e0e0; letter-spacing: 0.5px; }
        #graph-calendar .cal-year-count { font-size: 12px; color: #888; font-variant-numeric: tabular-nums; }
        #graph-calendar .cal-grid { display: grid; grid-template-columns: 28px 1fr; gap: 6px; }
        #graph-calendar .cal-weekday-col { display: grid; grid-template-rows: repeat(7, 14px); row-gap: 3px; padding-top: 18px; min-width: 26px; }
        #graph-calendar .cal-weekday-col span { font-size: 9.5px; color: #888; line-height: 14px; text-align: right; padding-right: 6px; font-variant-caps: all-small-caps; letter-spacing: 0.3px; }
        #graph-calendar .cal-month-row { display: flex; height: 14px; margin-bottom: 4px; position: relative; }
        #graph-calendar .cal-month-row span { position: absolute; font-size: 10px; color: #888; top: 0; }
        #graph-calendar .cal-week-grid { display: grid; grid-auto-flow: column; grid-template-rows: repeat(7, 14px); grid-auto-columns: 14px; column-gap: 3px; row-gap: 3px; }
        #graph-calendar .cal-cell { width: 14px; height: 14px; border-radius: 3px; background: #222233; cursor: pointer; transition: transform 0.08s ease, outline-color 0.15s; outline: 1.5px solid transparent; }
        #graph-calendar .cal-cell:hover { transform: scale(1.35); outline-color: #fff; z-index: 2; position: relative; }
        #graph-calendar .cal-cell.selected { outline-color: #ffcc66; transform: scale(1.35); z-index: 2; position: relative; }
        #graph-calendar .cal-cell.out-of-year { visibility: hidden; }
        #graph-calendar .cal-cell.lv1 { background: #0e3b6b; }
        #graph-calendar .cal-cell.lv2 { background: #1e5ca3; }
        #graph-calendar .cal-cell.lv3 { background: #3a7fcf; }
        #graph-calendar .cal-cell.lv4 { background: #6aabef; }
        #graph-calendar .cal-cell.lv5 { background: #a6cdf7; }
        /* Schwebende Legende unten-mittig im Kalender-View (nicht mitscrollen).
           Mittig statt rechts, weil das Tag-Panel rechts unten sitzt und
           rechts-bündige Positionierung kollidiert. */
        #calendar-legend { position: absolute; bottom: 16px; left: 50%; transform: translateX(-50%); display: none; align-items: center; gap: 5px; font-size: 10.5px; color: #aaa; background: rgba(26,26,46,0.85); backdrop-filter: blur(8px); border: 1px solid #333; border-radius: 999px; padding: 6px 12px; pointer-events: none; z-index: 20; white-space: nowrap; }
        #calendar-legend.visible { display: inline-flex; }
        #calendar-legend .cal-legend-swatch { width: 11px; height: 11px; border-radius: 2px; }
        #calendar-legend .cal-legend-sep { color: #555; margin: 0 4px; }
        #calendar-legend .cal-legend-max { color: #777; font-variant-numeric: tabular-nums; }
        #calendar-tooltip { position: fixed; background: #1a1a2e; border: 1px solid #4A90D9; border-radius: 6px; padding: 6px 10px; font-size: 11px; color: #e0e0e0; pointer-events: none; display: none; z-index: 300; max-width: 260px; line-height: 1.45; box-shadow: 0 4px 12px rgba(0,0,0,0.5); }
        #calendar-tooltip .tt-date { font-weight: 600; color: #fff; margin-bottom: 3px; }
        #calendar-tooltip .tt-count { color: #4A90D9; margin-bottom: 3px; font-variant-numeric: tabular-nums; }
        #calendar-tooltip .tt-titles { color: #bbb; font-size: 10.5px; }
        /* Day-Panel (Liste der Notizen eines Tages, Klick öffnet applenotes:) */
        /* top/bottom anchored statt max-height, damit das Panel nie ins
           TAGS-Panel reinläuft. TAGS sitzt bei bottom:80 und ist collapsed
           ~36px hoch → reicht bis bottom:116. Mit bottom:140 bleibt
           ~24px Luft. Bei voll expandierten TAGS (max-height 100vh-180)
           gibt's noch Overlap, aber dann kollabiert der User halt TAGS. */
        #day-panel { position: fixed; top: 60px; right: 16px; bottom: 140px; width: 340px; background: rgba(30,30,55,0.97); backdrop-filter: blur(10px); border: 1px solid #444; border-radius: 12px; padding: 16px; display: none; z-index: 50; flex-direction: column; }
        #day-panel.visible { display: flex; }
        #day-panel h2 { font-size: 15px; font-weight: 600; margin-bottom: 4px; color: #fff; }
        #day-panel-meta { font-size: 12px; color: #888; margin-bottom: 12px; }
        #day-panel-list { overflow-y: auto; flex: 1; display: flex; flex-direction: column; gap: 6px; }
        #day-panel-list a { display: block; padding: 8px 10px; border-radius: 6px; background: rgba(255,255,255,0.04); color: #e0e0e0; text-decoration: none; font-size: 12.5px; line-height: 1.35; border-left: 3px solid #4A90D9; transition: background 0.12s; }
        #day-panel-list a:hover { background: rgba(74,144,217,0.18); }
        #day-panel-list a .dp-folder { display: block; font-size: 10.5px; color: #888; margin-top: 2px; }
        #day-panel-close { position: absolute; top: 8px; right: 10px; width: 24px; height: 24px; border: none; background: transparent; color: #888; font-size: 20px; line-height: 1; cursor: pointer; border-radius: 4px; padding: 0; }
        #day-panel-close:hover { color: #fff; background: rgba(255,255,255,0.08); }
        /* --- Monthly-Heatmap (Jahre × Monate) --- */
        #graph-monthly { overflow: hidden; }
        #monthly-scroll { position: absolute; inset: 0; overflow-y: auto; overflow-x: auto; padding: 40px 48px; display: flex; align-items: center; justify-content: center; }
        #graph-monthly .mo-wrap { display: inline-block; }
        #graph-monthly .mo-grid { display: grid; grid-template-columns: 58px repeat(12, 54px); grid-auto-rows: 40px; column-gap: 6px; row-gap: 6px; align-items: center; }
        #graph-monthly .mo-header { font-size: 11px; color: #888; text-align: center; font-variant-caps: all-small-caps; letter-spacing: 0.5px; padding-bottom: 4px; }
        #graph-monthly .mo-corner { }
        #graph-monthly .mo-year-label { font-size: 13px; font-weight: 600; color: #e0e0e0; text-align: right; padding-right: 10px; letter-spacing: 0.3px; font-variant-numeric: tabular-nums; }
        #graph-monthly .mo-cell { background: #222233; border-radius: 5px; cursor: pointer; display: flex; align-items: center; justify-content: center; font-size: 13px; font-weight: 500; color: rgba(255,255,255,0.78); transition: transform 0.08s ease, outline-color 0.15s; outline: 1.5px solid transparent; font-variant-numeric: tabular-nums; }
        #graph-monthly .mo-cell:hover { transform: scale(1.08); outline-color: #fff; z-index: 2; position: relative; }
        #graph-monthly .mo-cell.selected { outline-color: #ffcc66; transform: scale(1.08); z-index: 2; position: relative; }
        #graph-monthly .mo-cell.empty { color: #555; font-weight: 400; background: #1e1e2e; }
        #graph-monthly .mo-cell.lv1 { background: #0e3b6b; }
        #graph-monthly .mo-cell.lv2 { background: #1e5ca3; }
        #graph-monthly .mo-cell.lv3 { background: #3a7fcf; color: #fff; }
        #graph-monthly .mo-cell.lv4 { background: #6aabef; color: #0a1520; }
        #graph-monthly .mo-cell.lv5 { background: #a6cdf7; color: #0a1520; }
        #graph-monthly .mo-cell.out-of-range { background: transparent; color: transparent; cursor: default; pointer-events: none; border: 1px dashed #2a2a3a; }
        /* Bottom-Bar: Toggle + Legende nebeneinander, zentriert.
           Oberhalb vom ORDNER-/TAGS-Panel (die sitzen bei bottom~80px).
           Höher positioniert als 16px, um Konflikt mit ORDNER-Panel zu vermeiden. */
        #monthly-bottom-bar { position: absolute; bottom: 18px; left: 50%; transform: translateX(-50%); display: flex; gap: 10px; align-items: center; z-index: 21; pointer-events: none; }
        #monthly-bottom-bar > * { pointer-events: auto; }
        #monthly-legend { display: none; align-items: center; gap: 5px; font-size: 10.5px; color: #aaa; background: rgba(26,26,46,0.85); backdrop-filter: blur(8px); border: 1px solid #333; border-radius: 999px; padding: 6px 12px; white-space: nowrap; pointer-events: none; }
        #monthly-legend.visible { display: inline-flex; }
        #monthly-legend .cal-legend-swatch { width: 11px; height: 11px; border-radius: 2px; }
        #monthly-legend .cal-legend-sep { color: #555; margin: 0 4px; }
        #monthly-legend .cal-legend-max { color: #777; font-variant-numeric: tabular-nums; }
        /* Toggle-Button: Zahlen in Zellen ein/aus. */
        #monthly-toggle-numbers { font-size: 11px; color: #ccc; background: rgba(26,26,46,0.85); backdrop-filter: blur(8px); border: 1px solid #333; border-radius: 999px; padding: 6px 14px; cursor: pointer; font-family: inherit; transition: all 0.15s; white-space: nowrap; }
        #monthly-toggle-numbers:hover { border-color: #4A90D9; color: #fff; }
        #monthly-toggle-numbers.off { color: #888; }
        /* Wenn Klasse `.numbers-hidden` am #graph-monthly: alle Zell-Texte transparent.
           Layout bleibt identisch (flex-center mit leerem "Text" behält die Zellgröße). */
        #graph-monthly.numbers-hidden .mo-cell { color: transparent; }

        /* --- Höhenkarte (UMAP + Contour) --- */
        #graph-heightmap { overflow: hidden; }
        #heightmap-contour { position: absolute; top: 0; left: 0; width: 100%; height: 100%; display: block; }
        #heightmap-svg { position: absolute; top: 0; left: 0; width: 100%; height: 100%; display: block; }
        /* 2D-Label-Overlay: liegt über Canvas+SVG, in 3D-Mode verborgen. */
        #heightmap-2d-labels { display: block; }
        #graph-heightmap.mode-3d #heightmap-2d-labels { display: none; }
        #heightmap3d-canvas-container { position: absolute; top: 0; left: 0; width: 100%; height: 100%; display: none; }
        #heightmap3d-canvas-container canvas { display: block; }
        #graph-heightmap.mode-3d #heightmap-contour,
        #graph-heightmap.mode-3d #heightmap-svg { display: none; }
        #graph-heightmap.mode-3d #heightmap3d-canvas-container { display: block; }
        /* Thematische Berg-Labels (DOM-Overlay, Screen-projiziert im RAF-Loop) */
        .hm3d-label {
            position: absolute; top: 0; left: 0;
            padding: 3px 9px;
            background: rgba(26, 26, 46, 0.82);
            border: 1px solid rgba(255, 255, 255, 0.25);
            border-radius: 12px;
            font-size: 11px;
            font-weight: 500;
            color: #f4f4f8;
            white-space: nowrap;
            text-shadow: 0 1px 2px rgba(0,0,0,0.75);
            pointer-events: none;
            user-select: none;
            -webkit-backdrop-filter: blur(4px);
            backdrop-filter: blur(4px);
            box-shadow: 0 2px 8px rgba(0,0,0,0.45);
            will-change: transform;
            transition: opacity 0.18s, border-color 0.18s;
        }
        /* Zustände:
         *   .pending  = Ollama noch nicht geantwortet → Fallback-Text, gedimmt + gestrichelt.
         *   .ready    = Ollama-Label erhalten → volle Opazität, dezente blaue Kante.
         *   .failed   = Ollama-Batch fertig ohne Antwort für diesen Peak → leicht abgedunkelt.
         * Damit sieht der User auf einen Blick, ob die KI durchgekommen ist. */
        .hm3d-label.pending {
            opacity: 0.55;
            border-style: dashed;
            border-color: rgba(255, 255, 255, 0.35);
        }
        .hm3d-label.pending::before {
            content: "⋯ ";
            opacity: 0.75;
            margin-right: 2px;
        }
        .hm3d-label.ready {
            border-color: rgba(120, 180, 255, 0.55);
        }
        .hm3d-label.failed {
            opacity: 0.75;
            border-color: rgba(255, 170, 120, 0.55);
        }
        #heightmap-svg circle { cursor: pointer; stroke: #1a1a28; stroke-width: 0.5px; transition: stroke 0.12s, stroke-width 0.12s; }
        #heightmap-svg circle:hover { stroke: #fff; stroke-width: 1.5px; }
        #heightmap-svg circle.hm-dim { opacity: 0.15; pointer-events: none; }
        #heightmap-tooltip { position: fixed; background: #1a1a2e; border: 1px solid #4A90D9; border-radius: 6px; padding: 7px 11px; font-size: 11.5px; color: #e0e0e0; pointer-events: none; display: none; z-index: 300; max-width: 340px; box-shadow: 0 4px 14px rgba(0,0,0,0.5); }
        #heightmap-tooltip .hm-tt-title { font-weight: 600; margin-bottom: 3px; color: #fff; }
        #heightmap-tooltip .hm-tt-meta { font-size: 10.5px; color: #888; font-variant-numeric: tabular-nums; }
        #heightmap-bottom-bar { position: absolute; bottom: 18px; left: 50%; transform: translateX(-50%); display: flex; gap: 14px; align-items: center; z-index: 21; pointer-events: none; }
        #heightmap-bottom-bar > * { pointer-events: auto; }
        #heightmap-bottom-bar .heightmap-sort-group { display: flex; gap: 2px; align-items: center; background: rgba(26,26,46,0.85); backdrop-filter: blur(8px); border: 1px solid #333; border-radius: 999px; padding: 4px 8px; font-size: 11px; color: #aaa; }
        #heightmap-bottom-bar .heightmap-sort-label { color: #777; margin-right: 4px; font-variant-caps: all-small-caps; letter-spacing: 0.5px; }
        #heightmap-bottom-bar .heightmap-sort-group button { font-size: 11px; color: #ccc; background: transparent; border: none; border-radius: 999px; padding: 4px 10px; cursor: pointer; font-family: inherit; transition: all 0.15s; }
        #heightmap-bottom-bar .heightmap-sort-group button:hover { color: #fff; background: rgba(255,255,255,0.06); }
        #heightmap-bottom-bar .heightmap-sort-group button.active { color: #fff; background: #4A90D9; font-weight: 600; }
        /* Peak-Count-Slider-Pill, selbes Pill-Chrome wie die Button-Gruppen, aber
           mit einer nativen range-Input in der Mitte. Die Webkit-Thumb-Farbe
           matched den aktiven Button-Hintergrund. */
        #heightmap-bottom-bar .heightmap-slider-group { padding-right: 12px; }
        #heightmap-bottom-bar .heightmap-slider-group input[type="range"] {
            -webkit-appearance: none;
            appearance: none;
            background: transparent;
            width: 96px;
            height: 14px;
            margin: 0 6px 0 2px;
            cursor: pointer;
        }
        #heightmap-bottom-bar .heightmap-slider-group input[type="range"]::-webkit-slider-runnable-track {
            height: 3px;
            background: rgba(255,255,255,0.18);
            border-radius: 999px;
        }
        #heightmap-bottom-bar .heightmap-slider-group input[type="range"]::-webkit-slider-thumb {
            -webkit-appearance: none;
            appearance: none;
            width: 12px;
            height: 12px;
            background: #4A90D9;
            border-radius: 50%;
            margin-top: -4.5px;
            cursor: pointer;
            border: 2px solid rgba(26,26,46,0.95);
        }
        #heightmap-bottom-bar .heightmap-slider-group .heightmap-slider-value {
            color: #fff;
            font-weight: 600;
            font-variant-numeric: tabular-nums;
            min-width: 1.4em;
            text-align: right;
            font-size: 11px;
        }
        #heightmap-contour-toggle { display: inline-flex; align-items: center; gap: 6px; font-size: 11px; color: #aaa; cursor: pointer; user-select: none; background: rgba(26,26,46,0.85); backdrop-filter: blur(8px); border: 1px solid #333; border-radius: 999px; padding: 6px 12px; }
        #heightmap-contour-toggle:hover { color: #fff; }
        #heightmap-contour-toggle input { cursor: pointer; accent-color: #4A90D9; }
        #heightmap-legend { display: none; align-items: center; gap: 4px; font-size: 10.5px; color: #aaa; background: rgba(26,26,46,0.85); backdrop-filter: blur(8px); border: 1px solid #333; border-radius: 999px; padding: 6px 12px; white-space: nowrap; }
        #heightmap-legend.visible { display: inline-flex; }
        #heightmap-legend .hm-legend-grad { width: 80px; height: 8px; border-radius: 2px; }
        #heightmap-legend .hm-legend-cap { font-variant-numeric: tabular-nums; color: #ccc; }
        #heightmap-overlay { position: absolute; inset: 0; background: rgba(20,20,35,0.94); backdrop-filter: blur(6px); display: flex; align-items: center; justify-content: center; z-index: 50; transition: opacity 0.3s; }
        #heightmap-overlay.hidden { opacity: 0; pointer-events: none; }
        #heightmap-overlay-inner { max-width: 460px; padding: 28px 32px; text-align: center; background: rgba(26,26,46,0.9); border: 1px solid #3a3a5a; border-radius: 12px; box-shadow: 0 8px 28px rgba(0,0,0,0.5); }
        #heightmap-title { font-size: 16px; font-weight: 600; margin-bottom: 10px; color: #e0e0e0; }
        #heightmap-message { font-size: 12.5px; color: #aaa; line-height: 1.55; margin-bottom: 18px; }
        #heightmap-progress-bar { width: 100%; height: 6px; background: #2a2a4a; border-radius: 3px; overflow: hidden; margin-bottom: 10px; }
        #heightmap-progress-fill { height: 100%; width: 0%; background: linear-gradient(90deg, #4A90D9, #8dc5ff); transition: width 0.25s; }
        #heightmap-detail { font-size: 11px; color: #777; font-variant-numeric: tabular-nums; min-height: 14px; }
        #heightmap-overlay.error #heightmap-progress-bar { background: #4a2a2a; }
        #heightmap-overlay.error #heightmap-progress-fill { background: #e05454; width: 100% !important; }
        #heightmap-overlay.error #heightmap-title { color: #e05454; }

        /* Circos-spezifische Styles */
        #graph-circos .folder-arc { stroke: #1a1a28; stroke-width: 1px; cursor: pointer; transition: opacity 0.2s; }
        #graph-circos .folder-arc:hover { opacity: 0.85; }
        #graph-circos .folder-label { fill: #aaa; font-size: 10px; font-family: -apple-system, sans-serif; pointer-events: none; }
        #graph-circos .note-tick { cursor: pointer; }
        #graph-circos .note-tick.dim { opacity: 0.18; }
        #graph-circos .note-tick.hot { stroke: #fff; stroke-width: 1.5px; }
        #graph-circos .link-arc { fill: none; stroke: #4A90D9; stroke-opacity: 0.22; stroke-width: 0.8px; pointer-events: none; transition: stroke-opacity 0.2s, stroke-width 0.2s; }
        #graph-circos .link-arc.dim { stroke-opacity: 0.04; }
        #graph-circos .link-arc.hot { stroke: #ffcc66; stroke-opacity: 0.95; stroke-width: 1.4px; }

        .link { stroke: #667; stroke-opacity: 0.45; stroke-width: 1px; }
        .link.dimmed { stroke-opacity: 0.08; }
        .link.highlighted { stroke: #4A90D9; stroke-opacity: 0.9; stroke-width: 1.8px; }

        .node circle { stroke: #1a1a2e; stroke-width: 1.5px; cursor: pointer; transition: stroke-width 0.15s; }
        .node.highlighted circle { stroke: #fff; stroke-width: 2.5px; }
        .node.selected circle { stroke: #4A90D9; stroke-width: 3px; }
        .node.dimmed { opacity: 0.15; }
        .node-label { font-size: 10px; fill: #ddd; pointer-events: none; text-anchor: middle; font-family: inherit; }

        /* --- Panel rechts --- */
        #panel { position: fixed; top: 60px; right: 16px; width: 320px; background: rgba(30,30,55,0.97); backdrop-filter: blur(10px); border: 1px solid #444; border-radius: 12px; padding: 16px; display: none; z-index: 50; max-height: calc(100vh - 150px); flex-direction: column; }
        #panel h2 { font-size: 16px; font-weight: 600; margin-bottom: 4px; line-height: 1.3; }
        #panel .meta { font-size: 12px; color: #888; margin-bottom: 10px; display: flex; align-items: center; gap: 6px; }
        #panel .link-counts { display: flex; gap: 14px; margin-bottom: 10px; }
        #panel .link-count { display: flex; align-items: center; gap: 5px; font-size: 12px; color: #aaa; }
        #panel .link-count .num { font-weight: 700; font-size: 16px; color: #e0e0e0; }
        #panel .link-count.incoming .arrow { color: #4A90D9; }
        #panel .link-count.outgoing .arrow { color: #E67E22; }
        #panel-snippet { font-size: 13px; color: #bbb; line-height: 1.55; flex: 1; overflow-y: auto; border-top: 1px solid #333; padding-top: 10px; white-space: pre-wrap; word-break: break-word; max-height: 380px; }
        #panel .btn { display: block; text-align: center; margin-top: 10px; padding: 8px 14px; border-radius: 8px; background: #4A90D9; color: white; text-decoration: none; font-size: 13px; font-weight: 500; }
        #panel .btn:hover { background: #357ABD; }
        #panel-close { position: absolute; top: 8px; right: 10px; background: none; border: none; color: #888; font-size: 18px; cursor: pointer; line-height: 1; padding: 4px 8px; }
        #panel-close:hover { color: #fff; }

        /* --- Ordner-Legende --- */
        #legend { position: fixed; bottom: 80px; left: 14px; background: rgb(30,30,55); border: 1px solid #444; border-radius: 10px; z-index: 50; max-height: calc(100vh - 180px); display: flex; flex-direction: column; width: 220px; }
        #legend-header { display: flex; align-items: center; justify-content: space-between; padding: 8px 12px; cursor: pointer; user-select: none; }
        #legend-header:hover { background: rgba(255,255,255,0.04); border-radius: 10px; }
        #legend.expanded #legend-header { border-bottom: 1px solid #333; border-radius: 10px 10px 0 0; }
        #legend h3 { font-size: 11px; color: #aaa; font-weight: 600; letter-spacing: 0.5px; text-transform: uppercase; display: flex; align-items: center; gap: 6px; }
        #legend-summary { font-size: 10px; color: #666; }
        #legend.has-selection #legend-summary { color: #4A90D9; font-weight: 600; }
        #legend-clear { display: none; font-size: 14px; color: #E67E22; cursor: pointer; margin-left: 6px; line-height: 1; font-weight: 700; }
        #legend-clear:hover { color: #ff9844; }
        #legend.has-selection #legend-clear { display: inline-block; }
        #legend-toggle { font-size: 10px; color: #888; transition: transform 0.2s; }
        #legend.expanded #legend-toggle { transform: rotate(180deg); }
        #legend-body { padding: 4px 10px 10px 10px; overflow-y: auto; display: none; }
        #legend.expanded #legend-body { display: block; }
        .legend-item { display: flex; align-items: center; gap: 8px; font-size: 11px; padding: 3px 6px; color: #ccc; cursor: pointer; border-radius: 4px; opacity: 0.8; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .legend-item:hover { opacity: 1; color: white; background: rgba(255,255,255,0.04); }
        .legend-item.active { opacity: 1; color: white; font-weight: 600; background: rgba(74,144,217,0.15); }
        .legend-dot { width: 9px; height: 9px; border-radius: 50%; flex-shrink: 0; }
        .legend-item span.count { color: #666; font-size: 10px; margin-left: auto; padding-left: 4px; }

        /* --- Tag-Panel (Spiegel der Ordner-Legende, rechts) --- */
        #tag-panel { position: fixed; bottom: 80px; right: 14px; background: rgb(30,30,55); border: 1px solid #444; border-radius: 10px; z-index: 50; max-height: calc(100vh - 180px); display: flex; flex-direction: column; width: 220px; }
        #tag-panel-header { display: flex; align-items: center; justify-content: space-between; padding: 8px 12px; cursor: pointer; user-select: none; }
        #tag-panel-header:hover { background: rgba(255,255,255,0.04); border-radius: 10px; }
        #tag-panel.expanded #tag-panel-header { border-bottom: 1px solid #333; border-radius: 10px 10px 0 0; }
        #tag-panel h3 { font-size: 11px; color: #aaa; font-weight: 600; letter-spacing: 0.5px; text-transform: uppercase; display: flex; align-items: center; gap: 6px; }
        #tag-panel-summary { font-size: 10px; color: #666; }
        #tag-panel.has-selection #tag-panel-summary { color: #4A90D9; font-weight: 600; }
        #tag-panel-clear { display: none; font-size: 14px; color: #E67E22; cursor: pointer; margin-left: 6px; line-height: 1; font-weight: 700; }
        #tag-panel-clear:hover { color: #ff9844; }
        #tag-panel.has-selection #tag-panel-clear { display: inline-block; }
        #tag-panel-toggle { font-size: 10px; color: #888; transition: transform 0.2s; }
        #tag-panel.expanded #tag-panel-toggle { transform: rotate(180deg); }
        #tag-panel-body { padding: 4px 10px 10px 10px; overflow-y: auto; display: none; }
        #tag-panel.expanded #tag-panel-body { display: block; }
        #tag-panel-empty { font-size: 11px; color: #666; padding: 6px 8px; font-style: italic; }
        .tag-item { display: flex; align-items: center; gap: 8px; font-size: 11px; padding: 3px 6px; color: #ccc; cursor: pointer; border-radius: 4px; opacity: 0.85; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .tag-item:hover { opacity: 1; color: white; background: rgba(255,255,255,0.04); }
        .tag-item.active { opacity: 1; color: white; font-weight: 600; background: rgba(74,144,217,0.15); }
        .tag-dot { width: 9px; height: 9px; border-radius: 50%; flex-shrink: 0; background: #666; }
        .tag-item.active .tag-dot { background: #4A90D9; }
        .tag-item span.tag-name { overflow: hidden; text-overflow: ellipsis; }
        .tag-item span.count { color: #666; font-size: 10px; margin-left: auto; padding-left: 4px; }

        /* Generate-Zeitstempel im Header (vorher als Footer rechts unten, kollidiert mit Tag-Panel) */
        #generated-at { margin-left: auto; font-size: 10px; color: #555; font-variant-numeric: tabular-nums; }

        /* Stats werden erst bei sehr schmalen Fenstern ausgeblendet, weil sie die
           informativsten Daten im Header sind (Notiz-Anzahl, Verlinkungen). Sobald
           View-Labels bereits aus sind und nur noch Icons da sind, brauchen wir nur
           noch ~910px für alles inkl. Stats. Unter 1100px geben wir die Stats auf,
           damit auch bei sehr schmalem Fenster (Min ist 900px) nichts überläuft. */
        @media (max-width: 1100px) {
            #stats { display: none; }
        }

        /* --- Timeline unten --- */
        #timeline { position: fixed; bottom: 0; left: 0; right: 0; z-index: 100; background: rgba(26,26,46,0.95); backdrop-filter: blur(10px); border-top: 1px solid #333; padding: 8px 18px 10px 18px; display: flex; align-items: center; gap: 14px; height: 70px; }
        /* Timeline ausblenden in Views, in denen sie keinen Sinn ergibt:
           - Calendar/Monthly: die Views SIND eine Timeline (doppelt gemoppelt)
           - Heightmap: basiert auf Embeddings, Zeitfilter würde Re-Compute triggern */
        /* Timeline standardmäßig versteckt, nur in 2D-Force und 3D wieder
           einblenden. In Radial/Radial 2/Circos hat sie keinen sinnvollen
           Effekt (Layout ist statisch); in Calendar/Monthly ist die View
           selbst eine Timeline; in Heightmap basieren Embeddings auf
           allen Notizen, Zeitfilter würde Re-Compute triggern. */
        #timeline { display: none; }
        body[data-mode="2d"][data-layout="force"] #timeline,
        body[data-mode="3d"] #timeline { display: flex; }
        /* In Views ohne Timeline rutschen Folder-/Tag-Panels nach unten:
           sonst klafft da ein 80px-Loch. */
        #legend, #tag-panel { bottom: 14px; }
        body[data-mode="2d"][data-layout="force"] #legend,
        body[data-mode="3d"] #legend,
        body[data-mode="2d"][data-layout="force"] #tag-panel,
        body[data-mode="3d"] #tag-panel { bottom: 80px; }
        #play-btn { width: 34px; height: 34px; border-radius: 50%; background: #4A90D9; border: none; color: white; font-size: 14px; cursor: pointer; display: flex; align-items: center; justify-content: center; flex-shrink: 0; }
        #play-btn:hover { background: #357ABD; }
        #play-btn.playing { background: #E67E22; }
        #time-label { font-size: 13px; color: #e0e0e0; font-weight: 600; min-width: 110px; text-align: center; font-variant-numeric: tabular-nums; }
        #slider-wrap { flex: 1; display: flex; flex-direction: column; gap: 2px; position: relative; }
        #heatmap-container { position: relative; height: 28px; cursor: pointer; }
        #heatmap-canvas { display: block; width: 100%; height: 100%; }
        #heatmap-tooltip { position: absolute; background: #1a1a2e; border: 1px solid #4A90D9; border-radius: 4px; padding: 3px 8px; font-size: 11px; color: #e0e0e0; pointer-events: none; white-space: nowrap; display: none; z-index: 101; transform: translate(-50%, -120%); }
        #time-slider { width: 100%; margin: 0; -webkit-appearance: none; appearance: none; height: 6px; border-radius: 3px; background: #333; outline: none; cursor: pointer; }
        #time-slider::-webkit-slider-thumb { -webkit-appearance: none; appearance: none; width: 16px; height: 16px; border-radius: 50%; background: #4A90D9; cursor: pointer; border: 2px solid white; }
        #time-counter { font-size: 12px; color: #888; min-width: 80px; text-align: right; font-variant-numeric: tabular-nums; }
        </style>
        </head>
        <body>

        <div id="header">
            <h1>\#(headerIcon)NotesMap</h1>
            <div id="mode-toggle">
                <button id="btn-2d" class="active" type="button" data-tip="\#(tip2D)">\#(icon2D)<span class="lbl">2D</span></button>
                <button id="btn-radial" type="button" data-tip="\#(tipRadial)">\#(iconRadial)<span class="lbl">Radial</span></button>
                <button id="btn-radial2" type="button" data-tip="\#(tipRadial2)">\#(iconRadial2)<span class="lbl">Radial 2</span></button>
                <button id="btn-circos" type="button" data-tip="\#(tipCircos)">\#(iconCircos)<span class="lbl">Circos</span></button>
                <button id="btn-calendar" type="button" data-tip="\#(tipCalendar)">\#(iconCalendar)<span class="lbl">\#(labelDays)</span></button>
                <button id="btn-monthly" type="button" data-tip="\#(tipMonthly)">\#(iconMonthly)<span class="lbl">\#(labelMonths)</span></button>
                <button id="btn-heightmap" type="button" data-tip="\#(tipHeightmap)">\#(iconHeightmap)<span class="lbl">\#(labelHeightmap)</span></button>
                <button id="btn-3d" type="button" data-tip="\#(tip3D)">\#(icon3D)<span class="lbl">3D</span></button>
            </div>
            <div id="search-wrap" data-tip="\#(searchTooltip)">
                <svg id="search-icon" viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true">
                    <circle cx="7" cy="7" r="5"/>
                    <line x1="11" y1="11" x2="14" y2="14" stroke-linecap="round"/>
                </svg>
                <input id="search-input" type="text" placeholder="\#(searchPlaceholder)" autocomplete="off" spellcheck="false">
                <button id="search-clear" type="button" tabindex="-1" aria-label="Clear">×</button>
            </div>
            <button id="btn-refresh" type="button" data-tip="\#(titleHeaderRefresh)">
                <svg viewBox="0 0 16 16" width="14" height="14" fill="currentColor" aria-hidden="true">
                    <path d="M8 3V1L4.5 4L8 7V5a3 3 0 1 1-3 3H3.5a4.5 4.5 0 1 0 4.5-5z"/>
                </svg>
            </button>
            <button id="btn-info" type="button" data-tip="\#(helpButtonTitle)" aria-label="\#(helpButtonTitle)">
                <svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true">
                    <circle cx="8" cy="8" r="6.5"/>
                    <line x1="8" y1="7.5" x2="8" y2="11.5" stroke-linecap="round"/>
                    <circle cx="8" cy="5" r="0.85" fill="currentColor" stroke="none"/>
                </svg>
            </button>
            <span id="live-dot" title="\#(titleLiveDot)"></span>
            <div id="stats"></div>
            <span id="generated-at">\#(generatedLabel)</span>
        </div>

        <!-- Floating Instant-Tooltip, gemeinsam genutzt für alle data-tip-Elemente -->
        <div id="instant-tooltip" role="tooltip"></div>

        <!-- Kontext-sensitives Help-Modal, wird via JS aus window.NM_HELP befüllt
             passend zur aktuell aktiven View. ESC oder Klick auf Backdrop schließt. -->
        <div id="help-modal" role="dialog" aria-modal="true" aria-labelledby="help-title">
            <div id="help-modal-card">
                <button id="help-modal-close" type="button" title="\#(helpCloseLabel)" aria-label="\#(helpCloseLabel)">×</button>
                <h2 id="help-title"></h2>
                <p id="help-description"></p>
                <h3 id="help-interactions-label">\#(helpInteractionsLabel)</h3>
                <ul id="help-interactions"></ul>
            </div>
        </div>

        <div id="graph-2d"></div>
        <div id="graph-3d"></div>
        <div id="graph-circos"></div>
        <div id="graph-calendar">
            <div id="calendar-scroll"></div>
            <div id="calendar-legend"></div>
            <div id="calendar-tooltip"></div>
        </div>
        <div id="graph-monthly">
            <div id="monthly-scroll"></div>
            <div id="monthly-bottom-bar">
                <button id="monthly-toggle-numbers" type="button" title="\#(titleMonthlyToggleNumbers)">\#(labelMonthlyNumbersOn)</button>
                <div id="monthly-legend"></div>
            </div>
        </div>
        <div id="graph-heightmap">
            <canvas id="heightmap-contour"></canvas>
            <svg id="heightmap-svg"></svg>
            <div id="heightmap3d-canvas-container"></div>
            <div id="heightmap-tooltip"></div>
            <div id="heightmap-overlay">
                <div id="heightmap-overlay-inner">
                    <div id="heightmap-title">Höhenkarte wird vorbereitet…</div>
                    <div id="heightmap-message">Embeddings werden via Ollama (bge-m3) berechnet. Beim ersten Mal dauert das 1-3 Minuten, danach ist der Cache auf Platte und es geht sofort.</div>
                    <div id="heightmap-progress-bar">
                        <div id="heightmap-progress-fill"></div>
                    </div>
                    <div id="heightmap-detail">Starte…</div>
                </div>
            </div>
            <div id="heightmap-bottom-bar">
                <div class="heightmap-sort-group">
                    <span class="heightmap-sort-label">\#(labelHmFarbe)</span>
                    <button id="btn-heightmap-color-folder" class="active" type="button" title="\#(titleHmColorFolder)">\#(labelHmColorFolder)</button>
                    <button id="btn-heightmap-color-hub" type="button" title="\#(titleHmColorHub)">\#(labelHmColorHub)</button>
                    <button id="btn-heightmap-color-created" type="button" title="\#(titleHmColorCreated)">\#(labelHmColorCreated)</button>
                </div>
                <div class="heightmap-sort-group">
                    <span class="heightmap-sort-label">\#(labelHmAnsicht)</span>
                    <button id="btn-heightmap-view-2d" class="active" type="button" title="\#(titleHm2D)">2D</button>
                    <button id="btn-heightmap-view-3d" type="button" title="\#(titleHm3D)">3D</button>
                </div>
                <div class="heightmap-sort-group heightmap-slider-group" title="\#(titleHmBandwidth)">
                    <span class="heightmap-sort-label">\#(labelHmDetail)</span>
                    <input type="range" id="heightmap-peak-slider" min="3" max="20" value="10" step="1">
                    <span class="heightmap-slider-value" id="heightmap-peak-slider-value">10</span>
                </div>
                <label id="heightmap-contour-toggle"><input type="checkbox" id="heightmap-show-contour" checked> \#(labelHmContour)</label>
                <div id="heightmap-legend"></div>
            </div>
        </div>
        <!-- Day-Panel auf Top-Level, damit es sowohl in Tages- als auch in
             Monats-View sichtbar bleibt (nicht Kind eines graph-*-Containers,
             der display:none geschaltet wird) -->
        <div id="day-panel">
            <button id="day-panel-close" type="button">×</button>
            <h2 id="day-panel-title"></h2>
            <div id="day-panel-meta"></div>
            <div id="day-panel-list"></div>
        </div>

        <div id="panel">
            <button id="panel-close" type="button">×</button>
            <h2 id="panel-title"></h2>
            <div class="meta"><span id="panel-folder"></span></div>
            <div class="link-counts">
                <div class="link-count incoming"><span class="arrow">←</span><span class="num" id="panel-incoming">0</span><span>Backlinks</span></div>
                <div class="link-count outgoing"><span class="arrow">→</span><span class="num" id="panel-outgoing">0</span><span>Outgoing</span></div>
            </div>
            <div id="panel-snippet"></div>
            <a id="panel-open" class="btn" href="#">\#(labelOpenInNotes)</a>
        </div>

        <div id="legend">
            <div id="legend-header">
                <h3>\#(labelFolders) <span id="legend-summary">0</span><span id="legend-clear" title="\#(labelResetTooltip)">×</span></h3>
                <span id="legend-toggle">▼</span>
            </div>
            <div id="legend-body"></div>
        </div>

        <div id="tag-panel">
            <div id="tag-panel-header">
                <h3>\#(labelTags) <span id="tag-panel-summary">0</span><span id="tag-panel-clear" title="\#(labelResetTooltip)">×</span></h3>
                <span id="tag-panel-toggle">▼</span>
            </div>
            <div id="tag-panel-body"></div>
        </div>

        <div id="timeline">
            <button id="play-btn" type="button" title="\#(titlePlay)">▶</button>
            <span id="time-label">\#(labelToday)</span>
            <div id="slider-wrap">
                <div id="heatmap-container" title="\#(titleHeatmap)">
                    <canvas id="heatmap-canvas"></canvas>
                    <div id="heatmap-tooltip"></div>
                </div>
                <input type="range" id="time-slider" min="0" max="1000" value="1000" step="1">
            </div>
            <span id="time-counter">0 / 0</span>
        </div>

        <script>
        __D3_SCRIPT__
        </script>
        <script>
        __FORCE_GRAPH_3D_SCRIPT__
        </script>
        <script>
        __UMAP_SCRIPT__
        </script>
        <script>
        __THREE_SCRIPT__
        </script>
        <script>
        // Lokalisierte Strings für JS-side dynamische Texte. Wird in
        // renderHTML(...) befüllt aus Swift's Localized.jsLocaleObject(in:).
        window.NM_LOC = __JS_LOCALE__;
        // Help-Inhalte pro View, befüllt aus Swift's ViewHelp.allAsJSON(in:).
        window.NM_HELP = __JS_HELP__;
        // Pluralisierungs-Helper: zählt n Notizen/notes lokal-richtig.
        // Beide Sprachen haben nur singular/plural-Form.
        window.NM_pluralNotes = function(n) {
            const L = window.NM_LOC || {};
            const word = (n === 1) ? (L.noteSingular || 'note') : (L.notePlural || 'notes');
            return n + ' ' + word;
        };
        // Date-Format-Helper: nutzt localeTag aus NM_LOC.
        window.NM_formatDate = function(ts, opts) {
            const L = window.NM_LOC || {};
            const tag = L.localeTag || 'en-US';
            return new Date(ts).toLocaleDateString(tag, opts);
        };
        </script>
        <script>
        (function() {
        const data = __PAYLOAD__;
        const L = window.NM_LOC || {};

        // ---- Stats
        const stats = data.stats;
        document.getElementById('stats').innerHTML =
            '<span><span class="stat-value">' + stats.total + '</span> ' + L.statsNotes + '</span>' +
            '<span><span class="stat-value">' + stats.edges + '</span> ' + L.statsLinks + '</span>' +
            '<span><span class="stat-value">' + stats.linked + '</span> ' + L.linked + '</span>' +
            '<span><span class="stat-value">' + stats.orphans + '</span> ' + L.statsOrphans + '</span>';

        function escapeHTML(s) {
            return (s || '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
        }

        // Für Hex→rgba im 3D-Fade
        function hexToRgba(hex, a) {
            const r = parseInt(hex.slice(1,3),16), gv = parseInt(hex.slice(3,5),16), b = parseInt(hex.slice(5,7),16);
            return 'rgba('+r+','+gv+','+b+','+a+')';
        }

        // Connectivity-Map für Hover-Highlight
        const connectedNodes = new Map();
        function rebuildConnectedNodes() {
            connectedNodes.clear();
            for (const n of data.nodes) connectedNodes.set(n.id, new Set());
            for (const e of data.edges) {
                connectedNodes.get(e.source)?.add(e.target);
                connectedNodes.get(e.target)?.add(e.source);
            }
        }
        rebuildConnectedNodes();

        // Shared State
        const activeFolders = new Set();
        const activeTags = new Set();
        function isFolderVisible(folder) { return activeFolders.size === 0 || activeFolders.has(folder); }

        // Suche: case-insensitive Substring-Match auf Notiz-Titel.
        // Leere Query = kein Filter (alle Notizen passen).
        let searchQuery = '';
        function isSearchMatch(n) {
            if (!searchQuery) return true;
            return (n.title || '').toLowerCase().indexOf(searchQuery) !== -1;
        }
        // Tag-Match: OR innerhalb der Tags, Node matcht wenn er MINDESTENS einen
        // aktiven Tag hat. Leerer Filter → alle Nodes matchen.
        function isTagVisible(tags) {
            if (activeTags.size === 0) return true;
            if (!tags || tags.length === 0) return false;
            for (const t of tags) if (activeTags.has(t)) return true;
            return false;
        }
        // Gesamt-Match: AND zwischen Ordner- und Tag-Filter.
        function nodeMatches(n) { return isFolderVisible(n.folder) && isTagVisible(n.tags) && isSearchMatch(n); }

        let currentMode = '2d';
        // '2d'-Mode hat drei Layouts: 'force' (klassisch), 'radial' (Torten-
        // Sektoren pro Ordner, alle Notizen proportional), 'radial2' (Orphans
        // auf festem Außenring, verlinkte Notizen bekommen den Innenraum).
        // Bei '3d'-Mode ignoriert; beim Zurückschalten auf 2D lebt das zuletzt
        // gewählte Layout weiter.
        let currentLayout = 'force';
        let graph3d = null;

        // Initial body-dataset setzen, damit CSS-Selektoren wie
        // body[data-mode="2d"][data-layout="force"] #timeline schon beim
        // ersten Render greifen. Ohne das wäre die Timeline auf Initial-Load
        // versteckt, weil der Default `#timeline { display: none }` ist und
        // `showOnlyContainer` erst beim ersten Mode-Klick die Werte setzt.
        document.body.dataset.mode = currentMode;
        document.body.dataset.layout = currentLayout;

        // ---- Pulse-Animation auf neuen Knoten (2D + 3D)
        // Map: node.id → performance.now() + 2500 (wann die Pulse-Animation endet)
        const PULSE_DURATION_MS = 2500;
        const pulseExpire = new Map();
        let pulseTicker = null;

        // Multiplikator für nodeVal im 3D-Graph während der Pulse-Phase.
        // Drei Pulse über 2.5s (sin(πt·3)), Peak bei ~3.5x Größe.
        function pulseMul(id) {
            const exp = pulseExpire.get(id);
            if (!exp) return 1;
            const rem = exp - performance.now();
            if (rem <= 0) { pulseExpire.delete(id); return 1; }
            const t = rem / PULSE_DURATION_MS;
            return 1 + 2.5 * Math.max(0, Math.sin(t * Math.PI * 3));
        }
        function isPulsing(id) {
            const exp = pulseExpire.get(id);
            return !!(exp && exp > performance.now());
        }

        // Periodisch das 3D-Force-Graph refreshen, solange mindestens ein
        // Knoten pulsiert. 50ms-Takt reicht visuell, ist nicht zu teuer.
        function startPulseTickerIfNeeded() {
            if (pulseTicker || pulseExpire.size === 0) return;
            pulseTicker = setInterval(() => {
                const now = performance.now();
                for (const [id, exp] of [...pulseExpire.entries()]) {
                    if (exp <= now) pulseExpire.delete(id);
                }
                if (pulseExpire.size === 0) {
                    clearInterval(pulseTicker); pulseTicker = null;
                    // Abschließender Refresh, damit finale Größe/Farbe greift.
                    if (graph3d) graph3d.nodeVal(graph3d.nodeVal()).nodeColor(graph3d.nodeColor());
                    return;
                }
                if (graph3d && currentMode === '3d') {
                    graph3d.nodeVal(graph3d.nodeVal()).nodeColor(graph3d.nodeColor());
                }
            }, 50);
        }

        // ---- Side Panel
        function showPanel(d) {
            document.getElementById('panel').style.display = 'flex';
            document.getElementById('panel-title').textContent = d.title;
            document.getElementById('panel-folder').textContent = d.folder;
            document.getElementById('panel-incoming').textContent = d.incoming ?? 0;
            document.getElementById('panel-outgoing').textContent = d.outgoing ?? 0;
            document.getElementById('panel-snippet').textContent = d.snippet || ((window.NM_LOC && window.NM_LOC.noText) || '(no text extracted)');
            document.getElementById('panel-open').href = d.link;
        }
        function hidePanel() {
            document.getElementById('panel').style.display = 'none';
        }

        // ===========================================================
        //                       2D-GRAPH
        // ===========================================================
        const width = window.innerWidth;
        const height = window.innerHeight - 50 - 70;

        // `nodes2d` und `edges2d` sind Arrays, deren *Inhalt* sich in
        // __applyDataUpdate() ändert (length=0; push(...)). Die Array-
        // Objekte selbst bleiben identisch, damit die d3-Simulation und
        // die Tick-Closure weiter darauf zeigen können.
        const nodes2d = data.nodes.map(n => ({...n}));
        const edges2d = data.edges.map(e => ({source: e.source, target: e.target}));

        function nodeRadius(d) {
            if (d.isShell) return 3;
            return Math.max(4, Math.min(16, 3 + d.hubScore * 2));
        }
        function truncateTitle(t) {
            return t && t.length > 28 ? t.slice(0, 25) + '…' : (t || '');
        }

        // Initiale Positionierung: Cluster-Ordner auf Ring, Shell-Notizen außen.
        // Wird nur einmal (beim ersten Build) angewendet. Bei inkrementellen
        // Updates kommen neue Knoten beim Nachbarn / Ordner-Centroid rein:
        // siehe newPositions-Logik in __applyDataUpdate.
        {
            const allFoldersInData = Array.from(new Set(nodes2d.map(n => n.folder))).sort();
            const clusterFolders2d = allFoldersInData.filter(
                f => !nodes2d.find(n => n.folder === f && n.isShell)
            );
            const folderCenter2d = {};
            clusterFolders2d.forEach((f, i) => {
                const a = (2 * Math.PI * i) / Math.max(1, clusterFolders2d.length);
                const r = 200 + Math.random() * 150;
                folderCenter2d[f] = { x: width/2 + r * Math.cos(a), y: height/2 + r * Math.sin(a) };
            });
            nodes2d.forEach(n => {
                if (n.isShell) {
                    const a = Math.random() * 2 * Math.PI;
                    const r = 400 + Math.random() * 300;
                    n.x = width/2 + r * Math.cos(a);
                    n.y = height/2 + r * Math.sin(a);
                } else {
                    const c = folderCenter2d[n.folder] || { x: width/2, y: height/2 };
                    n.x = c.x + (Math.random()-0.5) * 80;
                    n.y = c.y + (Math.random()-0.5) * 80;
                }
            });
        }

        function clusterForce2d(strength) {
            let _nodes;
            function force(alpha) {
                const sums = {}, counts = {};
                for (const n of _nodes) {
                    if (n.isShell) continue;
                    if (!sums[n.folder]) { sums[n.folder] = {x:0, y:0}; counts[n.folder] = 0; }
                    sums[n.folder].x += n.x; sums[n.folder].y += n.y;
                    counts[n.folder]++;
                }
                const centroids = {};
                for (const f in sums) {
                    centroids[f] = { x: sums[f].x/counts[f], y: sums[f].y/counts[f] };
                }
                const l = alpha * strength;
                for (const n of _nodes) {
                    if (n.isShell) continue;
                    const c = centroids[n.folder]; if (!c) continue;
                    n.vx -= (n.x - c.x) * l;
                    n.vy -= (n.y - c.y) * l;
                }
            }
            force.initialize = (n) => { _nodes = n; };
            return force;
        }

        const svg = d3.select('#graph-2d').append('svg').attr('viewBox', [0, 0, width, height]);
        const g = svg.append('g');
        // Persistente Container-Groups, bleiben über Rebinds hinweg erhalten,
        // nur die <line>/<g.node>-Kinder werden via d3.join(enter/update/exit)
        // aktualisiert.
        const linksG = g.append('g');
        const nodesG = g.append('g');
        const zoom2d = d3.zoom()
            .scaleExtent([0.05, 12])
            .wheelDelta(e => {
                const pinch = e.ctrlKey;
                const mul = pinch ? 8 : 3;
                return -e.deltaY * (e.deltaMode === 1 ? 0.05 : e.deltaMode ? 1 : 0.002) * mul;
            })
            .on('zoom', e => { g.attr('transform', e.transform); });
        svg.call(zoom2d);

        svg.append('defs').append('marker')
            .attr('id', 'arrow').attr('viewBox', '0 -2 4 4')
            .attr('refX', 10).attr('refY', 0)
            .attr('markerWidth', 3).attr('markerHeight', 3)
            .attr('orient', 'auto').attr('markerUnits', 'userSpaceOnUse')
            .append('path').attr('fill', '#667').attr('d', 'M0,-2L4,0L0,2');

        const sim = d3.forceSimulation(nodes2d)
            .force('link', d3.forceLink(edges2d).id(d => d.id).distance(200).strength(0.3))
            .force('charge', d3.forceManyBody().strength(d => d.hubScore > 0 ? -120 : -15).distanceMax(600))
            .force('cluster', clusterForce2d(0.35))
            .force('collision', d3.forceCollide().radius(d => nodeRadius(d) + 3))
            .force('center', d3.forceCenter(width/2, height/2).strength(0.03))
            .velocityDecay(0.4);

        // link2d und node2d müssen `let` sein, weil sie bei jedem Rebind
        // in bind2d() neu zugewiesen werden. Andere Funktionen (highlight2d,
        // applyNodeFilters, applyTimeFilter, sim.on('tick')) schließen über
        // diese let-Bindings und sehen automatisch den aktuellen Wert.
        let link2d, node2d;
        let sel2d = null;

        // Drag-Behavior als eigene Variable, damit es in bind2d() für neue
        // Enter-Elemente frisch applied werden kann. Layout-aware:
        //  • force: klassisch (sim reheat, fx/fy am Ende freigeben)
        //  • radial / radial2: sim läuft nicht → Position manuell schreiben +
        //    zeichnen, fx/fy bleiben gesetzt, damit der Knoten dort sitzen bleibt.
        const dragBehavior = d3.drag()
            .on('start', (e, d) => {
                if (currentLayout === 'force' && !e.active) sim.alphaTarget(0.3).restart();
                d.fx = d.x; d.fy = d.y;
            })
            .on('drag', (e, d) => {
                d.fx = e.x; d.fy = e.y;
                if (currentLayout === 'radial' || currentLayout === 'radial2') {
                    d.x = e.x; d.y = e.y;
                    node2d.filter(n => n.id === d.id)
                          .attr('transform', 'translate(' + d.x + ',' + d.y + ')');
                    link2d.filter(l => {
                        const s = typeof l.source === 'object' ? l.source.id : l.source;
                        const t = typeof l.target === 'object' ? l.target.id : l.target;
                        return s === d.id || t === d.id;
                    })
                    .attr('x1', l => l.source.x).attr('y1', l => l.source.y)
                    .attr('x2', l => l.target.x).attr('y2', l => l.target.y);
                }
            })
            .on('end', (e, d) => {
                if (currentLayout === 'force') {
                    if (!e.active) sim.alphaTarget(0);
                    d.fx = null; d.fy = null;
                }
                // radial: fx/fy bleiben stehen, Knoten bleibt, wo der User ihn losgelassen hat
            });

        function onNode2dClick(e, d) {
            e.stopPropagation();
            if (e.metaKey || e.ctrlKey) { window.location.href = d.link; return; }
            if (sel2d && sel2d.id === d.id) {
                sel2d = null; clearHighlight2d(); hidePanel();
            } else {
                sel2d = d; node2d.classed('selected', n => n.id === d.id);
                highlight2d(d); showPanel(d);
            }
        }

        // Rebind der d3-Selections an die aktuellen Arrays.
        // Enter: DOM-Elemente für neue Knoten/Kanten anlegen + Event-Handler.
        // Update: Attribute aktualisieren (Farbe, Radius, Label) für bestehende.
        // Exit: DOM-Elemente entfernter Knoten/Kanten abbauen.
        function bind2d() {
            link2d = linksG.selectAll('line')
                .data(edges2d, l => {
                    const s = (typeof l.source === 'object' ? l.source.id : l.source);
                    const t = (typeof l.target === 'object' ? l.target.id : l.target);
                    return s + '→' + t;
                })
                .join('line')
                .attr('class', 'link')
                .attr('marker-end', 'url(#arrow)');

            node2d = nodesG.selectAll('g.node')
                .data(nodes2d, d => d.id)
                .join(
                    enter => {
                        const gg = enter.append('g').attr('class', 'node').call(dragBehavior);
                        gg.append('circle').attr('r', nodeRadius).attr('fill', d => d.color);
                        gg.append('text').attr('class', 'node-label')
                            .attr('dy', d => nodeRadius(d) + 12)
                            .text(d => truncateTitle(d.title))
                            .attr('opacity', 0);
                        gg.on('mouseover', (e, d) => { if (!sel2d) highlight2d(d); })
                          .on('mouseout', () => { if (!sel2d) clearHighlight2d(); else highlight2d(sel2d); })
                          .on('click', onNode2dClick);
                        return gg;
                    },
                    update => {
                        // Knoten kann sich geändert haben: neuer Ordner (→ Farbe),
                        // geänderter hubScore (→ Radius), neuer Titel (→ Label).
                        update.select('circle').attr('fill', d => d.color).attr('r', nodeRadius);
                        update.select('text.node-label')
                              .attr('dy', d => nodeRadius(d) + 12)
                              .text(d => truncateTitle(d.title));
                        return update;
                    },
                    exit => exit.remove()
                );
        }
        bind2d();

        function highlight2d(d) {
            const conn = connectedNodes.get(d.id) || new Set();
            node2d.classed('dimmed', n => n.id !== d.id && !conn.has(n.id));
            node2d.classed('highlighted', n => n.id === d.id);
            link2d.classed('dimmed', l => {
                const s = l.source.id || l.source, t = l.target.id || l.target;
                return s !== d.id && t !== d.id;
            });
            link2d.classed('highlighted', l => {
                const s = l.source.id || l.source, t = l.target.id || l.target;
                return s === d.id || t === d.id;
            });
            node2d.select('.node-label').attr('opacity', n => (n.id === d.id || conn.has(n.id)) ? 1 : 0);
        }
        function clearHighlight2d() {
            node2d.classed('dimmed', false).classed('highlighted', false).classed('selected', false);
            link2d.classed('dimmed', false).classed('highlighted', false);
            node2d.select('.node-label').attr('opacity', 0);
        }

        svg.on('click', () => { sel2d = null; clearHighlight2d(); hidePanel(); });
        document.getElementById('panel-close').addEventListener('click', (e) => {
            e.stopPropagation(); sel2d = null; clearHighlight2d(); hidePanel();
        });

        sim.on('tick', () => {
            link2d.attr('x1', d => d.source.x).attr('y1', d => d.source.y)
                  .attr('x2', d => d.target.x).attr('y2', d => d.target.y);
            node2d.attr('transform', d => 'translate(' + d.x + ',' + d.y + ')');
        });

        // Auto-Zoom-Fit nach dem Initialen Force-Settling
        setTimeout(() => {
            svg.transition().duration(1200).call(
                zoom2d.transform,
                d3.zoomIdentity.translate(width/2, height/2).scale(0.45).translate(-width/2, -height/2)
            );
        }, 800);

        // ===========================================================
        //                      Radial-Layout
        // ===========================================================
        // Ordner werden zu Torten-Sektoren um die Mitte angeordnet. Der
        // Sektor-Winkel ist proportional zur Anzahl Notizen im Ordner.
        // Innerhalb eines Sektors werden die Knoten nach hubScore auf
        // konzentrischen Ringen platziert: starke Hubs nach innen, Orphans
        // nach außen. Alphabetische Ordner-Reihenfolge → stabil über Reloads.
        function computeRadialPositions() {
            const cx = width / 2;
            const cy = height / 2;
            const minR = 140;
            const maxR = Math.min(width, height) * 0.42;

            const folderBuckets = {};
            for (const n of nodes2d) {
                const f = n.folder || '(keiner)';
                if (!folderBuckets[f]) folderBuckets[f] = [];
                folderBuckets[f].push(n);
            }
            const folderNames = Object.keys(folderBuckets).sort();
            const total = nodes2d.length;
            if (total === 0) return {};

            let maxScore = 0;
            for (const n of nodes2d) maxScore = Math.max(maxScore, n.hubScore || 0);

            const positions = {};
            let angle = -Math.PI / 2; // starte oben (12 Uhr)
            for (const fname of folderNames) {
                const bucket = folderBuckets[fname];
                const K = bucket.length;
                const sectorAngle = (K / total) * 2 * Math.PI;
                for (let i = 0; i < K; i++) {
                    const n = bucket[i];
                    const hs = n.hubScore || 0;
                    // Power 0.6 dämpft: mäßige Hubs werden nicht sofort ganz innen platziert
                    const t = maxScore > 0 ? Math.pow(hs / maxScore, 0.6) : 0;
                    const r = maxR - t * (maxR - minR);
                    const a = angle + sectorAngle * (i + 0.5) / K;
                    positions[n.id] = {
                        x: cx + r * Math.cos(a),
                        y: cy + r * Math.sin(a)
                    };
                }
                angle += sectorAngle;
            }
            return positions;
        }

        // ===========================================================
        //                   Radial 2, Orphans-Halo
        // ===========================================================
        // Gleiche Idee wie Radial, aber **Orphans werden vom Sektor-Game
        // entkoppelt**: sie sitzen auf einem festen Außenring (nach Ordner
        // gruppiert, wie der hübsche Halo im klassischen Radial), und die
        // verlinkten Notizen kriegen Sektoren, die NUR proportional zu ihrer
        // eigenen Gruppe sind. Bei vielen Orphans (typisch: 90%+ der Daten)
        // blähen sich kleine verlinkte Cluster damit von ~2° auf z.B. ~70°.
        function computeRadial2Positions() {
            const cx = width / 2;
            const cy = height / 2;
            const minR = 140;
            const innerMax = Math.min(width, height) * 0.30;
            const outerR = Math.min(width, height) * 0.42;

            const positions = {};
            if (nodes2d.length === 0) return positions;

            const linkedNodes = [];
            const orphanNodes = [];
            for (const n of nodes2d) {
                if ((n.hubScore || 0) > 0) linkedNodes.push(n);
                else orphanNodes.push(n);
            }

            // --- Orphans: fester Außenring, nach Ordner gruppiert
            const orphanByFolder = {};
            for (const n of orphanNodes) {
                const f = n.folder || '(keiner)';
                if (!orphanByFolder[f]) orphanByFolder[f] = [];
                orphanByFolder[f].push(n);
            }
            const orphanFolders = Object.keys(orphanByFolder).sort();
            const orphanTotal = orphanNodes.length;
            if (orphanTotal > 0) {
                let angle = -Math.PI / 2;
                for (const fname of orphanFolders) {
                    const bucket = orphanByFolder[fname];
                    const K = bucket.length;
                    const sectorAngle = (K / orphanTotal) * 2 * Math.PI;
                    for (let i = 0; i < K; i++) {
                        const a = angle + sectorAngle * (i + 0.5) / K;
                        positions[bucket[i].id] = {
                            x: cx + outerR * Math.cos(a),
                            y: cy + outerR * Math.sin(a)
                        };
                    }
                    angle += sectorAngle;
                }
            }

            // --- Linked: eigener Vollkreis über den inneren Bereich,
            //     Sektorbreite proportional NUR zur linked-Summe, Hubs innen.
            const linkedByFolder = {};
            for (const n of linkedNodes) {
                const f = n.folder || '(keiner)';
                if (!linkedByFolder[f]) linkedByFolder[f] = [];
                linkedByFolder[f].push(n);
            }
            const linkedFolders = Object.keys(linkedByFolder).sort();
            const linkedTotal = linkedNodes.length;
            if (linkedTotal === 0) return positions;

            let maxScore = 0;
            for (const n of linkedNodes) maxScore = Math.max(maxScore, n.hubScore || 0);

            let angle = -Math.PI / 2;
            for (const fname of linkedFolders) {
                const bucket = linkedByFolder[fname];
                const K = bucket.length;
                const sectorAngle = (K / linkedTotal) * 2 * Math.PI;
                for (let i = 0; i < K; i++) {
                    const n = bucket[i];
                    const hs = n.hubScore || 0;
                    const t = maxScore > 0 ? Math.pow(hs / maxScore, 0.6) : 0;
                    const r = innerMax - t * (innerMax - minR);
                    const a = angle + sectorAngle * (i + 0.5) / K;
                    positions[n.id] = {
                        x: cx + r * Math.cos(a),
                        y: cy + r * Math.sin(a)
                    };
                }
                angle += sectorAngle;
            }
            return positions;
        }

        // Animierter Umzug von aktuellen Positionen zu einem Ziel-Set.
        // Stoppt die Simulation und fährt den Übergang via requestAnimationFrame.
        // Am Ende werden fx/fy gesetzt, damit ein späteres Re-Heat (z.B. durch
        // __applyDataUpdate während Radial) die Knoten nicht wegreißt.
        // Gemeinsam genutzt von applyRadialLayout und applyRadial2Layout.
        function animateToRadialPositions(positions) {
            sim.stop();
            // Zoom resetten auf Identity (scale=1) bevor Radial-Animation läuft.
            // Sonst zeigt Radial mit dem 2D-Auto-Fit-Scale(0.45) als winziger
            // Kreis in der Mitte, Radial-Positionen liegen schon in
            // kompakten [center ± 0.42*viewport]-Koordinaten, brauchen also
            // keinen Auto-Fit-Zoom-Out.
            svg.transition().duration(600).call(
                zoom2d.transform,
                d3.zoomIdentity
            );
            const start = new Map();
            const end = new Map();
            for (const n of nodes2d) {
                start.set(n.id, { x: n.x, y: n.y });
                const p = positions[n.id] || { x: width/2, y: height/2 };
                end.set(n.id, p);
            }
            const duration = 900;
            const startTime = performance.now();
            function step(now) {
                const tt = Math.min(1, (now - startTime) / duration);
                const ease = tt < 0.5 ? 2*tt*tt : 1 - Math.pow(-2*tt + 2, 2)/2; // easeInOutQuad
                for (const n of nodes2d) {
                    const s = start.get(n.id);
                    const p = end.get(n.id);
                    n.x = s.x + (p.x - s.x) * ease;
                    n.y = s.y + (p.y - s.y) * ease;
                }
                node2d.attr('transform', d => 'translate(' + d.x + ',' + d.y + ')');
                link2d.attr('x1', d => d.source.x).attr('y1', d => d.source.y)
                      .attr('x2', d => d.target.x).attr('y2', d => d.target.y);
                if (tt < 1) {
                    requestAnimationFrame(step);
                } else {
                    for (const n of nodes2d) {
                        const p = end.get(n.id);
                        n.x = p.x; n.y = p.y;
                        n.fx = p.x; n.fy = p.y;
                        n.vx = 0; n.vy = 0;
                    }
                    node2d.attr('transform', d => 'translate(' + d.x + ',' + d.y + ')');
                    link2d.attr('x1', d => d.source.x).attr('y1', d => d.source.y)
                          .attr('x2', d => d.target.x).attr('y2', d => d.target.y);
                }
            }
            requestAnimationFrame(step);
        }

        function applyRadialLayout()  { animateToRadialPositions(computeRadialPositions()); }
        function applyRadial2Layout() { animateToRadialPositions(computeRadial2Positions()); }

        // Zurück zur Force-Simulation: Fixierungen lösen, kräftig reheaten.
        // Wichtig: Orphans (keine Links) werden auf einen Außenring umgesetzt,
        // damit sie nach einem Radial→Force-Wechsel nicht als C-Bogen kleben
        // bleiben, wo sie aus dem Sektor-Layout kommen. Die Force-Simulation
        // hat keine explizite Outer-Ring-Force für Orphans, der Ring entsteht
        // emergent. Wenn Startpositionen aus Radial-Sektoren übernommen werden,
        // reicht alpha=0.8 nicht zum Redistribuieren. Daher: explizit Reset.
        function applyForceLayout() {
            // Zoom auf Auto-Fit-Scale (0.45) animieren, passend zur weiträumigen
            // Force-Verteilung. Sonst wirkt 2D nach einem Radial→Force-Wechsel
            // mega reingezoomt, weil Radial Identity (scale=1) gesetzt hat.
            svg.transition().duration(900).call(
                zoom2d.transform,
                d3.zoomIdentity.translate(width/2, height/2).scale(0.45).translate(-width/2, -height/2)
            );
            const cx = width / 2;
            const cy = height / 2;
            const ringRadius = Math.min(width, height) * 0.42;
            for (const n of nodes2d) {
                n.fx = null;
                n.fy = null;
                const conn = connectedNodes.get(n.id);
                const isOrphan = !conn || conn.size === 0;
                if (isOrphan) {
                    // Zufällige Ring-Position bei 75-95% des Ring-Radius:
                    // gibt der Force-Simulation einen guten Startpunkt, der
                    // nicht als zusammenhängender Cluster aus dem Radial-Mode
                    // herauskommt.
                    const angle = Math.random() * 2 * Math.PI;
                    const r = ringRadius * (0.75 + Math.random() * 0.20);
                    n.x = cx + r * Math.cos(angle);
                    n.y = cy + r * Math.sin(angle);
                    n.vx = 0;
                    n.vy = 0;
                }
            }
            // alpha=1.0 statt 0.8, kräftiger Reheat, damit auch verbliebene
            // Cluster sich vollständig neu sortieren.
            sim.alpha(1.0).restart();
        }

        // ===========================================================
        //                       3D-GRAPH (lazy init)
        // ===========================================================
        function init3d() {
            if (graph3d) return;
            const el = document.getElementById('graph-3d');

            let hov3d = null;
            let sel3d = null;
            function active3d() { return sel3d || hov3d; }
            function isConn3d(id) {
                const a = active3d(); if (!a) return true;
                if (id === a.id) return true;
                const c = connectedNodes.get(a.id);
                return c ? c.has(id) : false;
            }
            function isLinkConn3d(l) {
                const a = active3d(); if (!a) return true;
                const s = typeof l.source === 'object' ? l.source.id : l.source;
                const t = typeof l.target === 'object' ? l.target.id : l.target;
                return s === a.id || t === a.id;
            }
            function refresh3d() {
                if (!graph3d) return;
                graph3d.nodeColor(graph3d.nodeColor()).linkColor(graph3d.linkColor()).linkWidth(graph3d.linkWidth()).nodeVal(graph3d.nodeVal());
            }

            // Cluster-Centroids gleichmäßig auf einer Kugel verteilen (Fibonacci-Sphere)
            const clusterFolders3d = [...new Set(data.nodes.filter(n => !n.isShell).map(n => n.folder))].sort();
            const folderCenter3d = {};
            clusterFolders3d.forEach((f, i) => {
                const theta = 2 * Math.PI * i / ((1 + Math.sqrt(5)) / 2);
                const phi = Math.acos(1 - 2 * (i + 0.5) / Math.max(1, clusterFolders3d.length));
                const r = 200 + Math.random() * 150;
                folderCenter3d[f] = {
                    x: r * Math.sin(phi) * Math.cos(theta),
                    y: r * Math.sin(phi) * Math.sin(theta),
                    z: r * Math.cos(phi)
                };
            });

            const nodes3d = data.nodes.map(n => {
                const copy = { ...n };
                if (n.isShell) {
                    const phi = Math.acos(2 * Math.random() - 1);
                    const theta = 2 * Math.PI * Math.random();
                    const r = 400 + Math.random() * 300;
                    copy.x = r * Math.sin(phi) * Math.cos(theta);
                    copy.y = r * Math.sin(phi) * Math.sin(theta);
                    copy.z = r * Math.cos(phi);
                } else {
                    const c = folderCenter3d[n.folder] || { x: 0, y: 0, z: 0 };
                    copy.x = c.x + (Math.random()-0.5) * 160;
                    copy.y = c.y + (Math.random()-0.5) * 160;
                    copy.z = c.z + (Math.random()-0.5) * 160;
                }
                return copy;
            });

            graph3d = ForceGraph3D()(el)
                .graphData({
                    nodes: nodes3d,
                    links: data.edges.map(e => ({ source: e.source, target: e.target }))
                })
                .backgroundColor('#1a1a2e')
                .nodeVal(n => {
                    let base;
                    if (!nodeMatches(n)) base = 0.3;
                    else if (n.isShell) base = 1.5;
                    else base = Math.max(3, Math.min(12, 2 + n.hubScore * 1.5));
                    return base * pulseMul(n.id);
                })
                .nodeColor(n => {
                    // Pulsierende neue Knoten: warmes Orange, damit sie vom
                    // Ordner-Blau/Grün der Cluster abheben.
                    if (isPulsing(n.id)) return '#ffb84d';
                    if (!nodeMatches(n)) return hexToRgba(n.color, 0.03);
                    if (active3d()) return isConn3d(n.id) ? n.color : hexToRgba(n.color, 0.06);
                    return n.isShell ? hexToRgba(n.color, 0.4) : n.color;
                })
                .nodeOpacity(1)
                .nodeLabel(n => escapeHTML(n.title) + '  ·  ' + escapeHTML(n.folder))
                .linkColor(l => {
                    if (active3d()) return isLinkConn3d(l) ? 'rgba(200,200,255,0.9)' : 'rgba(50,50,70,0.03)';
                    return 'rgba(140,140,200,0.5)';
                })
                .linkWidth(l => {
                    if (active3d()) return isLinkConn3d(l) ? 3 : 0.1;
                    return 1.2;
                })
                .linkDirectionalArrowLength(4)
                .linkDirectionalArrowRelPos(1)
                .width(window.innerWidth)
                .height(window.innerHeight - 50 - 70)
                .onNodeHover(hovered => {
                    el.style.cursor = hovered ? 'pointer' : 'default';
                    if (!sel3d) { hov3d = hovered; refresh3d(); }
                })
                .onNodeClick((n, ev) => {
                    if (ev && (ev.metaKey || ev.ctrlKey)) { window.location.href = n.link; return; }
                    if (sel3d && sel3d.id === n.id) { sel3d = null; hov3d = null; hidePanel(); }
                    else { sel3d = n; hov3d = n; showPanel(n); }
                    refresh3d();
                })
                .onBackgroundClick(() => { sel3d = null; hov3d = null; hidePanel(); refresh3d(); });

            graph3d.d3Force('charge').strength(n => n.hubScore > 0 ? -120 : -15).distanceMax(600);
            graph3d.d3Force('link').distance(200).strength(0.3);
            graph3d.d3Force('center', d3.forceCenter().strength(0.03));

            graph3d.d3Force('cluster', function() {
                let _nodes;
                function force(alpha) {
                    const sums = {}, counts = {};
                    for (const n of _nodes) {
                        if (n.isShell) continue;
                        if (!sums[n.folder]) { sums[n.folder] = {x:0,y:0,z:0}; counts[n.folder] = 0; }
                        sums[n.folder].x += n.x; sums[n.folder].y += n.y; sums[n.folder].z += (n.z||0);
                        counts[n.folder]++;
                    }
                    const centroids = {};
                    for (const f in sums) {
                        centroids[f] = { x: sums[f].x/counts[f], y: sums[f].y/counts[f], z: sums[f].z/counts[f] };
                    }
                    const l = alpha * 0.35;
                    for (const n of _nodes) {
                        if (n.isShell) continue;
                        const c = centroids[n.folder]; if (!c) continue;
                        n.vx -= (n.x - c.x) * l;
                        n.vy -= (n.y - c.y) * l;
                        if (n.vz != null) n.vz -= ((n.z||0) - c.z) * l;
                    }
                }
                force.initialize = nn => { _nodes = nn; };
                return force;
            }());

            graph3d.cameraPosition({ z: 1800 });
        }

        // ===========================================================
        //                  CIRCOS-PLOT (lazy init)
        // ===========================================================
        // Inspiriert von Circos (Martin Krzywinski, Genomics). Darstellung:
        //  • Ordner als Kreissegmente am Rand (Breite ∝ Notizenzahl)
        //  • Jede Notiz ein Tick auf dem Innenrand des Segments
        //  • Outer-Track: Hub-Score-Heatmap (grün→gelb→rot)
        //  • Links als Bezier-Bögen durch das Zentrum. Bundling: nahe Ordner
        //    bekommen flachere Bögen, gegenüberliegende tiefere
        //  • Labels nur für die größten Ordner (sonst unleserlich bei 30+)
        //
        // Design-Entscheidungen:
        //  • Angle-Offset: unsere Winkel werden von 3-Uhr CCW gezählt (Math.cos/sin).
        //    d3.arc() rechnet von 12-Uhr CW → Transform: d3_angle = our_angle + π/2
        //  • Gap zwischen Segmenten (0.003 rad): visuelle Trennung kleiner Ordner
        //  • Bezier-Kontrollpunkt-Radius sinkt mit Winkelabstand → Edge-Bundling
        const circosState = {
            initialized: false,
            selectedNode: null,
            hoverNode: null,
            hoverFolder: null,
            nodeTicks: null,
            linkArcs: null,
            folderArcs: null,
            gRoot: null,
            cx: 0, cy: 0,
            folderArcInner: 0, folderArcOuter: 0,
            noteRingR: 0,
            labelRingR: 0,
            folderRanges: {},
            nodePosAngle: {},
        };

        function initCircos() {
            if (circosState.initialized) return;
            const container = document.getElementById('graph-circos');
            const cw = container.clientWidth;
            const ch = container.clientHeight;
            const cx = cw / 2;
            const cy = ch / 2;
            const baseR = Math.min(cw, ch) * 0.38;

            circosState.cw = cw;
            circosState.ch = ch;
            circosState.cx = cx;
            circosState.cy = cy;
            circosState.baseR = baseR;
            circosState.folderArcInner = baseR - 4;
            circosState.folderArcOuter = baseR + 4;
            circosState.noteRingR = baseR - 14;
            circosState.labelRingR = baseR + 40;

            const svg = d3.select('#graph-circos').append('svg')
                .attr('viewBox', [0, 0, cw, ch]);
            const gRoot = svg.append('g');

            circosState.zoomScale = 1;
            const zoomC = d3.zoom().scaleExtent([0.3, 8]).on('zoom', e => {
                gRoot.attr('transform', e.transform);
                circosState.zoomScale = e.transform.k;
                updateCircosLabels(e.transform.k);
                // Font-Size invers zum Zoom: Labels bleiben immer ~10 CSS-Pixel hoch,
                // statt beim Reinzoomen riesig zu werden.
                if (circosState.labelsG) {
                    circosState.labelsG.selectAll('text.folder-label')
                        .style('font-size', (10 / e.transform.k) + 'px');
                }
            });
            svg.call(zoomC);

            svg.on('click', (e) => {
                if (e.target === svg.node()) {
                    circosState.selectedNode = null;
                    updateCircosHighlight();
                    hidePanel();
                }
            });

            circosState.svg = svg;
            circosState.gRoot = gRoot;
            circosState.initialized = true;
            renderCircos();
        }

        // Kompletter Rebuild. Wird beim ersten Init und nach jeder Datenänderung
        // aufgerufen. SVG-Child-Elemente werden komplett weggeworfen und neu
        // aufgebaut, bei 1200 Notizen + paar hundert Links kein Performance-
        // Problem, und eine saubere Reset-Semantik ohne d3-join-Komplexität.
        function renderCircos() {
            if (!circosState.initialized) return;
            const { gRoot, cx, cy, noteRingR, folderArcInner, folderArcOuter,
                    labelRingR } = circosState;

            // --- Ordner bucketizen
            const folderBuckets = {};
            for (const n of data.nodes) {
                const f = n.folder || '(keiner)';
                if (!folderBuckets[f]) folderBuckets[f] = [];
                folderBuckets[f].push(n);
            }
            const folderNames = Object.keys(folderBuckets).sort();
            const total = data.nodes.length;
            if (total === 0) { gRoot.selectAll('*').remove(); return; }

            // Ordner-Farbe: erste Notiz im Bucket
            const folderColor = {};
            for (const fname of folderNames) {
                folderColor[fname] = folderBuckets[fname][0]?.color || '#666';
            }

            // --- Winkel mit Gaps zwischen Segmenten
            const gap = 0.003;
            const gapTotal = gap * folderNames.length;
            const usableAngle = 2 * Math.PI - gapTotal;

            const folderRanges = {};
            const nodePosAngle = {};
            let ang = -Math.PI / 2; // 12 Uhr

            let maxHub = 0;
            for (const n of data.nodes) maxHub = Math.max(maxHub, n.hubScore || 0);

            for (const fname of folderNames) {
                const bucket = folderBuckets[fname];
                const K = bucket.length;
                const sectorAngle = (K / total) * usableAngle;
                folderRanges[fname] = {
                    start: ang, end: ang + sectorAngle,
                    color: folderColor[fname],
                    nodes: bucket
                };
                for (let i = 0; i < K; i++) {
                    nodePosAngle[bucket[i].id] = ang + sectorAngle * (i + 0.5) / K;
                }
                ang += sectorAngle + gap;
            }
            circosState.folderRanges = folderRanges;
            circosState.nodePosAngle = nodePosAngle;

            // --- Clear + Rebuild
            gRoot.selectAll('*').remove();

            const folderArcGen = d3.arc()
                .innerRadius(folderArcInner).outerRadius(folderArcOuter);

            // Layer A: Folder-Arcs
            const folderG = gRoot.append('g').attr('class', 'folders');
            circosState.folderArcs = folderG.selectAll('path.folder-arc')
                .data(folderNames).enter().append('path')
                .attr('class', 'folder-arc')
                .attr('transform', 'translate(' + cx + ',' + cy + ')')
                .attr('d', fname => folderArcGen({
                    startAngle: folderRanges[fname].start + Math.PI/2,
                    endAngle:   folderRanges[fname].end   + Math.PI/2
                }))
                .attr('fill', fname => folderColor[fname])
                .on('mouseenter', (e, fname) => {
                    circosState.hoverFolder = fname;
                    updateCircosHighlight();
                })
                .on('mouseleave', () => {
                    circosState.hoverFolder = null;
                    updateCircosHighlight();
                });

            // Layer C: Link-Arcs (Bezier durchs Zentrum, mit Bundling)
            function arcPath(sa, ta) {
                const r = noteRingR - 2;
                const sx = cx + r * Math.cos(sa);
                const sy = cy + r * Math.sin(sa);
                const tx = cx + r * Math.cos(ta);
                const ty = cy + r * Math.sin(ta);
                // Kontrollpunkt in Richtung Zentrum; bei gegenüberliegenden
                // Nodes tief ins Zentrum (visual bundling), bei Nachbarn flach.
                let dA = Math.abs(sa - ta);
                if (dA > Math.PI) dA = 2 * Math.PI - dA;
                const bundleT = dA / Math.PI; // 0..1
                const ctrlR = r * (1 - 0.92 * bundleT);
                // Mittelwinkel (kürzerer Pfad)
                let midA = (sa + ta) / 2;
                if (Math.abs(sa - ta) > Math.PI) midA += Math.PI;
                const cpx = cx + ctrlR * Math.cos(midA);
                const cpy = cy + ctrlR * Math.sin(midA);
                return 'M' + sx + ',' + sy + ' Q' + cpx + ',' + cpy + ' ' + tx + ',' + ty;
            }
            const visibleLinks = [];
            for (const e of data.edges) {
                const sa = nodePosAngle[e.source];
                const ta = nodePosAngle[e.target];
                if (sa == null || ta == null) continue;
                visibleLinks.push({ source: e.source, target: e.target, sa, ta });
            }
            const linksG = gRoot.append('g').attr('class', 'links');
            circosState.linkArcs = linksG.selectAll('path.link-arc')
                .data(visibleLinks).enter().append('path')
                .attr('class', 'link-arc')
                .attr('d', d => arcPath(d.sa, d.ta));

            // Layer D: Note-Ticks als radiale Balken
            // Jede Notiz ist ein dünner Balken mit fester tangentialer Breite
            // (kein Überlapp zwischen Nachbarn!), dessen radiale Länge vom
            // hubScore abhängt. Hubs ragen deutlich nach innen, normale Notes
            // sind kurze Striche. Vorher waren das Kreise, die sich bei 1200
            // Notizen auf ~1px Arc-Abstand stark überschnitten, Bar-Form löst
            // das Problem, weil Breite und Länge entkoppelt sind.
            const notesG = gRoot.append('g').attr('class', 'notes');
            const N = Math.max(1, data.nodes.length);
            const arcPerNote = (2 * Math.PI * noteRingR) / N;
            const barWidth = Math.max(0.8, arcPerNote * 0.85);
            const maxHubLocal = maxHub > 0 ? maxHub : 1;
            circosState.nodeTicks = notesG.selectAll('rect.note-tick')
                .data(data.nodes).enter().append('rect')
                .attr('class', 'note-tick')
                .attr('x', -barWidth / 2)
                .attr('y', -noteRingR)
                .attr('width', barWidth)
                .attr('height', n => {
                    // Min 3px für sichtbare Basis, max 16px für Top-Hubs.
                    // Linear in hubScore / maxHub, so werden Hubs visuell
                    // als "längere Striche nach innen" erkennbar.
                    const hs = n.hubScore || 0;
                    const t = Math.min(1, hs / maxHubLocal);
                    return 3 + 13 * t;
                })
                .attr('fill', n => n.color || '#888')
                .attr('stroke', '#1a1a28').attr('stroke-width', 0.3)
                .attr('transform', n => {
                    const a = nodePosAngle[n.id];
                    if (a == null) return null;
                    // deg = a_rad→deg + 90: im Local Frame zeigt das Rect nach
                    // "oben" (y=-noteRingR), rotate(90) dreht es auf a=0 (Osten),
                    // rotate(180) auf a=π/2 (Süden) etc. (SVG rotiert CW, cos/sin
                    // haben in SVG-Koords +y=down, daher passt der Offset direkt.)
                    const deg = (a * 180 / Math.PI) + 90;
                    return 'translate(' + cx + ',' + cy + ') rotate(' + deg + ')';
                })
                .on('mouseenter', (ev, n) => {
                    circosState.hoverNode = n;
                    updateCircosHighlight();
                })
                .on('mouseleave', () => {
                    circosState.hoverNode = null;
                    updateCircosHighlight();
                })
                .on('click', (ev, n) => {
                    ev.stopPropagation();
                    if (ev.metaKey || ev.ctrlKey) { window.location.href = n.link; return; }
                    if (circosState.selectedNode && circosState.selectedNode.id === n.id) {
                        circosState.selectedNode = null; hidePanel();
                    } else {
                        circosState.selectedNode = n; showPanel(n);
                    }
                    updateCircosHighlight();
                });

            // Layer E: Folder-Labels, ALLE rendern, radial orientiert.
            // Sichtbarkeit + Deklumperung laufen in updateCircosLabels().
            const labelsG = gRoot.append('g').attr('class', 'labels');
            circosState.labelsG = labelsG;
            for (const fname of folderNames) {
                const range = folderRanges[fname];
                const sectorAngle = range.end - range.start;
                const midA = (range.start + range.end) / 2;
                const label = fname.length > 28 ? fname.slice(0, 26) + '…' : fname;
                const flipped = Math.cos(midA) < 0;
                const rotDeg = (midA * 180 / Math.PI) + (flipped ? 180 : 0);
                const anchor = flipped ? 'end' : 'start';
                const lx = cx + labelRingR * Math.cos(midA);
                const ly = cy + labelRingR * Math.sin(midA);
                labelsG.append('text')
                    .datum({ fname, sectorAngle, labelLen: label.length, midA })
                    .attr('class', 'folder-label')
                    .attr('transform',
                        'translate(' + lx + ',' + ly + ') rotate(' + rotDeg + ')')
                    .attr('text-anchor', anchor)
                    .attr('dominant-baseline', 'middle')
                    // Kleine Luft zum Ring, Anker ist direkt am Ring, dx schiebt nach außen
                    .attr('dx', flipped ? -4 : 4)
                    .style('opacity', 0)
                    .text(label);
            }
            // Labels für aktuellen Zoom-Level setzen (kann nach einem
            // __applyDataUpdate auch !=1 sein, wenn der User schon reingezoomt hat)
            const curScale = circosState.zoomScale || 1;
            updateCircosLabels(curScale);
            labelsG.selectAll('text.folder-label').style('font-size', (10 / curScale) + 'px');
        }

        // Sichtbarkeit + Deklumperung der Ordner-Labels.
        //
        // Labels sind RADIAL gezeichnet, ihre Bogenlänge am Ring ≈ Font-Höhe,
        // nicht Textbreite. Zwei Schritte:
        //
        //   1. Sichtbarkeit: Labels bekommen opacity=1, wenn ihr Sektor ≥ ein
        //      Label-Pitch (Font-Höhe + Padding) breit ist. Sonst unsichtbar.
        //      Dadurch tauchen beim Reinzoomen mehr Labels auf.
        //
        //   2. Deklumperung: sichtbare Labels nach Winkel sortieren. Nachbarn,
        //      die näher als minGap beieinander lägen, werden zu einer Gruppe
        //      gebündelt und gleichmäßig um ihren Durchschnitts-Winkel verteilt.
        //      Einzel-Labels bleiben exakt auf ihrem Sektor-Mittelpunkt.
        //
        // Effekt: Labels in dichten Ordner-Clustern rücken sanft zur Seite,
        // nichts überlappt mehr. Wrap-around am 360°-Übergang wird gehandhabt.
        function updateCircosLabels(scale) {
            if (!circosState.labelsG) return;
            const baseR = circosState.baseR;
            const labelRingR = circosState.labelRingR;
            const cx = circosState.cx;
            const cy = circosState.cy;
            // Font ~10 px + ~2 px Padding zwischen Nachbar-Labels.
            const labelPitchPx = 12;
            const minGap = labelPitchPx / (baseR * scale);

            // Schritt 1: Sichtbarkeit setzen + Liste der sichtbaren einsammeln.
            const vis = [];
            circosState.labelsG.selectAll('text.folder-label').each(function(d) {
                const arcLenPx = d.sectorAngle * baseR * scale;
                const on = arcLenPx >= labelPitchPx;
                d3.select(this).style('opacity', on ? 1 : 0);
                if (on) vis.push({ el: this, midA: d.midA });
            });
            if (vis.length === 0) return;

            // Schritt 2a: nach Winkel sortieren, benachbarte Labels (< minGap)
            // zu Gruppen clustern.
            vis.sort((a, b) => a.midA - b.midA);
            const groups = [[vis[0]]];
            for (let i = 1; i < vis.length; i++) {
                const g = groups[groups.length - 1];
                if (vis[i].midA - g[g.length - 1].midA < minGap) {
                    g.push(vis[i]);
                } else {
                    groups.push([vis[i]]);
                }
            }
            // Wrap-around: erste und letzte Gruppe prüfen (am 2π-Übergang).
            if (groups.length > 1) {
                const firstG = groups[0];
                const lastG = groups[groups.length - 1];
                const wrapGap =
                    (firstG[0].midA + 2 * Math.PI) - lastG[lastG.length - 1].midA;
                if (wrapGap < minGap) {
                    // Merge: die erste Gruppe mit +2π markieren und hinten anhängen
                    for (const v of firstG) v.midA += 2 * Math.PI;
                    lastG.push(...firstG);
                    groups.shift();
                }
            }

            // Schritt 2b: jede Gruppe um ihren Durchschnitts-Winkel verteilen.
            for (const g of groups) {
                const n = g.length;
                if (n === 1) {
                    g[0].displayA = g[0].midA;
                    continue;
                }
                const avg = g.reduce((s, v) => s + v.midA, 0) / n;
                const span = (n - 1) * minGap;
                const start = avg - span / 2;
                for (let k = 0; k < n; k++) g[k].displayA = start + k * minGap;
            }

            // Schritt 3: Transform + Anchor + dx anhand displayA neu setzen.
            // Die Rotation muss zum aktuellen Winkel passen (flipped kann sich
            // durch die Verschiebung ändern, z.B. wenn ein Label knapp über die
            // π/2-Grenze geschoben wird).
            for (const v of vis) {
                const a = v.displayA;
                const flipped = Math.cos(a) < 0;
                const rotDeg = (a * 180 / Math.PI) + (flipped ? 180 : 0);
                const lx = cx + labelRingR * Math.cos(a);
                const ly = cy + labelRingR * Math.sin(a);
                d3.select(v.el)
                    .attr('transform',
                        'translate(' + lx + ',' + ly + ') rotate(' + rotDeg + ')')
                    .attr('text-anchor', flipped ? 'end' : 'start')
                    .attr('dx', flipped ? -4 : 4);
            }
        }

        // Interaktions-Highlight. Drei Modi:
        //  • hoverFolder (ohne ausgewählte Notiz): alle Notizen des Ordners hell,
        //    Rest dim, Links dim
        //  • hoverNode / selectedNode: Node + verbundene Notizen + deren Links hell,
        //    alles andere dim
        //  • Nichts aktiv: alles normal
        function updateCircosHighlight() {
            if (!circosState.initialized) return;
            const { nodeTicks, linkArcs, selectedNode, hoverNode, hoverFolder, folderRanges } = circosState;
            if (!nodeTicks || !linkArcs) return;
            const active = selectedNode || hoverNode;

            if (!active && !hoverFolder) {
                nodeTicks.classed('dim', false).classed('hot', false);
                linkArcs.classed('dim', false).classed('hot', false);
                return;
            }

            if (hoverFolder && !active) {
                const folderNodes = folderRanges[hoverFolder]?.nodes || [];
                const idSet = new Set(folderNodes.map(n => n.id));
                nodeTicks.classed('dim', n => !idSet.has(n.id))
                         .classed('hot', n => idSet.has(n.id));
                linkArcs.classed('dim', d => !idSet.has(d.source) && !idSet.has(d.target))
                        .classed('hot', false);
                return;
            }

            const connected = connectedNodes.get(active.id) || new Set();
            nodeTicks.classed('hot', n => n.id === active.id || connected.has(n.id))
                     .classed('dim', n => n.id !== active.id && !connected.has(n.id));
            linkArcs.classed('hot', d => d.source === active.id || d.target === active.id)
                    .classed('dim', d => d.source !== active.id && d.target !== active.id);
        }

        // ===========================================================
        //                Calendar-Heatmap (GitHub-Style)
        // ===========================================================
        // Gruppiert alle Notizen nach yyyy-mm-dd (aus `node.created`, Unix-ms).
        // Rendert pro Jahr ein 7×53-Grid: Zeilen = Wochentage (Mo–So), Spalten =
        // ISO-Wochen. Zellen werden in 5 Farbstufen gemalt, abhängig von der
        // Anzahl Notizen an diesem Tag.
        //
        // Interaktion:
        //  • Hover → Tooltip mit Datum + Anzahl + (wenn ≤3) Titel
        //  • Klick → #day-panel mit Liste aller Notizen des Tages
        //
        // Rebuild bei jedem __applyDataUpdate (kein inkrementelles Diff, bei
        // ~1200 Notizen ist ein Full-Render in <30ms drin und vermeidet Komplexität).
        const calendarState = { initialized: false, selectedDay: null };

        function initCalendar() {
            if (!calendarState.initialized) {
                // Einmalige Event-Handler für Day-Panel-Close
                document.getElementById('day-panel-close').addEventListener('click', () => {
                    hideDayPanel();
                });
                calendarState.initialized = true;
            }
            renderCalendar();
        }

        function hideDayPanel() {
            document.getElementById('day-panel').classList.remove('visible');
            // Tages-View Auswahl zurücksetzen
            calendarState.selectedDay = null;
            document.querySelectorAll('#graph-calendar .cal-cell.selected')
                .forEach(el => el.classList.remove('selected'));
            // Monats-View Auswahl zurücksetzen (Panel wird von beiden Views
            // geteilt, also auch Monats-Highlight aufheben)
            if (typeof monthlyState !== 'undefined') {
                monthlyState.selectedMonth = null;
                document.querySelectorAll('#graph-monthly .mo-cell.selected')
                    .forEach(el => el.classList.remove('selected'));
            }
        }

        // Aus Unix-ms einen "yyyy-mm-dd"-Key in lokaler Zeitzone machen.
        // Wichtig: Lokale TZ (nicht UTC), weil der User seine Notizen in lokaler
        // Zeit erstellt und erwartet, dass 23:30 Notizen am selben Tag landen.
        function dayKeyFromMs(ms) {
            const d = new Date(ms);
            const y = d.getFullYear();
            const m = String(d.getMonth() + 1).padStart(2, '0');
            const day = String(d.getDate()).padStart(2, '0');
            return y + '-' + m + '-' + day;
        }

        // Gibt den Montag der Woche zurück, in der `date` liegt (Mo-basiert).
        // d.getDay(): Sonntag=0, Montag=1, ..., Samstag=6. Wir wollen Mo=0,...,So=6.
        function weekIndexFromDayOfWeek(jsDay) {
            return jsDay === 0 ? 6 : jsDay - 1;
        }

        function renderCalendar() {
            const scroll = document.getElementById('calendar-scroll');
            if (!scroll) return;
            scroll.innerHTML = '';

            // --- 1) Nodes nach Tag bucketizen ---
            // Folder/Tag-Filter greifen: wenn eine Auswahl aktiv ist, zählen nur
            // matchende Notizen in die Heatmap und das Day-Panel. Der Jahres-
            // Range wird weiterhin über ALLE Notizen bestimmt, damit beim
            // Filter-Toggle das Grid nicht schrumpft oder springt.
            const anyFilter = activeFolders.size > 0 || activeTags.size > 0 || searchQuery.length > 0;
            const dayBuckets = {}; // "yyyy-mm-dd" -> array of nodes (gefiltert)
            let minMs = Infinity, maxMs = -Infinity;
            for (const n of data.nodes) {
                if (!n.created || n.created <= 0) continue;
                if (n.created < minMs) minMs = n.created;
                if (n.created > maxMs) maxMs = n.created;
                if (anyFilter && !nodeMatches(n)) continue;
                const k = dayKeyFromMs(n.created);
                if (!dayBuckets[k]) dayBuckets[k] = [];
                dayBuckets[k].push(n);
            }

            if (!isFinite(minMs)) {
                scroll.innerHTML = '<div style="color:#888;font-size:13px;padding:12px;">' + ((window.NM_LOC && window.NM_LOC.noNotesWithDate) || 'No notes with a known creation date.') + '</div>';
                return;
            }

            // --- 2) Max-Tages-Count für Farbskala ---
            let maxDayCount = 0;
            for (const k in dayBuckets) {
                if (dayBuckets[k].length > maxDayCount) maxDayCount = dayBuckets[k].length;
            }

            // 5-stufige Skala: 0=lv0 (nix), ..., lv5 = >80% von max
            function cellLevel(count) {
                if (count === 0) return 0;
                if (maxDayCount <= 4) {
                    return Math.min(5, count);
                }
                const r = count / maxDayCount;
                if (r <= 0.15) return 1;
                if (r <= 0.35) return 2;
                if (r <= 0.6)  return 3;
                if (r <= 0.85) return 4;
                return 5;
            }

            // --- 3) Jahre absteigend rendern ---
            const minYear = new Date(minMs).getFullYear();
            const maxYear = new Date(maxMs).getFullYear();
            const years = [];
            for (let y = maxYear; y >= minYear; y--) years.push(y);

            const weekdayLabels = (window.NM_LOC && window.NM_LOC.weekdaysShort) || ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
            const monthLabels = (window.NM_LOC && window.NM_LOC.monthsShort) || ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];

            for (const year of years) {
                // Anzahl Notizen in diesem Jahr
                let yearCount = 0;
                for (const k in dayBuckets) {
                    if (k.startsWith(year + '-')) yearCount += dayBuckets[k].length;
                }

                const yearDiv = document.createElement('div');
                yearDiv.className = 'cal-year';

                const header = document.createElement('div');
                header.className = 'cal-year-header';
                const filterNote = anyFilter ? ' <span style="color:#ffcc66">· ' + (window.NM_LOC ? window.NM_LOC.filtered : 'filtered') + '</span>' : '';
                header.innerHTML =
                    '<span class="cal-year-title">' + year + '</span>' +
                    '<span class="cal-year-count">' + yearCount + ' ' + (window.NM_LOC ? window.NM_LOC.statsNotes : 'Notes') + filterNote + '</span>';
                yearDiv.appendChild(header);

                const grid = document.createElement('div');
                grid.className = 'cal-grid';

                // Weekday-Spalte: alle 7 Tage (Mo, Di, Mi, Do, Fr, Sa, So).
                // Reihenfolge = Reihenfolge der Cell-Rows im Grid (Row 0 = Montag).
                // `padding-top: 18px` im CSS schiebt die Spalte so weit runter,
                // dass die erste Label-Zeile exakt mit der ersten Zell-Zeile
                // fluchtet (Month-Row 14px + Margin 4px = 18px). KEIN Extra-
                // Header-Slot, sonst sind alle Labels um eine Zeile verschoben.
                const wdCol = document.createElement('div');
                wdCol.className = 'cal-weekday-col';
                for (let i = 0; i < 7; i++) {
                    const s = document.createElement('span');
                    s.textContent = weekdayLabels[i];
                    wdCol.appendChild(s);
                }
                grid.appendChild(wdCol);

                // Rechte Spalte: Month-Row + Week-Grid
                const rightCol = document.createElement('div');
                rightCol.style.display = 'flex';
                rightCol.style.flexDirection = 'column';

                // Jahr-Cursor: 1. Januar → auf vorheriges Montag zurückspulen,
                // damit Spalte 0 immer "oben Mo" zeigt. Wochen-Zählung ist dann
                // Abstand in 7-Tage-Schritten vom Ursprung.
                const yearStart = new Date(year, 0, 1);
                const yearEnd = new Date(year, 11, 31);
                const startDayIdx = weekIndexFromDayOfWeek(yearStart.getDay());
                const gridStart = new Date(yearStart);
                gridStart.setDate(gridStart.getDate() - startDayIdx);

                // Anzahl Wochen: vom gridStart bis einschl. 31.12 (in Wochen)
                const daysSpan = Math.ceil((yearEnd - gridStart) / 86400000) + 1;
                const numWeeks = Math.ceil(daysSpan / 7);

                // Month-Row: Label an Spalten-Position der jeweils ersten Woche, die den 1. enthält
                const monthRow = document.createElement('div');
                monthRow.className = 'cal-month-row';
                monthRow.style.width = (numWeeks * 14 + (numWeeks - 1) * 3) + 'px';
                for (let mo = 0; mo < 12; mo++) {
                    const firstOfMonth = new Date(year, mo, 1);
                    const diffDays = Math.floor((firstOfMonth - gridStart) / 86400000);
                    const weekIdx = Math.floor(diffDays / 7);
                    const label = document.createElement('span');
                    label.textContent = monthLabels[mo];
                    label.style.left = (weekIdx * 17) + 'px'; // 14 + 3
                    monthRow.appendChild(label);
                }
                rightCol.appendChild(monthRow);

                const weekGrid = document.createElement('div');
                weekGrid.className = 'cal-week-grid';

                // Iteriere 7 × numWeeks; column-major durch CSS grid-auto-flow:column.
                // Wir müssen die Zellen aber in der richtigen Reihenfolge anhängen,
                // damit Zelle (row=0,col=0), (row=1,col=0), ..., (row=6,col=0),
                // (row=0,col=1), ... erscheint.
                for (let w = 0; w < numWeeks; w++) {
                    for (let dow = 0; dow < 7; dow++) {
                        const cellDate = new Date(gridStart);
                        cellDate.setDate(cellDate.getDate() + w * 7 + dow);
                        const cell = document.createElement('div');
                        cell.className = 'cal-cell';
                        if (cellDate.getFullYear() !== year) {
                            cell.classList.add('out-of-year');
                            weekGrid.appendChild(cell);
                            continue;
                        }
                        const key = dayKeyFromMs(cellDate.getTime());
                        const bucket = dayBuckets[key] || [];
                        const count = bucket.length;
                        if (count > 0) {
                            cell.classList.add('lv' + cellLevel(count));
                        }
                        cell.dataset.day = key;
                        cell.dataset.count = String(count);

                        cell.addEventListener('mouseenter', (e) => showCalendarTooltip(e, key, bucket));
                        cell.addEventListener('mousemove', (e) => moveCalendarTooltip(e));
                        cell.addEventListener('mouseleave', () => hideCalendarTooltip());
                        cell.addEventListener('click', () => {
                            // Re-Klick auf ausgewählten Tag → Auswahl aufheben
                            if (calendarState.selectedDay === key) {
                                hideDayPanel();
                                return;
                            }
                            openDayPanel(key, bucket, cell);
                        });

                        weekGrid.appendChild(cell);
                    }
                }

                rightCol.appendChild(weekGrid);
                grid.appendChild(rightCol);
                yearDiv.appendChild(grid);

                scroll.appendChild(yearDiv);
            }

            // Schwebende Legende unten-rechts befüllen (einmal pro Render).
            // Liegt außerhalb des Scroll-Containers, damit sie beim Scrollen
            // stehen bleibt. Kein Inline-Block mehr zwischen den Jahres-Grids.
            const legend = document.getElementById('calendar-legend');
            if (legend) {
                const _L = window.NM_LOC || {};
                const maxFmt = (_L.legendMaxPerDay || 'Max: %d / day').replace('%d', maxDayCount);
                legend.innerHTML =
                    '<span>' + (_L.legendLow || 'low') + '</span>' +
                    '<span class="cal-legend-swatch" style="background:#222233"></span>' +
                    '<span class="cal-legend-swatch" style="background:#0e3b6b"></span>' +
                    '<span class="cal-legend-swatch" style="background:#1e5ca3"></span>' +
                    '<span class="cal-legend-swatch" style="background:#3a7fcf"></span>' +
                    '<span class="cal-legend-swatch" style="background:#6aabef"></span>' +
                    '<span class="cal-legend-swatch" style="background:#a6cdf7"></span>' +
                    '<span>' + (_L.legendHigh || 'high') + '</span>' +
                    '<span class="cal-legend-sep">·</span>' +
                    '<span class="cal-legend-max">' + maxFmt + '</span>';
                legend.classList.add('visible');
            }

            // Falls ein Tag ausgewählt war und die Zelle im neuen Render wieder da ist → markieren
            if (calendarState.selectedDay) {
                const sel = document.querySelector('#graph-calendar .cal-cell[data-day="' + calendarState.selectedDay + '"]');
                if (sel) sel.classList.add('selected');
            }
        }

        function showCalendarTooltip(e, dayKey, bucket) {
            const tt = document.getElementById('calendar-tooltip');
            // Datum formatiert: "Mi, 15. Jan 2026"
            const [y, mo, d] = dayKey.split('-').map(x => parseInt(x, 10));
            const dt = new Date(y, mo - 1, d);
            const dateStr = window.NM_formatDate(dt.getTime(), { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' });

            let html = '<div class="tt-date">' + dateStr + '</div>';
            if (bucket.length === 0) {
                html += '<div class="tt-count">' + ((window.NM_LOC && window.NM_LOC.noNotes) || 'no notes') + '</div>';
            } else {
                html += '<div class="tt-count">' + window.NM_pluralNotes(bucket.length) + '</div>';
                const titles = bucket.slice(0, 3).map(n => escapeHTML(n.title || ((window.NM_LOC && window.NM_LOC.noTitle) || '(no title)')));
                html += '<div class="tt-titles">' + titles.map(t => '• ' + t).join('<br>');
                if (bucket.length > 3) html += '<br>…';
                html += '</div>';
            }
            tt.innerHTML = html;
            tt.style.display = 'block';
            moveCalendarTooltip(e);
        }

        function moveCalendarTooltip(e) {
            const tt = document.getElementById('calendar-tooltip');
            if (tt.style.display === 'none') return;
            const pad = 12;
            let x = e.clientX + pad;
            let y = e.clientY + pad;
            // Rand-Clipping: wenn rechts/unten nicht genug Platz, auf die andere Seite
            const w = tt.offsetWidth || 220;
            const h = tt.offsetHeight || 60;
            if (x + w > window.innerWidth - 8) x = e.clientX - w - pad;
            if (y + h > window.innerHeight - 8) y = e.clientY - h - pad;
            tt.style.left = x + 'px';
            tt.style.top = y + 'px';
        }

        function hideCalendarTooltip() {
            document.getElementById('calendar-tooltip').style.display = 'none';
        }

        function openDayPanel(dayKey, bucket, cellEl) {
            // Vorherige Auswahl entfernen
            document.querySelectorAll('#graph-calendar .cal-cell.selected')
                .forEach(el => el.classList.remove('selected'));
            cellEl.classList.add('selected');
            calendarState.selectedDay = dayKey;

            const panel = document.getElementById('day-panel');
            const title = document.getElementById('day-panel-title');
            const meta = document.getElementById('day-panel-meta');
            const list = document.getElementById('day-panel-list');

            const [y, mo, d] = dayKey.split('-').map(x => parseInt(x, 10));
            const dt = new Date(y, mo - 1, d);
            title.textContent = window.NM_formatDate(dt.getTime(), { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' });
            meta.textContent = window.NM_pluralNotes(bucket.length) + ' ' + ((window.NM_LOC && window.NM_LOC.createdSuffix) || 'created');

            list.innerHTML = '';
            // Nach Uhrzeit sortieren (früh → spät)
            const sorted = bucket.slice().sort((a, b) => (a.created || 0) - (b.created || 0));
            for (const n of sorted) {
                const a = document.createElement('a');
                a.href = n.link;
                const time = new Date(n.created);
                const hh = String(time.getHours()).padStart(2, '0');
                const mm = String(time.getMinutes()).padStart(2, '0');
                a.innerHTML =
                    '<span style="color:#888;font-variant-numeric:tabular-nums;margin-right:6px;">' + hh + ':' + mm + '</span>' +
                    escapeHTML(n.title || ((window.NM_LOC && window.NM_LOC.noTitle) || '(no title)')) +
                    '<span class="dp-folder">' + escapeHTML(n.folder || '') + '</span>';
                list.appendChild(a);
            }

            panel.classList.add('visible');
        }

        // ===========================================================
        //                Monthly-Heatmap (Jahre × Monate)
        // ===========================================================
        // Eine Ebene über der Tages-Heatmap: Ein Feld pro Monat, Jahre als
        // Zeilen. Farbskala wie bei der Tages-View, aber neu normalisiert
        // auf das Monats-Maximum (sonst wären fast alle Zellen dunkel,
        // weil Monats-Counts 10–100× höher liegen als Tages-Counts).
        //
        // Interaktion: Klick auf eine Zelle → Day-Panel zeigt alle Notizen
        // des Monats (Wiederverwendung des #day-panel, andere Titel-Logik).
        const monthlyState = { initialized: false, selectedMonth: null, showNumbers: true };

        function initMonthly() {
            if (!monthlyState.initialized) {
                // Toggle-Button für Zahlen in Zellen
                const toggleBtn = document.getElementById('monthly-toggle-numbers');
                toggleBtn.addEventListener('click', () => {
                    monthlyState.showNumbers = !monthlyState.showNumbers;
                    applyMonthlyNumberVisibility();
                });
                applyMonthlyNumberVisibility();
                monthlyState.initialized = true;
            }
            renderMonthly();
        }

        // CSS-Klasse am Container + Button-Label synchronisieren.
        // Reine CSS-Lösung: textContent der Zellen bleibt im DOM, nur die
        // Text-Farbe wird transparent. Dadurch bleiben Cell-Größe und
        // Vertical-Centering konsistent mit dem "mit Zahlen"-Zustand.
        function applyMonthlyNumberVisibility() {
            const container = document.getElementById('graph-monthly');
            const btn = document.getElementById('monthly-toggle-numbers');
            const _L = window.NM_LOC || {};
            if (monthlyState.showNumbers) {
                container.classList.remove('numbers-hidden');
                btn.classList.remove('off');
                btn.textContent = _L.numbersOn || 'Numbers: on';
            } else {
                container.classList.add('numbers-hidden');
                btn.classList.add('off');
                btn.textContent = _L.numbersOff || 'Numbers: off';
            }
        }

        function renderMonthly() {
            const scroll = document.getElementById('monthly-scroll');
            if (!scroll) return;
            scroll.innerHTML = '';

            const anyFilter = activeFolders.size > 0 || activeTags.size > 0 || searchQuery.length > 0;

            // --- 1) Nodes nach YYYY-MM bucketizen ---
            // Jahres-Range über ALLE Nodes (unabhängig von Filter), damit die
            // Jahres-Zeilen nicht wegspringen beim Filter-Toggle.
            const monthBuckets = {}; // "yyyy-mm" -> array of (gefilterte) nodes
            let minMs = Infinity, maxMs = -Infinity;
            for (const n of data.nodes) {
                if (!n.created || n.created <= 0) continue;
                if (n.created < minMs) minMs = n.created;
                if (n.created > maxMs) maxMs = n.created;
                if (anyFilter && !nodeMatches(n)) continue;
                const d = new Date(n.created);
                const k = d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0');
                if (!monthBuckets[k]) monthBuckets[k] = [];
                monthBuckets[k].push(n);
            }

            if (!isFinite(minMs)) {
                scroll.innerHTML = '<div style="color:#888;font-size:13px;padding:12px;">' + ((window.NM_LOC && window.NM_LOC.noNotesWithDate) || 'No notes with a known creation date.') + '</div>';
                const lg = document.getElementById('monthly-legend');
                if (lg) lg.classList.remove('visible');
                return;
            }

            // --- 2) Max-Monats-Count für Farbskala ---
            let maxMonthCount = 0;
            for (const k in monthBuckets) {
                if (monthBuckets[k].length > maxMonthCount) maxMonthCount = monthBuckets[k].length;
            }

            function cellLevel(count) {
                if (count === 0) return 0;
                if (maxMonthCount <= 4) return Math.min(5, count);
                const r = count / maxMonthCount;
                if (r <= 0.15) return 1;
                if (r <= 0.35) return 2;
                if (r <= 0.6)  return 3;
                if (r <= 0.85) return 4;
                return 5;
            }

            // --- 3) Jahre absteigend rendern ---
            const minYear = new Date(minMs).getFullYear();
            const maxYear = new Date(maxMs).getFullYear();
            const minMonth = new Date(minMs).getMonth(); // 0-basiert
            const maxMonth = new Date(maxMs).getMonth();

            const monthLabels = (window.NM_LOC && window.NM_LOC.monthsShort) || ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];

            const wrap = document.createElement('div');
            wrap.className = 'mo-wrap';

            const grid = document.createElement('div');
            grid.className = 'mo-grid';

            // Header-Zeile: leere Ecke + 12 Monats-Labels
            const corner = document.createElement('div');
            corner.className = 'mo-header mo-corner';
            grid.appendChild(corner);
            for (let m = 0; m < 12; m++) {
                const h = document.createElement('div');
                h.className = 'mo-header';
                h.textContent = monthLabels[m];
                grid.appendChild(h);
            }

            // Jahres-Zeilen (neuestes oben)
            for (let y = maxYear; y >= minYear; y--) {
                const yl = document.createElement('div');
                yl.className = 'mo-year-label';
                yl.textContent = String(y);
                grid.appendChild(yl);

                for (let m = 0; m < 12; m++) {
                    const cell = document.createElement('div');
                    cell.className = 'mo-cell';

                    // Außerhalb des Daten-Bereichs (z.B. Monate nach max oder vor min)
                    const outOfRange =
                        (y === maxYear && m > maxMonth) ||
                        (y === minYear && m < minMonth);
                    if (outOfRange) {
                        cell.classList.add('out-of-range');
                        cell.textContent = '';
                        grid.appendChild(cell);
                        continue;
                    }

                    const key = y + '-' + String(m + 1).padStart(2, '0');
                    const bucket = monthBuckets[key] || [];
                    const count = bucket.length;
                    if (count === 0) {
                        cell.classList.add('empty');
                        cell.textContent = '·';
                    } else {
                        cell.classList.add('lv' + cellLevel(count));
                        cell.textContent = count;
                    }
                    cell.dataset.month = key;
                    cell.dataset.count = String(count);
                    cell.title = monthLabels[m] + ' ' + y + ' · ' + window.NM_pluralNotes(count);

                    cell.addEventListener('click', () => {
                        if (count === 0) return;
                        // Zweiter Klick auf den gleichen Monat → Auswahl aufheben
                        if (monthlyState.selectedMonth === key) {
                            hideDayPanel();
                            return;
                        }
                        openMonthPanel(key, bucket, cell);
                    });

                    grid.appendChild(cell);
                }
            }

            wrap.appendChild(grid);
            scroll.appendChild(wrap);

            // Legende unten-mittig füllen
            const legend = document.getElementById('monthly-legend');
            if (legend) {
                const _L = window.NM_LOC || {};
                const maxFmt = (_L.legendMaxPerMonth || 'Max: %d / month').replace('%d', maxMonthCount);
                legend.innerHTML =
                    '<span>' + (_L.legendLow || 'low') + '</span>' +
                    '<span class="cal-legend-swatch" style="background:#222233"></span>' +
                    '<span class="cal-legend-swatch" style="background:#0e3b6b"></span>' +
                    '<span class="cal-legend-swatch" style="background:#1e5ca3"></span>' +
                    '<span class="cal-legend-swatch" style="background:#3a7fcf"></span>' +
                    '<span class="cal-legend-swatch" style="background:#6aabef"></span>' +
                    '<span class="cal-legend-swatch" style="background:#a6cdf7"></span>' +
                    '<span>' + (_L.legendHigh || 'high') + '</span>' +
                    '<span class="cal-legend-sep">·</span>' +
                    '<span class="cal-legend-max">' + maxFmt + '</span>';
                legend.classList.add('visible');
            }

            // Falls ein Monat ausgewählt war → wieder markieren
            if (monthlyState.selectedMonth) {
                const sel = document.querySelector('#graph-monthly .mo-cell[data-month="' + monthlyState.selectedMonth + '"]');
                if (sel) sel.classList.add('selected');
            }
        }

        function openMonthPanel(monthKey, bucket, cellEl) {
            document.querySelectorAll('#graph-monthly .mo-cell.selected')
                .forEach(el => el.classList.remove('selected'));
            cellEl.classList.add('selected');
            monthlyState.selectedMonth = monthKey;

            const panel = document.getElementById('day-panel');
            const title = document.getElementById('day-panel-title');
            const meta = document.getElementById('day-panel-meta');
            const list = document.getElementById('day-panel-list');

            const [y, mo] = monthKey.split('-').map(x => parseInt(x, 10));
            const moNames = (window.NM_LOC && window.NM_LOC.monthsLong) || ['January','February','March','April','May','June','July','August','September','October','November','December'];
            title.textContent = moNames[mo - 1] + ' ' + y;
            meta.textContent = window.NM_pluralNotes(bucket.length) + ' ' + ((window.NM_LOC && window.NM_LOC.inThisMonth) || 'in this month');

            list.innerHTML = '';
            // Neueste zuerst (absteigend)
            const sorted = bucket.slice().sort((a, b) => (b.created || 0) - (a.created || 0));
            for (const n of sorted) {
                const a = document.createElement('a');
                a.href = n.link;
                const time = new Date(n.created);
                const dd = String(time.getDate()).padStart(2, '0');
                const mm = String(time.getMonth() + 1).padStart(2, '0');
                a.innerHTML =
                    '<span style="color:#888;font-variant-numeric:tabular-nums;margin-right:6px;">' + dd + '.' + mm + '.</span>' +
                    escapeHTML(n.title || ((window.NM_LOC && window.NM_LOC.noTitle) || '(no title)')) +
                    '<span class="dp-folder">' + escapeHTML(n.folder || '') + '</span>';
                list.appendChild(a);
            }

            panel.classList.add('visible');
        }

        // ===========================================================
        //                         HEIGHTMAP
        // ===========================================================
        // Themenlandschaft via Ollama-Embeddings (bge-m3) + UMAP → 2D → d3.
        //
        // Pipeline (3 asynchrone Etappen, alle optional überspringbar):
        //   (A) Ollama-Berechnung  : JS → Swift → Ollama → Cache → Payload zurück.
        //                             Läuft NUR beim ersten Klick (bzw. nach
        //                             Cache-Miss). Fortschritt kommt über
        //                             window.__heightmapProgress() rein.
        //   (B) UMAP-Reduktion     : 1024-dim → 2D. Läuft im JS-Thread, aber
        //                             in <10-epoch-Häppchen mit setTimeout(0),
        //                             damit der Browser nicht einfriert.
        //   (C) Rendering          : d3.contourDensity → Canvas, Kreise → SVG.
        //
        // State-Diagramm:
        //   idle → requested → (progress*) → (error|ready) → running-umap → rendered
        //                                         ↓
        //                                     retry-able (Button-Klick)
        //
        // Daten-Invalidierung:
        //   __applyDataUpdate() setzt dataReady=false + embeddings/coords=null.
        //   User muss erneut auf "Höhenkarte" klicken, damit die Embeddings
        //   für die neuen Notizen nachgezogen werden (Cache macht das schnell).
        const heightmapState = {
            initialized: false,  // initHeightmap schon gelaufen?
            requested: false,    // Swift wurde schon angefragt?
            dataReady: false,    // Embeddings da & UMAP fertig?
            umapRunning: false,  // Läuft UMAP-Schritt gerade?
            embeddings: null,    // Map<uuid, Float32Array(dim)>
            coords: null,        // Map<uuid, {x,y}>, normalisiert auf [0,1]
            canvas: null,        // Contour-Canvas
            ctx: null,
            svg: null,           // d3.select(#heightmap-svg)
            tooltip: null,       // HTMLElement #heightmap-tooltip
            colorMode: 'folder', // 'folder' | 'hub' | 'created'
            showContour: true,
            lastModel: '',
            lastDim: 0
        };

        function initHeightmap() {
            if (!heightmapState.initialized) {
                heightmapState.canvas = document.getElementById('heightmap-contour');
                heightmapState.ctx = heightmapState.canvas.getContext('2d');
                heightmapState.svg = d3.select('#heightmap-svg');
                heightmapState.tooltip = document.getElementById('heightmap-tooltip');

                // Color-Mode-Buttons verkabeln
                document.getElementById('btn-heightmap-color-folder').addEventListener('click', () => setHeightmapColor('folder'));
                document.getElementById('btn-heightmap-color-hub').addEventListener('click', () => setHeightmapColor('hub'));
                document.getElementById('btn-heightmap-color-created').addEventListener('click', () => setHeightmapColor('created'));

                // 2D/3D-Ansicht-Toggle
                document.getElementById('btn-heightmap-view-2d').addEventListener('click', () => setHeightmap3dView('2d'));
                document.getElementById('btn-heightmap-view-3d').addEventListener('click', () => setHeightmap3dView('3d'));

                // Detail-Slider: steuert die KDE-Bandwidth. Links = breitere
                // Bandwidth = weniger, breitere Hügel. Rechts = engere Bandwidth =
                // mehr, schärfere Spitzen. Wert-Anzeige ist instant, die
                // eigentliche Neuberechnung (KDE + Mesh + Peaks + Ollama-Call)
                // wird 150 ms debounced, damit beim Ziehen nicht bei jedem
                // Sub-Tick 80-100 ms Arbeit anfällt. Ollama-Labels werden
                // cache-backed abgerufen → wiederkehrende Cluster sind instant.
                const peakSliderEl = document.getElementById('heightmap-peak-slider');
                const peakSliderValueEl = document.getElementById('heightmap-peak-slider-value');
                if (peakSliderEl && peakSliderValueEl) {
                    let bwDebounceTimer = null;
                    peakSliderEl.addEventListener('input', (ev) => {
                        const n = parseInt(ev.target.value, 10);
                        peakSliderValueEl.textContent = String(n);
                        if (bwDebounceTimer) clearTimeout(bwDebounceTimer);
                        bwDebounceTimer = setTimeout(() => {
                            const bw = bandwidthForSliderValue(n);
                            // 3D-Seite zuerst: aktualisiert Peaks + Three.js-Mesh
                            // (wenn gebaut) + Labels + Ollama-Request.
                            recomputeHeightmap3dTerrain(bw);
                            // 2D-Seite: Contours neu zeichnen (nutzt intern
                            // bandwidth2DForSliderValue) + 2D-Label-Positionen.
                            renderHeightmap();
                        }, 150);
                    });
                }

                // Contour-Toggle
                document.getElementById('heightmap-show-contour').addEventListener('change', (ev) => {
                    heightmapState.showContour = !!ev.target.checked;
                    renderHeightmap();
                });

                // Resize: Canvas + SVG neu vermessen (debounced).
                let resizeTimer = null;
                window.addEventListener('resize', () => {
                    if (currentMode !== 'heightmap') return;
                    if (resizeTimer) clearTimeout(resizeTimer);
                    resizeTimer = setTimeout(() => renderHeightmap(), 150);
                });

                heightmapState.initialized = true;
            }

            // Haben wir Embeddings + Coords? Dann direkt rendern (z.B. Rückkehr nach Mode-Switch).
            if (heightmapState.dataReady) {
                showHeightmapOverlay(false);
                renderHeightmap();
                return;
            }

            // Noch nicht angefragt (oder Re-Request nach Error/Data-Update) → los.
            if (!heightmapState.requested) {
                heightmapState.requested = true;
                showHeightmapOverlay(true, {
                    title: (window.NM_LOC && window.NM_LOC.hmPreparing) || 'Preparing heightmap…',
                    message: (window.NM_LOC && window.NM_LOC.hmEmbeddingHint) || 'Embeddings via Ollama (bge-m3). First run takes a moment.',
                    detail: (window.NM_LOC && window.NM_LOC.hmStarting) || 'Starting…',
                    progress: 0,
                    error: false
                });
                try {
                    window.webkit.messageHandlers.heightmapRequest.postMessage({});
                } catch (e) {
                    console.warn('heightmapRequest not available:', e);
                    showHeightmapOverlay(true, {
                        title: (window.NM_LOC && window.NM_LOC.hmUnavailable) || 'Heightmap unavailable',
                        message: (window.NM_LOC && window.NM_LOC.hmBridgeMissing) || 'Native bridge unavailable.',
                        detail: String(e),
                        progress: 1,
                        error: true
                    });
                    heightmapState.requested = false;
                }
            }
        }

        function showHeightmapOverlay(visible, opts) {
            const ov = document.getElementById('heightmap-overlay');
            if (!visible) {
                ov.classList.add('hidden');
                ov.classList.remove('error');
                return;
            }
            ov.classList.remove('hidden');
            ov.classList.toggle('error', !!(opts && opts.error));
            if (opts) {
                if (opts.title != null)   document.getElementById('heightmap-title').textContent = opts.title;
                if (opts.message != null) document.getElementById('heightmap-message').textContent = opts.message;
                if (opts.detail != null)  document.getElementById('heightmap-detail').textContent = opts.detail;
                if (opts.progress != null) {
                    const pct = Math.max(0, Math.min(1, opts.progress)) * 100;
                    document.getElementById('heightmap-progress-fill').style.width = pct.toFixed(1) + '%';
                }
            }
        }

        // Swift → JS: Fortschritts-Updates.
        // payload = { phase, done, total, message }
        // phase ∈ {"check","load","embed"}, wir nutzen die Phase nur für die
        // Titelzeile. Progress-Bar füttert sich aus done/total.
        window.__heightmapProgress = function(payload) {
            try {
                const phase = payload.phase || '';
                const done = payload.done || 0;
                const total = payload.total || 0;
                const msg = payload.message || '';
                const _L = window.NM_LOC || {};
                let title = _L.hmPreparing || 'Preparing heightmap…';
                if (phase === 'check') title = _L.hmCheckOllama || 'Checking Ollama…';
                else if (phase === 'load') title = _L.hmLoadingNotesShort || 'Loading notes…';
                else if (phase === 'embed') title = _L.hmEmbedding || 'Computing embeddings…';
                const progress = total > 0 ? (done / total) : 0;
                showHeightmapOverlay(true, {
                    title: title,
                    message: msg || _L.hmProgress || 'In progress…',
                    detail: total > 0 ? (done + ' / ' + total) : '',
                    progress: progress,
                    error: false
                });
            } catch (e) {
                console.error('[__heightmapProgress]', e);
            }
        };

        // Swift → JS: Fehler beim Embedding (Ollama offline, Modell fehlt, ...).
        // payload = { message: String }
        window.__heightmapError = function(payload) {
            try {
                const _L = window.NM_LOC || {};
                const msg = (payload && payload.message) || _L.unknownError || 'Unknown error.';
                showHeightmapOverlay(true, {
                    title: _L.hmFailed || 'Heightmap failed',
                    message: msg,
                    detail: _L.hmRetryHint || 'Tip: `ollama serve` and `ollama pull bge-m3`, then retry.',
                    progress: 1,
                    error: true
                });
                heightmapState.requested = false; // Klick darauf → Retry
            } catch (e) {
                console.error('[__heightmapError]', e);
            }
        };

        // Swift → JS: Embeddings sind da, jetzt UMAP + Render.
        // payload = { model, dim, points: [{uuid, vec: [Float]}] }
        window.__applyHeightmap = async function(payload) {
            try {
                if (!payload || !Array.isArray(payload.points) || payload.points.length === 0) {
                    const _L = window.NM_LOC || {};
                    showHeightmapOverlay(true, {
                        title: _L.hmEmpty || 'Heightmap empty',
                        message: _L.hmEmptyMsg || 'No embeddings returned.',
                        progress: 1, error: true
                    });
                    heightmapState.requested = false;
                    return;
                }

                heightmapState.lastModel = payload.model || '';
                heightmapState.lastDim = payload.dim || (payload.points[0].vec ? payload.points[0].vec.length : 0);

                // Embeddings in Map umpacken (Float32Array spart Speicher + UMAP mag's).
                const emb = new Map();
                for (const p of payload.points) {
                    if (!p.uuid || !Array.isArray(p.vec)) continue;
                    emb.set(p.uuid, Float32Array.from(p.vec));
                }
                heightmapState.embeddings = emb;

                // Nur Nodes, für die wir ein Embedding haben. Sonst kann UMAP
                // nichts sinnvolles berechnen (Null-Vektor würde Cluster zerreißen).
                // WICHTIG: in data.nodes ist die UUID unter `id` abgelegt
                // (siehe buildDataPayload: "id": node.uuid). Es gibt kein `uuid`-Feld.
                const uuidToNode = new Map();
                for (const n of data.nodes) uuidToNode.set(n.id, n);

                const uuids = [];
                const vectors = [];
                for (const [uuid, vec] of emb) {
                    if (!uuidToNode.has(uuid)) continue;
                    uuids.push(uuid);
                    vectors.push(Array.from(vec));
                }

                if (vectors.length < 2) {
                    const _L = window.NM_LOC || {};
                    showHeightmapOverlay(true, {
                        title: _L.hmTooFewTitle || 'Too few notes',
                        message: _L.hmTooFew || 'Heightmap needs at least 2 notes with embeddings.',
                        progress: 1, error: true
                    });
                    heightmapState.requested = false;
                    return;
                }

                {
                    const _L = window.NM_LOC || {};
                    showHeightmapOverlay(true, {
                        title: _L.hmReducing || 'Reducing to 2D…',
                        message: _L.hmUmapRunning || 'UMAP runs locally in the browser.',
                        detail: (_L.hmEpoch || 'Epoch %d …').replace('%d', '0'),
                        progress: 0,
                        error: false
                    });
                }

                const coords = await runUMAPAsync(uuids, vectors, (epoch, totalEpochs) => {
                    showHeightmapOverlay(true, {
                        title: 'Reduziere auf 2D…',
                        detail: 'Epoche ' + epoch + ' / ' + totalEpochs,
                        progress: totalEpochs > 0 ? epoch / totalEpochs : 0,
                        error: false
                    });
                });

                heightmapState.coords = coords;
                heightmapState.dataReady = true;
                heightmapState.requested = false;

                // Fertig → Overlay weg, zeichnen.
                showHeightmapOverlay(false);
                renderHeightmap();

                // Falls User gerade in 3D ist (z.B. 3D-Button geklickt während
                // Embeddings liefen), die Szene jetzt aufbauen.
                if (heightmap3dState.view === '3d' && !heightmap3dState.built) {
                    init3DHeightmapIfNeeded();
                    onHeightmap3DResize();
                    buildHeightmap3dScene();
                }
            } catch (e) {
                console.error('[__applyHeightmap]', e);
                showHeightmapOverlay(true, {
                    title: 'UMAP fehlgeschlagen',
                    message: String(e && e.message ? e.message : e),
                    progress: 1, error: true
                });
                heightmapState.requested = false;
            }
        };

        // UMAP asynchron: initializeFit einmal, step() in kleinen Häppchen
        // mit setTimeout(0) dazwischen, damit der Browser-Thread atmen kann.
        // Alternative wäre ein Web-Worker, aber UMD-Import im WKWebView ist
        // fummelig, Häppchen-Variante ist bei <2000 Notizen schnell genug.
        async function runUMAPAsync(uuids, vectors, onEpoch) {
            // umap-js UMD setzt globalThis.UMAP auf das Modul-Exports-Objekt,
            // nicht direkt auf die Klasse. Die Klasse liegt auf .UMAP.
            // Fallback: Wenn UMAP selbst schon eine Klasse ist (andere Versionen).
            const UMAPModule = globalThis.UMAP;
            if (!UMAPModule) {
                throw new Error('UMAP-Library nicht geladen (umap-js fehlt im Bundle).');
            }
            const UMAPClass = (typeof UMAPModule === 'function') ? UMAPModule : UMAPModule.UMAP;
            if (typeof UMAPClass !== 'function') {
                throw new Error('UMAP-Klasse in umap-js nicht gefunden (unexpected module shape).');
            }
            // nNeighbors > Knotenzahl führt zu UMAP-Fehler, clampen.
            // 40 statt UMAP-Default 15 (und unserem Zwischenschritt 30): bei
            // ~1200 Notizen gibt ein größeres Nachbarschafts-Fenster eine noch
            // globalere Topologie. Die Cluster werden kompakter, die Themen-
            // Inseln stärker voneinander getrennt. Faustregel aus UMAP-Docs:
            //   <200 Punkte → 15, 200-1k → 20-30, 1k-10k → 30-50, 10k+ → 50-100.
            // Test mit 30 lieferte schon gute Landschaft; 40 soll noch feiner
            // die verbliebenen Mischcluster aufbrechen. Wenn zu "glatt": zurück
            // auf 30 drehen.
            const n = vectors.length;
            const nNeighbors = Math.max(2, Math.min(40, n - 1));

            const umap = new UMAPClass({
                nComponents: 2,
                nNeighbors: nNeighbors,
                minDist: 0.1,
                spread: 1.0,
                random: () => Math.random()
            });

            // initializeFit ist synchron & teuer (~ein paar Sekunden bei 1200 × 1024).
            // Kein Chunking möglich, wir zeigen "Initialisiere…" und schlucken's.
            if (onEpoch) onEpoch(0, 0);
            // setTimeout(0), damit der Overlay-DOM-Update sicher durchkommt,
            // bevor der große Sync-Block startet.
            await new Promise(r => setTimeout(r, 16));

            const totalEpochs = umap.initializeFit(vectors);
            if (onEpoch) onEpoch(0, totalEpochs);
            await new Promise(r => setTimeout(r, 0));

            const CHUNK = 10;
            for (let i = 0; i < totalEpochs; i += CHUNK) {
                const end = Math.min(i + CHUNK, totalEpochs);
                for (let j = i; j < end; j++) umap.step();
                if (onEpoch) onEpoch(end, totalEpochs);
                await new Promise(r => setTimeout(r, 0));
            }

            const raw = umap.getEmbedding(); // [[x,y], ...] parallel zu uuids
            // Auf [0,1] normalisieren (bewahrt Aspect Ratio nicht, wollen
            // wir auch nicht, weil Canvas-Koordinaten später skaliert werden).
            let xMin = Infinity, xMax = -Infinity, yMin = Infinity, yMax = -Infinity;
            for (const p of raw) {
                if (p[0] < xMin) xMin = p[0]; if (p[0] > xMax) xMax = p[0];
                if (p[1] < yMin) yMin = p[1]; if (p[1] > yMax) yMax = p[1];
            }
            const xRange = (xMax - xMin) || 1;
            const yRange = (yMax - yMin) || 1;

            const coords = new Map();
            for (let i = 0; i < uuids.length; i++) {
                coords.set(uuids[i], {
                    x: (raw[i][0] - xMin) / xRange,
                    y: (raw[i][1] - yMin) / yRange
                });
            }
            return coords;
        }

        // Farbe setzen (Button + Render-Refresh).
        function setHeightmapColor(mode) {
            if (!['folder','hub','created'].includes(mode)) return;
            if (heightmapState.colorMode === mode) return;
            heightmapState.colorMode = mode;
            // Nur die Farb-Buttons togglen (nicht die 2D/3D-Buttons, die
            // in einer anderen .heightmap-sort-group sitzen).
            ['folder','hub','created'].forEach(m => {
                const b = document.getElementById('btn-heightmap-color-' + m);
                if (b) b.classList.toggle('active', m === mode);
            });
            renderHeightmap();
            // Falls 3D aufgebaut ist, Farben dort auch aktualisieren, auch wenn
            // die 2D-Ansicht aktiv ist (User könnte gleich umschalten).
            if (heightmap3dState.built) updateHeightmap3dColors();
        }

        // Liefert den Fill-Color eines Nodes je nach colorMode. Gibt ein
        // {color, legend} zurück, Legend-Info wird in renderHeightmap für die
        // Min/Max-Labels ausgewertet.
        function heightmapFillFor(node, ctx) {
            if (heightmapState.colorMode === 'folder') {
                return ctx.folderColor[node.folder] || '#888';
            }
            if (heightmapState.colorMode === 'hub') {
                // hubScore ∈ [0, max]. Interpoliere viridis.
                if (ctx.hubMax <= 0) return d3.interpolateViridis(0.3);
                const t = (node.hubScore || 0) / ctx.hubMax;
                return d3.interpolateViridis(t);
            }
            // created: alt → dunkel, neu → hell
            if (ctx.createdMax === ctx.createdMin) return d3.interpolatePlasma(0.5);
            const t = (((node.created || ctx.createdMin) - ctx.createdMin) / (ctx.createdMax - ctx.createdMin));
            return d3.interpolatePlasma(t);
        }

        function renderHeightmap() {
            if (!heightmapState.initialized || !heightmapState.dataReady) return;
            const container = document.getElementById('graph-heightmap');
            const cw = container.clientWidth;
            const ch = container.clientHeight;
            if (cw <= 0 || ch <= 0) return;

            // Padding, damit Punkte nicht an den Rändern kleben.
            const padX = 40, padY = 40;
            const plotW = Math.max(20, cw - 2 * padX);
            const plotH = Math.max(20, ch - 2 * padY);

            // Nodes mit Coord auflisten. Wieder: data.nodes[i].id = UUID.
            const uuidToNode = new Map();
            for (const n of data.nodes) uuidToNode.set(n.id, n);

            const plotNodes = [];
            for (const [uuid, p] of heightmapState.coords) {
                const node = uuidToNode.get(uuid);
                if (!node) continue; // Node gelöscht seit Embedding-Run
                plotNodes.push({
                    node: node,
                    cx: padX + p.x * plotW,
                    cy: padY + p.y * plotH
                });
            }

            // Kontext für Farb-Skalen
            const ctx = {
                folderColor: {},
                hubMax: 0,
                createdMin: Infinity,
                createdMax: -Infinity
            };
            for (const f of data.folders) ctx.folderColor[f.name] = f.color;
            for (const pn of plotNodes) {
                const n = pn.node;
                if ((n.hubScore || 0) > ctx.hubMax) ctx.hubMax = n.hubScore || 0;
                const c = n.created || 0;
                if (c > 0) {
                    if (c < ctx.createdMin) ctx.createdMin = c;
                    if (c > ctx.createdMax) ctx.createdMax = c;
                }
            }
            if (!isFinite(ctx.createdMin)) { ctx.createdMin = 0; ctx.createdMax = 1; }

            // --- Canvas: Contour-Density ---
            const dpr = window.devicePixelRatio || 1;
            const canvas = heightmapState.canvas;
            canvas.style.width = cw + 'px';
            canvas.style.height = ch + 'px';
            canvas.width = Math.round(cw * dpr);
            canvas.height = Math.round(ch * dpr);
            const cctx = heightmapState.ctx;
            cctx.setTransform(dpr, 0, 0, dpr, 0, 0);
            cctx.clearRect(0, 0, cw, ch);

            if (heightmapState.showContour && plotNodes.length >= 3) {
                // contourDensity erwartet Array<{x,y}> aber mit accessor-Funktionen.
                // Bandwidth vom Detail-Slider übernehmen, gleiche Logik wie 3D,
                // nur in Pixel-Space (d3-Konvention).
                const bw2d = bandwidth2DForSliderValue(getPeakSliderValue());
                const contours = d3.contourDensity()
                    .x(d => d.cx)
                    .y(d => d.cy)
                    .size([cw, ch])
                    .bandwidth(bw2d)
                    .thresholds(14)(plotNodes);

                // Max-value finden für normalisierte Farbskala
                let maxVal = 0;
                for (const c of contours) if (c.value > maxVal) maxVal = c.value;
                const colorScale = d3.scaleSequential(d3.interpolateViridis).domain([0, maxVal || 1]);

                cctx.globalAlpha = 0.55;
                for (const c of contours) {
                    cctx.beginPath();
                    // Jeder Contour ist ein MultiPolygon, Path-String via d3.geoPath
                    const pathStr = d3.geoPath()(c);
                    const p2d = new Path2D(pathStr);
                    cctx.fillStyle = colorScale(c.value);
                    cctx.fill(p2d);
                }
                cctx.globalAlpha = 1;
            }

            // --- SVG: Scatter ---
            const svg = heightmapState.svg;
            svg.attr('viewBox', '0 0 ' + cw + ' ' + ch)
               .attr('width', cw)
               .attr('height', ch);

            const r = plotNodes.length > 500 ? 3.5 : 5;

            const circles = svg.selectAll('circle')
                .data(plotNodes, d => d.node.id);

            circles.exit().remove();

            const enter = circles.enter().append('circle')
                .attr('r', r)
                .on('mouseenter', function(ev, d) {
                    showHeightmapTooltip(ev, d.node);
                })
                .on('mousemove', moveHeightmapTooltip)
                .on('mouseleave', hideHeightmapTooltip)
                .on('click', function(ev, d) {
                    ev.stopPropagation();
                    showPanel(d.node);
                });

            enter.merge(circles)
                .attr('cx', d => d.cx)
                .attr('cy', d => d.cy)
                .attr('r', r)
                .attr('fill', d => heightmapFillFor(d.node, ctx));

            // Filter direkt nach Draw anwenden (damit dimmed-State sichtbar wird)
            applyHeightmapFilters();

            // 2D-Peak-Labels: wenn Peaks noch nicht existieren (User ist direkt
            // zu 2D ohne je in 3D gewesen zu sein), einmalig berechnen und
            // Ollama anfragen. Danach einfach nur re-positionieren.
            if (!heightmap3dState.peaks && heightmapState.dataReady) {
                rebuildPeakData(bandwidthForSliderValue(getPeakSliderValue()));
                requestOllamaPeakLabels();
            }
            renderHeightmap2dLabels();

            // Legende je nach Color-Mode
            renderHeightmapLegend(ctx);
        }

        // Erzeugt (oder ersetzt) die 2D-Label-Overlay-Div. Läuft durch
        // heightmap3dState.peaks, platziert jeden Peak bei
        // (padX + x01*plotW, padY + y01*plotH) im 2D-Container. Gemergete Peaks
        // werden übersprungen. CSS-Klasse ist identisch zu 3D (.hm3d-label +
        // state-Class), damit sehen beide Label-Sets gleich aus (Pending/Ready/Failed).
        function renderHeightmap2dLabels() {
            const container = document.getElementById('graph-heightmap');
            if (!container) return;
            const old = container.querySelector('#heightmap-2d-labels');
            if (old) old.remove();
            const peaks = heightmap3dState.peaks;
            if (peaks) for (const p of peaks) p.dom2d = null;
            if (!peaks || peaks.length === 0) return;

            const cw = container.clientWidth;
            const ch = container.clientHeight;
            if (cw <= 0 || ch <= 0) return;
            const padX = 40, padY = 40;
            const plotW = Math.max(20, cw - 2 * padX);
            const plotH = Math.max(20, ch - 2 * padY);

            const wrap = document.createElement('div');
            wrap.id = 'heightmap-2d-labels';
            wrap.style.cssText = 'position:absolute;top:0;left:0;width:100%;height:100%;pointer-events:none;z-index:3;overflow:hidden;';
            for (const p of peaks) {
                if (p.state === 'merged') continue;
                const el = document.createElement('div');
                const stateClass = p.state === 'ready'
                    ? 'ready'
                    : (p.state === 'failed' ? 'failed' : 'pending');
                el.className = 'hm3d-label ' + stateClass;
                el.textContent = p.text;
                el.title = (p.noteCount || 0) + ' Notizen'
                    + (p.state === 'pending' ? ', Ollama generiert Label…' : '');
                el.style.position = 'absolute';
                el.style.left = (padX + p.x01 * plotW) + 'px';
                el.style.top  = (padY + p.y01 * plotH) + 'px';
                el.style.transform = 'translate(-50%, -50%)';
                wrap.appendChild(el);
                p.dom2d = el;
            }
            container.appendChild(wrap);
        }

        function renderHeightmapLegend(ctx) {
            const el = document.getElementById('heightmap-legend');
            if (heightmapState.colorMode === 'folder') {
                // Bei Ordner-Farben gibt es schon die große Legende oben links.
                el.classList.remove('visible');
                el.innerHTML = '';
                return;
            }
            el.classList.add('visible');
            if (heightmapState.colorMode === 'hub') {
                // Gradient-Vorschau + Min/Max
                const gradId = 'hm-grad-hub';
                el.innerHTML =
                    '<span class="hm-legend-cap">0</span>' +
                    '<svg width="80" height="8" class="hm-legend-grad"><defs><linearGradient id="' + gradId + '" x1="0" x2="1" y1="0" y2="0">' +
                    '<stop offset="0%" stop-color="' + d3.interpolateViridis(0) + '"/>' +
                    '<stop offset="50%" stop-color="' + d3.interpolateViridis(0.5) + '"/>' +
                    '<stop offset="100%" stop-color="' + d3.interpolateViridis(1) + '"/>' +
                    '</linearGradient></defs><rect width="80" height="8" fill="url(#' + gradId + ')"/></svg>' +
                    '<span class="hm-legend-cap">Hub=' + Math.round(ctx.hubMax) + '</span>';
            } else if (heightmapState.colorMode === 'created') {
                const fmt = (ts) => {
                    if (!ts) return '…';
                    return window.NM_formatDate(ts, { year: 'numeric', month: 'short' });
                };
                const gradId = 'hm-grad-created';
                el.innerHTML =
                    '<span class="hm-legend-cap">' + fmt(ctx.createdMin) + '</span>' +
                    '<svg width="80" height="8" class="hm-legend-grad"><defs><linearGradient id="' + gradId + '" x1="0" x2="1" y1="0" y2="0">' +
                    '<stop offset="0%" stop-color="' + d3.interpolatePlasma(0) + '"/>' +
                    '<stop offset="50%" stop-color="' + d3.interpolatePlasma(0.5) + '"/>' +
                    '<stop offset="100%" stop-color="' + d3.interpolatePlasma(1) + '"/>' +
                    '</linearGradient></defs><rect width="80" height="8" fill="url(#' + gradId + ')"/></svg>' +
                    '<span class="hm-legend-cap">' + fmt(ctx.createdMax) + '</span>';
            }
        }

        function showHeightmapTooltip(ev, node) {
            const tt = heightmapState.tooltip;
            if (!tt) return;
            const snippet = (node.snippet || '').slice(0, 180);
            const hub = Math.round(node.hubScore || 0);
            tt.innerHTML =
                '<div class="hm-tt-title">' + escapeHTML(node.title || '') + '</div>' +
                '<div>' + escapeHTML(node.folder || '') + '</div>' +
                (snippet ? '<div class="hm-tt-meta" style="margin-top:4px;color:#aaa">' + escapeHTML(snippet) + (node.snippet && node.snippet.length > 180 ? '…' : '') + '</div>' : '') +
                '<div class="hm-tt-meta" style="margin-top:4px">Hub ' + hub + ' · In ' + (node.incoming || 0) + ' · Out ' + (node.outgoing || 0) + '</div>';
            tt.style.display = 'block';
            moveHeightmapTooltip(ev);
        }

        function moveHeightmapTooltip(ev) {
            const tt = heightmapState.tooltip;
            if (!tt || tt.style.display === 'none') return;
            const pad = 14;
            let x = ev.clientX + pad;
            let y = ev.clientY + pad;
            const w = tt.offsetWidth || 200;
            const h = tt.offsetHeight || 60;
            if (x + w > window.innerWidth)  x = ev.clientX - w - pad;
            if (y + h > window.innerHeight) y = ev.clientY - h - pad;
            tt.style.left = x + 'px';
            tt.style.top = y + 'px';
        }

        function hideHeightmapTooltip() {
            const tt = heightmapState.tooltip;
            if (tt) tt.style.display = 'none';
        }

        // Folder-/Tag-Filter in der Heightmap: non-matching Kreise dimmen (statt
        // komplett rausnehmen, Nutzer sieht so den Kontext, wo die Cluster liegen).
        function applyHeightmapFilters() {
            if (!heightmapState.initialized || !heightmapState.dataReady) return;
            const anyFilter = activeFolders.size > 0 || activeTags.size > 0 || searchQuery.length > 0;
            heightmapState.svg.selectAll('circle')
                .classed('hm-dim', d => anyFilter && !nodeMatches(d.node));
            // 3D: Dimming passiert via Color-Blend (InstancedMesh kann pro
            // Instanz keine opacity). Deshalb Farben neu setzen, die dann
            // gegen Grau gemischt werden, wenn der Filter greift.
            if (heightmap3dState.built) {
                updateHeightmap3dColors();
            }
        }

        // ===========================================================
        //                         HEIGHTMAP 3D
        // ===========================================================
        // Three.js-basierte 3D-Ansicht der Themenlandschaft:
        //   - Terrain = PlaneGeometry (81×81 verts), Y-verschoben nach KDE-Dichte
        //   - Punkte = InstancedMesh (1 SphereGeom für alle Notizen, Per-Instance
        //     Matrix + Color)
        //   - Lichter = Ambient + Directional von schräg oben
        //   - Steuerung = eigene Orbit-Controls (LMB=rotate, RMB=pan, Wheel=zoom)
        //   - Raycast-Pick auf InstancedMesh → showPanel / Tooltip
        //
        // Lazy-Init: erst beim ersten Klick auf "3D", spart WebGL-Kontext und
        // Speicher, wenn User nie in 3D wechselt.
        //
        // Shared State:
        //   - heightmapState.coords wird 1:1 wiederverwendet (x/y → Welt-X/Z)
        //   - KDE wird eigenständig berechnet (d3.contourDensity gibt Polygone,
        //     aber wir brauchen Gitter-Werte)
        const heightmap3dState = {
            view: '2d',        // '2d' | '3d'
            built: false,      // Szene steht (nur erst nach init+build)
            initialized: false,// Three.js-Objekte existieren
            scene: null,
            camera: null,
            renderer: null,
            container: null,
            terrain: null,
            notes: null,       // InstancedMesh
            points: null,      // [{x01, y01, node, density}]
            orbit: null,
            raycaster: null,
            tooltip: null,
            rafHandle: 0,
            running: false,
            hoverInstance: -1,
            peaks: null,       // [{world: Vector3, text, noteCount, dom}]
            labelsDOM: null,   // Container-Div für alle Labels
            // Terrain-Kontext (für Bandwidth-Slider gecacht, damit
            // recomputeHeightmap3dTerrain ohne Scene-Rebuild laufen kann):
            plotSize: 0,
            heightScale: 0,
            gridN: 0,          // 81 (gridSegs + 1)
            points01: null,    // [{x,y} in [0,1]], Kernel-Centers
            plotNodes: null    // [{x,y,node}], Note-Rohdaten
        };

        // Liefert die KDE-Dichte an einem Punkt (x,y ∈ [0,1]), direkte Summe
        // über alle Notizen, kein Gitter. Für ~1200 Notizen pro Abfrage <1ms.
        function kdeAt01(x, y, points01, bw) {
            const invBw2 = 1 / (bw * bw);
            let sum = 0;
            for (let i = 0; i < points01.length; i++) {
                const dx = points01[i].x - x, dy = points01[i].y - y;
                sum += Math.exp(-(dx*dx + dy*dy) * invBw2 * 0.5);
            }
            return sum;
        }

        // Baut den Ctx (Farbskalen) für die Farb-Modi, parallel zu renderHeightmap().
        function buildHeightmap3dColorCtx(plotNodes) {
            const ctx = { folderColor: {}, hubMax: 0, createdMin: Infinity, createdMax: -Infinity };
            for (const f of data.folders) ctx.folderColor[f.name] = f.color;
            for (const pn of plotNodes) {
                const n = pn.node;
                if ((n.hubScore || 0) > ctx.hubMax) ctx.hubMax = n.hubScore || 0;
                const c = n.created || 0;
                if (c > 0) {
                    if (c < ctx.createdMin) ctx.createdMin = c;
                    if (c > ctx.createdMax) ctx.createdMax = c;
                }
            }
            if (!isFinite(ctx.createdMin)) { ctx.createdMin = 0; ctx.createdMax = 1; }
            return ctx;
        }

        // ---------- Berg-Labels: lokale KDE-Maxima + Keyword-Extraktion ----------

        // Stoppwort-Set (Deutsch + Englisch). Dient dem Zweck, offensichtliche
        // Füllwörter rauszufiltern, das eigentliche Scoring läuft über TF-IDF.
        // Hintergrund: "sehr dir" als Peak-Label kam, weil beides Füllwörter sind,
        // die in kleinen Clustern noch häufig genug auftreten, um hochzuklettern.
        const STOPWORDS_HM3D = new Set([
            // DE, Artikel/Pronomen/Partikel
            'der','die','das','den','dem','des','ein','eine','einen','einer','eines','und','oder','aber','auch','nicht','nur','von','zu','zum','zur','mit','im','in','am','an','auf','für','fuer','über','ueber','unter','ist','sind','war','waren','sei','sein','bin','bist','ich','du','er','sie','es','wir','ihr','man','dass','daß','so','als','wie','noch','wenn','wo','da','dort','hier','also','bei','aus','nach','vor','um','durch','ohne','gegen','bis','hat','haben','hatte','hatten','wird','werden','wurde','wurden','kann','können','koennen','soll','sollen','muss','müssen','muessen','darf','dürfen','duerfen','möchte','moechte','will','gibt','geben','ja','nein','ok','sich','seine','seiner','seinem','seinen','ihre','ihrer','ihren','ihrem','mein','meine','meinen','meinem','meiner','dein','deine','deinen','deinem','deiner','euer','eure','unser','unsere','mich','dich','mir','dir','uns','euch','ihnen','ihm','ihn','keine','kein','keinen','keinem','keiner','etwas','viel','viele','vielen','weit','weiter','mehr','schon','immer','mal','doch','oft','jetzt','heute','gestern','morgen','beim','vom','ans','ins','aufs',
            // DE, Füllwörter/Abtönung (die kleinen Übeltäter)
            'sehr','ganz','echt','total','ziemlich','eher','eigentlich','halt','eben','wohl','zwar','quasi','ungefähr','circa','ca','evtl','eventuell','vielleicht','gerne','bitte','danke','hallo','hi','hey','tschüss','tschuess','ciao','super','toll','gut','schön','schoen','cool','nice','klar','genau','naja','nun','dann','einfach','gleich','bald','schließlich','schliesslich','nämlich','naemlich','allerdings','selbst','sonst','deshalb','deswegen','darum','weil','dabei','damit','daher','dadurch','davon','danach','davor','darauf','worauf','wobei','wodurch','warum','wieso','weshalb','zwei','drei','vier','fünf','fuenf','sechs','sieben','acht','neun','zehn','erste','zweite','dritte','letzte','neue','alte','groß','gross','klein','lang','kurz','wenig','beide','etwa','rund','knapp','fast','kaum','irgendwie','irgendwo','überhaupt','ueberhaupt','sowieso','trotzdem','außerdem','ausserdem','zudem','zusätzlich','zusaetzlich','immerhin','vielleicht','wohl','eben','mal','halt','bisschen','ein','eins','dran','drin','drauf','rüber','rueber','rauf','runter','rein','raus','los','weg','heran','hin','her','hinzu','weiter','weiterhin','insgesamt','insbesondere','besonders','lieber','am','allein','allem','allen','allerdings','andere','anderen','anders','bekommen','gemacht','machen','machst','macht','gehen','geht','gehst','gegangen','kommt','kommen','komme','kommst','gekommen','lassen','gelassen','sagen','sagte','sagt','gesagt','sieht','sehen','gesehen','finden','findet','gefunden','stehen','steht','gestanden','liegt','liegen','gelegen','halten','hält','haelt','gehalten','nehmen','nimmt','genommen','bringen','bringt','gebracht','warten','wartet','gewartet','glauben','glaube','glaubt','geglaubt','denken','denke','denkt','gedacht','wissen','weiß','weiss','gewusst','fragen','fragt','gefragt','tun','tut','getan','heißt','heissen','geheissen','geheißen','bleiben','bleibt','geblieben',
            // EN
            'the','an','and','or','but','of','for','with','by','are','was','were','be','been','being','have','has','had','do','does','did','will','would','can','could','should','may','might','must','just','only','very','some','any','all','not','more','most','than','then','from','this','that','these','those','which','who','whom','when','where','why','how','your','his','her','its','our','their','me','you','him','them','us','we','they','he','she','as','if','up','out','about','into','over','after','before','again','down','off','once','here','there','also','still','much','many','each','every','few','other','another','such','same','really','quite','rather','pretty','thing','things','stuff','something','someone','anything','everyone','everybody','bit','lot','way','yeah','yes','ok','okay','cool','nice','good','bad','big','small','new','old','get','got','getting','go','going','gone','goes','make','makes','made','making','take','takes','took','taken','taking','come','comes','came','coming','see','sees','saw','seen','seeing','know','knows','knew','known','think','thinks','thought','say','says','said','saying','like','likes','liked','liking','want','wants','wanted','need','needs','needed','use','uses','used','using','look','looks','looked','looking','try','tries','tried','trying','feel','feels','felt','work','works','worked','working','call','calls','called','put','puts','putting','find','finds','found','give','gives','gave','given','tell','tells','told','telling','ask','asks','asked','asking'
        ]);

        // Findet lokale Maxima im KDE-Gitter (8-Nachbarschaft, strict größer).
        // Filtert unter minThreshold raus. Sortiert nach Wert.
        function findTopPeaks(kde, gridN, topN, minThreshold) {
            const peaks = [];
            for (let iy = 1; iy < gridN - 1; iy++) {
                for (let ix = 1; ix < gridN - 1; ix++) {
                    const v = kde[iy * gridN + ix];
                    if (v < minThreshold) continue;
                    let isMax = true;
                    for (let dy = -1; dy <= 1 && isMax; dy++) {
                        for (let dx = -1; dx <= 1 && isMax; dx++) {
                            if (dx === 0 && dy === 0) continue;
                            if (kde[(iy + dy) * gridN + (ix + dx)] >= v) isMax = false;
                        }
                    }
                    if (isMax) peaks.push({ ix, iy, value: v });
                }
            }
            peaks.sort((a, b) => b.value - a.value);
            return peaks.slice(0, topN);
        }

        // Tokenisierung + Qualitätsfilter. Wird sowohl beim globalen DF-Aufbau
        // wie beim per-Cluster-TF benutzt, damit beide Seiten konsistent sind.
        function tokenizeHm3d(text) {
            const tokens = text.toLowerCase().match(/[\p{L}\p{N}]+/gu) || [];
            const out = [];
            for (const t of tokens) {
                if (t.length < 3) continue;            // 'zu', 'a', …
                if (t.length > 22) continue;           // UUIDs, Hash-Kram
                if (/^\d+$/.test(t)) continue;         // reine Zahlen (2024, 17, …)
                if (STOPWORDS_HM3D.has(t)) continue;
                // URL-Artefakte: 'https', 'com', 'www', 'html' sind nie Themen.
                if (t === 'https' || t === 'http' || t === 'www' || t === 'com' ||
                    t === 'html' || t === 'php' || t === 'pdf' || t === 'jpg' ||
                    t === 'png') continue;
                out.push(t);
            }
            return out;
        }

        // Globale Token-Statistik: wie oft erscheint jedes Token in wie vielen
        // Notizen. Basis für IDF. Wird einmal pro Peak-Build berechnet.
        function buildGlobalTokenStats(allNotes) {
            const df = new Map();
            for (const n of allNotes) {
                const text = (n.title || '') + ' ' + (n.snippet || '');
                const uniq = new Set(tokenizeHm3d(text));
                for (const t of uniq) df.set(t, (df.get(t) || 0) + 1);
            }
            return { df, totalDocs: Math.max(1, allNotes.length) };
        }

        // TF-IDF-basierte Keyword-Extraktion für einen Cluster. Idee:
        //   score(t) = clusterTF(t) × IDF(t) × titleBoost(t)
        // Wörter, die fast in jeder Notiz vorkommen ("mir", "dir", "sehr"),
        // werden über den IDF-Faktor massiv abgewertet. Wörter aus dem TITEL
        // bekommen einen Boost, weil sie typischerweise thematisch fokussierter
        // sind als Snippet-Geschwätz. Zusätzlich: im Deutschen fangen Substantive
        // groß an, dafür gibt's nochmal einen kleinen Boost, weil Substantive
        // "Berg-Thema" sind, Verben und Adjektive nicht.
        function extractPeakKeywordsTFIDF(clusterNotes, topN, globalStats) {
            if (!globalStats || globalStats.totalDocs === 0) return [];
            const { df, totalDocs } = globalStats;
            const tf = new Map();
            const titleDf = new Map();
            const capCount = new Map();  // Wie oft taucht Token großgeschrieben auf?

            for (const n of clusterNotes) {
                const title = n.title || '';
                const snippet = n.snippet || '';
                for (const t of tokenizeHm3d(snippet + ' ' + title)) {
                    tf.set(t, (tf.get(t) || 0) + 1);
                }
                const titleTokens = new Set(tokenizeHm3d(title));
                for (const t of titleTokens) {
                    titleDf.set(t, (titleDf.get(t) || 0) + 1);
                }
                // Substantiv-Heuristik: Wörter, die mit Großbuchstaben anfangen,
                // sind im Deutschen meist Substantive. Wir zählen, wie oft ein
                // Token großgeschrieben vorkam (vor lowercasing).
                const caps = (snippet + ' ' + title).match(/\b[A-ZÄÖÜ][\p{L}]{2,}/gu) || [];
                for (const cap of caps) {
                    const key = cap.toLowerCase();
                    capCount.set(key, (capCount.get(key) || 0) + 1);
                }
            }

            const scored = [];
            const clusterSize = clusterNotes.length;
            for (const [token, tfCount] of tf) {
                const dfCount = df.get(token) || 1;
                const dfRatio = dfCount / totalDocs;
                // Wenn ein Token in >55% aller Notizen vorkommt, ist es de facto
                // ein globales Füllwort, wegschneiden.
                if (dfRatio > 0.55) continue;
                // Wenn ein Token NUR in EINER Cluster-Notiz vorkommt (tfCount=1)
                // und der Cluster ≥4 Notizen hat, ist es eher Rauschen als Thema.
                if (tfCount <= 1 && clusterSize >= 4) continue;

                const idf = Math.log((totalDocs + 1) / (dfCount + 1)) + 1;
                let score = tfCount * idf;

                // Titel-Boost: wenn das Token in ≥30% der Cluster-Titel steht, ×1.7.
                const tCount = titleDf.get(token) || 0;
                if (tCount / clusterSize >= 0.3) score *= 1.7;
                else if (tCount > 0) score *= 1.25;

                // Substantiv-Boost (deutsch: Großschreibung). Wenn ein Token
                // mindestens einmal großgeschrieben vorkam, ×1.3.
                if ((capCount.get(token) || 0) > 0) score *= 1.3;

                scored.push({ token, score, tf: tfCount, df: dfCount });
            }
            scored.sort((a, b) => b.score - a.score);
            return scored.slice(0, topN).map(x => x.token);
        }

        // Baut die Peak-Label-Liste aus KDE + Notizen.
        //   1) lokale KDE-Maxima oberhalb Threshold finden
        //   2) nach Abstand deduplizieren (verhindert zwei Labels auf einem "Grat")
        //   3) Notizen im Umkreis 0.1 (01-space) sammeln
        //   4) Top-2-Keywords extrahieren → Label-Text
        function buildPeakLabels(pointsExt, kde, gridN, kdeMax, plotSize, heightScale) {
            if (!kdeMax || kdeMax <= 0) return [];
            // Schwelle deutlich gesenkt: 0.22 statt 0.35 → auch Neben-Gipfel und
            // Berg-Schultern bekommen eine Chance auf ein Label. Bei reinem 0.35
            // kam fast alles, was nicht zentraler Hauptberg war, durch.
            const minThreshold = kdeMax * 0.22;
            // Mehr Kandidaten suchen (32 statt 24), damit nach Dedup & Cluster-
            // Größen-Filter auch bei Slider=20 noch genug übrig ist. Ollama labelt
            // alle, die Slider-Pill steuert nur die Sichtbarkeit im DOM.
            const raw = findTopPeaks(kde, gridN, 32, minThreshold);
            const peaks01 = raw.map(p => ({
                x01: p.ix / (gridN - 1),
                y01: p.iy / (gridN - 1),
                value: p.value
            }));

            // Dedupliziere Peaks, die im 01-Space zu nah beieinander liegen.
            // Distanz 0.07 → Labels dürfen eng beieinander stehen. Hard-Cap 20:
            // matches Slider-Max. Mehr würde unlesbar und Ollama unnötig belasten.
            const filtered = [];
            for (const p of peaks01) {
                let tooClose = false;
                for (const q of filtered) {
                    const dx = p.x01 - q.x01, dy = p.y01 - q.y01;
                    if (Math.sqrt(dx*dx + dy*dy) < 0.07) { tooClose = true; break; }
                }
                if (!tooClose) filtered.push(p);
                if (filtered.length >= 20) break;
            }

            // Globale Token-Statistik: einmalig über ALLE Notizen, damit IDF
            // weiß, welche Wörter überall auftauchen (und also nichts sagen).
            const allNodes = pointsExt.map(p => p.node);
            const globalStats = buildGlobalTokenStats(allNodes);

            const clusterRadius = 0.1;
            const labels = [];
            for (const peak of filtered) {
                const clusterNotes = [];
                for (const p of pointsExt) {
                    const dx = p.x01 - peak.x01, dy = p.y01 - peak.y01;
                    if (Math.sqrt(dx*dx + dy*dy) < clusterRadius) {
                        clusterNotes.push(p.node);
                    }
                }
                if (clusterNotes.length < 3) continue;
                const keywords = extractPeakKeywordsTFIDF(clusterNotes, 2, globalStats);
                if (keywords.length === 0) continue;
                const text = keywords.join(' · ');

                // Welt-Position (Y-Flip wie bei den Kugeln).
                // Kleines Offset +4 über dem Gipfel, groß genug, damit das Label
                // nicht im Terrain clippt, klein genug, dass es sichtbar zum Berg
                // gehört. (Vorher +16 → wirkte "abgehoben".)
                const wx = (peak.x01 - 0.5) * plotSize;
                const wz = (0.5 - peak.y01) * plotSize;
                const density = peak.value / kdeMax;
                const wy = density * heightScale + 4;
                labels.push({
                    world: new THREE.Vector3(wx, wy, wz),
                    // 01-space-Koordinaten für 2D-Rendering (padX + x01*plotW, …)
                    x01: peak.x01,
                    y01: peak.y01,
                    text,
                    noteCount: clusterNotes.length,
                    dom: null,   // 3D-Label-DOM (Projektion via Frame-Loop)
                    dom2d: null, // 2D-Label-DOM (statisch über SVG positioniert)
                    // Ollama-Input: erste 8 Notizen des Clusters (Titel+kurzer Snippet).
                    // Das reicht für ein thematisches Label; mehr macht den Prompt
                    // nur träger, ohne Qualitätsgewinn.
                    ollamaSamples: clusterNotes.slice(0, 8).map(n => ({
                        title: String(n.title || '').slice(0, 120),
                        snippet: String(n.snippet || '').slice(0, 180)
                    }))
                });
            }
            return labels;
        }

        // Baut den DOM-Container und die Label-Divs. Erfolgt einmal pro Szenen-Build.
        // No-op wenn der 3D-Container (noch) nicht existiert, z.B. wenn der User
        // in 2D ist und der Slider via recompute auch 3D-Labels vorbereiten will:
        // sobald er zu 3D wechselt, wird der Build dort die Labels nachziehen.
        function createHeightmap3dLabelDOM() {
            if (!heightmap3dState.container) return;
            // Alte wegräumen
            if (heightmap3dState.labelsDOM) {
                heightmap3dState.labelsDOM.remove();
                heightmap3dState.labelsDOM = null;
            }
            const peaks = heightmap3dState.peaks;
            if (!peaks || peaks.length === 0) return;

            const wrap = document.createElement('div');
            wrap.id = 'heightmap3d-labels';
            wrap.style.cssText = 'position:absolute;top:0;left:0;width:100%;height:100%;pointer-events:none;z-index:3;overflow:hidden;';
            for (const p of peaks) {
                const el = document.createElement('div');
                // Start-Zustand 'pending': Fallback-Text sichtbar, aber gedimmt +
                // gestrichelt, damit der User weiß "Ollama arbeitet noch dran".
                // requestOllamaPeakLabels() wird gleich danach gerufen; sobald eine
                // Antwort ankommt, wechselt die Klasse auf 'ready'.
                el.className = 'hm3d-label pending';
                el.textContent = p.text;
                el.title = p.noteCount + ' Notizen, Ollama generiert Label…';
                wrap.appendChild(el);
                p.dom = el;
                p.state = 'pending';
            }
            heightmap3dState.container.appendChild(wrap);
            heightmap3dState.labelsDOM = wrap;
            // Alle Peaks werden angezeigt. Die Anzahl wird jetzt durch die
            // KDE-Bandwidth (Detail-Slider) gesteuert, nicht durch DOM-Filter.
            // hiddenBySlider-Flag bleibt im Frame-Loop-Check erhalten (defaults
            // auf falsy) → unverändertes Verhalten, ohne dass der Slider es setzt.
        }

        // Liest den aktuellen Slider-Wert. Fallback 10 falls der Slider noch nicht
        // im DOM ist (shouldn't happen, defensive).
        function getPeakSliderValue() {
            const el = document.getElementById('heightmap-peak-slider');
            if (!el) return 10;
            const v = parseInt(el.value, 10);
            return Number.isFinite(v) ? v : 10;
        }

        // Regelt die Sichtbarkeit der Peak-Labels:
        //   • 'merged'-Peaks bleiben IMMER verborgen (sie sind echte Duplikate).
        //   • Unter den verbleibenden wird nur Top-N (= Slider-Wert) angezeigt.
        //     Reihenfolge = Array-Reihenfolge, was = nach KDE-Height absteigend,
        //     weil buildPeakLabels() die Peaks so produziert.
        // Statt direkt display zu setzen, pflegen wir einen Flag p.hiddenBySlider.
        // Der Frame-Loop (updateHeightmap3dLabels) respektiert beides (merged +
        // hiddenBySlider) und stellt display:none nicht zurück. Ohne diesen Flag
        // würde jeder Render-Tick die Labels wieder sichtbar machen.
        // Effekt: schiebt der User den Slider von 10 auf 5, verschwinden die
        // 5 unwichtigsten Labels. Schiebt er auf 20, tauchen alle auf (sofern
        // so viele generiert wurden, cap liegt bei 20 in buildPeakLabels).
        function applyPeakVisibility(maxVisible) {
            const peaks = heightmap3dState.peaks;
            if (!peaks) return;
            let shown = 0;
            for (const p of peaks) {
                if (!p) continue;
                if (p.state === 'merged') {
                    // merged hat Vorrang, kein Slider-Budget verbraten.
                    p.hiddenBySlider = false;
                    if (p.dom) p.dom.style.display = 'none';
                    continue;
                }
                if (shown < maxVisible) {
                    p.hiddenBySlider = false;
                    shown++;
                    // display wird im nächsten Frame-Tick korrekt gesetzt
                    // (block wenn im Viewport, none wenn außerhalb).
                } else {
                    p.hiddenBySlider = true;
                    if (p.dom) p.dom.style.display = 'none';
                }
            }
        }

        // Eindeutige ID pro Label-Build, damit spät ankommende Ollama-Antworten
        // auf einen alten Berg-Satz nicht durchschlagen.
        let heightmap3dLabelsEpoch = 0;

        // Schickt die Peak-Cluster (Titel+Snippets) an die Swift-Seite, die dann
        // via Ollama /api/generate ein 1-3-Wörter-Thema generiert. Antwort kommt
        // über window.__applyHeightmapPeakLabels(...) zurück.
        // Graceful: Wenn der Handler nicht existiert (z.B. älterer Build) oder
        // Ollama nicht erreichbar ist, bleiben die Token-Labels stehen.
        function requestOllamaPeakLabels() {
            const peaks = heightmap3dState.peaks;
            if (!peaks || peaks.length === 0) return;
            heightmap3dLabelsEpoch++;
            const epoch = heightmap3dLabelsEpoch;

            const payload = {
                epoch: epoch,
                peaks: peaks.map((p, idx) => ({
                    i: idx,
                    fallback: p.text,
                    notes: p.ollamaSamples || []
                }))
            };
            try {
                if (window.webkit && window.webkit.messageHandlers
                        && window.webkit.messageHandlers.heightmapLabelsRequest) {
                    window.webkit.messageHandlers.heightmapLabelsRequest
                        .postMessage(payload);
                }
            } catch (e) {
                // Kein Swift-Bridge vorhanden (z.B. Standalone-Test im Browser):
                // einfach ignorieren, Fallback-Labels bleiben sichtbar.
            }
        }

        // Merged semantisch identische Peaks: wenn zwei Labels mindestens zwei
        // "inhaltsreiche" Substantive teilen (len ≥ 4, case-insensitive), blenden
        // wir den Peak mit weniger Notizen aus. Klassisches Beispiel:
        //   "Zauberei, Magie, Tricks"   ← bleibt
        //   "Zauberei, Magie, Unterhaltung"  ← wird ausgeblendet
        // Läuft idempotent: Peaks mit state='merged' werden beim nächsten Lauf
        // übersprungen. Ausgelöst nach jedem Label-Batch, wenn kein 'pending'
        // mehr offen ist, ODER sobald Swift 'done: true' signalisiert.
        // Levenshtein-Distanz (zwei-Zeilen-DP, O(m*n) Zeit, O(n) Speicher).
        // Für kurze Tokens (≤ ~20 Zeichen) mehr als schnell genug.
        function levenshteinDist(a, b) {
            if (a === b) return 0;
            if (a.length === 0) return b.length;
            if (b.length === 0) return a.length;
            let prev = new Array(b.length + 1);
            let curr = new Array(b.length + 1);
            for (let j = 0; j <= b.length; j++) prev[j] = j;
            for (let i = 1; i <= a.length; i++) {
                curr[0] = i;
                for (let j = 1; j <= b.length; j++) {
                    const cost = a.charCodeAt(i - 1) === b.charCodeAt(j - 1) ? 0 : 1;
                    curr[j] = Math.min(
                        prev[j] + 1,         // deletion
                        curr[j - 1] + 1,     // insertion
                        prev[j - 1] + cost   // substitution
                    );
                }
                const tmp = prev; prev = curr; curr = tmp;
            }
            return prev[b.length];
        }

        // Zwei Tokens gelten als "semantisch gleich", wenn:
        //   • exakter String-Match, ODER
        //   • das kürzere Token (≥ 6 Zeichen) ist Präfix des längeren
        //     → fängt "karriere" ⊂ "karriereentwicklung",
        //        "projekt" ⊂ "projektentwicklung", "software" ⊂ "softwareentwicklung"
        //   • Levenshtein-Distanz ≤ 2 bei Tokens mit mindestens 5 Zeichen
        //     → fängt Singular/Plural ("projekt/projekte"), Tippfehler,
        //        kleine Flexions-Unterschiede ("rezept/rezepte")
        // Der 6-Zeichen-Cutoff für Präfix verhindert, dass "netz" zufällig
        // "netzwerk"/"netzhaut"/"netzteil" alle zusammenwirft.
        function tokensMatch(a, b) {
            if (a === b) return true;
            const shorter = a.length < b.length ? a : b;
            const longer  = a.length < b.length ? b : a;
            if (shorter.length >= 6 && longer.startsWith(shorter)) return true;
            if (shorter.length >= 5 && levenshteinDist(a, b) <= 2) return true;
            return false;
        }

        function mergeSimilarPeakLabels() {
            const peaks = heightmap3dState.peaks;
            if (!peaks || peaks.length < 2) return;

            // Token pro Peak extrahieren. 'merged' → null (übersprungen).
            // Kurze Wörter (<4 Buchstaben) raus, weil "und", "mit", "die"
            // sonst zufällige Treffer produzieren würden.
            const tokensPerPeak = peaks.map(p => {
                if (!p || !p.dom) return null;
                if (p.state === 'merged') return null;
                const txt = (p.text || '').toLowerCase();
                return txt.split(/[,\s·\-–—]+/).filter(t => t.length >= 4);
            });

            // Pairwise: wer teilt genug Substantive?
            // Fuzzy-Vergleich via tokensMatch() (oben): exakt | Präfix | Levenshtein≤2.
            // Adaptive Schwelle: Wenn eines der beiden Peaks nur 1-2 Tokens hat
            // (Einwort-Label wie "Selbstentwicklung" oder "Politik"), reicht 1 Match,
            // weil mehr Overlap rein mathematisch nicht möglich ist. Erst ab drei
            // Tokens auf beiden Seiten fordern wir 2 Matches, damit wir nicht durch
            // einen einzelnen Zufallstreffer zusammenschmeißen.
            for (let i = 0; i < peaks.length; i++) {
                const ti = tokensPerPeak[i];
                if (!ti || ti.length === 0) continue;
                for (let j = i + 1; j < peaks.length; j++) {
                    const tj = tokensPerPeak[j];
                    if (!tj || tj.length === 0) continue;
                    const required = Math.min(ti.length, tj.length) <= 2 ? 1 : 2;
                    let shared = 0;
                    for (const t of ti) {
                        let matched = false;
                        for (const t2 of tj) {
                            if (tokensMatch(t, t2)) { matched = true; break; }
                        }
                        if (matched) shared++;
                        if (shared >= required) break;
                    }
                    if (shared < required) continue;

                    // Gewinner bestimmen: mehr Notizen gewinnt.
                    // Tie-Break: 'ready' schlägt 'failed' (echtes LLM-Label
                    // besser als Fallback). Bei Gleichstand bleibt i.
                    const a = peaks[i];
                    const b = peaks[j];
                    const aCount = a.noteCount || 0;
                    const bCount = b.noteCount || 0;
                    let keepI;
                    if (aCount !== bCount) {
                        keepI = (aCount > bCount);
                    } else {
                        keepI = (a.state === 'ready' && b.state !== 'ready') ||
                                (a.state === b.state);
                    }
                    const loserIdx = keepI ? j : i;
                    const loserPeak = peaks[loserIdx];
                    if (loserPeak && loserPeak.state !== 'merged'
                            && (loserPeak.dom || loserPeak.dom2d)) {
                        if (loserPeak.dom)   loserPeak.dom.style.display = 'none';
                        if (loserPeak.dom2d) loserPeak.dom2d.style.display = 'none';
                        loserPeak.state = 'merged';
                        tokensPerPeak[loserIdx] = null;
                        try {
                            console.log('[mergeSimilarPeakLabels] "'
                                + a.text + '" ≈ "' + b.text
                                + '" → verberge "' + loserPeak.text + '"');
                        } catch (e) { /* ignore log errors */ }
                        if (loserIdx === i) break; // i ist weg, nicht weiter mit j
                    }
                }
            }
            // Gemergete Peaks setzen selbst state='merged' + display:none
            // (siehe oben, Zeile ~4400). Der Frame-Loop respektiert das.
            // Ein applyPeakVisibility-Aufruf ist mit dem Bandwidth-Slider nicht
            // mehr sinnvoll (Slider-Wert ≠ max-Labels-Budget).
        }

        // Wird von der Swift-Seite aufgerufen (evaluateJavaScript), sobald ein
        // Peak-Label generiert ist. Akzeptiert Einzel-Updates (ein Label nach dem
        // anderen) UND Bulk-Updates (alle auf einmal). Updates aus alten Epochen
        // werden verworfen, wichtig bei Rebuild (Data-Update, View-Toggle).
        window.__applyHeightmapPeakLabels = function(payload) {
            try {
                const peaks = heightmap3dState.peaks;
                if (!peaks || peaks.length === 0) return;
                if (!payload || typeof payload !== 'object') return;
                if (typeof payload.epoch === 'number'
                        && payload.epoch !== heightmap3dLabelsEpoch) {
                    return; // stale
                }
                // Sonderfall: Swift signalisiert "Batch komplett", pending-Labels,
                // die bis hier keine Antwort bekamen, werden auf 'failed' gestellt
                // (Fallback-Text bleibt, aber mit orange Kante → User sieht, dass
                // Ollama hier nichts liefern konnte).
                if (payload.done === true) {
                    for (const p of peaks) {
                        if (p.state === 'pending') {
                            const title = (p.noteCount || 0) + ' Notizen, Ollama hat kein Label geliefert';
                            if (p.dom) {
                                p.dom.classList.remove('pending');
                                p.dom.classList.add('failed');
                                p.dom.title = title;
                            }
                            if (p.dom2d) {
                                p.dom2d.classList.remove('pending');
                                p.dom2d.classList.add('failed');
                                p.dom2d.title = title;
                            }
                            p.state = 'failed';
                        }
                    }
                    // Alle Labels sind jetzt fertig (ready|failed|merged):
                    // semantische Duplikate final wegräumen.
                    mergeSimilarPeakLabels();
                    return;
                }
                const list = Array.isArray(payload.labels) ? payload.labels : [];
                for (const entry of list) {
                    if (!entry || typeof entry.i !== 'number') continue;
                    const idx = entry.i;
                    if (idx < 0 || idx >= peaks.length) continue;
                    const t = (typeof entry.text === 'string') ? entry.text.trim() : '';
                    if (!t) continue;
                    const p = peaks[idx];
                    p.text = t;
                    const title = (p.noteCount || 0) + ' Notizen, Ollama: "' + t + '"';
                    if (p.dom) {
                        p.dom.textContent = t;
                        p.dom.classList.remove('pending', 'failed');
                        p.dom.classList.add('ready');
                        p.dom.title = title;
                    }
                    if (p.dom2d) {
                        p.dom2d.textContent = t;
                        p.dom2d.classList.remove('pending', 'failed');
                        p.dom2d.classList.add('ready');
                        p.dom2d.title = title;
                    }
                    p.state = 'ready';
                }
                // Wenn nach diesem Batch keine Pendings mehr offen sind
                // (z.B. Bulk-Update mit allen Labels auf einmal ODER letzter
                // Einzel-Update vor dem 'done'-Signal), direkt mergen:
                // damit der User keine Duplikate zwischenzeitlich sieht.
                const anyPending = peaks.some(p => p.state === 'pending');
                if (!anyPending) {
                    mergeSimilarPeakLabels();
                }
            } catch (e) {
                console.warn('[__applyHeightmapPeakLabels] error:', e);
            }
        };

        // Wird im RAF-Loop aufgerufen: projiziert die Welt-Position jedes
        // Peaks auf Screen-Pixel und positioniert das Label-Div.
        function updateHeightmap3dLabels() {
            const peaks = heightmap3dState.peaks;
            if (!peaks || peaks.length === 0) return;
            const { camera, container } = heightmap3dState;
            const cw = container.clientWidth;
            const ch = container.clientHeight;
            const v = new THREE.Vector3();
            for (const p of peaks) {
                if (!p.dom) continue;
                // Explizit versteckt (Merge-Duplikat oder Slider-Cap) → nicht
                // rückstellen. Ohne diesen Guard überschreibt der Frame-Loop
                // den 'display:none', den applyPeakVisibility() gerade gesetzt hat.
                if (p.state === 'merged' || p.hiddenBySlider) {
                    if (p.dom.style.display !== 'none') p.dom.style.display = 'none';
                    continue;
                }
                v.copy(p.world).project(camera);
                // z > 1 = hinter far-plane, z < -1 = hinter Kamera
                if (v.z > 1 || v.z < -1) {
                    if (p.dom.style.display !== 'none') p.dom.style.display = 'none';
                    continue;
                }
                const sx = (v.x * 0.5 + 0.5) * cw;
                const sy = (-v.y * 0.5 + 0.5) * ch;
                if (p.dom.style.display === 'none') p.dom.style.display = 'block';
                p.dom.style.transform = 'translate(-50%, -100%) translate(' + sx.toFixed(1) + 'px,' + sy.toFixed(1) + 'px)';
            }
        }

        function init3DHeightmapIfNeeded() {
            if (heightmap3dState.initialized) return;
            const container = document.getElementById('heightmap3d-canvas-container');
            const cw = Math.max(10, container.clientWidth);
            const ch = Math.max(10, container.clientHeight);

            const scene = new THREE.Scene();
            scene.background = new THREE.Color(0x10101e);
            scene.fog = new THREE.Fog(0x10101e, 600, 1800);

            const camera = new THREE.PerspectiveCamera(40, cw / ch, 0.5, 3000);

            const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: false });
            // WICHTIG: setPixelRatio VOR setSize, und setSize OHNE `false`:
            // sonst bleiben die CSS-Styles des Canvas unberührt und der Canvas
            // wird mit `canvas.width`-Attribut (= cw * pixelRatio CSS-Pixel)
            // dargestellt. Bei pixelRatio=2 landet das Bild dann mit doppelter
            // Größe im overflow:hidden-Container → Szenen-Mitte erscheint am
            // unteren rechten Rand statt zentriert.
            renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
            renderer.setSize(cw, ch);
            container.appendChild(renderer.domElement);

            // Lichter: ein bisschen ambient für Details im Schatten, ein starkes
            // gerichtetes Licht von schräg oben für Hang-Schattierung.
            scene.add(new THREE.AmbientLight(0xffffff, 0.45));
            const dir = new THREE.DirectionalLight(0xffffff, 0.9);
            dir.position.set(-250, 500, 200);
            scene.add(dir);
            const rim = new THREE.DirectionalLight(0x88aaff, 0.25);
            rim.position.set(250, 200, -250);
            scene.add(rim);

            heightmap3dState.scene = scene;
            heightmap3dState.camera = camera;
            heightmap3dState.renderer = renderer;
            heightmap3dState.container = container;
            heightmap3dState.raycaster = new THREE.Raycaster();
            heightmap3dState.raycaster.params.Points = { threshold: 4 };
            heightmap3dState.tooltip = document.getElementById('heightmap-tooltip');

            // Custom Orbit-Controls
            const target = new THREE.Vector3(0, 0, 0);
            heightmap3dState.orbit = createSimpleOrbit(camera, renderer.domElement, target);

            // Resize-Listener
            let resizeTimer = null;
            window.addEventListener('resize', () => {
                if (currentMode !== 'heightmap' || heightmap3dState.view !== '3d') return;
                if (resizeTimer) clearTimeout(resizeTimer);
                resizeTimer = setTimeout(() => onHeightmap3DResize(), 120);
            });

            // Maus-Events für Pick/Hover
            renderer.domElement.addEventListener('click', onHeightmap3DClick);
            renderer.domElement.addEventListener('mousemove', onHeightmap3DMouseMove);
            renderer.domElement.addEventListener('mouseleave', () => {
                if (heightmap3dState.tooltip) heightmap3dState.tooltip.style.display = 'none';
                heightmap3dState.hoverInstance = -1;
            });

            heightmap3dState.initialized = true;
        }

        function onHeightmap3DResize() {
            const { container, camera, renderer } = heightmap3dState;
            if (!container || !camera || !renderer) return;
            const cw = Math.max(10, container.clientWidth);
            const ch = Math.max(10, container.clientHeight);
            camera.aspect = cw / ch;
            camera.updateProjectionMatrix();
            // setSize OHNE false → Three.js setzt canvas.style.width/height auf
            // cw/ch, sonst würde der Canvas visuell 2× (pixelRatio) so groß
            // werden wie der Container (overflow:hidden schneidet rechts/unten ab).
            renderer.setSize(cw, ch);
        }

        // Einfache Orbit-Controls: links-ziehen = rotieren, rechts-ziehen = schieben,
        // Rad = zoomen. ~80 Zeilen statt 40KB OrbitControls-Vendor. Kein Inertia,
        // kein Touch, reicht für Desktop-Maus.
        function createSimpleOrbit(camera, domElement, target) {
            let radius = 700;
            let theta = Math.PI * 0.25;  // Azimuth, horizontale Rotation
            let phi = Math.PI * 0.33;    // Polar, 0=direkt oben, π/2=Horizont
            const minR = 120, maxR = 2000;
            const minPhi = 0.05, maxPhi = Math.PI / 2 - 0.02;  // nicht unter Horizont

            let dragMode = 0; // 0 nix, 1 rotate, 2 pan
            let lastX = 0, lastY = 0;

            function update() {
                const sinPhi = Math.sin(phi), cosPhi = Math.cos(phi);
                camera.position.x = target.x + radius * sinPhi * Math.cos(theta);
                camera.position.y = target.y + radius * cosPhi;
                camera.position.z = target.z + radius * sinPhi * Math.sin(theta);
                camera.lookAt(target);
            }
            update();

            domElement.addEventListener('mousedown', (e) => {
                if (e.button === 2) dragMode = 2;
                else if (e.button === 0) dragMode = 1;
                else return;
                lastX = e.clientX; lastY = e.clientY;
                e.preventDefault();
            });
            window.addEventListener('mouseup', () => { dragMode = 0; });
            window.addEventListener('mousemove', (e) => {
                if (dragMode === 0) return;
                const dx = e.clientX - lastX, dy = e.clientY - lastY;
                lastX = e.clientX; lastY = e.clientY;
                if (dragMode === 1) {
                    // Rotate, horizontale Drehung folgt der Mausrichtung
                    // (Maus nach rechts → Szene dreht nach rechts, als ob
                    // man das Terrain mit der Hand greift und mitzieht).
                    theta += dx * 0.005;
                    phi -= dy * 0.005;
                    phi = Math.max(minPhi, Math.min(maxPhi, phi));
                } else if (dragMode === 2) {
                    // Pan: verschiebe target in Screen-X (right) und Screen-Y (up)
                    const right = new THREE.Vector3().setFromMatrixColumn(camera.matrix, 0);
                    const up = new THREE.Vector3().setFromMatrixColumn(camera.matrix, 1);
                    const panScale = radius * 0.0018;
                    target.addScaledVector(right, -dx * panScale);
                    target.addScaledVector(up, dy * panScale);
                }
                update();
            });
            domElement.addEventListener('wheel', (e) => {
                radius *= Math.pow(1.0015, e.deltaY);
                radius = Math.max(minR, Math.min(maxR, radius));
                update();
                e.preventDefault();
            }, { passive: false });
            domElement.addEventListener('contextmenu', (e) => e.preventDefault());

            return {
                update,
                setCenter(centerVec, plotSize) {
                    // Startzustand: Target = geometrische Terrain-Mitte (fest bei
                    // 0,0,0 in X/Z; Y etwa in halber Bergbuckel-Höhe). Rotation
                    // passiert dann um diesen Punkt, genau das Zentrum des Bildes.
                    // Radius 1.8 * plotSize: die Plane-Diagonale (~√2·plotSize =
                    // 1.41·plotSize) passt mit ~30% Rand bequem ins 40°-FOV.
                    target.copy(centerVec);
                    radius = plotSize * 1.8;
                    theta = Math.PI * 0.25;
                    phi = Math.PI * 0.33;
                    update();
                }
            };
        }

        // Mapping Slider-Wert (3..20) → KDE-Bandwidth im [0,1]-Space.
        // Verankert über drei Punkte:
        //   val=3  → 0.070 (breite Bandwidth → wenige, breite Hügel / Übersicht)
        //   val=10 → 0.045 (alter Default, Standardansicht bleibt unverändert)
        //   val=20 → 0.025 (enge Bandwidth  → viele scharfe Spitzen / Detail)
        // Piecewise-linear, damit val=10 exakt auf dem Original-Wert landet.
        // Jeder Tick links von 10 macht grob +3.5‰, rechts grob −2‰, gefühlt
        // gleichmäßig auf beiden Seiten.
        function bandwidthForSliderValue(v) {
            if (v <= 10) {
                const t = (v - 3) / 7; // 0..1 über [3,10]
                return 0.070 - t * (0.070 - 0.045);
            } else {
                const t = (v - 10) / 10; // 0..1 über [10,20]
                return 0.045 - t * (0.045 - 0.025);
            }
        }

        // Analog für 2D, d3.contourDensity nimmt bandwidth in Pixeln (nicht
        // 01-Space). Anker: val=10 → 32 px (alter Fest-Wert). Links breiter,
        // rechts enger. Pixel-Werte fühlen sich auf einer ~900 px breiten
        // Canvas gleich an wie die 01-Werte in 3D.
        function bandwidth2DForSliderValue(v) {
            if (v <= 10) {
                const t = (v - 3) / 7;
                return 56 - t * (56 - 32);
            } else {
                const t = (v - 10) / 10;
                return 32 - t * (32 - 18);
            }
        }

        // Stellt sicher, dass für die aktuelle Bandwidth gültige Peaks
        // (heightmap3dState.peaks) existieren, auch ohne gebautes 3D-Terrain.
        // Berechnet KDE-Gitter + Peak-Liste. Wird von 2D-Render wie 3D-Recompute
        // gerufen. Erzeugt pointsExt lazy, wenn noch nicht da (z.B. User war
        // nie in 3D). Rückgabe: { kde, kdeMax, pointsExt, plotSize, heightScale,
        // gridN }, wird in 3D-Terrain-Update nachgereicht, in 2D ignoriert.
        function rebuildPeakData(bandwidth) {
            if (!heightmapState.dataReady) return null;
            const plotSize = 500;
            const heightScale = 120;
            const gridSegs = 80;
            const gridN = gridSegs + 1;

            // points01 / plotNodes einmal bauen (falls nicht schon durch 3D-Build).
            // Rebuild bei jedem Aufruf ist OK, nur ~1200 Map-Lookups, µs-Level.
            const uuidToNode = new Map();
            for (const n of data.nodes) uuidToNode.set(n.id, n);
            const points01 = [];
            const plotNodes = [];
            for (const [uuid, p] of heightmapState.coords) {
                const node = uuidToNode.get(uuid);
                if (!node) continue;
                points01.push({ x: p.x, y: p.y });
                plotNodes.push({ x: p.x, y: p.y, node });
            }
            if (points01.length < 2) return null;

            // KDE-Gitter.
            const kde = new Float32Array(gridN * gridN);
            let kdeMax = 0;
            for (let iy = 0; iy < gridN; iy++) {
                const v = iy / (gridN - 1);
                for (let ix = 0; ix < gridN; ix++) {
                    const u = ix / (gridN - 1);
                    const d = kdeAt01(u, v, points01, bandwidth);
                    kde[iy * gridN + ix] = d;
                    if (d > kdeMax) kdeMax = d;
                }
            }
            if (kdeMax === 0) kdeMax = 1;

            // pointsExt für buildPeakLabels (braucht x01, y01, node).
            // Für 3D-Build: die existierenden pointsExt-Objekte haben zusätzlich
            // wx/wy/wz, die werden danach durch updateTerrainFromKDE erneuert.
            const pointsExt = plotNodes.map(pn => ({
                x01: pn.x, y01: pn.y, node: pn.node,
                wx: 0, wy: 0, wz: 0, density: 0
            }));

            heightmap3dState.peaks = buildPeakLabels(
                pointsExt, kde, gridN, kdeMax, plotSize, heightScale
            );
            // Kontext cachen, damit 3D-Terrain-Update später die gleichen
            // points01/plotNodes/gridN wiederverwenden kann.
            heightmap3dState.plotSize = plotSize;
            heightmap3dState.heightScale = heightScale;
            heightmap3dState.gridN = gridN;
            heightmap3dState.points01 = points01;
            heightmap3dState.plotNodes = plotNodes;
            heightmap3dState.points = pointsExt;

            return { kde, kdeMax, pointsExt, plotSize, heightScale, gridN };
        }

        // Re-berechnet Terrain-Höhen, Notiz-Y-Positionen und Peak-Labels für
        // eine neue Bandwidth. Two-Pass:
        //   (1) rebuildPeakData() berechnet KDE + Peaks, auch ohne 3D-Scene.
        //   (2) Wenn 3D-Szene gebaut ist, werden Mesh-Vertices + Instance-Matrizen
        //       in-place aktualisiert. Sonst no-op.
        //   (3) Labels (3D-DOM + 2D-DOM) neu aufbauen, Ollama-Request anstoßen.
        // Kosten: KDE-Grid ~80 ms bei 1200 Notizen. Wird debounced vom Slider gerufen.
        function recomputeHeightmap3dTerrain(bandwidth) {
            const data = rebuildPeakData(bandwidth);
            if (!data) return;
            const { kde, kdeMax, pointsExt, plotSize, heightScale, gridN } = data;
            const gridSegs = gridN - 1;

            // 3D-Mesh-Update nur wenn Szene bereits gebaut.
            if (heightmap3dState.built && heightmap3dState.terrain && heightmap3dState.notes) {
                const terrain = heightmap3dState.terrain;
                const inst = heightmap3dState.notes;
                // Terrain-Vertices (Y + Farbe) in-place aktualisieren.
                const geom = terrain.geometry;
                const pos = geom.attributes.position;
                const colorAttr = geom.attributes.color;
                for (let i = 0; i < pos.count; i++) {
                    const ix = i % gridN;
                    const iyRaw = Math.floor(i / gridN);
                    const iy = gridSegs - iyRaw; // y-Flip
                    const dNorm = kde[iy * gridN + ix] / kdeMax;
                    pos.setY(i, dNorm * heightScale);
                    const col = new THREE.Color(d3.interpolateViridis(dNorm));
                    colorAttr.array[i*3]   = col.r;
                    colorAttr.array[i*3+1] = col.g;
                    colorAttr.array[i*3+2] = col.b;
                }
                pos.needsUpdate = true;
                colorAttr.needsUpdate = true;
                geom.computeVertexNormals();

                // Notizen-Kugeln auf neue Höhe heben.
                const tmpMat = new THREE.Matrix4();
                const up = 2.0;
                const plotNodes = heightmap3dState.plotNodes;
                const points01 = heightmap3dState.points01;
                for (let i = 0; i < plotNodes.length; i++) {
                    const pn = plotNodes[i];
                    const wx = (pn.x - 0.5) * plotSize;
                    const wz = (0.5 - pn.y) * plotSize;
                    const density = kdeAt01(pn.x, pn.y, points01, bandwidth) / kdeMax;
                    const wy = density * heightScale + up;
                    tmpMat.makeTranslation(wx, wy, wz);
                    inst.setMatrixAt(i, tmpMat);
                    pointsExt[i].wx = wx;
                    pointsExt[i].wy = wy;
                    pointsExt[i].wz = wz;
                    pointsExt[i].density = density;
                }
                inst.instanceMatrix.needsUpdate = true;
            }

            // Labels neu bauen, sowohl 3D-DOM (wenn Szene existiert) als auch
            // 2D-DOM (wenn 2D-Container sichtbar/initialisiert ist).
            createHeightmap3dLabelDOM();
            renderHeightmap2dLabels();

            // Ollama-Labels anfragen (seit Cache-Integration billig für
            // wiederkehrende Cluster).
            requestOllamaPeakLabels();
        }

        // Baut (oder ersetzt) Terrain + Note-Instances aus heightmapState.coords.
        // Wird aufgerufen, wenn User nach 3D wechselt UND Daten sich geändert haben
        // (dataReady=true). Bei Color-Mode-Wechsel reicht updateHeightmap3dColors().
        function buildHeightmap3dScene() {
            if (!heightmap3dState.initialized) return;
            if (!heightmapState.dataReady) return;

            // Alte Meshes rausräumen (beim Daten-Reload).
            const scene = heightmap3dState.scene;
            if (heightmap3dState.terrain) {
                scene.remove(heightmap3dState.terrain);
                heightmap3dState.terrain.geometry.dispose();
                heightmap3dState.terrain.material.dispose();
                heightmap3dState.terrain = null;
            }
            if (heightmap3dState.notes) {
                scene.remove(heightmap3dState.notes);
                heightmap3dState.notes.geometry.dispose();
                heightmap3dState.notes.material.dispose();
                heightmap3dState.notes = null;
            }
            if (heightmap3dState.labelsDOM) {
                heightmap3dState.labelsDOM.remove();
                heightmap3dState.labelsDOM = null;
                heightmap3dState.peaks = null;
            }

            const plotSize = 500;     // Weltmaß der X/Z-Ausdehnung
            const heightScale = 120;  // Y-Multiplikator für Dichte → sichtbare Hügel
            const gridSegs = 80;      // 80×80 Quads (6561 verts)
            // Bandwidth kommt aus dem Detail-Slider. Default-Position 10
            // entspricht per bandwidthForSliderValue() exakt dem alten
            // Fest-Wert 0.045, Standardansicht sieht gleich aus.
            const bandwidth = bandwidthForSliderValue(getPeakSliderValue());

            // Coords in Arbeitsformat konvertieren + Nodes matchen.
            const uuidToNode = new Map();
            for (const n of data.nodes) uuidToNode.set(n.id, n);
            const points01 = []; // {x,y} in [0,1]
            const plotNodes = []; // {x,y in [0,1], node}
            for (const [uuid, p] of heightmapState.coords) {
                const node = uuidToNode.get(uuid);
                if (!node) continue;
                points01.push({ x: p.x, y: p.y });
                plotNodes.push({ x: p.x, y: p.y, node });
            }
            if (plotNodes.length < 2) return;

            // KDE-Gitter (81×81 Werte) aus points01.
            const gridN = gridSegs + 1;
            const kde = new Float32Array(gridN * gridN);
            let kdeMax = 0;
            for (let iy = 0; iy < gridN; iy++) {
                const v = iy / (gridN - 1);
                for (let ix = 0; ix < gridN; ix++) {
                    const u = ix / (gridN - 1);
                    const d = kdeAt01(u, v, points01, bandwidth);
                    kde[iy * gridN + ix] = d;
                    if (d > kdeMax) kdeMax = d;
                }
            }
            if (kdeMax === 0) kdeMax = 1;

            // PlaneGeometry: liegt initial in XY-Ebene (z=0). Wir rotieren sie in
            // die XZ-Ebene (y=0) und heben dann Y nach Dichte an.
            // Wichtig: PlaneGeometry legt Vertices in Zeilen an:
            //   idx = iy * (gridSegs+1) + ix,  iy=0 oben (+Y), iy=gridSegs unten (−Y)
            // Nach rotateX(-π/2): oben (+Y) → hinten (−Z). Darum flippen wir iy
            // beim KDE-Lookup, damit (u=0,v=0) links-vorne landet (intuitiv).
            const planeGeom = new THREE.PlaneGeometry(plotSize, plotSize, gridSegs, gridSegs);
            planeGeom.rotateX(-Math.PI / 2);
            const pos = planeGeom.attributes.position;
            const colorArr = new Float32Array(pos.count * 3);
            for (let i = 0; i < pos.count; i++) {
                const ix = i % gridN;
                const iyRaw = Math.floor(i / gridN);
                // planegeo iy=0 ist +Y (nach rotateX: −Z = "hinten"). Wir wollen
                // UMAP-v=0 vorne → flippen.
                const iy = gridSegs - iyRaw;
                const dNorm = kde[iy * gridN + ix] / kdeMax;
                pos.setY(i, dNorm * heightScale);
                const col = new THREE.Color(d3.interpolateViridis(dNorm));
                colorArr[i*3] = col.r; colorArr[i*3+1] = col.g; colorArr[i*3+2] = col.b;
            }
            pos.needsUpdate = true;
            planeGeom.computeVertexNormals();
            planeGeom.setAttribute('color', new THREE.BufferAttribute(colorArr, 3));

            const terrainMat = new THREE.MeshStandardMaterial({
                vertexColors: true,
                roughness: 0.95,
                metalness: 0.0,
                flatShading: false
            });
            const terrain = new THREE.Mesh(planeGeom, terrainMat);
            terrain.receiveShadow = false;
            scene.add(terrain);

            // Notizen als InstancedMesh, 1 Draw-Call für alle 1200+ Kugeln.
            const noteRadius = plotNodes.length > 700 ? 2.4 : 3.2;
            const sphereGeom = new THREE.SphereGeometry(noteRadius, 10, 8);
            const sphereMat = new THREE.MeshStandardMaterial({
                roughness: 0.45,
                metalness: 0.05
            });
            const inst = new THREE.InstancedMesh(sphereGeom, sphereMat, plotNodes.length);
            inst.instanceMatrix.setUsage(THREE.DynamicDrawUsage);
            const tmpMat = new THREE.Matrix4();
            const up = 2.0; // Kugeln leicht anheben, damit sie nicht im Terrain stecken

            const pointsExt = [];
            for (let i = 0; i < plotNodes.length; i++) {
                const pn = plotNodes[i];
                // World-Koordinaten aus [0,1]→ [-plotSize/2, +plotSize/2]
                const wx = (pn.x - 0.5) * plotSize;
                const wz = (0.5 - pn.y) * plotSize; // y-Flip: UMAP-v=0 nach vorne
                // Dichte am Punkt direkt berechnen (keine Gitter-Interpolation)
                const density = kdeAt01(pn.x, pn.y, points01, bandwidth) / kdeMax;
                const wy = density * heightScale + up;
                tmpMat.makeTranslation(wx, wy, wz);
                inst.setMatrixAt(i, tmpMat);
                pointsExt.push({ x01: pn.x, y01: pn.y, wx, wy, wz, density, node: pn.node });
            }
            inst.instanceMatrix.needsUpdate = true;
            scene.add(inst);

            heightmap3dState.terrain = terrain;
            heightmap3dState.notes = inst;
            heightmap3dState.points = pointsExt;
            // Kontext für Bandwidth-Slider-Recompute aufheben:
            heightmap3dState.plotSize = plotSize;
            heightmap3dState.heightScale = heightScale;
            heightmap3dState.gridN = gridN;
            heightmap3dState.points01 = points01;
            heightmap3dState.plotNodes = plotNodes;
            heightmap3dState.built = true;

            // Erstfärbung passend zum aktuellen Color-Mode.
            updateHeightmap3dColors();

            // Kamera: Target ist immer die geometrische Mitte des Terrain-Meshes.
            // Das Terrain spannt -plotSize/2..+plotSize/2 in X/Z, Y 0..heightScale.
            // Wir setzen den Target auf (0, heightScale*0.35, 0), das ist mittig
            // im bemaßten Bergbuckel-Volumen. Auch wenn alle Notizen in einer Ecke
            // clustern, dreht die Szene damit um die visuelle Mitte der Plane,
            // nicht um einen abgelegenen Cluster-Schwerpunkt.
            const terrainCenter = new THREE.Vector3(0, heightScale * 0.35, 0);
            heightmap3dState.orbit.setCenter(terrainCenter, plotSize);

            // Thematische Berg-Labels aus KDE-Maxima + Keyword-Extraktion.
            heightmap3dState.peaks = buildPeakLabels(
                pointsExt, kde, gridN, kdeMax, plotSize, heightScale
            );
            createHeightmap3dLabelDOM();
            // 2D-Labels gleich mitziehen, damit beim Wechsel zurück zur
            // 2D-Ansicht sofort die aktuellen Beschriftungen sichtbar sind,
            // ohne einen Slider-Move als Auslöser zu brauchen.
            renderHeightmap2dLabels();

            // Ollama-Labels anfragen (async, ersetzt die Token-Labels sobald da).
            requestOllamaPeakLabels();
        }

        function updateHeightmap3dColors() {
            if (!heightmap3dState.built) return;
            const { notes, points } = heightmap3dState;
            const ctx = buildHeightmap3dColorCtx(points);
            const anyFilter = activeFolders.size > 0 || activeTags.size > 0 || searchQuery.length > 0;
            const dimColor = new THREE.Color(0x2a2a3a);
            const col = new THREE.Color();
            for (let i = 0; i < points.length; i++) {
                const hex = heightmapFillFor(points[i].node, ctx);
                col.set(hex);
                if (anyFilter && !nodeMatches(points[i].node)) {
                    // Mische zu Grau → dimmed-Look
                    col.lerp(dimColor, 0.85);
                }
                notes.setColorAt(i, col);
            }
            if (notes.instanceColor) notes.instanceColor.needsUpdate = true;
        }

        function startHeightmap3dAnim() {
            if (heightmap3dState.running) return;
            heightmap3dState.running = true;
            const tick = () => {
                if (!heightmap3dState.running) return;
                heightmap3dState.renderer.render(heightmap3dState.scene, heightmap3dState.camera);
                updateHeightmap3dLabels();
                heightmap3dState.rafHandle = requestAnimationFrame(tick);
            };
            heightmap3dState.rafHandle = requestAnimationFrame(tick);
        }

        function stopHeightmap3dAnim() {
            heightmap3dState.running = false;
            if (heightmap3dState.rafHandle) {
                cancelAnimationFrame(heightmap3dState.rafHandle);
                heightmap3dState.rafHandle = 0;
            }
        }

        function setHeightmap3dView(view) {
            if (view === heightmap3dState.view) return;
            heightmap3dState.view = view;
            document.getElementById('btn-heightmap-view-2d').classList.toggle('active', view === '2d');
            document.getElementById('btn-heightmap-view-3d').classList.toggle('active', view === '3d');
            const container = document.getElementById('graph-heightmap');
            container.classList.toggle('mode-3d', view === '3d');
            // Höhenlinien-Checkbox und Farb-Legende sind im 3D egal, blenden wir aus.
            document.getElementById('heightmap-contour-toggle').style.visibility = (view === '3d') ? 'hidden' : 'visible';

            if (view === '3d') {
                init3DHeightmapIfNeeded();
                onHeightmap3DResize();
                if (heightmapState.dataReady && !heightmap3dState.built) {
                    buildHeightmap3dScene();
                }
                startHeightmap3dAnim();
            } else {
                stopHeightmap3dAnim();
                // Tooltip einklappen
                if (heightmap3dState.tooltip) heightmap3dState.tooltip.style.display = 'none';
                // 2D-Render könnte wegen Resize leicht abweichen → neu zeichnen
                renderHeightmap();
            }
        }

        function onHeightmap3DClick(event) {
            const hit = raycast3DNote(event);
            if (hit >= 0) {
                showPanel(heightmap3dState.points[hit].node);
            }
        }

        function onHeightmap3DMouseMove(event) {
            const hit = raycast3DNote(event);
            if (hit !== heightmap3dState.hoverInstance) {
                heightmap3dState.hoverInstance = hit;
            }
            if (hit >= 0) {
                showHeightmapTooltip(event, heightmap3dState.points[hit].node);
            } else {
                hideHeightmapTooltip();
            }
        }

        function raycast3DNote(event) {
            const { renderer, camera, raycaster, notes } = heightmap3dState;
            if (!notes) return -1;
            const rect = renderer.domElement.getBoundingClientRect();
            const ndc = new THREE.Vector2(
                ((event.clientX - rect.left) / rect.width) * 2 - 1,
                -((event.clientY - rect.top) / rect.height) * 2 + 1
            );
            raycaster.setFromCamera(ndc, camera);
            const hits = raycaster.intersectObject(notes);
            return hits.length > 0 ? hits[0].instanceId : -1;
        }

        // ===========================================================
        //  Mode Toggle 2D / Radial / Radial 2 / Circos / Tage / Monate / Sunburst / Matrix / Heightmap / 3D
        // ===========================================================
        // Gegenseitig exklusive Buttons:
        //  • btn-2d       → 2D-View mit Force-Layout
        //  • btn-radial   → 2D-View mit klassischem Radial-Layout (alle Nodes)
        //  • btn-radial2  → 2D-View mit Radial 2 (Orphans-Halo + Linked-Sektoren)
        //  • btn-circos   → Circos-View (Ordner-Segmente, Link-Bögen, radiale Balken)
        //  • btn-calendar → Kalender-Heatmap (Notizen nach Erstelldatum, pro Tag)
        //  • btn-monthly  → Monats-Heatmap (Jahre × Monate)
        //  • btn-3d       → 3D-View (Layout-Wahl inaktiv)
        function setActiveModeButton(id) {
            for (const bid of ['btn-2d', 'btn-radial', 'btn-radial2', 'btn-circos', 'btn-calendar', 'btn-monthly', 'btn-heightmap', 'btn-3d']) {
                document.getElementById(bid).classList.toggle('active', bid === id);
            }
        }

        // ===========================================================
        //                       Help-Modal
        // ===========================================================
        // Klick auf ⓘ-Button im Header → Help-Panel mit kontext-sensitivem
        // Inhalt für die aktuell aktive View (window.NM_HELP[currentMode]).
        // Esc oder Klick auf Backdrop schließt.
        // Help-Key passend zur aktuellen View: 2D differenziert nach Layout
        // (force / radial / radial2), die anderen Modi nehmen direkt currentMode.
        function helpKey() {
            if (currentMode === '2d') {
                return currentLayout === 'force' ? '2d' : currentLayout;
            }
            return currentMode;
        }
        function openHelpModal() {
            const key = helpKey();
            const help = (window.NM_HELP && window.NM_HELP[key]) || null;
            const modal = document.getElementById('help-modal');
            const titleEl = document.getElementById('help-title');
            const descEl = document.getElementById('help-description');
            const intersEl = document.getElementById('help-interactions');

            if (!help) {
                titleEl.textContent = '...';
                descEl.textContent = '';
                intersEl.innerHTML = '';
            } else {
                titleEl.textContent = help.title;
                descEl.textContent = help.description;
                intersEl.innerHTML = '';
                for (const item of (help.interactions || [])) {
                    const li = document.createElement('li');
                    li.textContent = item;
                    intersEl.appendChild(li);
                }
            }
            modal.classList.add('visible');
            document.getElementById('btn-info').classList.add('active');
        }
        function closeHelpModal() {
            document.getElementById('help-modal').classList.remove('visible');
            document.getElementById('btn-info').classList.remove('active');
        }
        document.getElementById('btn-info').addEventListener('click', () => {
            const modal = document.getElementById('help-modal');
            if (modal.classList.contains('visible')) closeHelpModal();
            else openHelpModal();
        });
        document.getElementById('help-modal-close').addEventListener('click', closeHelpModal);
        document.getElementById('help-modal').addEventListener('click', (e) => {
            // Klick auf Backdrop (das Modal selbst) schließt; Klicks im Card nicht.
            if (e.target.id === 'help-modal') closeHelpModal();
        });
        document.addEventListener('keydown', (e) => {
            if (e.key === 'Escape' && document.getElementById('help-modal').classList.contains('visible')) {
                closeHelpModal();
            }
        });

        // ===========================================================
        //                   Hover-Tooltip
        // ===========================================================
        // Native title="..." hat unkontrollierbaren OS-Delay (oft 1-2s).
        // Eigene Lösung: data-tip-Attribut + ein gemeinsames Tooltip-Element
        // + setTimeout-basierter Hover-Delay. Konsistente 1s Verzögerung,
        // 80ms Fade-in via CSS-transition.
        (function() {
            const tt = document.getElementById('instant-tooltip');
            const HOVER_DELAY_MS = 0;
            let active = null;
            let hoverTimer = null;

            function showTip(el) {
                const text = el.dataset.tip;
                if (!text) return;
                tt.textContent = text;
                // Erst off-screen positionieren um zu messen (kein Flash).
                tt.classList.remove('visible');
                tt.style.left = '-9999px';
                tt.style.top = '-9999px';
                // Force layout für offsetWidth/offsetHeight.
                const w = tt.offsetWidth;
                const h = tt.offsetHeight;
                const rect = el.getBoundingClientRect();
                let x = rect.left + rect.width / 2 - w / 2;
                let y = rect.bottom + 8;
                // Edge-Clipping: rechts/unten reinrücken bzw. nach oben flippen.
                if (x < 8) x = 8;
                if (x + w > window.innerWidth - 8) x = window.innerWidth - w - 8;
                if (y + h > window.innerHeight - 8) y = rect.top - h - 8;
                tt.style.left = x + 'px';
                tt.style.top = y + 'px';
                // Jetzt sichtbar machen, CSS-Transition macht den Fade.
                tt.classList.add('visible');
            }
            function scheduleShow(el) {
                if (hoverTimer) clearTimeout(hoverTimer);
                hoverTimer = setTimeout(() => {
                    hoverTimer = null;
                    showTip(el);
                }, HOVER_DELAY_MS);
            }
            function cancelPending() {
                if (hoverTimer) {
                    clearTimeout(hoverTimer);
                    hoverTimer = null;
                }
            }
            function hideTip() {
                cancelPending();
                tt.classList.remove('visible');
                active = null;
            }

            // Event-Delegation: ein Listener für alle data-tip-Elemente,
            // egal ob sie nachträglich ins DOM kommen.
            document.addEventListener('mouseover', (e) => {
                const el = e.target.closest('[data-tip]');
                if (!el || el === active) return;
                active = el;
                cancelPending();
                scheduleShow(el);
            });
            document.addEventListener('mouseout', (e) => {
                const el = e.target.closest('[data-tip]');
                if (!el) return;
                // mouseout feuert auch beim Wechsel auf Kind-Elemente,
                // nur hide wenn related target wirklich außerhalb ist.
                const to = e.relatedTarget;
                if (to && el.contains(to)) return;
                hideTip();
            });
            // Sicherheits-Hide bei Klick / Mode-Wechsel.
            document.addEventListener('click', hideTip, true);
            window.addEventListener('blur', hideTip);
        })();

        // ===========================================================
        //                     Suche im Header
        // ===========================================================
        // Schreibt in `searchQuery` und triggert applyNodeFilters() in
        // allen Views. Die nodeMatches()-Funktion checkt searchQuery
        // automatisch, daher reicht ein Re-Render der aktiven View.
        (function() {
            const input = document.getElementById('search-input');
            const wrap = document.getElementById('search-wrap');
            const clearBtn = document.getElementById('search-clear');
            if (!input) return;

            function apply() {
                const newQ = input.value.trim().toLowerCase();
                if (newQ === searchQuery) return;
                searchQuery = newQ;
                wrap.classList.toggle('has-text', searchQuery.length > 0);
                // Re-Filter über alle Views. applyNodeFilters() handhabt 2D
                // direkt; für non-2D-Views sind Re-Renders bei jedem
                // Mode-Wechsel sowieso, und ihre Filter-Pfade prüfen
                // nodeMatches() pro Render ohnehin neu.
                if (typeof applyNodeFilters === 'function') applyNodeFilters();
                // Andere Views forciert neu rendern, falls aktiv:
                if (currentMode === 'circos' && typeof renderCircos === 'function') renderCircos();
                else if (currentMode === 'calendar' && typeof renderCalendar === 'function') renderCalendar();
                else if (currentMode === 'monthly' && typeof renderMonthly === 'function') renderMonthly();
                else if (currentMode === 'heightmap' && typeof refreshHeightmap === 'function') refreshHeightmap();
            }

            input.addEventListener('input', apply);
            clearBtn.addEventListener('click', () => {
                input.value = '';
                apply();
                input.focus();
            });
            // Cmd+F im Header-Fokus = Suche fokussieren (alternativ zur OS-Suche).
            document.addEventListener('keydown', (e) => {
                if ((e.metaKey || e.ctrlKey) && e.key === 'f') {
                    e.preventDefault();
                    input.focus();
                    input.select();
                }
                if (e.key === 'Escape' && document.activeElement === input) {
                    input.value = '';
                    apply();
                    input.blur();
                }
            });
        })();
        function showOnlyContainer(which) {
            // Mode + Layout als data-attribute am body tracken, CSS nutzt
            // beide Werte um Timeline einzublenden (nur in 2D-Force und 3D)
            // bzw. graph-Container bis Bildschirmkante zu strecken.
            document.body.dataset.mode = which;
            // Layout nur für 2D relevant, in anderen Modi gibt's nur ein.
            if (which === '2d') {
                document.body.dataset.layout = currentLayout;
            } else {
                document.body.dataset.layout = which;
            }
            document.getElementById('graph-2d').style.display = which === '2d' ? 'block' : 'none';
            document.getElementById('graph-3d').style.display = which === '3d' ? 'block' : 'none';
            document.getElementById('graph-circos').style.display = which === 'circos' ? 'block' : 'none';
            document.getElementById('graph-calendar').style.display = which === 'calendar' ? 'block' : 'none';
            document.getElementById('graph-monthly').style.display = which === 'monthly' ? 'block' : 'none';
            document.getElementById('graph-heightmap').style.display = which === 'heightmap' ? 'block' : 'none';
            // Tooltip / Day-Panel ausblenden, wenn wir aus Kalender/Monatlich rausgehen
            if (which !== 'calendar') {
                hideCalendarTooltip();
            }
            if (which !== 'calendar' && which !== 'monthly') {
                hideDayPanel();
            }
            // Heightmap-Tooltip schließen, wenn wir die View verlassen
            if (which !== 'heightmap') {
                const hmt = document.getElementById('heightmap-tooltip');
                if (hmt) hmt.style.display = 'none';
            }
        }
        document.getElementById('btn-2d').addEventListener('click', () => {
            if (currentMode === '2d' && currentLayout === 'force') return;
            const cameFromNon2D = (currentMode !== '2d');
            currentMode = '2d';
            setActiveModeButton('btn-2d');
            if (currentLayout === 'radial' || currentLayout === 'radial2') {
                currentLayout = 'force';
                applyForceLayout();  // macht intern sim.alpha(0.8).restart()
            } else if (cameFromNon2D) {
                // Kommt von Circos/Calendar/.., Sim wurde dort via sim.stop()
                // angehalten. Sanft weiterlaufen lassen (kein Reheat, damit
                // Positionen bleiben). Bei ausgekühltem Alpha ist das ein No-Op.
                sim.restart();
            }
            // showOnlyContainer NACH currentLayout-Update aufrufen, damit
            // body.dataset.layout den korrekten neuen Wert kriegt, sonst
            // zeigt CSS Timeline/Spacing falsch.
            showOnlyContainer('2d');
            hidePanel();
        });
        document.getElementById('btn-radial').addEventListener('click', () => {
            if (currentMode === '2d' && currentLayout === 'radial') return;
            currentMode = '2d';
            setActiveModeButton('btn-radial');
            if (currentLayout !== 'radial') {
                currentLayout = 'radial';
                applyRadialLayout();
            }
            showOnlyContainer('2d');
            hidePanel();
        });
        document.getElementById('btn-radial2').addEventListener('click', () => {
            if (currentMode === '2d' && currentLayout === 'radial2') return;
            currentMode = '2d';
            setActiveModeButton('btn-radial2');
            if (currentLayout !== 'radial2') {
                currentLayout = 'radial2';
                applyRadial2Layout();
            }
            showOnlyContainer('2d');
            hidePanel();
        });
        // Non-2D-Modi: die 2D-Force-Simulation wird gestoppt, sonst tickt sie
        // im Hintergrund weiter und blockiert den Main-Thread (merkbar bei
        // ~1200 Nodes direkt nach App-Start). Beim Rückwechsel auf btn-2d
        // übernimmt dort sim.restart() bzw. applyForceLayout.
        document.getElementById('btn-circos').addEventListener('click', () => {
            if (currentMode === 'circos') return;
            currentMode = 'circos';
            sim.stop();
            setActiveModeButton('btn-circos');
            showOnlyContainer('circos');
            hidePanel();
            // initCircos() in rAF: sofortiges Umschalten des Containers, dann
            // im nächsten Frame das SVG-Aufbauen. Ohne rAF klebt der Click bis
            // zum fertigen Render (~200ms bei 1200 Notizen), mit rAF fühlt sich
            // die UI responsive an, weil der Browser zuerst paint'et.
            requestAnimationFrame(() => {
                initCircos();
            });
        });
        document.getElementById('btn-calendar').addEventListener('click', () => {
            if (currentMode === 'calendar') return;
            currentMode = 'calendar';
            sim.stop();
            setActiveModeButton('btn-calendar');
            showOnlyContainer('calendar');
            initCalendar();
            hidePanel();
        });
        document.getElementById('btn-monthly').addEventListener('click', () => {
            if (currentMode === 'monthly') return;
            currentMode = 'monthly';
            sim.stop();
            setActiveModeButton('btn-monthly');
            showOnlyContainer('monthly');
            initMonthly();
            hidePanel();
        });
        document.getElementById('btn-heightmap').addEventListener('click', () => {
            if (currentMode === 'heightmap') return;
            currentMode = 'heightmap';
            sim.stop();
            setActiveModeButton('btn-heightmap');
            showOnlyContainer('heightmap');
            initHeightmap();
            hidePanel();
        });
        document.getElementById('btn-3d').addEventListener('click', () => {
            if (currentMode === '3d') return;
            currentMode = '3d';
            sim.stop();
            setActiveModeButton('btn-3d');
            showOnlyContainer('3d');
            init3d();
            applyTimeFilter();
            applyNodeFilters();
            hidePanel();
        });

        // ===========================================================
        //                       Refresh-Button
        // ===========================================================
        // Request → Swift (WKScriptMessageHandler "refreshRequest").
        // Swift triggert silentRefresh im LinkMapModel → nach Fertig wird
        // die HTML komplett neu geladen; der Spinner verschwindet dabei
        // automatisch, weil das neue HTML keine .spinning-Klasse hat.
        const refreshBtn = document.getElementById('btn-refresh');
        refreshBtn.addEventListener('click', () => {
            if (refreshBtn.classList.contains('spinning')) return;
            refreshBtn.classList.add('spinning');
            try {
                window.webkit.messageHandlers.refreshRequest.postMessage({});
            } catch (e) {
                // Fallback: wir sind nicht im WKWebView (z.B. Preview in Safari)
                console.warn('refreshRequest not available:', e);
                refreshBtn.classList.remove('spinning');
            }
            // Safety-Timeout: falls kein Reload kommt, Spinner nach 30s stoppen.
            setTimeout(() => refreshBtn.classList.remove('spinning'), 30000);
        });

        // ===========================================================
        //                     Legende / Multiselect
        // ===========================================================
        const legend = document.getElementById('legend');
        const legendBody = document.getElementById('legend-body');
        const legendSummary = document.getElementById('legend-summary');
        // `totalFolders` und `folderCounts` sind `let`, weil sie bei
        // __applyDataUpdate() auf neue Werte rezignet werden.
        let totalFolders = data.folders.length;
        let folderCounts = {};
        for (const n of data.nodes) folderCounts[n.folder] = (folderCounts[n.folder] || 0) + 1;

        // Ein Legend-Item + Click-Handler. Wird initial für alle Ordner
        // aufgerufen und in rebuildLegend() bei inkrementellem Update erneut.
        function appendLegendItem(f) {
            const item = document.createElement('div');
            item.className = 'legend-item';
            item.dataset.folder = f.name;
            if (activeFolders.has(f.name)) item.classList.add('active');
            item.innerHTML =
                '<span class="legend-dot" style="background:' + f.color + '"></span>' +
                '<span style="overflow:hidden;text-overflow:ellipsis">' + escapeHTML(f.name) + '</span>' +
                '<span class="count">' + (folderCounts[f.name] || 0) + '</span>';
            item.addEventListener('click', ev => {
                ev.stopPropagation();
                const folder = item.dataset.folder;
                if (item.classList.toggle('active')) activeFolders.add(folder);
                else activeFolders.delete(folder);
                applyNodeFilters();
                updateLegendState();
            });
            legendBody.appendChild(item);
        }

        for (const f of data.folders) appendLegendItem(f);

        // Nach inkrementellem Update: Legende komplett neu aufbauen, aber
        // activeFolders (User-Auswahl) erhalten. Aus activeFolders werden
        // Einträge entfernt, deren Ordner im neuen Datensatz nicht mehr
        // existieren (z.B. Ordner wurde in Notes gelöscht).
        function rebuildLegend() {
            totalFolders = data.folders.length;
            folderCounts = {};
            for (const n of data.nodes) folderCounts[n.folder] = (folderCounts[n.folder] || 0) + 1;

            legendBody.innerHTML = '';
            for (const f of data.folders) appendLegendItem(f);

            // activeFolders säubern (für verschwundene Ordner)
            const nameSet = new Set(data.folders.map(f => f.name));
            for (const fn of [...activeFolders]) {
                if (!nameSet.has(fn)) activeFolders.delete(fn);
            }
            updateLegendState();
        }

        document.getElementById('legend-header').addEventListener('click', () => {
            legend.classList.toggle('expanded');
        });
        document.getElementById('legend-clear').addEventListener('click', ev => {
            ev.stopPropagation();
            clearFolderSelection();
        });

        function updateLegendState() {
            if (activeFolders.size === 0) {
                legend.classList.remove('has-selection');
                legendSummary.textContent = totalFolders;
            } else {
                legend.classList.add('has-selection');
                legendSummary.textContent = activeFolders.size + '/' + totalFolders;
            }
        }
        function clearFolderSelection() {
            activeFolders.clear();
            document.querySelectorAll('.legend-item.active').forEach(el => el.classList.remove('active'));
            applyNodeFilters();
            updateLegendState();
        }
        updateLegendState();

        // ===========================================================
        //                   Tag-Panel / Multiselect
        // ===========================================================
        // Spiegel der Ordner-Legende, aber rechts. Tags sind Apple-Notes-
        // Hashtags (`com.apple.notes.inlinetextattachment.hashtag`). Sie
        // haben keine Farbe (anders als Ordner), daher einheitlicher grauer
        // Dot, der bei aktivem Tag blau leuchtet (CSS).
        const tagPanel = document.getElementById('tag-panel');
        const tagPanelBody = document.getElementById('tag-panel-body');
        const tagPanelSummary = document.getElementById('tag-panel-summary');
        let totalTags = (data.tagsList || []).length;

        function appendTagItem(t) {
            const item = document.createElement('div');
            item.className = 'tag-item';
            item.dataset.tag = t.tag;
            if (activeTags.has(t.tag)) item.classList.add('active');
            item.innerHTML =
                '<span class="tag-dot"></span>' +
                '<span class="tag-name">' + escapeHTML(t.tag) + '</span>' +
                '<span class="count">' + (t.count || 0) + '</span>';
            item.addEventListener('click', ev => {
                ev.stopPropagation();
                const tag = item.dataset.tag;
                if (item.classList.toggle('active')) activeTags.add(tag);
                else activeTags.delete(tag);
                applyNodeFilters();
                updateTagState();
            });
            tagPanelBody.appendChild(item);
        }

        function renderTagList() {
            tagPanelBody.innerHTML = '';
            const list = data.tagsList || [];
            if (list.length === 0) {
                const empty = document.createElement('div');
                empty.id = 'tag-panel-empty';
                empty.textContent = 'Keine Tags gefunden';
                tagPanelBody.appendChild(empty);
                return;
            }
            for (const t of list) appendTagItem(t);
        }
        renderTagList();

        // Nach inkrementellem Update: Tag-Liste neu bauen, activeTags säubern
        // (Tags, die keiner Notiz mehr zugeordnet sind, fallen aus der Selektion).
        function rebuildTagList() {
            totalTags = (data.tagsList || []).length;
            renderTagList();
            const tagSet = new Set((data.tagsList || []).map(t => t.tag));
            for (const tn of [...activeTags]) {
                if (!tagSet.has(tn)) activeTags.delete(tn);
            }
            updateTagState();
        }

        document.getElementById('tag-panel-header').addEventListener('click', () => {
            tagPanel.classList.toggle('expanded');
        });
        document.getElementById('tag-panel-clear').addEventListener('click', ev => {
            ev.stopPropagation();
            clearTagSelection();
        });

        function updateTagState() {
            if (activeTags.size === 0) {
                tagPanel.classList.remove('has-selection');
                tagPanelSummary.textContent = totalTags;
            } else {
                tagPanel.classList.add('has-selection');
                tagPanelSummary.textContent = activeTags.size + '/' + totalTags;
            }
        }
        function clearTagSelection() {
            activeTags.clear();
            document.querySelectorAll('.tag-item.active').forEach(el => el.classList.remove('active'));
            applyNodeFilters();
            updateTagState();
        }
        updateTagState();

        // Kombinierter Filter (Ordner + Tags). AND zwischen den Kategorien,
        // OR innerhalb Tags. Leer heißt "kein Filter aktiv" → alles sichtbar.
        // Edge ist highlighted wenn MINDESTENS einer der Endpunkte matcht
        // (konsistent mit der früheren reinen Ordner-Logik).
        function applyNodeFilters() {
            const anyFilter = activeFolders.size > 0 || activeTags.size > 0 || searchQuery.length > 0;
            if (!anyFilter) {
                node2d.classed('dimmed', false);
                link2d.classed('dimmed', false).classed('highlighted', false);
                node2d.select('.node-label').attr('opacity', 0);
            } else {
                node2d.classed('dimmed', d => !nodeMatches(d));
                link2d.classed('dimmed', l => {
                    const s = l.source, t = l.target;
                    return !(nodeMatches(s) || nodeMatches(t));
                });
                link2d.classed('highlighted', l => {
                    const s = l.source, t = l.target;
                    return nodeMatches(s) || nodeMatches(t);
                });
                node2d.select('.node-label').attr('opacity', d => nodeMatches(d) ? 0.9 : 0);
            }
            if (graph3d && currentMode === '3d') {
                graph3d.nodeColor(graph3d.nodeColor()).nodeVal(graph3d.nodeVal())
                       .linkColor(graph3d.linkColor()).linkWidth(graph3d.linkWidth());
            }
            // Circos: Ordner-/Tag-Filter als Dim der Ticks und Arcs
            if (circosState.initialized && circosState.nodeTicks) {
                if (!anyFilter) {
                    circosState.nodeTicks.classed('dim', false);
                    circosState.linkArcs.classed('dim', false);
                } else {
                    circosState.nodeTicks.classed('dim', n => !nodeMatches(n));
                    circosState.linkArcs.classed('dim', l => {
                        const s = data.nodes.find(n => n.id === l.source);
                        const t = data.nodes.find(n => n.id === l.target);
                        return !((s && nodeMatches(s)) || (t && nodeMatches(t)));
                    });
                }
            }
            // Calendar: Heatmap-Farbskala komplett re-rechnen (Buckets ändern sich,
            // wenn Ordner-/Tag-Filter gesetzt wird). Ein Full-Rebuild ist bei
            // ~1200 Notizen <30ms und vermeidet komplexe Teil-Updates.
            if (calendarState.initialized) {
                renderCalendar();
            }
            // Monthly: analog, Farbskala wird pro Monats-Max normalisiert,
            // muss also bei Filter-Toggle mit neu berechnet werden.
            if (monthlyState.initialized) {
                renderMonthly();
            }
            // Sunburst: Notes werden gedimmt (Layout bleibt stabil)
            if (sunburstState.initialized) {
                applySunburstFilters();
            }
            // Matrix: Zeilen/Spalten werden bei Filter abgeschwächt gezeichnet.
            // Ein Re-Render ist bei 1200×1200 noch schnell genug.
            if (matrixState.initialized) {
                renderMatrix();
            }
            // Heightmap: nur Circle-Dimming, Koordinaten bleiben konstant.
            if (heightmapState.initialized && heightmapState.dataReady) {
                applyHeightmapFilters();
            }
        }

        // Esc schließt Ordner- und Tag-Filter. Zwei Pfade:
        // 1. Regulärer JS-Listener (funktioniert wenn HTML-Elemente Fokus haben).
        // 2. Swift-NSEvent-Monitor ruft window.__onEscapeFromNative() auf
        //    (funktioniert auch wenn 3d-force-graph-Canvas den Fokus hält).
        function onEscape() {
            const hadSelection = activeFolders.size > 0 || activeTags.size > 0;
            if (!hadSelection) return;
            if (activeFolders.size > 0) clearFolderSelection();
            if (activeTags.size > 0) clearTagSelection();
        }
        window.__onEscapeFromNative = onEscape;
        window.addEventListener('keydown', ev => {
            if (ev.key === 'Escape') {
                ev.preventDefault();
                ev.stopPropagation();
                onEscape();
            }
        }, true);

        // ===========================================================
        //                 Time-Machine (Slider + Heatmap)
        // ===========================================================
        // minTime/maxTime/maxMonthCount sind `let`, weil recomputeTimeline()
        // sie neu setzt, wenn eine Notiz mit ungewöhnlichem created-Datum
        // reinkommt (z.B. ältere als der bisherige Minimum-Wert).
        let minTime, maxTime;
        let currentTime;
        {
            const timeNodes = data.nodes.filter(n => n.created > 0).map(n => n.created);
            minTime = timeNodes.length ? Math.min(...timeNodes) : Date.now() - 365*24*3600*1000;
            maxTime = Math.max(Date.now(), ...(timeNodes.length ? timeNodes : [Date.now()]));
            currentTime = maxTime;
        }
        let playing = false;
        let playTimer = null;

        const slider = document.getElementById('time-slider');
        const timeLabel = document.getElementById('time-label');
        const timeCounter = document.getElementById('time-counter');
        const playBtn = document.getElementById('play-btn');

        function formatDate(ts) {
            if (ts >= maxTime - 86400000) {
                return (window.NM_LOC && window.NM_LOC.today) || 'today';
            }
            return window.NM_formatDate(ts, { day: '2-digit', month: 'short', year: 'numeric' });
        }
        function isVisibleTime(n) { return n.created > 0 && n.created <= currentTime; }
        function isLinkVisibleTime(l) {
            const s = typeof l.source === 'object' ? l.source : data.nodes.find(n => n.id === l.source);
            const t = typeof l.target === 'object' ? l.target : data.nodes.find(n => n.id === l.target);
            return s && t && isVisibleTime(s) && isVisibleTime(t);
        }

        function applyTimeFilter() {
            timeLabel.textContent = formatDate(currentTime);
            const visibleCount = data.nodes.filter(isVisibleTime).length;
            timeCounter.textContent = visibleCount + ' / ' + data.nodes.length;

            if (node2d) {
                node2d.style('display', d => isVisibleTime(d) ? null : 'none');
                link2d.style('display', d => isLinkVisibleTime(d) ? null : 'none');
            }
            if (graph3d) {
                graph3d.nodeVisibility(isVisibleTime).linkVisibility(isLinkVisibleTime);
            }
            drawHeatmap();
        }

        slider.addEventListener('input', () => {
            const pct = +slider.value / 1000;
            currentTime = minTime + (maxTime - minTime) * pct;
            applyTimeFilter();
        });

        function togglePlay() {
            if (playing) {
                playing = false;
                playBtn.textContent = '▶';
                playBtn.classList.remove('playing');
                if (playTimer) { cancelAnimationFrame(playTimer); playTimer = null; }
                return;
            }
            playing = true;
            playBtn.textContent = '⏸';
            playBtn.classList.add('playing');
            if (+slider.value >= 1000) slider.value = 0;
            const DURATION_MS = 15000;
            const startVal = +slider.value;
            const startTs = performance.now();
            function step(now) {
                if (!playing) return;
                const elapsed = now - startTs;
                const remaining = 1000 - startVal;
                const progress = Math.min(1, elapsed / DURATION_MS * (1000 / Math.max(1, remaining)));
                const val = Math.min(1000, startVal + remaining * progress);
                slider.value = val;
                const pct = val / 1000;
                currentTime = minTime + (maxTime - minTime) * pct;
                applyTimeFilter();
                if (val >= 1000) {
                    playing = false;
                    playBtn.textContent = '▶';
                    playBtn.classList.remove('playing');
                    return;
                }
                playTimer = requestAnimationFrame(step);
            }
            playTimer = requestAnimationFrame(step);
        }
        playBtn.addEventListener('click', togglePlay);

        // Aktivitäts-Heatmap (Monats-Buckets)
        const heatCanvas = document.getElementById('heatmap-canvas');
        const heatTooltip = document.getElementById('heatmap-tooltip');
        const heatCtx = heatCanvas.getContext('2d');

        function monthKey(ts) {
            const d = new Date(ts);
            return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0');
        }
        const monthCounts = new Map();
        const months = [];
        let maxMonthCount = 1;

        // Zeitbereich + Heatmap-Buckets aus data.nodes ableiten. Wird initial
        // und bei jedem inkrementellen Update aufgerufen.
        function recomputeTimeline() {
            const timeNodes = data.nodes.filter(n => n.created > 0).map(n => n.created);
            const newMin = timeNodes.length ? Math.min(...timeNodes) : Date.now() - 365*24*3600*1000;
            const newMax = Math.max(Date.now(), ...(timeNodes.length ? timeNodes : [Date.now()]));
            // Wenn der Slider vorher auf "heute" stand, bleibt er auf "heute"
            // relativ zum neuen Max. Sonst Absolutwert clampen.
            const wasAtMax = currentTime >= maxTime - 1000;
            minTime = newMin;
            maxTime = newMax;
            currentTime = wasAtMax ? newMax : Math.min(newMax, Math.max(newMin, currentTime));

            const pct = (currentTime - minTime) / Math.max(1, maxTime - minTime);
            slider.value = Math.round(pct * 1000);

            monthCounts.clear();
            for (const n of data.nodes) {
                if (n.created <= 0) continue;
                const k = monthKey(n.created);
                monthCounts.set(k, (monthCounts.get(k) ?? 0) + 1);
            }
            months.length = 0;
            const start = new Date(minTime); start.setDate(1);
            const end = new Date(maxTime);
            const cur = new Date(start.getFullYear(), start.getMonth(), 1);
            while (cur <= end) {
                const k = monthKey(cur.getTime());
                months.push({
                    key: k, ts: cur.getTime(), count: monthCounts.get(k) ?? 0,
                    label: window.NM_formatDate(cur.getTime(), { month: 'short', year: 'numeric' })
                });
                cur.setMonth(cur.getMonth() + 1);
            }
            maxMonthCount = Math.max(1, ...months.map(m => m.count));
        }
        recomputeTimeline();

        function drawHeatmap() {
            const dpr = window.devicePixelRatio || 1;
            const rect = heatCanvas.getBoundingClientRect();
            heatCanvas.width = rect.width * dpr;
            heatCanvas.height = rect.height * dpr;
            heatCtx.setTransform(1, 0, 0, 1, 0, 0);
            heatCtx.scale(dpr, dpr);
            heatCtx.clearRect(0, 0, rect.width, rect.height);
            const n = months.length; if (n === 0) return;
            // Slider-Thumb ist 16px breit MIT border (globales `* { box-sizing:
            // border-box }`, d.h. `width: 16` = gesamte Box inkl. border).
            // Thumb-Mittelpunkt sitzt also 8px vom Track-Rand. Muss exakt passen,
            // sonst driftet die orange Scrubber-Linie vom blauen Thumb weg.
            const THUMB_INSET = 8;
            const trackWidth = rect.width - 2 * THUMB_INSET;
            const w = trackWidth / n;
            const barW = Math.max(1, w - 1);
            for (let i = 0; i < n; i++) {
                const m = months[i];
                const h = (m.count / maxMonthCount) * (rect.height - 2);
                const x = THUMB_INSET + i * w;
                const y = rect.height - h;
                const active = m.ts <= currentTime;
                heatCtx.fillStyle = active ? 'rgba(74,144,217,0.85)' : 'rgba(100,100,120,0.3)';
                heatCtx.fillRect(x, y, barW, h);
            }
            const pct = (currentTime - minTime) / Math.max(1, maxTime - minTime);
            const mx = THUMB_INSET + pct * trackWidth;
            heatCtx.strokeStyle = 'rgba(230,126,34,0.9)';
            heatCtx.lineWidth = 1.5;
            heatCtx.beginPath();
            heatCtx.moveTo(mx, 0); heatCtx.lineTo(mx, rect.height);
            heatCtx.stroke();
        }

        function monthFromX(clientX) {
            const rect = heatCanvas.getBoundingClientRect();
            const THUMB_INSET = 8;  // muss identisch zu drawHeatmap sein
            const trackWidth = rect.width - 2 * THUMB_INSET;
            const relX = Math.max(0, Math.min(trackWidth, clientX - rect.left - THUMB_INSET));
            const n = months.length;
            const idx = Math.max(0, Math.min(n - 1, Math.floor(relX / (trackWidth / n))));
            return { index: idx, month: months[idx], relX: relX + THUMB_INSET };
        }

        heatCanvas.addEventListener('mousemove', e => {
            const { month, relX } = monthFromX(e.clientX);
            heatTooltip.style.display = 'block';
            heatTooltip.style.left = relX + 'px';
            heatTooltip.textContent = month.label + ', ' + month.count + ' Notiz' + (month.count === 1 ? '' : 'en');
        });
        heatCanvas.addEventListener('mouseleave', () => { heatTooltip.style.display = 'none'; });
        heatCanvas.addEventListener('click', e => {
            const { month } = monthFromX(e.clientX);
            const endOfMonth = new Date(month.ts);
            endOfMonth.setMonth(endOfMonth.getMonth() + 1);
            endOfMonth.setTime(endOfMonth.getTime() - 1);
            currentTime = Math.min(maxTime, endOfMonth.getTime());
            const pct = (currentTime - minTime) / (maxTime - minTime);
            slider.value = Math.round(pct * 1000);
            applyTimeFilter();
        });

        window.addEventListener('resize', () => {
            drawHeatmap();
            if (graph3d && currentMode === '3d') graph3d.width(window.innerWidth).height(window.innerHeight - 50 - 70);
            // Sunburst: Radius skaliert mit Fensterbreite → bei Resize neu zeichnen
            if (sunburstState.initialized && currentMode === 'sunburst') {
                renderSunburst();
            }
            // Matrix: cellSize hängt vom verfügbaren Platz ab → neu zeichnen
            if (matrixState.initialized && currentMode === 'matrix') {
                renderMatrix();
            }
        });

        applyTimeFilter(); // Initial: alles sichtbar

        // ===========================================================
        //              Inkrementelles Data-Update (Slice 2f)
        // ===========================================================
        // Wird von Swift via WKWebView.evaluateJavaScript(
        //   "window.__applyDataUpdate({nodes, edges, folders, stats})"
        // ) aufgerufen, wenn der NoteStore-Watcher eine Änderung erkennt.
        //
        // Ziel: keinen Full-Reload der WebView, kein Force-Sim-Restart,
        // keine Fly-In-Animation. Stattdessen:
        //   - Diff: neue IDs, entfernte IDs, geänderte Knoten
        //   - Neue Knoten werden beim ersten bekannten Nachbarn gestartet
        //     (Fallback: Ordner-Centroid, sonst Canvas-Mitte)
        //   - d3 rebind via enter/update/exit behält DOM-Identität
        //   - Sanftes Reheat der Force-Simulation (alpha 0.3)
        //   - 3D: graph3d.graphData(...) diff-merged intern, Positionen
        //     existierender Knoten bleiben
        //   - Puls-Animation auf neuen Knoten (2.5s, drei Pulse, orange)
        //
        // State der im UI bleibt: Zoom/Pan (auf g-Element), Kamera (3D),
        // activeFolders, currentMode, currentTime/Slider, sel2d/sel3d (wenn
        // nicht gelöscht).
        window.__applyDataUpdate = function(newData) {
            try {
                // ---- 1) Stats-Zeile im Header ----
                const stats = newData.stats || {};
                document.getElementById('stats').innerHTML =
                    '<span><span class="stat-value">' + (stats.total || 0) + '</span> ' + (window.NM_LOC ? window.NM_LOC.statsNotes : 'Notes') + '</span>' +
                    '<span><span class="stat-value">' + (stats.edges || 0) + '</span> ' + (window.NM_LOC ? window.NM_LOC.statsLinks : 'Links') + '</span>' +
                    '<span><span class="stat-value">' + (stats.linked || 0) + '</span> ' + (window.NM_LOC ? window.NM_LOC.linked : 'linked') + '</span>' +
                    '<span><span class="stat-value">' + (stats.orphans || 0) + '</span> ' + (window.NM_LOC ? window.NM_LOC.statsOrphans : 'Orphans') + '</span>';

                // ---- 2) Diff gegen aktuelle 2D-Nodes ----
                const oldById = new Map(nodes2d.map(n => [n.id, n]));
                const newIdSet = new Set(newData.nodes.map(n => n.id));
                const addedIds = new Set();
                for (const nn of newData.nodes) {
                    if (!oldById.has(nn.id)) addedIds.add(nn.id);
                }

                // ---- 3) Startposition für neue Knoten berechnen ----
                // Strategie: erst beim ersten bekannten Nachbarn, sonst
                // Centroid bestehender Knoten im selben Ordner, sonst Mitte.
                const newPos = {};
                const existingFolderCentroid = {};
                {
                    const sums = {};
                    for (const o of oldById.values()) {
                        if (!sums[o.folder]) sums[o.folder] = {x:0, y:0, n:0};
                        sums[o.folder].x += o.x; sums[o.folder].y += o.y; sums[o.folder].n++;
                    }
                    for (const f in sums) {
                        if (sums[f].n === 0) continue;
                        existingFolderCentroid[f] = {x: sums[f].x/sums[f].n, y: sums[f].y/sums[f].n};
                    }
                }
                for (const nn of newData.nodes) {
                    if (!addedIds.has(nn.id)) continue;

                    // a) Erster Nachbar in neuen Edges, der schon existiert
                    const neighborEdge = newData.edges.find(e =>
                        (e.source === nn.id && oldById.has(e.target)) ||
                        (e.target === nn.id && oldById.has(e.source))
                    );
                    if (neighborEdge) {
                        const nbId = neighborEdge.source === nn.id ? neighborEdge.target : neighborEdge.source;
                        const nb = oldById.get(nbId);
                        newPos[nn.id] = {
                            x: nb.x + (Math.random() - 0.5) * 60,
                            y: nb.y + (Math.random() - 0.5) * 60
                        };
                        continue;
                    }

                    // b) Centroid des Ordners (falls er schon Knoten hat)
                    const c = existingFolderCentroid[nn.folder];
                    if (c) {
                        newPos[nn.id] = {
                            x: c.x + (Math.random() - 0.5) * 80,
                            y: c.y + (Math.random() - 0.5) * 80
                        };
                        continue;
                    }

                    // c) Fallback: Canvas-Mitte + Offset
                    newPos[nn.id] = {
                        x: width/2 + (Math.random() - 0.5) * 200,
                        y: height/2 + (Math.random() - 0.5) * 200
                    };
                }

                // ---- 4) data-Snapshot aktualisieren ----
                data.nodes = newData.nodes;
                data.edges = newData.edges;
                data.folders = newData.folders;
                data.stats = newData.stats;
                rebuildConnectedNodes();

                // ---- 5) 2D-Arrays in-place aktualisieren (Position erhalten) ----
                const next2dNodes = newData.nodes.map(n => {
                    const old = oldById.get(n.id);
                    if (old) {
                        return Object.assign({}, n, {
                            x: old.x, y: old.y,
                            vx: old.vx || 0, vy: old.vy || 0,
                            fx: old.fx, fy: old.fy
                        });
                    }
                    const p = newPos[n.id] || {x: width/2, y: height/2};
                    return Object.assign({}, n, {x: p.x, y: p.y, vx: 0, vy: 0});
                });
                nodes2d.length = 0;
                nodes2d.push(...next2dNodes);

                const next2dEdges = newData.edges.map(e => ({source: e.source, target: e.target}));
                edges2d.length = 0;
                edges2d.push(...next2dEdges);

                // ---- 6) Simulation reinitialisieren + dezent reheaten ----
                sim.nodes(nodes2d);
                sim.force('link', d3.forceLink(edges2d).id(d => d.id).distance(200).strength(0.3));

                // ---- 7) d3-Selections rebinden ----
                bind2d();

                // Layout-spezifisches Re-Settle. Bei Radial/Radial 2 darf die
                // Force-Simulation nicht aufheizen, sonst fliegen alle
                // fixierten Knoten auseinander. Stattdessen das passende
                // Radial-Layout neu berechnen, damit neue Notizen auch einen
                // Sektor-Platz bekommen.
                if (currentLayout === 'radial') {
                    applyRadialLayout();
                } else if (currentLayout === 'radial2') {
                    applyRadial2Layout();
                } else {
                    sim.alpha(0.3).restart();
                }

                // Falls ausgewählter Knoten gelöscht → Selektion freigeben
                if (sel2d && !newIdSet.has(sel2d.id)) {
                    sel2d = null; clearHighlight2d(); hidePanel();
                }

                // ---- 8) 3D-Graph aktualisieren, falls initialisiert ----
                if (graph3d) {
                    const existing3d = graph3d.graphData().nodes;
                    const existing3dById = new Map(existing3d.map(n => [n.id, n]));

                    // 3D-Position für neue Knoten (analog 2D-Logik)
                    const new3dPos = {};
                    {
                        const sums = {};
                        for (const o of existing3dById.values()) {
                            if (!sums[o.folder]) sums[o.folder] = {x:0, y:0, z:0, n:0};
                            sums[o.folder].x += (o.x||0); sums[o.folder].y += (o.y||0); sums[o.folder].z += (o.z||0); sums[o.folder].n++;
                        }
                        const centroids = {};
                        for (const f in sums) {
                            if (sums[f].n === 0) continue;
                            centroids[f] = {x: sums[f].x/sums[f].n, y: sums[f].y/sums[f].n, z: sums[f].z/sums[f].n};
                        }
                        for (const nn of newData.nodes) {
                            if (!addedIds.has(nn.id)) continue;
                            const ne = newData.edges.find(e =>
                                (e.source === nn.id && existing3dById.has(e.target)) ||
                                (e.target === nn.id && existing3dById.has(e.source))
                            );
                            if (ne) {
                                const nbId = ne.source === nn.id ? ne.target : ne.source;
                                const nb = existing3dById.get(nbId);
                                new3dPos[nn.id] = {
                                    x: (nb.x||0) + (Math.random()-0.5) * 60,
                                    y: (nb.y||0) + (Math.random()-0.5) * 60,
                                    z: (nb.z||0) + (Math.random()-0.5) * 60
                                };
                                continue;
                            }
                            const c = centroids[nn.folder];
                            if (c) {
                                new3dPos[nn.id] = {
                                    x: c.x + (Math.random()-0.5) * 80,
                                    y: c.y + (Math.random()-0.5) * 80,
                                    z: c.z + (Math.random()-0.5) * 80
                                };
                                continue;
                            }
                            new3dPos[nn.id] = {
                                x: (Math.random()-0.5) * 200,
                                y: (Math.random()-0.5) * 200,
                                z: (Math.random()-0.5) * 200
                            };
                        }
                    }

                    const next3d = newData.nodes.map(n => {
                        const old = existing3dById.get(n.id);
                        if (old) {
                            return Object.assign({}, n, {
                                x: old.x, y: old.y, z: old.z,
                                vx: old.vx, vy: old.vy, vz: old.vz
                            });
                        }
                        const p = new3dPos[n.id] || {x:0, y:0, z:0};
                        return Object.assign({}, n, {x: p.x, y: p.y, z: p.z});
                    });
                    graph3d.graphData({
                        nodes: next3d,
                        links: newData.edges.map(e => ({source: e.source, target: e.target}))
                    });
                }

                // ---- 8b) Circos neu rendern (falls initialisiert) ----
                // Circos zeichnet sich aus data.nodes/data.edges frisch auf.
                // Kein animierter Übergang, ein harter Rebuild ist bei 1200
                // Knoten ausreichend schnell und vermeidet Positions-Chaos
                // wenn sich Ordnergröße → Sektorbreite ändert.
                if (circosState.initialized) {
                    renderCircos();
                }

                // ---- 8c) Calendar neu rendern (falls initialisiert) ----
                // Full-Rebuild, bei ~1200 Notizen <30ms, und neue Notizen
                // müssen im Grid an ihrer Tages-Zelle aufleuchten.
                if (calendarState.initialized) {
                    renderCalendar();
                }

                // ---- 8d) Monthly-Heatmap neu rendern ----
                if (monthlyState.initialized) {
                    renderMonthly();
                }

                // ---- 8e) Sunburst neu rendern (Focus-Pfad wird nach Namen
                //         gemappt, siehe renderSunburst) ----
                if (sunburstState.initialized) {
                    renderSunburst();
                }

                // ---- 8f) Adjazenz-Matrix neu rendern ----
                if (matrixState.initialized) {
                    renderMatrix();
                }

                // ---- 8g) Heightmap invalidieren ----
                // Neue Notizen → neue Embeddings nötig. Die bestehende
                // Projektion passt nicht mehr zu data.nodes, also forcen wir
                // einen Neubau beim nächsten "Höhenkarte"-Klick. Wenn User
                // gerade IN der Heightmap ist, zeigen wir sofort das Overlay
                // und holen neue Embeddings (inkrementell via Cache, schnell).
                if (heightmapState.initialized) {
                    heightmapState.dataReady = false;
                    heightmapState.coords = null;
                    heightmapState.embeddings = null;
                    heightmapState.svg.selectAll('circle').remove();
                    heightmapState.ctx.clearRect(0, 0, heightmapState.canvas.width, heightmapState.canvas.height);

                    // 3D-Scene ebenfalls invalidieren: Terrain + Instances
                    // verwerfen, Anim stoppen. Bei nächstem Build wird alles
                    // aus den neuen coords/nodes frisch aufgebaut.
                    if (heightmap3dState.built) {
                        stopHeightmap3dAnim();
                        try {
                            if (heightmap3dState.terrain) {
                                heightmap3dState.scene.remove(heightmap3dState.terrain);
                                heightmap3dState.terrain.geometry.dispose();
                                heightmap3dState.terrain.material.dispose();
                                heightmap3dState.terrain = null;
                            }
                            if (heightmap3dState.notes) {
                                heightmap3dState.scene.remove(heightmap3dState.notes);
                                heightmap3dState.notes.geometry.dispose();
                                heightmap3dState.notes.material.dispose();
                                heightmap3dState.notes = null;
                            }
                            if (heightmap3dState.labelsDOM) {
                                heightmap3dState.labelsDOM.remove();
                                heightmap3dState.labelsDOM = null;
                                heightmap3dState.peaks = null;
                            }
                        } catch (_) {}
                        heightmap3dState.points = [];
                        heightmap3dState.built = false;
                    }

                    if (currentMode === 'heightmap') {
                        heightmapState.requested = false;
                        // Erneut anstoßen, Cache deckt die alten Notizen sofort ab.
                        initHeightmap();
                    }
                }

                // ---- 9) Legende + Tags + Timeline neu ----
                rebuildLegend();
                rebuildTagList();
                recomputeTimeline();

                // ---- 10) Filter wieder anwenden ----
                applyNodeFilters();
                applyTimeFilter();

                // ---- 11) Puls-Animation ----
                pulseNewNodes(addedIds);

                // ---- 12) Spinner am Refresh-Button abschalten ----
                const btn = document.getElementById('btn-refresh');
                if (btn) btn.classList.remove('spinning');
            } catch (e) {
                console.error('[__applyDataUpdate] Fehler:', e);
                const btn = document.getElementById('btn-refresh');
                if (btn) btn.classList.remove('spinning');
            }
        };

        // Puls-Animation für neu eingefügte Knoten. 2D: d3-Transition auf
        // den SVG-Kreisen (Radius + Stroke). 3D: pulseExpire-Map setzt
        // pulseMul/isPulsing auf true, der Ticker refresht die nodeVal/
        // nodeColor-Caches periodisch.
        function pulseNewNodes(addedIds) {
            if (!addedIds || addedIds.size === 0) return;

            // 2D-Pulse, egal ob gerade sichtbar oder nicht, wir animieren
            // immer; falls User gerade 3D anschaut, sieht er die 2D-Puls
            // beim Wechsel nicht mehr, das ist OK.
            for (const id of addedIds) {
                const sel = node2d.filter(d => d.id === id).select('circle');
                if (sel.empty()) continue;
                const datum = sel.datum();
                const origR = nodeRadius(datum);
                const peakR = Math.max(origR * 3, 14);
                sel
                    .attr('stroke', '#ffb84d').attr('stroke-width', 3)
                    .transition().duration(350).attr('r', peakR)
                    .transition().duration(300).attr('r', origR * 1.4)
                    .transition().duration(300).attr('r', peakR * 0.9)
                    .transition().duration(500).attr('r', origR)
                    .attr('stroke', '#1a1a2e').attr('stroke-width', 1.5);
            }

            // 3D-Pulse, via pulseExpire + Ticker
            if (graph3d) {
                const until = performance.now() + PULSE_DURATION_MS;
                for (const id of addedIds) pulseExpire.set(id, until);
                graph3d.nodeVal(graph3d.nodeVal()).nodeColor(graph3d.nodeColor());
                startPulseTickerIfNeeded();
            }
        }
        })();
        </script>
        </body>
        </html>
        """#
        .replacingOccurrences(of: "__D3_SCRIPT__", with: d3Script)
        .replacingOccurrences(of: "__FORCE_GRAPH_3D_SCRIPT__", with: forceGraph3dScript)
        .replacingOccurrences(of: "__UMAP_SCRIPT__", with: umapScript)
        .replacingOccurrences(of: "__THREE_SCRIPT__", with: threeScript)
        .replacingOccurrences(of: "__PAYLOAD__", with: payloadJSON)
        .replacingOccurrences(of: "__GENERATED_AT__", with: generatedAt)
        .replacingOccurrences(of: "__JS_LOCALE__", with: jsLocaleObject)
        .replacingOccurrences(of: "__JS_HELP__", with: helpJSON)
    }
}

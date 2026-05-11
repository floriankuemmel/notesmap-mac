// OllamaLabelService.swift: HTTP-Client für Ollama's `/api/generate`.
//
// Zweck: kurze thematische Labels für Berg-Cluster in der 3D-Höhenkarte.
// Pro Cluster kriegt das Modell ~8 Notiz-Titel + kurze Snippets und soll
// daraus ein 1-3-wörtiges Thema extrahieren ("Rezepte", "Urlaub Italien",
// "Haus-Sanierung").
//
// Modell: wir versuchen aus einer Präferenzliste das erste lokal verfügbare
// Modell zu finden. Das erspart dem User ein zusätzliches `ollama pull`:
// was auch immer schon da ist, wird verwendet. Bei keinem passenden Modell
// bekommt der User eine klare Fehlermeldung mit Pull-Hinweisen.
//
// Architektur: stateless, `Sendable`. LinkMapModel ruft für jeden Peak
// einen Task auf und propagiert die Resultate inkrementell an JS.

import Foundation

struct OllamaLabelService: Sendable {
    let baseURL: URL
    /// Wird beim ersten erfolgreichen `resolveModel` befüllt. Initial nil
    /// = "noch nicht bestimmt".
    let model: String?
    let timeout: TimeInterval

    /// Präferenzliste: Qualität-First für thematische Labels.
    /// gemma2:9b steht bewusst ganz vorne; es liefert für 1-3-Wort-Themen
    /// deutlich bessere deutsche Substantiv-Phrasen als die kleinen 1-3B-
    /// Varianten und läuft auf 16-32 GB-Macs noch komfortabel (~6 GB RAM).
    /// Danach mid-size Alternativen, dann schnelle Fallbacks für schwache
    /// Geräte. Die kaputten `gemma4:*`-Community-Builds (liefern leere
    /// Responses wegen defekter chat-template-Metadaten) stehen ganz am Ende.
    /// bge-m3 steht NICHT auf der Liste; das ist ein reines Embedding-Modell.
    static let preferredModels: [String] = [
        // Qualität-First: 1-3-Wort-Themen brauchen semantisches Verständnis,
        // nicht nur Geschwindigkeit. Diese drei liefern saubere Substantive.
        "gemma2:9b",
        "llama3.1:8b",
        "qwen2.5:7b",
        "gemma2:27b",
        // Schnelle kleine Modelle als Fallback. Reichen für kurze Labels,
        // falls der User nur begrenzt RAM hat (<16 GB).
        "llama3.2:3b",
        "llama3.2:1b",
        "qwen2.5:3b",
        "qwen2.5:1.5b",
        "gemma2:2b",
        "phi3.5",
        "mistral:7b",
        // Letzter Notnagel: gemma4-Builds. "gemma4" ist KEIN offizielles
        // Google-Release. Manche Community-Quantisierungen haben defekte
        // chat-template-Metadaten und liefern `response: ""` trotz eval_count>0.
        // Nur als allerletzte Option, wenn sonst nichts installiert ist.
        "gemma4:31b-it-q8_0",
        "gemma4:9b"
    ]

    init(
        baseURL: URL = URL(string: "http://localhost:11434")!,
        model: String? = nil,
        timeout: TimeInterval = 60
    ) {
        self.baseURL = baseURL
        self.model = model
        self.timeout = timeout
    }

    enum ServiceError: Error, LocalizedError, Sendable {
        case ollamaUnreachable(String)
        case noUsableModel([String])
        case httpError(Int, String)
        case decodingFailed
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .ollamaUnreachable(let reason):
                return "\(Localized.string(\.errOllamaUnreachable)) \(reason)"
            case .noUsableModel(let available):
                let hint = Localized.string(\.errNoModelHint)
                if available.isEmpty {
                    return String(format: Localized.string(\.errNoGenerativeModel), hint)
                }
                return String(format: Localized.string(\.errNoPreferredModel),
                              available.joined(separator: ", "), hint)
            case .httpError(let code, let body):
                return String(format: Localized.string(\.errOllamaHTTP), code, String(body.prefix(200)))
            case .decodingFailed:
                return Localized.string(\.errLabelDecodeFail)
            case .emptyResponse:
                return Localized.string(\.errEmptyResponse)
            }
        }
    }

    /// Eingabe für einen Cluster: einige Titel + kurze Snippets.
    struct ClusterSample: Sendable {
        let title: String
        let snippet: String
    }

    /// Fragt Ollama nach installierten Modellen und wählt das erste aus der
    /// `preferredModels`-Liste aus, das vorhanden ist. Fallback: wenn ein Modell
    /// explizit via `self.model` gesetzt wurde, wird das genommen (ohne Prüfung).
    /// Gibt den Modellnamen zurück ODER einen klaren Fehler.
    func resolveModel() async -> Result<String, ServiceError> {
        // Expliziter Override via Init-Parameter: nutze direkt, ohne Check.
        if let pinned = model, !pinned.isEmpty {
            return .success(pinned)
        }

        var req = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        req.timeoutInterval = 5
        req.httpMethod = "GET"

        struct TagResp: Decodable {
            struct Entry: Decodable { let name: String }
            let models: [Entry]
        }

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                return .failure(.ollamaUnreachable("Antwort != 200."))
            }
            let parsed = (try? JSONDecoder().decode(TagResp.self, from: data))
            let names = parsed?.models.map { $0.name } ?? []

            // Erster Treffer aus der Präferenzliste.
            for candidate in Self.preferredModels {
                for installed in names {
                    // "llama3.2:3b" matcht sowohl "llama3.2:3b" als auch
                    // "llama3.2:3b-latest" als auch "llama3.2:3b-foo".
                    if installed == candidate ||
                       installed.hasPrefix(candidate + "-") ||
                       installed.hasPrefix(candidate + ":") {
                        return .success(installed)
                    }
                }
            }

            // Nichts passt. Filter: bge-m3 ist nur embed, als Fallback ungeeignet.
            let generative = names.filter { !$0.lowercased().hasPrefix("bge-") &&
                                            !$0.lowercased().hasPrefix("nomic-embed") &&
                                            !$0.lowercased().hasPrefix("snowflake") }
            // Letzter Ausweg: irgendein generatives Modell nehmen, damit
            // wenigstens *etwas* passiert. Besser als stumm zu scheitern.
            if let fallback = generative.first {
                NSLog("[OllamaLabelService] Kein bevorzugtes Modell, benutze Fallback '\(fallback)'.")
                return .success(fallback)
            }

            return .failure(.noUsableModel(names))
        } catch {
            return .failure(.ollamaUnreachable(error.localizedDescription))
        }
    }

    /// Generiert ein kurzes Thema (1-3 Wörter) für einen Cluster.
    /// Gibt einen schon gesäuberten String zurück (ohne Quotes, ohne Trailing-Dots).
    /// - parameter modelName: vom `resolveModel()` ermittelter echter Modellname.
    func generateLabel(
        for samples: [ClusterSample],
        modelName: String
    ) async throws -> String {
        let prompt = Self.buildPrompt(samples: samples)

        var req = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct Req: Encodable {
            let model: String
            let prompt: String
            let stream: Bool
            let options: Options
            struct Options: Encodable {
                let temperature: Double
                // `num_predict` begrenzt die Token-Ausgabe. 20 ≈ ~15 Wörter, was
                // locker für 1-3 Wörter reicht und den Call konstant <1s hält.
                let num_predict: Int
                // Stop-Tokens: schützen gegen Modelle, die anfangen, die
                // Few-Shot-Beispiele fortzusetzen oder eine Erklärung zu liefern.
                // WICHTIG: KEIN einzelnes "\n"! Instruct-Modelle produzieren nach
                // dem Prompt-Ende sehr oft als ALLERERSTES Token einen Newline
                // (speziell gemma/llama3 nach "...:"). Mit "\n" als Stop-Token
                // kam dann eine leere Antwort zurück → alle Peaks stecken im
                // Fallback. Nur noch Doppel-Newline als Stop.
                let stop: [String]
            }
        }
        let body = Req(
            model: modelName,
            prompt: prompt,
            stream: false,
            options: Req.Options(
                temperature: 0.2,
                num_predict: 20,
                stop: ["\n\n", "Beispiel", "Notizen:", "Thema:"]
            )
        )
        req.httpBody = try JSONEncoder().encode(body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw ServiceError.ollamaUnreachable(Localized.string(\.errInvalidHTTP))
        }
        guard http.statusCode == 200 else {
            let s = String(data: data, encoding: .utf8) ?? ""
            throw ServiceError.httpError(http.statusCode, s)
        }

        struct Resp: Decodable { let response: String? }
        let r = try JSONDecoder().decode(Resp.self, from: data)
        guard let raw = r.response, !raw.isEmpty else {
            #if DEBUG
            NSLog("[OllamaLabelService] LEERE Antwort von '\(modelName)'. Stop-Token hat zu früh gegriffen?")
            #endif
            throw ServiceError.emptyResponse
        }
        let cleaned = Self.sanitize(raw)
        // PRIVACY: das Roh-Output des LLMs basiert auf realem Notiz-Inhalt und kann
        // Themen oder Stichwörter aus privaten Notizen enthalten. NSLog landet im
        // System-Log (Console.app), wo es andere Admin-Prozesse auslesen können.
        // Daher nur in Debug-Builds loggen, in der Release-Version wandert nichts
        // mehr in den System-Log.
        #if DEBUG
        let rawShort = raw.count > 200 ? String(raw.prefix(200)) + "…" : raw
        NSLog("[OllamaLabelService] raw='\(rawShort)' → '\(cleaned)'")
        #endif
        return cleaned
    }

    // MARK: - Prompt / Sanitize

    static func buildPrompt(samples: [ClusterSample]) -> String {
        // Knapp-präziser Prompt auf Deutsch mit zwei Few-Shot-Beispielen. Die
        // Beispiele zeigen dem Modell, was wir wollen (Substantiv-Thema, keine
        // Füllwörter, keine Anführungszeichen, keine Erklärung). Temperature
        // niedrig → konsistenter.
        //
        // Zusätzlich: statt nur Titel listen wir "Titel — Snippet". Kurze
        // Titel allein ("Notiz", "Test", "Meeting") reichen dem Modell oft
        // nicht zum Clustern, ein paar Wörter Kontext helfen massiv.
        let listing = samples.prefix(8).enumerated().map { _, s -> String in
            let t = s.title.replacingOccurrences(of: "\n", with: " ")
            let sn = s.snippet.replacingOccurrences(of: "\n", with: " ")
            let trimmedSn = sn.count > 140 ? String(sn.prefix(140)) + "…" : sn
            if trimmedSn.isEmpty {
                return "- \(t)"
            }
            return "- \(t) — \(trimmedSn)"
        }.joined(separator: "\n")

        // Prompt endet bewusst auf "Thema: " (mit Leerzeichen, OHNE Newline).
        // Grund: Instruct-Modelle produzieren nach einem Doppelpunkt+Newline
        // sehr oft als allererstes Token nochmal einen Newline; und wenn
        // das als Stop-Token konfiguriert ist, kommt eine leere Antwort.
        // Mit Leerzeichen kann das Modell direkt mit dem ersten Wort starten.
        let body = """
        Du bist Kurator einer Notiz-Sammlung. Du bekommst einige Apple-Notizen, \
        die thematisch zusammengehören. Finde das gemeinsame Oberthema und \
        beschreibe es in 1 bis 3 deutschen Substantiven.

        Regeln:
        - Nur Substantive oder konkrete Themen, keine Verben, keine Füllwörter.
        - Keine Artikel (kein "Die", "Das", "Der").
        - Keine Anführungszeichen, keine Erklärung, kein Punkt am Ende.
        - Nur das Thema selbst — sonst nichts.

        Beispiel 1:
        Notizen:
        - Pasta Carbonara — Spaghetti, Speck, Eigelb, Pecorino
        - Pizzateig Grundrezept — 500g Mehl, 300ml Wasser, Hefe
        - Apfelkuchen Blech — Mürbteig mit Zimt
        Thema: Rezepte

        Beispiel 2:
        Notizen:
        - Hotel Rom — Check-in 3.Juni, Nähe Vatikan
        - Flug MUC-FCO — 14:30 Abflug, Sitz 12A
        - Colosseum Tickets — online buchen
        Thema: Italien-Urlaub

        Jetzt du:
        Notizen:
        \(listing)
        Thema:
        """
        // Triple-quoted String endet mit einem \n vor den schließenden """.
        // Wir trimmen das weg und hängen ein Leerzeichen an, damit das Modell
        // direkt nach "Thema: " sein Wort generiert und keinen Newline als
        // erstes Token produziert (das wäre bei gemma/llama3 sehr häufig).
        return body.trimmingCharacters(in: .whitespacesAndNewlines) + " "
    }

    static func sanitize(_ raw: String) -> String {
        // 1. Leerzeichen + Newlines trimmen, nur erste Zeile behalten.
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let nl = s.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            s = String(s[..<nl])
        }
        s = s.trimmingCharacters(in: .whitespaces)

        // 2. Markdown-Emphasis entfernen: gemma2 und llama3 lieben es, die
        // Antwort in **bold** zu wrappen ("Das Thema könnte **italienische
        // Küche** sein."). Wir ziehen alle Marker raus, Content behalten.
        s = s.replacingOccurrences(of: "**", with: "")
        s = s.replacingOccurrences(of: "__", with: "")

        // 3. Quote-Extraction: wenn die Antwort sowas wie
        // `Das Thema könnte "italienische Küche" sein.` enthält, ist der
        // Inhalt innerhalb der Anführungszeichen fast immer die eigentliche
        // Antwort; das Modell emphasiert damit das Thema. Wir greifen das
        // erste Quote-Paar und nehmen den Inhalt, wenn er plausibel kurz ist.
        if let quoted = extractQuotedContent(s) {
            s = quoted
        }

        // 4. Führende/abschließende Quotes, Klammern, Backticks, Sterne wegräumen.
        let junk: Set<Character> = ["\"", "'", "`", "„", "“", "”", "«", "»",
                                    "(", ")", "[", "]", "{", "}", "*", "_"]
        while let first = s.first, junk.contains(first) {
            s.removeFirst()
        }
        while let last = s.last, junk.contains(last) {
            s.removeLast()
        }

        // 5. Trailing-Punkte/Satzzeichen entfernen (Modelle lieben die).
        let trailingPunct: Set<Character> = [".", ":", ";", "—", "-", "–", "!", "?", ","]
        while let last = s.last, trailingPunct.contains(last) {
            s.removeLast()
        }
        s = s.trimmingCharacters(in: .whitespaces)

        // 6. Häufige Präambeln entfernen, erweitert um alle gemma2:9b /
        // llama3 / qwen-Varianten, die wir in der Praxis gesehen haben.
        // Reihenfolge wichtig: lange Prefixe zuerst, sonst matcht "das thema"
        // bevor "das thema könnte" dran kommt.
        let prefixes = [
            "gemeinsames thema ist", "gemeinsames thema lautet",
            "gemeinsames thema:",
            "das gemeinsame thema ist", "das gemeinsame thema lautet",
            "das gemeinsame thema:",
            "das thema könnte", "das thema wäre", "das thema lautet",
            "das thema ist", "das thema sein",
            "das thema:", "das oberthema:",
            "mögliches thema ist", "mögliches thema", "ein mögliches thema",
            "mein vorschlag", "vorschlag:",
            "oberthema ist", "oberthema:",
            "thema lautet", "thema wäre", "thema ist", "thema:",
            "antwort:", "titel:",
            "topic is", "topic:", "the theme is",
            "das wäre", "das ist"
        ]
        let lower = s.lowercased()
        for p in prefixes {
            if lower.hasPrefix(p) {
                s = String(s.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        while let first = s.first, junk.contains(first) || first == "-" || first == "—" {
            s.removeFirst()
        }
        s = s.trimmingCharacters(in: .whitespaces)

        // 7. Trailing-Füllwörter: "X sein" / "X wäre" / "X ist" abschneiden.
        // Modelle schreiben "italienische Küche sein" statt nur "italienische Küche".
        let trailingWords = [" sein.", " sein", " wäre.", " wäre",
                             " ist.", " ist", " wären"]
        let sLow = s.lowercased()
        for tw in trailingWords {
            if sLow.hasSuffix(tw) {
                s = String(s.dropLast(tw.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        // Nach dem Trim nochmal trailing-punct/junk abräumen.
        while let last = s.last, trailingPunct.contains(last) || junk.contains(last) {
            s.removeLast()
        }
        s = s.trimmingCharacters(in: .whitespaces)

        // 8. Auf max. 60 Zeichen begrenzen (Safety-Cap gegen langatmige Modelle).
        // Wichtig: am letzten Leerzeichen vor Position 60 schneiden, damit
        // wir nicht mitten in einem Wort landen ("Kommunikation" → "Komm").
        // Nur wenn überhaupt kein Leerzeichen existiert (sehr selten: ein
        // einziges langes Wort), fallen wir auf Hard-Cut zurück.
        if s.count > 60 {
            let hardLimit = s.index(s.startIndex, offsetBy: 60)
            let candidate = String(s[s.startIndex..<hardLimit])
            if let lastSpace = candidate.lastIndex(of: " ") {
                s = String(candidate[..<lastSpace])
                    .trimmingCharacters(in: .whitespaces)
            } else {
                s = candidate.trimmingCharacters(in: .whitespaces)
            }
        }
        return s
    }

    /// Sucht das erste Quote-Paar und extrahiert den Inhalt, wenn er
    /// plausibel kurz ist (1-50 Zeichen, nicht leer). Gibt `nil` zurück,
    /// wenn kein Quote-Paar gefunden wird oder der Inhalt unsinnig ist.
    /// Unterstützte Paare: `"X"`, `„X"`, `»X«`, `'X'`, `‚X'`, gerade + smart.
    private static func extractQuotedContent(_ s: String) -> String? {
        let openChars: Set<Character> = ["\"", "„", "“", "«", "'", "‚", "‘"]
        let closeChars: Set<Character> = ["\"", "”", "“", "»", "'", "’"]
        guard let openIdx = s.firstIndex(where: { openChars.contains($0) }) else {
            return nil
        }
        let afterOpen = s.index(after: openIdx)
        guard afterOpen < s.endIndex else { return nil }
        // Nach dem ersten Quote: nächsten Schließer finden.
        guard let closeIdx = s[afterOpen...].firstIndex(where: { closeChars.contains($0) }) else {
            return nil
        }
        let inner = String(s[afterOpen..<closeIdx])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Plausibilitätscheck: nicht leer, nicht absurd lang.
        // 50 Zeichen lassen Raum für "italienische Küche & Wein-Reisen" o.ä.
        if inner.isEmpty || inner.count > 50 { return nil }
        return inner
    }
}

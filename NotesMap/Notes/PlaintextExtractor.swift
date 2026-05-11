// PlaintextExtractor.swift: Apple-Notes-Notiz-Plaintext aus gzip-Protobuf ziehen.
//
// Pipeline:
//   1. gunzip(ZDATA) → Protobuf-Bytes
//   2. Alle length-delimited Felder sammeln (rekursiv)
//   3. UTF-8-decodieren, nur "echte" Plaintext-Strings behalten (Heuristik)
//   4. Längsten Kandidaten wählen, Control-Chars + U+FFFC/FFFD strippen
//
// Rationale für den "längsten String": Apple Notes speichert den eigentlichen
// Notiz-Text als ein großes Textfeld. Font-Namen, UUIDs, Attachment-Platzhalter
// etc. sind alle kürzer.

import Foundation

enum PlaintextExtractor {

    /// Extrahiert den Klartext einer Notiz aus ihrem ZDATA-Blob.
    /// Leerer String bei Fehler / Bild-only-Notizen.
    static func extract(from zdata: Data) -> String {
        guard let decompressed = GzipDecoder.decompress(zdata) else { return "" }

        let fields = ProtobufReader.collectLengthDelimitedFields(decompressed)

        let candidates: [String] = fields.compactMap { payload -> String? in
            guard payload.count >= 2,
                  let text = String(data: payload, encoding: .utf8),
                  text.count >= 2,
                  isLikelyPlaintext(text)
            else { return nil }
            return text
        }

        guard let longest = candidates.max(by: { $0.count < $1.count }) else { return "" }
        let cleaned = cleanup(longest)

        // Nach dem Strip sind Notizen mit reinen Attachments/Hashtags/Links
        // praktisch leer. Zu wenig Buchstaben → als "kein Text" behandeln.
        let letters = countMatches(letterRegex, cleaned)
        return letters >= 3 ? cleaned : ""
    }

    // MARK: - Heuristik: "echter" Plaintext?

    // Pre-compiled Regex-Patterns (throws mit try! weil Konstanten validiert sind)
    private static let uuidRegex = try! NSRegularExpression(
        pattern: "^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$",
        options: [.caseInsensitive]
    )
    private static let mimeRegex = try! NSRegularExpression(
        pattern: "^(public|com\\.apple)\\."
    )
    private static let fontNameRegex = try! NSRegularExpression(
        pattern: "^[A-Z][a-zA-Z]+(-[A-Z][a-zA-Z]+)*$"
    )
    private static let hexColorRegex = try! NSRegularExpression(
        pattern: "^[0-9a-f]{6,}$",
        options: [.caseInsensitive]
    )
    private static let letterRegex = try! NSRegularExpression(
        pattern: "[a-zA-ZäöüßÄÖÜ]"
    )
    private static let goodCharRegex = try! NSRegularExpression(
        pattern: "[a-zA-ZäöüßÄÖÜ0-9\\s.,!?;:()\\[\\]\"'\\-–—\\n]"
    )

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    private static func countMatches(_ regex: NSRegularExpression, _ text: String) -> Int {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.numberOfMatches(in: text, options: [], range: range)
    }

    private static func isLikelyPlaintext(_ text: String) -> Bool {
        if matches(uuidRegex, text) { return false }
        if matches(mimeRegex, text) { return false }
        if text.count < 40 && matches(fontNameRegex, text) { return false }
        if matches(hexColorRegex, text) { return false }

        let letters = countMatches(letterRegex, text)
        if letters < 2 { return false }

        let good = countMatches(goodCharRegex, text)
        return Double(good) / Double(text.count) >= 0.7
    }

    // MARK: - Cleanup

    // ICU-Regex kennt `\u{…}` nicht; wir fügen die Zeichen direkt als
    // Unicode-Skalare ein (Swift-String-Literal-Interpolation).
    private static let cleanupControlChars = try! NSRegularExpression(
        pattern: "[\u{0000}-\u{0008}\u{000B}\u{000C}\u{000E}-\u{001F}\u{007F}-\u{009F}]"
    )
    private static let cleanupReplacementChars = try! NSRegularExpression(
        pattern: "[\u{FFFC}\u{FFFD}]"
    )
    // Inline-Attachment-Platzhalter: optional "$" oder "(", dann UUID.
    // Apple Notes speichert $<UUID> als Platzhalter für PDFs/Links/Hashtags.
    private static let inlineUuidRegex = try! NSRegularExpression(
        pattern: "[\\$\\(\\)]?[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}",
        options: [.caseInsensitive]
    )
    // Inline-MIME-Typen wie `com.apple.notes.inlinetextattachment.hashtag`
    // oder `public.jpeg`.
    private static let inlineMimeRegex = try! NSRegularExpression(
        pattern: "(?:public|com\\.apple)\\.[a-zA-Z0-9.\\-]+"
    )
    private static let cleanupWhitespace = try! NSRegularExpression(
        pattern: "\\s+"
    )
    // Leere Klammern und vereinzelte Satzzeichen-Reste, die nach dem UUID-Strip
    // übrig bleiben (z.B. "()" oder ", ,").
    private static let junkPunctuationRegex = try! NSRegularExpression(
        pattern: "\\(\\s*\\)|(?:[,;:]\\s*){2,}|^\\s*[,;:.]+|\\s+[,;:]\\s*"
    )

    private static func cleanup(_ text: String) -> String {
        var result = text
        result = replace(result, regex: cleanupControlChars, with: " ")
        result = replace(result, regex: cleanupReplacementChars, with: "")
        result = replace(result, regex: inlineUuidRegex, with: " ")
        result = replace(result, regex: inlineMimeRegex, with: " ")
        result = replace(result, regex: junkPunctuationRegex, with: " ")
        result = replace(result, regex: cleanupWhitespace, with: " ")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replace(_ text: String, regex: NSRegularExpression, with template: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}

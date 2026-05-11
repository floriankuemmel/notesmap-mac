// LocalizationParityTests.swift, Sicherheitsnetz für Localized.swift.
//
// Verifiziert, dass jeder T2-Eintrag (de, en) in der Localized-Struktur
// folgende Eigenschaften hat:
// - Beide Sprachen sind nicht leer (kein Placeholder vergessen)
// - Whitespace-only zählt als leer
// - Format-Specifier (%d, %@, %s, %f, %lld, %.Nf etc.) treten in beiden
//   Versionen mit derselben Häufigkeit auf, sonst crasht String(format:)
//   zur Laufzeit, wenn der User auf eine Sprache umschaltet
//
// Greift NICHT durch wenn beide Sprachen identisch sind, das ist okay
// für proper nouns ("Ollama"), Sprach-Codes ("API", "OK"), Markennamen.
//
// Bauen + ausführen: ⌘U in Xcode oder
//   xcodebuild test -project NotesMap.xcodeproj -scheme NotesMap -destination 'platform=macOS'

import Testing
import Foundation
@testable import NotesMap

@Suite("Localized parity (DE/EN coverage)")
struct LocalizationParityTests {

    /// Enumeriert alle T2-Eintragspaare via Mirror. Wenn ein neuer T2 zu
    /// Localized.swift hinzugefügt wird, fließt er automatisch in die Tests.
    private static func allT2Entries() -> [(label: String, de: String, en: String)] {
        let mirror = Mirror(reflecting: Localized())
        var out: [(label: String, de: String, en: String)] = []
        for child in mirror.children {
            guard let label = child.label else { continue }
            // T2 ist ein Tupel (String, String). Dynamic cast funktioniert.
            if let pair = child.value as? (String, String) {
                out.append((label: label, de: pair.0, en: pair.1))
            }
        }
        return out
    }

    @Test("Es gibt mindestens 100 lokalisierte Strings (Sanity-Check)")
    func minimumEntries() {
        let entries = Self.allT2Entries()
        // Stand 2026-04: ~250 Einträge. 100 als untere Schranke ist großzügig
        // genug, um nicht ständig bei Erweiterungen anzuschlagen, aber fängt
        // ab wenn jemand versehentlich die halbe Tabelle löscht.
        #expect(entries.count >= 100,
                "Localized scheint stark geschrumpft zu sein, nur \(entries.count) Einträge gefunden")
    }

    @Test("Jeder Eintrag hat eine nicht-leere deutsche Übersetzung")
    func germanNotEmpty() {
        for entry in Self.allT2Entries() {
            #expect(!entry.de.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "Deutsche Übersetzung für '\(entry.label)' ist leer")
        }
    }

    @Test("Jeder Eintrag hat eine nicht-leere englische Übersetzung")
    func englishNotEmpty() {
        for entry in Self.allT2Entries() {
            #expect(!entry.en.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "Englische Übersetzung für '\(entry.label)' ist leer")
        }
    }

    @Test("Format-Specifier zählen sind identisch in beiden Sprachen")
    func formatSpecifiersMatch() {
        // Matched alle Standard-Format-Specifier, die in der App vorkommen:
        // %d, %@, %s, %f, %lld, %.2f, %1$@, %2$d etc. Die Position-Marker
        // (1$, 2$) sind nicht zwingend identisch zwischen Sprachen, weil
        // deutsche und englische Reihenfolge unterschiedlich sein kann.
        // Wir zählen daher nur Anzahl + Typ, nicht Position.
        let pattern = #"%(?:\d+\$)?[\-+0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|L|z|t|j)?[diouxXeEfgGsScCpaA@]"#
        let regex = try! NSRegularExpression(pattern: pattern)

        for entry in Self.allT2Entries() {
            let deCount = regex.numberOfMatches(
                in: entry.de, range: NSRange(entry.de.startIndex..., in: entry.de))
            let enCount = regex.numberOfMatches(
                in: entry.en, range: NSRange(entry.en.startIndex..., in: entry.en))
            #expect(deCount == enCount,
                    "Format-Specifier-Anzahl für '\(entry.label)' ungleich: DE=\(deCount) ('\(entry.de)') vs. EN=\(enCount) ('\(entry.en)')")
        }
    }

    @Test("Format-Specifier-Typen sind identisch in beiden Sprachen")
    func formatSpecifierTypesMatch() {
        // Ein zusätzlicher Härtetest: nicht nur Anzahl, sondern auch die
        // Typen (Set aus den verwendeten Typ-Buchstaben). Verhindert dass
        // jemand DE %d mit EN %s übersetzt, beide hätten 1× Specifier,
        // aber String(format: "...%s...", 42) crasht.
        let pattern = #"%(?:\d+\$)?[\-+0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|L|z|t|j)?([diouxXeEfgGsScCpaA@])"#
        let regex = try! NSRegularExpression(pattern: pattern)

        func types(in s: String) -> [Character] {
            let nsString = s as NSString
            let matches = regex.matches(in: s, range: NSRange(location: 0, length: nsString.length))
            return matches.compactMap { match -> Character? in
                guard match.numberOfRanges >= 2 else { return nil }
                let range = match.range(at: 1)
                guard range.location != NSNotFound else { return nil }
                let substr = nsString.substring(with: range)
                return substr.first
            }.sorted()
        }

        for entry in Self.allT2Entries() {
            let deTypes = types(in: entry.de)
            let enTypes = types(in: entry.en)
            #expect(deTypes == enTypes,
                    "Format-Specifier-Typen für '\(entry.label)' weichen ab: DE=\(deTypes) vs. EN=\(enTypes)")
        }
    }

    @Test("Jeder Eintrag-Label ist eindeutig (keine doppelten property-Namen)")
    func labelsAreUnique() {
        let entries = Self.allT2Entries()
        let labels = entries.map(\.label)
        let unique = Set(labels)
        #expect(labels.count == unique.count,
                "Doppelte Property-Labels in Localized: \(labels.count - unique.count) Duplikate")
    }
}

@Suite("ViewHelp parity (DE/EN coverage)")
struct ViewHelpParityTests {

    /// Lädt JSON-Dump für eine Sprache und parsed sie, dann zählen wir
    /// die enthaltenen View-Keys. DE und EN müssen dieselben Keys haben.
    private func keysFor(_ lang: Localized.Lang) -> Set<String> {
        let json = ViewHelp.allAsJSON(in: lang)
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return Set(parsed.keys)
    }

    @Test("DE und EN haben dieselben View-Keys")
    func sameKeys() {
        let de = keysFor(.de)
        let en = keysFor(.en)
        #expect(de == en,
                "ViewHelp-Keys ungleich: DE-only=\(de.subtracting(en)), EN-only=\(en.subtracting(de))")
    }

    @Test("Mindestens 8 Views sind dokumentiert")
    func minimumViews() {
        let de = keysFor(.de)
        // Stand: 10 Views (2d, radial, radial2, sphere, matrix, sunburst, calendar,
        // timeline, heatmap, heightmap). 8 als untere Schranke.
        #expect(de.count >= 8,
                "ViewHelp scheint Views verloren zu haben, nur \(de.count) gefunden")
    }
}

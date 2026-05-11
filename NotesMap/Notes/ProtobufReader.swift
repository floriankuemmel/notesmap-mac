// ProtobufReader.swift: minimaler Protobuf-Wire-Format-Scanner.
//
// Wir parsen KEIN konkretes .proto-Schema. Stattdessen sammeln wir rekursiv
// alle length-delimited Felder (wire type 2) und geben sie als Bytes zurück.
// Die Apple-Notes-Protobuf-Struktur ist reverse-engineered und nicht öffentlich,
// aber der Plaintext liegt als UTF-8-String in einem wire-type-2-Feld.
//
// Strategie (wie im TS-Referenzprojekt):
// 1. Scanne Top-Level-Message Byte für Byte
// 2. Für jedes Length-Delimited Feld: Payload sammeln
// 3. Wenn Payload wie eine Sub-Message aussieht → rekursiv reinscannen
// 4. Bei Parse-Fehlern: 1 Byte weiter, nicht abbrechen (robust gegen Müll)

import Foundation

enum ProtobufReader {

    /// Scannt ein Protobuf-Message und gibt alle length-delimited Payloads zurück,
    /// inkl. rekursiv aus verschachtelten Sub-Messages.
    static func collectLengthDelimitedFields(_ data: Data) -> [Data] {
        var result: [Data] = []
        collectRecursive(data, into: &result)
        return result
    }

    // MARK: - Implementation

    private static func collectRecursive(_ data: Data, into result: inout [Data]) {
        var i = data.startIndex
        let end = data.endIndex

        while i < end {
            let start = i

            guard let tag = readVarint(data, at: i) else { i += 1; continue }
            i += tag.bytesRead
            let wireType = tag.value & 0x07

            switch wireType {
            case 0:  // Varint
                guard let v = readVarint(data, at: i) else { i = start + 1; continue }
                i += v.bytesRead

            case 1:  // 64-bit fixed
                i += 8

            case 2:  // Length-delimited
                guard let len = readVarint(data, at: i),
                      len.value >= 0,
                      i + len.bytesRead + Int(len.value) <= end
                else { i = start + 1; continue }
                i += len.bytesRead
                let payloadRange = i..<(i + Int(len.value))
                let payload = data.subdata(in: payloadRange)
                result.append(payload)
                // Rekursion nur wenn's wie eine Sub-Message aussieht
                if len.value > 10 && looksLikeProtobuf(payload) {
                    collectRecursive(payload, into: &result)
                }
                i += Int(len.value)

            case 5:  // 32-bit fixed
                i += 4

            default:
                // Unbekannter Wire-Type → 1 Byte weiter
                i = start + 1
            }
        }
    }

    /// Liest einen Varint (max 10 Bytes) aus `data` ab `offset`.
    private static func readVarint(_ data: Data, at offset: Int) -> (value: UInt64, bytesRead: Int)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var o = offset
        let end = min(offset + 10, data.endIndex)

        while o < end {
            let byte = data[o]
            o += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                return (result, o - offset)
            }
            shift += 7
        }
        return nil
    }

    /// Heuristik: sieht das erste Byte wie ein gültiger Protobuf-Tag aus?
    private static func looksLikeProtobuf(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        let wireType = data[data.startIndex] & 0x07
        return wireType == 0 || wireType == 1 || wireType == 2 || wireType == 5
    }
}

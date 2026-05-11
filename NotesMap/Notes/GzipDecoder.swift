// GzipDecoder.swift, entpackt gzip-komprimierte Daten (wie sie in Apple Notes'
// ZDATA-Blobs stehen) über Apple's Compression-Framework.
//
// Problem: Compression.framework kann "raw deflate" (COMPRESSION_ZLIB-Constant),
// aber keine echten gzip-Streams (die haben 10-Byte-Header + CRC32-Trailer).
// Lösung: gzip-Header manuell strippen, deflate-Payload decoden.
//
// Gzip-Format (RFC 1952):
//   Offset 0-1:  Magic (0x1F 0x8B)
//   Offset 2:    Compression Method (0x08 = deflate)
//   Offset 3:    Flags (FTEXT|FHCRC|FEXTRA|FNAME|FCOMMENT)
//   Offset 4-7:  Modification Time
//   Offset 8:    Extra Flags
//   Offset 9:    OS
//   [optional extras abhängig von Flags]
//   [deflate-payload]
//   [CRC32 (4 Byte) + ISIZE (4 Byte)]

import Foundation
import Compression

enum GzipError: Error, LocalizedError {
    case notGzip
    case truncated
    case decompressionFailed

    var errorDescription: String? {
        let de = LanguagePreference.current.resolved == .de
        switch self {
        case .notGzip:
            return de ? "Daten sind kein gültiges gzip (Magic-Bytes fehlen)"
                      : "Data is not valid gzip (magic bytes missing)"
        case .truncated:
            return de ? "Gzip-Daten sind abgeschnitten" : "Gzip data is truncated"
        case .decompressionFailed:
            return de ? "Dekompression fehlgeschlagen" : "Decompression failed"
        }
    }
}

enum GzipDecoder {

    /// Entpackt einen gzip-Stream zu rohen Bytes.
    /// Gibt `nil` zurück bei Fehlern (statt zu werfen), passt zur defensiv-robusten
    /// Protobuf-Pipeline, wo einzelne Korrupte-Notizen nicht den Gesamt-Build abbrechen.
    static func decompress(_ data: Data) -> Data? {
        guard data.count > 18 else { return nil }  // 10 header + 8 trailer minimum

        // Magic check
        guard data[data.startIndex] == 0x1F,
              data[data.startIndex + 1] == 0x8B,
              data[data.startIndex + 2] == 0x08  // deflate
        else { return nil }

        let flags = data[data.startIndex + 3]
        var cursor = data.startIndex + 10

        // FEXTRA: 2-Byte Längenfeld + Payload
        if flags & 0x04 != 0 {
            guard cursor + 2 <= data.endIndex else { return nil }
            let xlen = Int(data[cursor]) | (Int(data[cursor + 1]) << 8)
            cursor += 2 + xlen
        }
        // FNAME: zero-terminated String
        if flags & 0x08 != 0 {
            while cursor < data.endIndex && data[cursor] != 0 { cursor += 1 }
            cursor += 1
        }
        // FCOMMENT: zero-terminated String
        if flags & 0x10 != 0 {
            while cursor < data.endIndex && data[cursor] != 0 { cursor += 1 }
            cursor += 1
        }
        // FHCRC: 2-Byte Header-CRC
        if flags & 0x02 != 0 {
            cursor += 2
        }

        guard cursor < data.endIndex - 8 else { return nil }
        let deflateStart = cursor
        let deflateEnd = data.endIndex - 8  // letzte 8 Bytes: CRC32 + ISIZE

        // ISIZE (letzte 4 Byte, little-endian) = dekomprimierte Größe mod 2^32.
        // Bei Apple-Notes-Daten typisch <<4GB, also zuverlässig.
        let isize = data.withUnsafeBytes { raw -> UInt32 in
            let ptr = raw.baseAddress!.advanced(by: data.endIndex - 4 - data.startIndex)
            return ptr.assumingMemoryBound(to: UInt32.self).pointee
        }
        // Puffer großzügig dimensionieren, falls ISIZE ungenau ist (selten).
        let targetSize = max(Int(isize), deflateEnd - deflateStart) * 4 + 1024

        return data.subdata(in: deflateStart..<deflateEnd).withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data? in
            guard let src = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: targetSize)
            defer { dst.deallocate() }

            let written = compression_decode_buffer(
                dst, targetSize,
                src, raw.count,
                nil,
                COMPRESSION_ZLIB
            )
            guard written > 0 else { return nil }
            return Data(bytes: dst, count: written)
        }
    }
}

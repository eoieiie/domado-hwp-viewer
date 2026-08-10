import Compression
import Foundation

/// Minimal read-only ZIP reader.
///
/// `.hwpx` is a zip package, and Foundation has no zip API. Rather than take a
/// dependency (or shell out to `/usr/bin/unzip`) we read the central directory
/// ourselves and reuse the same raw-DEFLATE path the classic .hwp body uses.
struct ZipArchive {
    struct Entry {
        let name: String
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private let data: Data
    private(set) var entries: [Entry] = []

    init?(data: Data) {
        guard data.count > 22 else { return nil }
        self.data = data

        // End of Central Directory: scan backwards for the signature, allowing
        // for a trailing comment of up to 64KB.
        let maxBack = min(data.count, 65_557)
        var eocd = -1
        var i = data.count - 22
        let floor = data.count - maxBack
        while i >= floor && i >= 0 {
            if data.u32(at: i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return nil }

        let count = Int(data.u16(at: eocd + 10))
        var offset = Int(data.u32(at: eocd + 16))

        for _ in 0..<count {
            guard offset + 46 <= data.count, data.u32(at: offset) == 0x0201_4B50 else { break }
            let method = data.u16(at: offset + 10)
            let compressed = Int(data.u32(at: offset + 20))
            let uncompressed = Int(data.u32(at: offset + 24))
            let nameLen = Int(data.u16(at: offset + 28))
            let extraLen = Int(data.u16(at: offset + 30))
            let commentLen = Int(data.u16(at: offset + 32))
            let localOffset = Int(data.u32(at: offset + 42))

            let nameStart = data.startIndex + offset + 46
            guard nameStart + nameLen <= data.endIndex else { break }
            let name = String(data: data.subdata(in: nameStart..<(nameStart + nameLen)),
                              encoding: .utf8) ?? ""

            entries.append(Entry(name: name,
                                 compressionMethod: method,
                                 compressedSize: compressed,
                                 uncompressedSize: uncompressed,
                                 localHeaderOffset: localOffset))
            offset += 46 + nameLen + extraLen + commentLen
        }
        guard !entries.isEmpty else { return nil }
    }

    /// Decompressed contents of a named entry.
    func read(_ name: String) -> Data? {
        guard let e = entries.first(where: { $0.name == name }) else { return nil }
        return read(e)
    }

    func read(_ e: Entry) -> Data? {
        let lo = e.localHeaderOffset
        guard lo + 30 <= data.count, data.u32(at: lo) == 0x0403_4B50 else { return nil }
        let nameLen = Int(data.u16(at: lo + 26))
        let extraLen = Int(data.u16(at: lo + 28))
        let start = data.startIndex + lo + 30 + nameLen + extraLen
        guard start + e.compressedSize <= data.endIndex else { return nil }
        let payload = data.subdata(in: start..<(start + e.compressedSize))

        switch e.compressionMethod {
        case 0:                                   // stored
            return payload
        case 8:                                   // deflate
            return Self.inflate(payload, expected: e.uncompressedSize)
        default:
            return nil
        }
    }

    static func inflate(_ input: Data, expected: Int) -> Data? {
        var capacity = max(expected, 64 * 1024)
        for _ in 0..<6 {
            var output = Data(count: capacity)
            let written = output.withUnsafeMutableBytes { dst -> Int in
                input.withUnsafeBytes { src -> Int in
                    guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                          let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(d, capacity, s, input.count, nil, COMPRESSION_ZLIB)
                }
            }
            if written > 0 && written < capacity { return output.prefix(written) }
            capacity *= 4
        }
        return nil
    }
}

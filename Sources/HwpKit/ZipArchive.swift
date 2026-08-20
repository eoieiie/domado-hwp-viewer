import Compression
import Foundation

/// Minimal read-only ZIP reader.
///
/// `.hwpx` is a zip package, and Foundation has no zip API. Rather than take a
/// dependency (or shell out to `/usr/bin/unzip`) we read the central directory
/// ourselves and reuse the same raw-DEFLATE path the classic .hwp body uses.
public struct ZipArchive {
    /// How an entry's name was stored.
    ///
    /// Korean Windows tools — 알집, 탐색기 — write names in CP949 and leave the
    /// zip's UTF-8 flag clear. macOS then reads those bytes as CP437, which is
    /// where `과제제출.hwp` becomes `????????.hwp`.
    public enum NameEncoding: String {
        case utf8 = "UTF-8"
        case cp949 = "CP949"
    }

    public struct Entry {
        public let name: String
        public let nameEncoding: NameEncoding
        /// Whether the archive declared its names UTF-8 (general purpose bit 11).
        ///
        /// Not used to decode — too many tools write UTF-8 without setting it —
        /// but it is exactly what a Windows reader consults. An archive holding
        /// UTF-8 names with this clear is one that will be misread as CP949 on
        /// the other side.
        public let declaresUTF8: Bool

        /// True when the name is stored with its Hangul split into jamo. macOS
        /// writes names this way; it looks right here and wrong elsewhere.
        ///
        /// Compared as bytes on purpose. Swift string equality is canonical
        /// equivalence, so a decomposed name and its composed form test as equal
        /// and this check silently reported every archive clean.
        public var isDecomposed: Bool {
            Array(name.utf8) != Array(name.precomposedStringWithCanonicalMapping.utf8)
        }
        let compressionMethod: UInt16
        let compressedSize: Int
        public let uncompressedSize: Int
        let localHeaderOffset: Int

        public var isDirectory: Bool { name.hasSuffix("/") }
    }

    private let data: Data
    public private(set) var entries: [Entry] = []

    public init?(data: Data) {
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
            let flags = data.u16(at: offset + 8)
            let method = data.u16(at: offset + 10)
            let compressed = Int(data.u32(at: offset + 20))
            let uncompressed = Int(data.u32(at: offset + 24))
            let nameLen = Int(data.u16(at: offset + 28))
            let extraLen = Int(data.u16(at: offset + 30))
            let commentLen = Int(data.u16(at: offset + 32))
            let localOffset = Int(data.u32(at: offset + 42))

            let nameStart = data.startIndex + offset + 46
            guard nameStart + nameLen <= data.endIndex else { break }
            let (name, nameEncoding) = Self.decodeName(
                data.subdata(in: nameStart..<(nameStart + nameLen)))

            entries.append(Entry(name: name,
                                 nameEncoding: nameEncoding,
                                 declaresUTF8: flags & 0x800 != 0,
                                 compressionMethod: method,
                                 compressedSize: compressed,
                                 uncompressedSize: uncompressed,
                                 localHeaderOffset: localOffset))
            offset += 46 + nameLen + extraLen + commentLen
        }
        guard !entries.isEmpty else { return nil }
    }

    /// Ceilings on what an archive is allowed to talk this program into
    /// allocating.
    ///
    /// An entry states its own uncompressed size and the reader believes it in
    /// order to size a buffer. A file claiming four gigabytes costs a few bytes
    /// to write and takes the process down — the classic decompression bomb.
    /// These bounds are far above any real document and far below anything that
    /// hurts. They matter the moment this opens a file someone else made.
    public static let maxEntryBytes = 512 << 20      // 512MB
    public static let maxTotalBytes = 2 << 30        // 2GB

    /// CP949, which is what Korean Windows writes when it does not claim UTF-8.
    private static let cp949 = String.Encoding(rawValue:
        CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))

    /// An entry name as text, and which encoding it turned out to be.
    ///
    /// The archive's UTF-8 flag is not consulted. Too many tools write UTF-8 names
    /// without setting it for the flag to decide anything, so what decodes as
    /// valid UTF-8 is taken at face value and only bytes that cannot be UTF-8 fall
    /// through to CP949. Korean in CP949 is almost always invalid UTF-8 — its lead
    /// UTF-8 continuation bytes — so the two do not get confused in practice.
    ///
    /// The name is returned exactly as stored, **not** normalised. Repairing it
    /// is the extractor's job; this layer has to be able to report that the
    /// archive holds decomposed names, and precomposing here would erase the
    /// evidence.
    static func decodeName(_ bytes: Data) -> (String, NameEncoding) {
        if let utf8 = String(data: bytes, encoding: .utf8) {
            return (utf8, .utf8)
        }
        if let korean = String(data: bytes, encoding: cp949) {
            return (korean, .cp949)
        }
        return (String(decoding: bytes, as: UTF8.self), .utf8)
    }

    /// Decompressed contents of a named entry.
    func read(_ name: String) -> Data? {
        guard let e = entries.first(where: { $0.name == name }) else { return nil }
        return read(e)
    }

    public func read(_ e: Entry) -> Data? {
        guard e.uncompressedSize <= Self.maxEntryBytes else { return nil }
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

    /// Raw DEFLATE, the inverse of `inflate`.
    ///
    /// `COMPRESSION_ZLIB` in Apple's compression library is headerless DEFLATE,
    /// which is exactly what both a .hwp section stream and a zip member hold.
    static func deflate(_ input: Data) -> Data? {
        // Incompressible input grows slightly; a stored-block DEFLATE stream adds
        // five bytes per 64KB. This bound covers that with room to spare.
        let capacity = input.count + input.count / 64 + 1024
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { dst -> Int in
            input.withUnsafeBytes { src -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                      let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(d, capacity, s, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return output.prefix(written)
    }

    static func inflate(_ input: Data, expected: Int) -> Data? {
        // The starting guess may be the archive's own claim, so it is clamped
        // before it becomes an allocation, and the growth loop stops at the same
        // ceiling rather than quadrupling its way to the moon.
        var capacity = min(max(expected, 64 * 1024), maxEntryBytes)
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
            guard capacity < maxEntryBytes else { return nil }
            capacity = min(capacity * 4, maxEntryBytes)
        }
        return nil
    }
}

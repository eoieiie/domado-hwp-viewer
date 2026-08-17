import Foundation

/// Builds a zip that does not break when it leaves this Mac.
///
/// Two things go wrong with archives made on macOS and opened on Windows, and
/// both are fixed here rather than left to the reader:
///
/// - **Names are written UTF-8 and flagged as such.** The flag costs one bit and
///   is what tells a Windows reader not to fall back to CP949.
/// - **Names are normalised to precomposed form.** macOS stores filenames
///   decomposed — `한` as `ᄒ`+`ᅡ`+`ᆫ` — which is invisible locally and shows up
///   as mangled text nearly everywhere else.
public struct ZipWriter {
    public struct File {
        public let name: String
        public let data: Data

        public init(name: String, data: Data) {
            self.name = name
            self.data = data
        }
    }

    /// Entries whose bytes must be stored uncompressed, in the order given, ahead
    /// of everything else. `.hwpx` requires its `mimetype` entry to be first and
    /// stored, the same rule ODF and EPUB use.
    public static func archive(_ files: [File], storedFirst: [String] = []) -> Data {
        let ordered = storedFirst.compactMap { name in files.first { $0.name == name } }
            + files.filter { !storedFirst.contains($0.name) }

        var out = Data()
        var directory = Data()
        var count = 0
        let (time, date) = dosTimestamp(Date())

        for file in ordered {
            let name = Array(file.name.precomposedStringWithCanonicalMapping.utf8)
            let stored = storedFirst.contains(file.name)
            let crc = crc32(file.data)

            // Compression that does not shrink anything is just a slower way to
            // store the same bytes, and a reader still has to inflate it.
            var payload = file.data
            var method: UInt16 = 0
            if !stored, let deflated = ZipArchive.deflate(file.data),
               deflated.count < file.data.count {
                payload = deflated
                method = 8
            }

            let localOffset = out.count
            out.append(header(signature: 0x0403_4B50, versionMadeBy: nil, method: method,
                              time: time, date: date, crc: crc,
                              compressed: payload.count, uncompressed: file.data.count,
                              nameLength: name.count, localOffset: nil))
            out.append(contentsOf: name)
            out.append(payload)

            directory.append(header(signature: 0x0201_4B50, versionMadeBy: 0x031E,
                                    method: method, time: time, date: date, crc: crc,
                                    compressed: payload.count, uncompressed: file.data.count,
                                    nameLength: name.count, localOffset: localOffset))
            directory.append(contentsOf: name)
            count += 1
        }

        let directoryOffset = out.count
        out.append(directory)

        var end = Data()
        end.append(le(UInt32(0x0605_4B50)))
        end.append(le(UInt16(0)))                  // this disk
        end.append(le(UInt16(0)))                  // disk with the directory
        end.append(le(UInt16(count)))
        end.append(le(UInt16(count)))
        end.append(le(UInt32(directory.count)))
        end.append(le(UInt32(directoryOffset)))
        end.append(le(UInt16(0)))                  // comment length
        out.append(end)
        return out
    }

    /// The local and central headers share every field up to the name length, so
    /// they are built together; `versionMadeBy` and `localOffset` are the parts
    /// only the central directory carries.
    private static func header(signature: UInt32, versionMadeBy: UInt16?, method: UInt16,
                               time: UInt16, date: UInt16, crc: UInt32,
                               compressed: Int, uncompressed: Int,
                               nameLength: Int, localOffset: Int?) -> Data {
        var h = Data()
        h.append(le(signature))
        if let versionMadeBy { h.append(le(versionMadeBy)) }
        h.append(le(UInt16(20)))                   // version needed to extract
        h.append(le(UInt16(0x0800)))               // names are UTF-8
        h.append(le(method))
        h.append(le(time))
        h.append(le(date))
        h.append(le(crc))
        h.append(le(UInt32(compressed)))
        h.append(le(UInt32(uncompressed)))
        h.append(le(UInt16(nameLength)))
        h.append(le(UInt16(0)))                    // extra field length
        if let localOffset {
            h.append(le(UInt16(0)))                // comment length
            h.append(le(UInt16(0)))                // disk number start
            h.append(le(UInt16(0)))                // internal attributes
            h.append(le(UInt32(0o644 << 16)))      // external attributes
            h.append(le(UInt32(localOffset)))
        }
        return h
    }

    // MARK: - Bits

    private static func le(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private static func le(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    /// Zip stores the modification time in the 1980 MS-DOS format: two-second
    /// resolution, and no year before 1980.
    private static func dosTimestamp(_ date: Date) -> (time: UInt16, date: UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, c.year ?? 1980) - 1980
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | ((c.second ?? 0) / 2))
        let day = UInt16(year << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (time, day)
    }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        (0..<8).reduce(UInt32(i)) { c, _ in c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }

    /// Every entry carries a CRC32 of its uncompressed bytes, and readers check
    /// it. Getting this wrong produces an archive that opens and then reports
    /// every file as corrupt.
    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

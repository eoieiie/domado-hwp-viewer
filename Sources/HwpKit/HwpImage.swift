import Foundation

/// An image embedded in a 한글 document.
///
/// The compressed bytes are kept and only inflated when someone asks for the
/// image. That matters: a 한글 form routinely stores uncompressed BMPs, and one
/// 98-byte stream in a real 사업계획서 expands to 6MB. Holding twelve of those
/// decoded would cost more memory than the entire rest of the app.
public struct HwpImage: Identifiable, Hashable {
    /// Stream name as stored, e.g. `BIN0001.bmp`.
    public let name: String
    /// Extension the document claims, e.g. `bmp`, `jpg`, `png`, `gif`.
    public let format: String
    /// Bytes as stored in the document — compressed, so this is cheap to read.
    public let storedByteCount: Int

    private let payload: Data
    private let deflated: Bool

    public var id: String { name }

    /// Size after inflating. Computed on demand: doing this at init inflated every
    /// image just to measure it, which cost 80MB on a twelve-image document and
    /// defeated the whole point of storing them compressed.
    public var byteCount: Int { data()?.count ?? storedByteCount }

    init(name: String, payload: Data, deflated: Bool) {
        self.name = name
        self.format = (name as NSString).pathExtension.lowercased()
        self.payload = payload
        self.deflated = deflated
        self.storedByteCount = payload.count
    }

    /// Decoded image bytes, ready to hand to `NSImage`.
    public func data() -> Data? {
        deflated ? Self.inflate(payload) : payload
    }

    /// Filename extension inferred from the actual bytes rather than the stream
    /// name, since the two occasionally disagree.
    public func detectedFormat() -> String? {
        guard let d = data(), d.count >= 4 else { return nil }
        let b = [UInt8](d.prefix(4))
        switch (b[0], b[1], b[2], b[3]) {
        case (0x89, 0x50, 0x4E, 0x47): return "png"
        case (0xFF, 0xD8, 0xFF, _):    return "jpg"
        case (0x47, 0x49, 0x46, 0x38): return "gif"
        case (0x42, 0x4D, _, _):       return "bmp"
        case (0x49, 0x49, 0x2A, 0x00), (0x4D, 0x4D, 0x00, 0x2A): return "tiff"
        default: return nil
        }
    }

    private static func inflate(_ input: Data) -> Data? {
        ZipArchive.inflate(input, expected: max(input.count * 12, 256 * 1024))
    }
}

extension HwpDocument {
    /// Images embedded in the document, in stream order.
    ///
    /// Not held on the document: reading them walks the container again, and most
    /// callers never ask. `HwpImage` keeps only compressed bytes, so the result is
    /// cheap to hold once obtained.
    public static func images(at url: URL) throws -> [HwpImage] {
        try images(in: Data(contentsOf: url))
    }

    public static func images(in data: Data) throws -> [HwpImage] {
        if data.count >= 2, data[data.startIndex] == 0x50, data[data.startIndex + 1] == 0x4B {
            guard let zip = ZipArchive(data: data) else { return [] }
            return zip.entries
                .filter { $0.name.hasPrefix("BinData/") && !$0.name.hasSuffix("/") }
                .compactMap { entry in
                    guard let bytes = zip.read(entry) else { return nil }
                    return HwpImage(name: (entry.name as NSString).lastPathComponent,
                                    payload: bytes, deflated: false)
                }
        }

        let cf = try CompoundFile(data: data)
        let compressed = (cf.read("FileHeader").map { $0.u32(at: 36) & 1 == 1 }) ?? true
        return cf.streamNames
            .filter { $0.uppercased().hasPrefix("BIN") }
            .sorted()
            .compactMap { name in
                guard let bytes = cf.read(name) else { return nil }
                return HwpImage(name: name, payload: bytes, deflated: compressed)
            }
    }
}

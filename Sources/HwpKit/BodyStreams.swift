import Foundation

/// The body sections of a binary .hwp, decompressed, together with what is
/// needed to put them back.
///
/// Reading and editing both start here so the two agree on which streams are the
/// body and in what order — a disagreement would let an edit land in the wrong
/// section.
struct BodyStreams {
    let container: CompoundFile
    /// True when the document stores its streams deflated, which is the norm.
    let compressed: Bool
    /// Section stream names in numeric order: `BodyText/Section0`, `Section1`, …
    let names: [String]
    /// Section contents, decompressed, in the same order as `names`.
    let inflated: [Data]

    init(data: Data) throws {
        let cf = try CompoundFile(data: data)
        guard let header = cf.read("FileHeader"), header.count >= 40 else {
            throw HwpError.noFileHeader
        }
        container = cf
        compressed = header.u32(at: 36) & 1 == 1
        names = cf.streamNames
            .filter { $0.hasPrefix("Section") }
            .sorted { (Int($0.dropFirst(7)) ?? 0) < (Int($1.dropFirst(7)) ?? 0) }

        var out: [Data] = []
        for name in names {
            guard let raw = cf.read(name) else { continue }
            if compressed {
                guard let body = ZipArchive.inflate(raw, expected: raw.count * 8) else {
                    throw HwpError.decompressionFailed
                }
                out.append(body)
            } else {
                out.append(raw)
            }
        }
        inflated = out
    }

    /// Compresses a section back into the form the container stores.
    func packed(_ section: Data) throws -> Data {
        guard compressed else { return section }
        guard let out = ZipArchive.deflate(section) else { throw HwpError.decompressionFailed }
        return out
    }
}

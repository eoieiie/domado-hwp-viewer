import Compression
import Foundation

public enum HwpError: LocalizedError {
    case notCompoundFile
    case noFileHeader
    case decompressionFailed

    public var errorDescription: String? {
        switch self {
        case .notCompoundFile:
            return "읽을 수 있는 한글 문서가 아닙니다. 구버전 .hwp(3.0 이하)일 수 있습니다."
        case .noFileHeader:
            return "손상된 문서입니다. 본문을 찾을 수 없습니다."
        case .decompressionFailed:
            return "본문 압축을 풀지 못했습니다."
        }
    }
}

/// A body paragraph. `level` is nesting depth — paragraphs inside table cells
/// report a deeper level than ordinary body text.
public struct Paragraph: Hashable {
    public let text: String
    public let level: Int

    public init(text: String, level: Int) {
        self.text = text
        self.level = level
    }

    public var isInsideTable: Bool { level > 0 }
}

public enum HwpFormat: String {
    case binary = "hwp"     // HWP 5.x — OLE compound file
    case owpml = "hwpx"     // OWPML — zip + XML
}

/// A parsed 한글 document, in either the binary `.hwp` or the newer `.hwpx` form.
public struct HwpDocument {
    public let paragraphs: [Paragraph]
    public let format: HwpFormat

    public var text: String { paragraphs.map(\.text).joined(separator: "\n") }

    /// Plain text with table paragraphs indented, so structure survives export.
    public var indentedText: String {
        paragraphs
            .map { String(repeating: "  ", count: $0.level) + $0.text }
            .joined(separator: "\n")
    }

    public init(url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    public init(data: Data) throws {
        // Dispatch on the container signature rather than the file extension —
        // people rename these files constantly.
        if data.count >= 4, data[data.startIndex] == 0x50, data[data.startIndex + 1] == 0x4B {
            paragraphs = try HwpxParser.parse(data: data)
            format = .owpml
        } else {
            paragraphs = try Self.parseBinary(data: data)
            format = .binary
        }
    }

    // MARK: - Binary .hwp

    private static func parseBinary(data: Data) throws -> [Paragraph] {
        let cf = try CompoundFile(data: data)
        guard let header = cf.read("FileHeader"), header.count >= 40 else {
            throw HwpError.noFileHeader
        }
        let compressed = header.u32(at: 36) & 1 == 1

        var result: [Paragraph] = []
        let sections = cf.streamNames
            .filter { $0.hasPrefix("Section") }
            .sorted { (Int($0.dropFirst(7)) ?? 0) < (Int($1.dropFirst(7)) ?? 0) }

        for name in sections {
            guard var raw = cf.read(name) else { continue }
            if compressed {
                guard let inflated = inflate(raw) else { throw HwpError.decompressionFailed }
                raw = inflated
            }
            for record in RecordSequence(data: raw) where record.tag == .paragraphText {
                let line = decodeParagraph(record.payload)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty {
                    // Record levels step by two per container: body text sits at
                    // level 1, a table cell's paragraphs at 3, a nested table's at
                    // 5. Halving gives the nesting depth.
                    let depth = max(0, (Int(record.level) - 1) / 2)
                    result.append(Paragraph(text: line, level: depth))
                }
            }
        }
        return result
    }

    /// HWP stores sections as raw DEFLATE, which is what COMPRESSION_ZLIB expects.
    private static func inflate(_ input: Data) -> Data? {
        ZipArchive.inflate(input, expected: input.count * 8)
    }

    // MARK: - Paragraph text

    /// Control characters occupying 8 UTF-16 units (char + payload + char) rather
    /// than one. Miscounting these shifts every following glyph.
    private static let wideControls: Set<UInt16> = [1, 2, 3, 4, 5, 6, 7, 8, 11, 12,
                                                    14, 15, 16, 17, 18, 19, 20, 21, 22, 23]
    private static let skipControls: Set<UInt16> = [0, 10, 13, 24, 25, 26, 27, 28, 29, 30, 31]

    private static func decodeParagraph(_ buffer: Data) -> String {
        var scalars = String.UnicodeScalarView()
        var i = 0
        while i + 1 < buffer.count {
            let c = buffer.u16(at: i)
            if wideControls.contains(c) {
                i += 16
            } else if c == 9 {
                scalars.append("\t"); i += 2
            } else if skipControls.contains(c) {
                i += 2
            } else {
                if let scalar = Unicode.Scalar(c) { scalars.append(scalar) }
                i += 2
            }
        }
        return String(scalars)
    }
}

// MARK: - Record stream

struct HwpRecord {
    enum Tag: UInt16 {
        case paragraphHeader = 66
        case paragraphText = 67
        case paragraphCharShape = 68
        case unknown = 0
    }

    let tag: Tag
    let level: UInt16
    let payload: Data
}

/// HWP body streams are a flat sequence of records with a packed 32-bit header:
/// tag (10 bits) | level (10 bits) | size (12 bits). A size of 0xFFF means the
/// real size follows in the next four bytes.
struct RecordSequence: Sequence, IteratorProtocol {
    private let data: Data
    private var offset = 0

    init(data: Data) { self.data = data }

    mutating func next() -> HwpRecord? {
        guard offset + 4 <= data.count else { return nil }
        let header = data.u32(at: offset)
        let rawTag = UInt16(header & 0x3FF)
        let level = UInt16((header >> 10) & 0x3FF)
        var size = Int((header >> 20) & 0xFFF)
        offset += 4
        if size == 0xFFF {
            guard offset + 4 <= data.count else { return nil }
            size = Int(data.u32(at: offset))
            offset += 4
        }
        guard offset + size <= data.count else { return nil }
        let payload = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + size))
        offset += size
        return HwpRecord(tag: HwpRecord.Tag(rawValue: rawTag) ?? .unknown,
                         level: level,
                         payload: payload)
    }
}

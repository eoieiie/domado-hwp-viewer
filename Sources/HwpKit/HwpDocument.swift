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
    /// Derived from `blocks` on demand. Storing it alongside doubled the text
    /// held in memory for no gain — callers that want a flat list are rare.
    public var paragraphs: [Paragraph] { Self.flatten(blocks) }
    /// Body content in document order, with tables kept as grids.
    public let blocks: [Block]
    public let format: HwpFormat

    public var tables: [Table] {
        blocks.compactMap { if case .table(let t) = $0 { return t } else { return nil } }
    }

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
            blocks = try HwpxParser.parse(data: data).map { Block.paragraph($0) }
            format = .owpml
        } else {
            let records = try Self.binaryRecords(data: data)
            blocks = TableBuilder.build(records: records, decode: Self.decodeParagraph)
            format = .binary
        }
    }

    // MARK: - Binary .hwp

    /// Paragraph view of the block list, so existing callers keep working.
    private static func flatten(_ blocks: [Block]) -> [Paragraph] {
        blocks.flatMap { block -> [Paragraph] in
            switch block {
            case .paragraph(let p):
                return [p]
            case .table(let t):
                return t.rows.flatMap { row in
                    row.map { Paragraph(text: $0.text, level: 1) }
                }
            }
        }
    }

    private static func binaryRecords(data: Data) throws
        -> [(tag: UInt16, level: Int, payload: Data)] {
        var result: [(tag: UInt16, level: Int, payload: Data)] = []
        for section in try BodyStreams(data: data).inflated {
            for record in RecordSequence(data: section) {
                result.append((tag: record.rawTag, level: Int(record.level), payload: record.payload))
            }
        }
        return result
    }

    // MARK: - Paragraph text

    /// Control characters occupying 8 UTF-16 units (char + payload + char) rather
    /// than one. Miscounting these shifts every following glyph.
    static let wideControls: Set<UInt16> = [1, 2, 3, 4, 5, 6, 7, 8, 11, 12,
                                            14, 15, 16, 17, 18, 19, 20, 21, 22, 23]
    static let skipControls: Set<UInt16> = [0, 10, 13, 24, 25, 26, 27, 28, 29, 30, 31]

    static func decodeParagraph(_ buffer: Data) -> String {
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
    let rawTag: UInt16
    let level: UInt16
    let payload: Data
    /// Offset of this record's header within the section, and of its payload.
    /// The editor rewrites records by splicing these ranges, which leaves every
    /// byte it did not mean to touch exactly as the original had it.
    let start: Int
    let payloadStart: Int

    var end: Int { payloadStart + payload.count }
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
        let start = offset
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
        let payloadStart = offset
        offset += size
        return HwpRecord(rawTag: rawTag, level: level, payload: payload,
                         start: start, payloadStart: payloadStart)
    }
}

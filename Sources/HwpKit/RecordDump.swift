import Foundation

/// A count of what the body record stream contains, and whether each paragraph
/// header agrees with the records it describes.
///
/// `HwpEditor` writes character positions using field offsets that no public
/// specification confirmed — they were read off real documents. This audit is how
/// that reading stays honest: it re-derives every count from the records
/// themselves and reports any paragraph where the header disagrees. A document
/// that audits clean is one the editor is safe to touch, and `hwpcli -r` runs it.
public struct ParagraphAudit {
    public struct Mismatch {
        public let paragraph: Int
        public let field: String
        public let declared: Int
        public let actual: Int
    }

    public let recordCounts: [(name: String, count: Int)]
    public let paragraphs: Int
    public let mismatches: [Mismatch]
    /// Tag name and nesting level of the first records, in order. The grouping
    /// rule that ties a paragraph's records to its header depends on these, and
    /// they are not the same in every document.
    public let head: [(name: String, level: Int, bytes: Int)]
    /// Per body section: bytes stored, bytes the sector chain holds, the size the
    /// text inflates to, and what re-compressing it costs. An edit has to fit
    /// `allocated`, so `repacked` against `allocated` is the room to work in.
    public let space: [(name: String, stored: Int, allocated: Int,
                        inflated: Int, repacked: Int)]

    public var isClean: Bool { mismatches.isEmpty }
}

extension HwpDocument {
    /// Audits the body of a binary .hwp. `.hwpx` has no record stream and returns
    /// an empty result.
    public static func auditParagraphs(at url: URL) throws -> ParagraphAudit {
        try auditParagraphs(in: try Data(contentsOf: url))
    }

    public static func auditParagraphs(in data: Data) throws -> ParagraphAudit {
        guard let body = try? BodyStreams(data: data) else {
            return ParagraphAudit(recordCounts: [], paragraphs: 0, mismatches: [], head: [], space: [])
        }

        var names: [UInt16: String] = [66: "PARA_HEADER", 67: "PARA_TEXT",
                                       68: "PARA_CHAR_SHAPE", 69: "PARA_LINE_SEG",
                                       70: "PARA_RANGE_TAG", 71: "CTRL_HEADER",
                                       72: "LIST_HEADER"]
        var counts: [UInt16: Int] = [:]
        var mismatches: [ParagraphAudit.Mismatch] = []
        var paragraphs = 0
        var head: [(name: String, level: Int, bytes: Int)] = []
        var space: [(name: String, stored: Int, allocated: Int,
                     inflated: Int, repacked: Int)] = []
        for (i, name) in body.names.enumerated() {
            guard let s = body.container.space(of: name), i < body.inflated.count else { continue }
            let section = body.inflated[i]
            space.append((name, s.stored, s.allocated, section.count,
                          (try? body.packed(section))?.count ?? 0))
        }

        for section in body.inflated {
            var header: Data?
            var level: UInt16 = 0
            var seen: [UInt16: Int] = [:]

            /// Compares the header's declared counts with what actually followed.
            func settle() {
                guard let h = header, h.count >= 22 else { return }
                paragraphs += 1
                // An empty paragraph carries no PARA_TEXT record at all and
                // declares the single character that ends it.
                let declaredChars = Int(h.u32(at: 0) & 0x7FFF_FFFF)
                let actualChars = seen[67].map { $0 / 2 } ?? min(declaredChars, 1)
                let expected: [(String, Int, Int)] = [
                    ("글자 수", declaredChars, actualChars),
                    ("글자 서식 수", Int(h.u16(at: 12)), (seen[68] ?? 0) / 8),
                    ("범위 태그 수", Int(h.u16(at: 14)), (seen[70] ?? 0) / 12),
                    ("줄 정보 수", Int(h.u16(at: 16)), (seen[69] ?? 0) / 36),
                ]
                for (field, declared, actual) in expected where declared != actual {
                    mismatches.append(.init(paragraph: paragraphs, field: field,
                                            declared: declared, actual: actual))
                }
            }

            for r in RecordSequence(data: section) {
                counts[r.rawTag, default: 0] += 1
                if head.count < 24 {
                    head.append((names[r.rawTag] ?? "tag\(r.rawTag)",
                                 Int(r.level), r.payload.count))
                }
                if r.rawTag == 66 {
                    settle()
                    header = r.payload
                    level = r.level
                    seen = [:]
                } else if (67...70).contains(r.rawTag), r.level == level + 1 {
                    seen[r.rawTag, default: 0] += r.payload.count
                }
            }
            settle()
        }

        let listed = counts
            .sorted { $0.value > $1.value }
            .map { (name: names[$0.key] ?? "tag\($0.key)", count: $0.value) }
        return ParagraphAudit(recordCounts: listed, paragraphs: paragraphs,
                              mismatches: mismatches, head: head, space: space)
    }
}

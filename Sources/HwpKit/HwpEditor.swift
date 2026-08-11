import Foundation

/// One find-and-replace to apply to a document's body text.
public struct HwpChange: Hashable {
    public let find: String
    public let replaceWith: String

    public init(find: String, replaceWith: String) {
        self.find = find
        self.replaceWith = replaceWith
    }
}

/// What an edit did, and what it declined to do.
public struct HwpEditReport {
    /// The edited document. Writing this anywhere other than a new file is the
    /// caller's mistake to avoid — `HwpEditor` never touches the original.
    public let data: Data
    public let replacements: Int
    /// Matches that were found but deliberately left alone, each with a reason.
    public let skipped: [String]
}

public enum HwpEditError: LocalizedError {
    case owpmlNotSupported
    case noMatch(String)
    case inconsistentParagraph(String)
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .owpmlNotSupported:
            return ".hwpx 문서 수정은 아직 지원하지 않습니다."
        case .noMatch(let s):
            return "‘\(s)’을(를) 문서에서 찾지 못했습니다."
        case .inconsistentParagraph(let detail):
            return "문단 구조가 예상과 달라 수정을 중단했습니다 (\(detail)). 원본은 그대로입니다."
        case .verificationFailed(let detail):
            return "수정한 결과를 다시 읽어 확인하는 데 실패해 저장하지 않았습니다 (\(detail))."
        }
    }
}

/// Replaces text inside a .hwp without disturbing anything else in the file.
///
/// The rule this is built around: a .hwp that opens wrong is worse than an edit
/// that does not happen. Every step that could be guessed at is instead checked
/// against the file, and a check that fails aborts the whole edit.
///
/// - The paragraph header's own character and record counts are compared with
///   the records they describe before any byte is written. A mismatch means the
///   field layout assumed here does not hold for this document, so nothing is.
/// - A match that spans a control character, or a run of differently formatted
///   text, is reported and skipped rather than cut in half.
/// - Records that were not edited keep their original bytes exactly, headers
///   included; only the spliced ranges differ.
/// - The finished file is parsed again and every paragraph compared with what
///   the edit was supposed to produce, and every other stream compared byte for
///   byte with the original, before it is handed back.
public enum HwpEditor {
    /// How many places each change would touch, without producing a file.
    ///
    /// Cheap enough to run while someone is typing: it decompresses the body and
    /// counts, where `apply` also patches records and compresses the result.
    public static func preview(_ changes: [HwpChange],
                               in data: Data) -> [HwpChange: (found: Int, skipped: Int)] {
        guard let body = try? BodyStreams(data: data) else { return [:] }
        var out: [HwpChange: (found: Int, skipped: Int)] = [:]
        for section in body.inflated {
            for r in RecordSequence(data: section) where r.rawTag == 67 {
                let buffer = ParagraphBuffer(payload: r.payload)
                for change in changes where !change.find.isEmpty {
                    let (usable, straddling) = buffer.matches(of: Array(change.find.utf16))
                    guard !usable.isEmpty || straddling > 0 else { continue }
                    let running = out[change] ?? (0, 0)
                    out[change] = (running.found + usable.count,
                                   running.skipped + straddling)
                }
            }
        }
        return out
    }

    public static func apply(_ changes: [HwpChange], to url: URL) throws -> HwpEditReport {
        try apply(changes, to: try Data(contentsOf: url))
    }

    public static func apply(_ changes: [HwpChange], to original: Data) throws -> HwpEditReport {
        guard !(original.count >= 2 && original[original.startIndex] == 0x50
                && original[original.startIndex + 1] == 0x4B) else {
            throw HwpEditError.owpmlNotSupported
        }
        let body = try BodyStreams(data: original)
        let wanted = changes.filter { !$0.find.isEmpty && $0.find != $0.replaceWith }
        guard !wanted.isEmpty else {
            return HwpEditReport(data: original, replacements: 0, skipped: [])
        }

        var edited = original
        var totalReplacements = 0
        var skipped: [String] = []
        var matchedFinds = Set<String>()
        /// Every paragraph's text after editing, in document order, so the
        /// finished file can be checked against it.
        var expectedText: [String] = []

        for (i, section) in body.inflated.enumerated() {
            let result = try rewrite(section: section, applying: wanted)
            totalReplacements += result.replacements
            skipped.append(contentsOf: result.skipped)
            matchedFinds.formUnion(result.matchedFinds)
            expectedText.append(contentsOf: result.expectedText)
            guard result.replacements > 0 else { continue }
            edited = try CompoundFile(data: edited)
                .replacing(stream: body.names[i], with: try body.packed(result.section))
        }

        if let missing = wanted.first(where: { !matchedFinds.contains($0.find) }) {
            throw HwpEditError.noMatch(missing.find)
        }
        try verify(edited, against: original, expectedText: expectedText, body: body)
        return HwpEditReport(data: edited, replacements: totalReplacements, skipped: skipped)
    }

    // MARK: - Section rewriting

    private struct SectionResult {
        let section: Data
        let replacements: Int
        let skipped: [String]
        let matchedFinds: Set<String>
        let expectedText: [String]
    }

    /// A paragraph's records. `PARA_TEXT` and the three position-bearing records
    /// follow their header at the same nesting level.
    private struct Group {
        var header: HwpRecord
        var text: HwpRecord?
        var charShape: HwpRecord?
        var lineSeg: HwpRecord?
        var rangeTag: HwpRecord?
    }

    /// One replacement inside a single paragraph's text payload.
    private struct Edit {
        let byteRange: Range<Int>
        let newBytes: Data

        var startPos: Int { byteRange.lowerBound / 2 }
        var endPos: Int { byteRange.upperBound / 2 }
        var delta: Int { newBytes.count / 2 - byteRange.count / 2 }
    }

    private static func rewrite(section: Data,
                                applying changes: [HwpChange]) throws -> SectionResult {
        let records = Array(RecordSequence(data: section))
        var groups: [Group] = []
        for r in records {
            switch r.rawTag {
            case 66:
                groups.append(Group(header: r))
            case 67, 68, 69, 70:
                // A paragraph's records nest one level under its header, not
                // beside it. Grouping them by equal level silently produced
                // paragraphs with no text and would have written every character
                // position into the wrong record.
                guard var g = groups.last, g.header.level + 1 == r.level else { break }
                switch r.rawTag {
                case 67: g.text = r
                case 68: g.charShape = r
                case 69: g.lineSeg = r
                default: g.rangeTag = r
                }
                groups[groups.count - 1] = g
            default:
                break
            }
        }

        /// Replacement bytes for record ranges, applied to the section at the end
        /// so untouched records keep their original bytes verbatim.
        var patches: [(range: Range<Int>, bytes: Data)] = []
        var replacements = 0
        var skipped: [String] = []
        var matchedFinds = Set<String>()
        var expectedText: [String] = []

        for group in groups {
            guard let textRecord = group.text else { continue }
            let buffer = ParagraphBuffer(payload: textRecord.payload)

            var edits: [Edit] = []
            for change in changes {
                let needle = Array(change.find.utf16)
                let (usable, straddling) = buffer.matches(of: needle)
                if straddling > 0 {
                    skipped.append("‘\(change.find)’ \(straddling)곳 — 글자 사이에 표·그림 같은 "
                                   + "제어문자가 끼어 있어 건너뜀")
                }
                guard !usable.isEmpty else { continue }
                matchedFinds.insert(change.find)
                let bytes = Data(Array(change.replaceWith.utf16)
                    .flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
                edits.append(contentsOf: usable.map { Edit(byteRange: $0, newBytes: bytes) })
            }

            guard !edits.isEmpty else {
                expectedText.append(buffer.text)
                continue
            }
            edits.sort { $0.byteRange.lowerBound < $1.byteRange.lowerBound }
            guard !overlapping(edits) else {
                throw HwpEditError.inconsistentParagraph("바꿀 구간이 서로 겹칩니다")
            }

            // A run of differently formatted text inside the match has no
            // sensible new formatting, so leave the paragraph alone and say so.
            if let shapes = group.charShape,
               let boundary = charShapeBoundary(inside: edits, of: shapes) {
                skipped.append("\(boundary)자 부근 — 바꾸려는 글자 중간에서 서식이 바뀌어 건너뜀")
                expectedText.append(buffer.text)
                continue
            }

            try checkCounts(of: group)
            patches.append(contentsOf: try patch(group: group, edits: edits))
            replacements += edits.count
            expectedText.append(applying(edits, to: buffer))
        }

        guard replacements > 0 else {
            return SectionResult(section: section, replacements: 0, skipped: skipped,
                                 matchedFinds: matchedFinds, expectedText: expectedText)
        }

        var out = Data()
        var cursor = 0
        for p in patches.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            guard p.range.lowerBound >= cursor else {
                throw HwpEditError.inconsistentParagraph("고칠 레코드가 겹칩니다")
            }
            out.append(section[(section.startIndex + cursor)..<(section.startIndex + p.range.lowerBound)])
            out.append(p.bytes)
            cursor = p.range.upperBound
        }
        out.append(section[(section.startIndex + cursor)...])

        return SectionResult(section: out, replacements: replacements, skipped: skipped,
                             matchedFinds: matchedFinds, expectedText: expectedText)
    }

    // MARK: - Record patches

    /// Rewrites the four records of a paragraph whose text changed length.
    private static func patch(group: Group,
                              edits: [Edit]) throws -> [(range: Range<Int>, bytes: Data)] {
        let delta = edits.reduce(0) { $0 + $1.delta }
        var out: [(range: Range<Int>, bytes: Data)] = []

        guard let text = group.text else { return [] }
        var payload = text.payload
        for e in edits.reversed() {   // right to left, so earlier offsets stay valid
            let lo = payload.startIndex + e.byteRange.lowerBound
            let hi = payload.startIndex + e.byteRange.upperBound
            guard hi <= payload.endIndex else {
                throw HwpEditError.inconsistentParagraph("본문 범위를 벗어났습니다")
            }
            payload.replaceSubrange(lo..<hi, with: e.newBytes)
        }
        out.append((text.start..<text.end, encode(tag: 67, level: text.level, payload: payload)))

        if delta != 0 {
            // Paragraph header: character count in the low 31 bits at offset 0.
            var header = group.header.payload
            let raw = header.u32(at: 0)
            let count = Int(raw & 0x7FFF_FFFF) + delta
            guard count >= 0 else {
                throw HwpEditError.inconsistentParagraph("글자 수가 음수가 됩니다")
            }
            write(UInt32(count) | (raw & 0x8000_0000), into: &header, at: 0)
            out.append((group.header.start..<group.header.end,
                        encode(tag: 66, level: group.header.level, payload: header)))

            if let r = group.charShape {
                out.append((r.start..<r.end,
                            encode(tag: 68, level: r.level,
                                   payload: shiftPositions(in: r.payload, stride: 8,
                                                           at: [0], by: edits))))
            }
            if let r = group.lineSeg {
                out.append((r.start..<r.end,
                            encode(tag: 69, level: r.level,
                                   payload: shiftPositions(in: r.payload, stride: 36,
                                                           at: [0], by: edits))))
            }
            if let r = group.rangeTag {
                out.append((r.start..<r.end,
                            encode(tag: 70, level: r.level,
                                   payload: shiftPositions(in: r.payload, stride: 12,
                                                           at: [0, 4], by: edits))))
            }
        }
        return out
    }

    /// Moves every character position in a fixed-stride record to where the text
    /// it points at ended up.
    private static func shiftPositions(in payload: Data, stride: Int,
                                       at fieldOffsets: [Int], by edits: [Edit]) -> Data {
        var out = payload
        var i = 0
        while i + stride <= out.count {
            for f in fieldOffsets {
                write(UInt32(shifted(Int(out.u32(at: i + f)), by: edits)), into: &out, at: i + f)
            }
            i += stride
        }
        return out
    }

    /// Where a character position lands after the edits.
    ///
    /// A position inside a replaced run has nothing left to point at, so it
    /// collapses to the start of that run — the same place the replacement text
    /// begins.
    private static func shifted(_ p: Int, by edits: [Edit]) -> Int {
        var accumulated = 0
        for e in edits {
            if p >= e.endPos {
                accumulated += e.delta
            } else if p > e.startPos {
                return e.startPos + accumulated
            } else {
                break
            }
        }
        return p + accumulated
    }

    /// The first character-shape boundary that falls strictly inside a match.
    private static func charShapeBoundary(inside edits: [Edit], of record: HwpRecord) -> Int? {
        var i = 0
        while i + 8 <= record.payload.count {
            let pos = Int(record.payload.u32(at: i))
            if edits.contains(where: { pos > $0.startPos && pos < $0.endPos }) { return pos }
            i += 8
        }
        return nil
    }

    private static func overlapping(_ edits: [Edit]) -> Bool {
        zip(edits, edits.dropFirst())
            .contains { $0.byteRange.upperBound > $1.byteRange.lowerBound }
    }

    /// Confirms the paragraph header describes the records that follow it.
    ///
    /// These four counts are the only evidence available that the field offsets
    /// used above are the ones this document actually uses. If they disagree,
    /// every position written afterwards would be written to the wrong place.
    private static func checkCounts(of group: Group) throws {
        let header = group.header.payload
        guard header.count >= 22 else {
            throw HwpEditError.inconsistentParagraph("문단 머리 레코드가 너무 짧습니다")
        }
        func check(_ label: String, _ declared: Int, _ actual: Int) throws {
            guard declared == actual else {
                throw HwpEditError.inconsistentParagraph("\(label) \(declared)≠\(actual)")
            }
        }
        try check("글자 수", Int(header.u32(at: 0) & 0x7FFF_FFFF),
                  (group.text?.payload.count ?? 0) / 2)
        try check("글자 서식 수", Int(header.u16(at: 12)),
                  (group.charShape?.payload.count ?? 0) / 8)
        try check("범위 태그 수", Int(header.u16(at: 14)),
                  (group.rangeTag?.payload.count ?? 0) / 12)
        try check("줄 정보 수", Int(header.u16(at: 16)),
                  (group.lineSeg?.payload.count ?? 0) / 36)
    }

    private static func applying(_ edits: [Edit], to buffer: ParagraphBuffer) -> String {
        var payload = Data(buffer.units.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        // The buffer's units are already control-free, so byte offsets in the
        // original payload have to be mapped through the offset table.
        var mapped: [Edit] = []
        for e in edits {
            guard let unit = buffer.offsets.firstIndex(of: e.byteRange.lowerBound) else { continue }
            let length = e.byteRange.count / 2
            mapped.append(Edit(byteRange: (unit * 2)..<((unit + length) * 2), newBytes: e.newBytes))
        }
        for e in mapped.reversed() {
            let lo = payload.startIndex + e.byteRange.lowerBound
            let hi = payload.startIndex + e.byteRange.upperBound
            guard hi <= payload.endIndex else { continue }
            payload.replaceSubrange(lo..<hi, with: e.newBytes)
        }
        return ParagraphBuffer(payload: payload).text
    }

    // MARK: - Encoding

    /// A record header packs tag, level and size into 32 bits, with sizes of
    /// 0xFFF and above spilling into a following word.
    private static func encode(tag: UInt16, level: UInt16, payload: Data) -> Data {
        var out = Data()
        let size = payload.count
        let short = size < 0xFFF ? UInt32(size) : 0xFFF
        var header = ((UInt32(tag) & 0x3FF) | ((UInt32(level) & 0x3FF) << 10)
                      | (short << 20)).littleEndian
        withUnsafeBytes(of: &header) { out.append(contentsOf: $0) }
        if size >= 0xFFF {
            var full = UInt32(size).littleEndian
            withUnsafeBytes(of: &full) { out.append(contentsOf: $0) }
        }
        out.append(payload)
        return out
    }

    private static func write(_ value: UInt32, into data: inout Data, at offset: Int) {
        let i = data.startIndex + offset
        guard i + 4 <= data.endIndex else { return }
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.replaceSubrange(i..<(i + 4), with: $0) }
    }

    // MARK: - Verification

    /// Reads the finished document back and refuses it unless it is exactly what
    /// the edit intended, with nothing else disturbed.
    private static func verify(_ edited: Data, against original: Data,
                               expectedText: [String], body: BodyStreams) throws {
        let check: BodyStreams
        do {
            check = try BodyStreams(data: edited)
        } catch {
            throw HwpEditError.verificationFailed("다시 열리지 않습니다")
        }
        _ = try? HwpDocument(data: edited)

        var actual: [String] = []
        for section in check.inflated {
            for r in RecordSequence(data: section) where r.rawTag == 67 {
                actual.append(ParagraphBuffer(payload: r.payload).text)
            }
        }
        guard actual.count == expectedText.count else {
            throw HwpEditError.verificationFailed(
                "문단 수가 \(expectedText.count)에서 \(actual.count)로 바뀌었습니다")
        }
        for (i, pair) in zip(actual, expectedText).enumerated() where pair.0 != pair.1 {
            throw HwpEditError.verificationFailed("\(i + 1)번째 문단이 예상과 다릅니다")
        }

        // Nothing outside the body may have moved: images, styles, fonts, the
        // preview, and the header all have to come back byte for byte.
        let before = try CompoundFile(data: original)
        let after = try CompoundFile(data: edited)
        for name in before.streamNames where !body.names.contains(name) {
            guard before.read(name) == after.read(name) else {
                throw HwpEditError.verificationFailed("\(name) 스트림이 함께 바뀌었습니다")
            }
        }
        guard Set(after.streamNames) == Set(before.streamNames) else {
            throw HwpEditError.verificationFailed("스트림 목록이 바뀌었습니다")
        }
    }
}

import Foundation

/// A `PARA_TEXT` payload with a map from each visible character back to the byte
/// it came from.
///
/// Editing text means editing these bytes, and the two do not line up: control
/// characters are dropped from the visible string, and the wide ones occupy
/// sixteen bytes. Searching the decoded string and then indexing the payload with
/// the result would silently write into the middle of a control record.
struct ParagraphBuffer {
    /// Visible characters, as UTF-16 code units.
    let units: [UInt16]
    /// Byte offset within the payload that each unit was read from.
    let offsets: [Int]

    /// A character position as 한글 counts it. Every two bytes of the payload is
    /// one position, including the eight that a wide control spans, so the
    /// conversion is exact.
    static func charPosition(ofByte offset: Int) -> Int { offset / 2 }

    init(payload: Data) {
        var units: [UInt16] = []
        var offsets: [Int] = []
        var i = 0
        while i + 1 < payload.count {
            let c = payload.u16(at: i)
            if HwpDocument.wideControls.contains(c) {
                i += 16
            } else if HwpDocument.skipControls.contains(c) {
                i += 2
            } else {
                units.append(c == 9 ? 9 : c)
                offsets.append(i)
                i += 2
            }
        }
        self.units = units
        self.offsets = offsets
    }

    var text: String {
        String(decoding: units.map { $0 == 9 ? UInt16(9) : $0 }, as: UTF16.self)
    }

    /// Byte ranges of every occurrence of `needle`, skipping any match that is
    /// not a contiguous run of plain characters.
    ///
    /// A match that straddles a control character has no single byte range to
    /// replace — the halves sit either side of sixteen bytes that mean something
    /// else. Those are reported separately rather than edited.
    func matches(of needle: [UInt16]) -> (usable: [Range<Int>], straddling: Int) {
        guard !needle.isEmpty, units.count >= needle.count else { return ([], 0) }
        var usable: [Range<Int>] = []
        var straddling = 0
        var i = 0
        while i <= units.count - needle.count {
            guard Array(units[i ..< i + needle.count]) == needle else { i += 1; continue }
            let base = offsets[i]
            let contiguous = (0 ..< needle.count).allSatisfy { offsets[i + $0] == base + 2 * $0 }
            if contiguous {
                usable.append(base ..< (base + 2 * needle.count))
            } else {
                straddling += 1
            }
            i += needle.count
        }
        return (usable, straddling)
    }
}

extension ParagraphBuffer {
    /// The byte range covering all visible text, when it is one unbroken run.
    ///
    /// Replacing a paragraph wholesale means writing over this range. If a control
    /// character sits between two visible characters — a table or image anchored
    /// mid-paragraph — there is no single range that covers the text without also
    /// covering the control, so this reports nothing and the edit is refused.
    func wholeRange() -> Range<Int>? {
        guard let first = offsets.first, let last = offsets.last else { return nil }
        guard offsets.enumerated().allSatisfy({ $0.element == first + 2 * $0.offset }) else {
            return nil
        }
        return first ..< (last + 2)
    }
}

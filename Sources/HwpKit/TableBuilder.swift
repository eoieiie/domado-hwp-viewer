import Foundation

/// A table cell with its grid address. Spans come straight from the file.
public struct TableCell: Hashable, Identifiable {
    public let row: Int
    public let column: Int
    public let rowSpan: Int
    public let columnSpan: Int
    public let lines: [String]

    public var id: Int { row << 20 | column }
    public var text: String { lines.joined(separator: "\n") }
}

public struct Table: Hashable, Identifiable {
    public let cells: [TableCell]
    public let id: Int

    /// Cells grouped by starting row, each row ordered left to right.
    ///
    /// Computed once here rather than on access: SwiftUI reads this on every
    /// layout pass, and regrouping a hundred cells per pass is what made window
    /// resizing crawl.
    public let rows: [[TableCell]]
    public let rowCount: Int
    public let columnCount: Int

    init(cells: [TableCell], id: Int) {
        self.cells = cells
        self.id = id
        self.rows = Dictionary(grouping: cells, by: \.row)
            .sorted { $0.key < $1.key }
            .map { $0.value.sorted { $0.column < $1.column } }
        self.rowCount = cells.map { $0.row + $0.rowSpan }.max() ?? 0
        self.columnCount = cells.map { $0.column + $0.columnSpan }.max() ?? 0
    }
}

/// Body content in document order: either a loose paragraph or a table.
public enum Block: Identifiable {
    case paragraph(Paragraph)
    case table(Table)

    public var id: String {
        switch self {
        case .paragraph(let p): return "p:\(p.level):\(p.text.hashValue)"
        case .table(let t): return "t:\(t.id)"
        }
    }
}

/// Rebuilds table structure from the flat record stream.
///
/// A `CTRL_HEADER` carrying the `tbl ` id opens a table; every record nested
/// deeper than it belongs to that table. Inside, each `LIST_HEADER` starts a cell
/// and carries its grid address, and the paragraphs that follow are its contents.
struct TableBuilder {
    private struct Frame {
        let controlLevel: Int
        let id: Int
        var cells: [TableCell] = []
        var current: (row: Int, col: Int, rowSpan: Int, colSpan: Int)?
        var buffer: [String] = []
    }

    private var stack: [Frame] = []
    private var blocks: [Block] = []
    private var tableSeq = 0

    static let tableControlID: UInt32 = 0x7462_6C20   // 'tbl ' little-endian in file order

    static func build(records: [(tag: UInt16, level: Int, payload: Data)],
                      decode: (Data) -> String) -> [Block] {
        var b = TableBuilder()
        for r in records { b.consume(r, decode: decode) }
        b.closeAll()
        return b.blocks
    }

    private mutating func consume(_ r: (tag: UInt16, level: Int, payload: Data),
                                  decode: (Data) -> String) {
        // Leaving a table: any record at or above the control's level ends it.
        while let top = stack.last, r.level <= top.controlLevel {
            close()
        }

        switch r.tag {
        case 71 where isTableControl(r.payload):     // CTRL_HEADER
            tableSeq += 1
            stack.append(Frame(controlLevel: r.level, id: tableSeq))

        case 72 where !stack.isEmpty:                // LIST_HEADER — a cell
            // Other controls (headers, footers, captions) carry list headers too.
            // Only the ones sitting directly under the table control are cells.
            guard r.payload.count >= 16,
                  r.level == stack[stack.count - 1].controlLevel + 1 else { break }
            flushCell()
            stack[stack.count - 1].current = (
                row: Int(r.payload.u16(at: 10)),
                col: Int(r.payload.u16(at: 8)),
                rowSpan: max(1, Int(r.payload.u16(at: 14))),
                colSpan: max(1, Int(r.payload.u16(at: 12)))
            )

        case 67:                                     // PARA_TEXT
            let line = decode(r.payload).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { break }
            if stack.isEmpty {
                let depth = max(0, (r.level - 1) / 2)
                blocks.append(.paragraph(Paragraph(text: line, level: depth)))
            } else {
                stack[stack.count - 1].buffer.append(line)
            }

        default:
            break
        }
    }

    private func isTableControl(_ payload: Data) -> Bool {
        guard payload.count >= 4 else { return false }
        let i = payload.startIndex
        return payload[i] == 0x20 && payload[i + 1] == 0x6C
            && payload[i + 2] == 0x62 && payload[i + 3] == 0x74   // " lbt" == 'tbl ' reversed
    }

    private mutating func flushCell() {
        guard var top = stack.last, let c = top.current else { return }
        if !top.buffer.isEmpty {
            top.cells.append(TableCell(row: c.row, column: c.col,
                                       rowSpan: c.rowSpan, columnSpan: c.colSpan,
                                       lines: top.buffer))
        }
        top.buffer = []
        top.current = nil
        stack[stack.count - 1] = top
    }

    private mutating func close() {
        flushCell()
        guard let top = stack.popLast() else { return }
        guard !top.cells.isEmpty else { return }
        let table = Table(cells: top.cells, id: top.id)
        if stack.isEmpty {
            blocks.append(.table(table))
        } else {
            // A nested table: fold its text into the enclosing cell rather than
            // trying to render grids inside grids.
            stack[stack.count - 1].buffer.append(contentsOf: top.cells.map(\.text))
        }
    }

    private mutating func closeAll() {
        while !stack.isEmpty { close() }
    }
}

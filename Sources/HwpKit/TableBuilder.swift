import Foundation

/// A table cell with its grid address. Spans come straight from the file.
public struct TableCell: Hashable, Identifiable {
    public let row: Int
    public let column: Int
    public let rowSpan: Int
    public let columnSpan: Int

    /// Joined once at parse time. As a computed property this rebuilt the string
    /// on every access, and SwiftUI reads it on each layout pass.
    public let text: String
    /// The `PARA_TEXT` record behind each line of this cell, in the same order.
    /// A cell holding three lines is three records, and an edit has to name the
    /// one it means.
    public let sources: [Int]

    public var id: Int { row << 20 | column }

    /// True when the cell is a single record, which is the only shape that can be
    /// replaced as one piece. Form cells are almost always this.
    public var isSingleLine: Bool { sources.count == 1 }

    init(row: Int, column: Int, rowSpan: Int, columnSpan: Int, lines: [(String, Int?)]) {
        self.row = row
        self.column = column
        self.rowSpan = rowSpan
        self.columnSpan = columnSpan
        self.text = lines.map(\.0).joined(separator: "\n")
        self.sources = lines.compactMap(\.1)
    }
}

/// One position in a row, in the order it has to be drawn.
///
/// A grid row is not just its cells. A cell merged downward occupies a column in
/// the rows beneath it without appearing in them, and a form that leaves a corner
/// empty has no cell there at all. Drawing only the cells that start in a row
/// slides everything after the gap one column to the left — which is exactly what
/// happened to every 신청서 with a merged header column down its left edge.
public enum Slot: Hashable {
    /// A cell that starts here.
    case cell(TableCell)
    /// Covered by a cell merged downward from above. Carries that cell's width so
    /// the column keeps its place.
    case merged(columns: Int)
    /// No cell defined here; the table is not rectangular.
    case empty
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

    /// Every row as a complete left-to-right sequence of slots, so column `n` of
    /// one row lines up with column `n` of the next. Computed once, for the same
    /// reason `rows` is.
    public let layout: [[Slot]]
    public let rowCount: Int
    public let columnCount: Int

    /// Above this many grid positions the occupancy pass is skipped and `layout`
    /// falls back to the cells alone. A misread address can claim a 128×4096
    /// grid, and filling half a million slots to lay out one broken table is a
    /// worse failure than the misalignment it would fix.
    private static let maxSlots = 20_000

    init(cells: [TableCell], id: Int) {
        self.cells = cells
        self.id = id
        self.rows = Dictionary(grouping: cells, by: \.row)
            .sorted { $0.key < $1.key }
            .map { $0.value.sorted { $0.column < $1.column } }
        let rowCount = cells.map { $0.row + $0.rowSpan }.max() ?? 0
        let columnCount = cells.map { $0.column + $0.columnSpan }.max() ?? 0
        self.rowCount = rowCount
        self.columnCount = columnCount
        self.layout = Self.occupancy(cells: cells, rows: rowCount, columns: columnCount)
            ?? rows.map { $0.map(Slot.cell) }
    }

    /// Walks the grid position by position, so a row's slots come out in the
    /// order they occupy columns rather than in the order cells were parsed.
    private static func occupancy(cells: [TableCell], rows: Int,
                                  columns: Int) -> [[Slot]]? {
        guard rows > 0, columns > 0, rows * columns <= maxSlots else { return nil }

        /// What starts at each position, and which positions are already taken by
        /// a cell that starts elsewhere.
        var starts = [TableCell?](repeating: nil, count: rows * columns)
        // Column of the cell occupying each position, or -1 for nothing.
        var takenBy = [Int](repeating: -1, count: rows * columns)
        for cell in cells {
            guard cell.row < rows, cell.column < columns else { continue }
            starts[cell.row * columns + cell.column] = cell
            for r in cell.row ..< min(rows, cell.row + cell.rowSpan) {
                for c in cell.column ..< min(columns, cell.column + cell.columnSpan) {
                    takenBy[r * columns + c] = cell.column
                }
            }
        }

        var out: [[Slot]] = []
        out.reserveCapacity(rows)
        for r in 0 ..< rows {
            var line: [Slot] = []
            var c = 0
            while c < columns {
                let i = r * columns + c
                if let cell = starts[i] {
                    line.append(.cell(cell))
                    c += max(1, cell.columnSpan)
                } else if takenBy[i] >= 0 {
                    // Covered from above. Advance past the whole width of the
                    // cell doing the covering so one placeholder stands in for it.
                    let owner = takenBy[i]
                    var width = 0
                    while c + width < columns, takenBy[r * columns + c + width] == owner {
                        width += 1
                    }
                    line.append(.merged(columns: width))
                    c += width
                } else {
                    line.append(.empty)
                    c += 1
                }
            }
            out.append(line)
        }
        // Trailing rows can be entirely empty when a span overshoots the real
        // grid; they would draw as blank stripes.
        while let last = out.last, last.allSatisfy({ $0 == .empty }) { out.removeLast() }
        return out
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
        var buffer: [(String, Int?)] = []
    }

    private var stack: [Frame] = []
    private var blocks: [Block] = []
    private var tableSeq = 0

    /// Plausibility bounds for a cell address. A 한글 table cannot realistically
    /// exceed these, and anything beyond them is a misread of a non-cell record.
    static let maxColumns = 128
    static let maxRows = 4096

    static func build(records: [(tag: UInt16, level: Int, payload: Data, source: Int?)],
                      decode: (Data) -> String) -> [Block] {
        var b = TableBuilder()
        for r in records { b.consume(r, decode: decode) }
        b.closeAll()
        return b.blocks
    }

    private mutating func consume(_ r: (tag: UInt16, level: Int, payload: Data, source: Int?),
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

            let col = Int(r.payload.u16(at: 8))
            let row = Int(r.payload.u16(at: 10))
            let colSpan = Int(r.payload.u16(at: 12))
            let rowSpan = Int(r.payload.u16(at: 14))

            // Some list headers that pass the level check still are not cells, and
            // reading their bytes as coordinates yields values like column 8506.
            // A grid that wide never renders. Treat implausible addresses as "not
            // a cell" and let the text fall into the cell already open, so nothing
            // is dropped.
            guard col < Self.maxColumns, row < Self.maxRows,
                  colSpan >= 1, colSpan <= Self.maxColumns,
                  rowSpan >= 1, rowSpan <= Self.maxRows else { break }

            flushCell()
            stack[stack.count - 1].current = (row: row, col: col,
                                              rowSpan: rowSpan, colSpan: colSpan)

        case 67:                                     // PARA_TEXT
            let line = decode(r.payload).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { break }
            if stack.isEmpty {
                let depth = max(0, (r.level - 1) / 2)
                blocks.append(.paragraph(Paragraph(text: line, level: depth, source: r.source)))
            } else {
                stack[stack.count - 1].buffer.append((line, r.source))
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
            stack[stack.count - 1].buffer.append(
                contentsOf: top.cells.map { ($0.text, $0.sources.first) })
        }
    }

    private mutating func closeAll() {
        while !stack.isEmpty { close() }
    }
}

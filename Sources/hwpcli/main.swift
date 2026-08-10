import Foundation
import HwpKit

var args = Array(CommandLine.arguments.dropFirst())
let showTables = args.contains("-t") || args.contains("--tables")
args.removeAll { $0.hasPrefix("-") }

guard let path = args.first else {
    FileHandle.standardError.write("사용법: hwpcli <파일.hwp|.hwpx> [-t]\n".data(using: .utf8)!)
    exit(1)
}

do {
    let doc = try HwpDocument(url: URL(fileURLWithPath: path))
    if showTables {
        for block in doc.blocks {
            switch block {
            case .paragraph(let p):
                print(p.text)
            case .table(let t):
                print("┌─ 표 \(t.rowCount)행 × \(t.columnCount)열 ─────")
                for row in t.rows {
                    let cells = row.map { c -> String in
                        let span = (c.rowSpan > 1 || c.columnSpan > 1)
                            ? "(\(c.columnSpan)×\(c.rowSpan))" : ""
                        return c.text.replacingOccurrences(of: "\n", with: " ") + span
                    }
                    print("│ " + cells.joined(separator: " | "))
                }
                print("└──────────")
            }
        }
    } else {
        print(doc.text)
    }
    let t = doc.tables
    FileHandle.standardError.write(
        "\n[\(doc.format.rawValue) · \(doc.paragraphs.count)문단 · 표 \(t.count)개]\n"
            .data(using: .utf8)!)
} catch {
    FileHandle.standardError.write("실패: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}

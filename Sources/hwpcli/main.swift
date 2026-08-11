import Foundation
import HwpKit

var args = Array(CommandLine.arguments.dropFirst())
let showTables = args.contains("-t") || args.contains("--tables")
let listImages = args.contains("-g") || args.contains("--images")
args.removeAll { $0.hasPrefix("-") }

guard let path = args.first else {
    FileHandle.standardError.write("사용법: hwpcli <파일.hwp|.hwpx> [-t]\n".data(using: .utf8)!)
    exit(1)
}

if listImages {
    let images = (try? HwpDocument.images(at: URL(fileURLWithPath: path))) ?? []
    print("이미지 \(images.count)개")
    let outDir = URL(fileURLWithPath: "/tmp/imgchk/swift")
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    for i in images {
        let real = i.detectedFormat() ?? "?"
        let flag = real == i.format ? "" : "  ⚠︎ 이름은 .\(i.format)"
        let d = i.data()
        print(String(format: "  %-16s 저장 %8.1fKB → 해제 %9.1fKB  %@%@",
                     (i.name as NSString).utf8String!,
                     Double(i.storedByteCount) / 1024,
                     Double(d?.count ?? 0) / 1024, real, flag))
        if let d { try? d.write(to: outDir.appendingPathComponent(i.name)) }
    }
    exit(0)
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

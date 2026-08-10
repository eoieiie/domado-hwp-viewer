import Foundation
import HwpKit

var args = Array(CommandLine.arguments.dropFirst())
let indent = args.contains("-i") || args.contains("--indent")
args.removeAll { $0.hasPrefix("-") }

guard let path = args.first else {
    FileHandle.standardError.write("사용법: hwpcli <파일.hwp|.hwpx> [-i]\n".data(using: .utf8)!)
    exit(1)
}

do {
    let doc = try HwpDocument(url: URL(fileURLWithPath: path))
    print(indent ? doc.indentedText : doc.text)
    let tableCount = doc.paragraphs.filter(\.isInsideTable).count
    FileHandle.standardError.write(
        "\n[\(doc.format.rawValue) · \(doc.paragraphs.count)개 문단 · 표 안 \(tableCount)개]\n"
            .data(using: .utf8)!)
} catch {
    FileHandle.standardError.write("실패: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}

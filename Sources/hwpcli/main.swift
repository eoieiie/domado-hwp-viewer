import Foundation
import HwpKit

func fail(_ message: String) -> Never {
    // stdout is buffered and stderr is not, so anything already printed has to be
    // pushed out first or the reason lands above the notes explaining it.
    fflush(stdout)
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
let showTables = args.contains("-t") || args.contains("--tables")
let listImages = args.contains("-g") || args.contains("--images")
let dumpRecords = args.contains("-r") || args.contains("--records")

/// `-e 찾을말=>바꿀말`, repeatable. Writes a new file and never the original.
var changes: [HwpChange] = []
while let i = args.firstIndex(where: { $0 == "-e" || $0 == "--edit" }) {
    guard i + 1 < args.count else { fail("-e 뒤에 ‘찾을말=>바꿀말’이 필요합니다") }
    let spec = args[i + 1]
    guard let sep = spec.range(of: "=>") else { fail("‘찾을말=>바꿀말’ 형식이어야 합니다: \(spec)") }
    changes.append(HwpChange(find: String(spec[spec.startIndex..<sep.lowerBound]),
                             replaceWith: String(spec[sep.upperBound...])))
    args.removeSubrange(i...(i + 1))
}
args.removeAll { $0.hasPrefix("-") }

guard let path = args.first else {
    fail("""
    사용법: hwpcli <파일.hwp|.hwpx> [옵션]
      -t          표 구조로 출력
      -g          이미지 목록·추출
      -r          레코드 덤프 (문단 구조 점검)
      -e 찾을말=>바꿀말   본문 치환. 원본은 건드리지 않고 _수정.hwp로 저장
    """)
}
let url = URL(fileURLWithPath: path)

// MARK: - Edit

if !changes.isEmpty {
    let report: HwpEditReport
    do {
        report = try HwpEditor.apply(changes, to: url)
    } catch {
        fail("수정하지 않았습니다: \(error.localizedDescription)")
    }
    for note in report.skipped { print("건너뜀: \(note)") }
    guard report.replacements > 0 else { fail("바꾼 곳이 없습니다.") }

    let out = url.deletingPathExtension().appendingPathExtension("")
        .deletingLastPathComponent()
        .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "_수정")
        .appendingPathExtension(url.pathExtension)
    guard !FileManager.default.fileExists(atPath: out.path) else {
        fail("\(out.lastPathComponent)이(가) 이미 있습니다. 지우거나 옮기고 다시 실행하세요.")
    }
    do {
        try report.data.write(to: out, options: .withoutOverwriting)
    } catch {
        fail("저장 실패: \(error.localizedDescription)")
    }
    print("\(report.replacements)곳 바꿔 \(out.lastPathComponent)로 저장했습니다. 원본은 그대로입니다.")
    exit(0)
}

// MARK: - Records

if dumpRecords {
    guard let audit = try? HwpDocument.auditParagraphs(at: url) else { fail("읽지 못했습니다") }
    print("문단 \(audit.paragraphs)개")
    print("처음 레코드:")
    for h in audit.head {
        print(String(format: "  lv%d %-16s %5d바이트", h.level,
                     (h.name as NSString).utf8String!, h.bytes))
    }
    for r in audit.recordCounts {
        print(String(format: "  %-16s %5d", (r.name as NSString).utf8String!, r.count))
    }
    for s in audit.space {
        print("\(s.name): 저장 \(s.stored) / 자리 \(s.allocated) "
              + "(여유 \(s.allocated - s.stored)) · 본문 \(s.inflated) → 다시압축 \(s.repacked) "
              + "(\(s.repacked - s.stored > 0 ? "+" : "")\(s.repacked - s.stored))")
    }
    if audit.isClean {
        print("✓ 모든 문단에서 머리 레코드와 본문·서식·줄 정보의 개수가 일치합니다.")
    } else {
        print("⚠︎ 불일치 \(audit.mismatches.count)곳 — 이 문서는 수정하지 않는 게 좋습니다")
        for m in audit.mismatches.prefix(10) {
            print("  \(m.paragraph)번째 문단 \(m.field): 머리 \(m.declared) ≠ 실제 \(m.actual)")
        }
    }
    exit(audit.isClean ? 0 : 1)
}

// MARK: - Images

if listImages {
    let images = (try? HwpDocument.images(at: url)) ?? []
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

// MARK: - Text

do {
    let doc = try HwpDocument(url: url)
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
    fail("실패: \(error.localizedDescription)")
}

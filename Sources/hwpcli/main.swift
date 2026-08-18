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
let listZip = args.contains("-z") || args.contains("--zip")
let numbered = args.contains("-n") || args.contains("--numbered")

/// `-p 12=새 내용`, repeatable. Replaces one paragraph named by its index from
/// `-n`, which is how the app edits a single cell without touching the cells
/// that happen to read the same.
var paragraphEdits: [Int: String] = [:]
while let i = args.firstIndex(where: { $0 == "-p" || $0 == "--paragraph" }) {
    guard i + 1 < args.count else { fail("-p 뒤에 ‘번호=새 내용’이 필요합니다") }
    let spec = args[i + 1]
    guard let sep = spec.firstIndex(of: "="),
          let n = Int(spec[spec.startIndex..<sep]) else {
        fail("‘번호=새 내용’ 형식이어야 합니다: \(spec)")
    }
    paragraphEdits[n] = String(spec[spec.index(after: sep)...])
    args.removeSubrange(i...(i + 1))
}

/// `-c 만들파일.zip` — 뒤에 오는 경로들을 압축한다. 이름은 UTF-8·결합형으로 쓴다.
var createZip: String?
if let i = args.firstIndex(where: { $0 == "-c" || $0 == "--create" }) {
    guard i + 1 < args.count else { fail("-c 뒤에 만들 zip 이름이 필요합니다") }
    createZip = args[i + 1]
    args.removeSubrange(i...(i + 1))
}

/// `-x 대상폴더` — 압축 풀기. 이름이 CP949면 고쳐서 푼다.
var extractTo: String?
if let i = args.firstIndex(where: { $0 == "-x" || $0 == "--extract" }) {
    guard i + 1 < args.count else { fail("-x 뒤에 풀어둘 폴더가 필요합니다") }
    extractTo = args[i + 1]
    args.removeSubrange(i...(i + 1))
}

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

// MARK: - Create a zip

if let target = createZip {
    let sources = args.filter { !$0.hasPrefix("-") }
    guard !sources.isEmpty else { fail("압축할 파일이나 폴더를 지정하세요") }
    let out = URL(fileURLWithPath: target)
    guard !FileManager.default.fileExists(atPath: out.path) else {
        fail("\(out.lastPathComponent)이(가) 이미 있습니다.")
    }

    let files = ZipWriter.files(at: sources.map { URL(fileURLWithPath: $0) })
    guard !files.isEmpty else { fail("압축할 파일이 없습니다.") }

    do {
        try ZipWriter.archive(files).write(to: out, options: .withoutOverwriting)
    } catch {
        fail("저장 실패: \(error.localizedDescription)")
    }
    let size = (try? Data(contentsOf: out).count) ?? 0
    print("\(files.count)개를 \(out.lastPathComponent)로 묶었습니다 "
          + "(\(size / 1024)KB). 이름은 UTF-8·결합형이라 윈도우에서 안 깨집니다.")
    exit(0)
}

guard let path = args.first else {
    fail("""
    사용법: hwpcli <파일.hwp|.hwpx> [옵션]
      -t          표 구조로 출력
      -g          이미지 목록·추출
      -r          레코드 덤프 (문단 구조 점검)
      -e 찾을말=>바꿀말   본문 치환. 원본은 건드리지 않고 _수정.hwp로 저장
      -z          zip 안 파일 목록 (윈도우가 만든 CP949 이름도 제대로 보임)
      -x 폴더      zip 풀기. 깨진 한글 이름을 고쳐서 푼다
      -c 새.zip    파일·폴더를 압축. 윈도우에서 안 깨지는 이름으로 쓴다
      -n          문단마다 번호를 붙여 출력 (-p에 쓸 번호)
      -p 번호=새 내용   그 문단만 통째로 교체 → 문서_수정.hwp
    """)
}
let url = URL(fileURLWithPath: path)

// MARK: - Edit

if !changes.isEmpty || !paragraphEdits.isEmpty {
    let report: HwpEditReport
    do {
        report = paragraphEdits.isEmpty
            ? try HwpEditor.apply(changes, to: url)
            : try HwpEditor.apply(paragraphs: paragraphEdits, to: url)
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

// MARK: - Zip

if listZip || extractTo != nil {
    guard let data = try? Data(contentsOf: url), let zip = ZipArchive(data: data) else {
        fail("zip으로 읽지 못했습니다: \(url.lastPathComponent)")
    }
    let broken = zip.entries.filter { $0.nameEncoding == .cp949 }

    if let folder = extractTo {
        let out = URL(fileURLWithPath: folder)
        let report: ZipArchive.ExtractReport
        do {
            report = try zip.extract(to: out)
        } catch {
            fail("풀지 못했습니다: \(error.localizedDescription)")
        }
        for s in report.skipped { print("건너뜀: \(s.name) — \(s.reason)") }
        print("\(report.written.count)개를 \(out.path)에 풀었습니다.")
        if report.repairedNames {
            print("한글 이름 \(broken.count)개를 CP949에서 고쳐서 풀었습니다.")
        }
        exit(0)
    }

    print("파일 \(zip.entries.count)개")
    for e in zip.entries where !e.isDirectory {
        let mark = e.nameEncoding == .cp949 ? "  ← CP949에서 복구" : ""
        print(String(format: "  %9.1fKB  %@%@", Double(e.uncompressedSize) / 1024,
                     e.name, mark))
    }
    if !broken.isEmpty {
        print("\n윈도우에서 만든 압축입니다. Finder로 풀면 이 \(broken.count)개는 "
              + "이름이 ????로 깨집니다. -x 폴더 로 풀면 제대로 나옵니다.")
    }
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
                // Printed from `layout`, so a column that is only occupied by a
                // downward merge still takes its place on the line. Reading the
                // cells alone hid a real misalignment for months.
                for row in t.layout {
                    let slots = row.map { slot -> String in
                        switch slot {
                        case .cell(let c):
                            let span = (c.rowSpan > 1 || c.columnSpan > 1)
                                ? "(\(c.columnSpan)×\(c.rowSpan))" : ""
                            return c.text.replacingOccurrences(of: "\n", with: " ") + span
                        case .merged:
                            return "↑"
                        case .empty:
                            return ""
                        }
                    }
                    print("│ " + slots.joined(separator: " | "))
                }
                print("└──────────")
            }
        }
    } else if numbered {
        // The index is what `-p` takes. Paragraphs with no record behind them
        // (.hwpx) print a dash and cannot be targeted.
        for p in doc.paragraphs {
            // Plain interpolation, not String(format:): "%s" wants a C string and
            // handing it a Swift String prints garbage.
            let label = p.source.map(String.init) ?? "-"
            print(String(repeating: " ", count: max(0, 5 - label.count)) + label + "  " + p.text)
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

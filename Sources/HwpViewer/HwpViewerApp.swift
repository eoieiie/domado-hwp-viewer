import HwpKit
import SwiftUI
import UniformTypeIdentifiers

/// Finder hands documents to the app through the AppKit delegate; SwiftUI's
/// WindowGroup does not receive them on its own.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        Task { @MainActor in DocumentModel.shared.load(url: url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct HwpViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = DocumentModel.shared

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 640, minHeight: 480)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("열기…") { model.presentOpenPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .saveItem) {
                Button("텍스트로 저장…") { model.presentSavePanel() }
                    .keyboardShortcut("s")
                    .disabled(model.document == nil)
                Button("전체 복사") { model.copyAll() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(model.document == nil)
            }
        }
    }
}

@MainActor
final class DocumentModel: ObservableObject {
    static let shared = DocumentModel()

    @Published var document: HwpDocument?
    @Published var fileName = ""
    @Published var errorMessage: String?
    @Published var query = ""
    @Published var showTableIndent = true
    @Published var showTableGrid = true

    static let readableTypes: [UTType] = ["hwp", "hwpx"]
        .compactMap { UTType(filenameExtension: $0) }

    var visible: [Paragraph] {
        guard let document else { return [] }
        guard !query.isEmpty else { return document.paragraphs }
        return document.paragraphs.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var summary: String {
        guard let document else { return "" }
        let chars = document.paragraphs.reduce(0) { $0 + $1.text.count }
        let tables = document.paragraphs.filter(\.isInsideTable).count
        var parts = ["\(document.format.rawValue.uppercased())",
                     "\(document.paragraphs.count)문단",
                     "\(chars)자"]
        if tables > 0 { parts.append("표 \(tables)") }
        return parts.joined(separator: " · ")
    }

    func load(url: URL) {
        do {
            document = try HwpDocument(url: url)
            errorMessage = nil
        } catch {
            document = nil
            errorMessage = error.localizedDescription
        }
        fileName = url.lastPathComponent
        query = ""
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.readableTypes
        if panel.runModal() == .OK, let url = panel.url { load(url: url) }
    }

    func presentSavePanel() {
        guard let document else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = (fileName as NSString).deletingPathExtension + ".txt"
        if panel.runModal() == .OK, let url = panel.url {
            let body = showTableIndent ? document.indentedText : document.text
            try? body.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func copyAll() {
        guard let document else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            showTableIndent ? document.indentedText : document.text, forType: .string)
    }
}

struct ContentView: View {
    @ObservedObject var model: DocumentModel
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if model.document == nil && model.errorMessage == nil {
                DropPrompt(isTargeted: isTargeted)
            } else {
                header
                Divider()
                content
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.load(url: url) }
            }
            return true
        }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(8)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.fileName)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !model.summary.isEmpty {
                        Text(model.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("열기") { model.presentOpenPanel() }
            }

            if model.document != nil {
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("문서 내 검색", text: $model.query)
                            .textFieldStyle(.plain)
                        if !model.query.isEmpty {
                            Text("\(model.visible.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Button {
                                model.query = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

                    Toggle("표 보기", isOn: $model.showTableGrid)
                        .toggleStyle(.checkbox)
                        .disabled(!model.query.isEmpty)
                    Button("복사") { model.copyAll() }
                    Button("저장") { model.presentSavePanel() }
                }
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.errorMessage {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 34))
                    .foregroundStyle(.orange)
                Text(error)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
        } else if !model.query.isEmpty && model.visible.isEmpty {
            Text("‘\(model.query)’ 검색 결과가 없습니다")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.query.isEmpty && model.showTableGrid, let doc = model.document {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(doc.blocks.enumerated()), id: \.offset) { _, block in
                        switch block {
                        case .paragraph(let p):
                            Text(p.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        case .table(let table):
                            TableGrid(table: table)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(model.visible.enumerated()), id: \.offset) { _, p in
                        ParagraphRow(paragraph: p,
                                     query: model.query,
                                     indent: model.showTableIndent)
                    }
                }
                .padding(20)
            }
        }
    }
}

struct ParagraphRow: View {
    let paragraph: Paragraph
    let query: String
    let indent: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if indent && paragraph.isInsideTable {
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 2)
            }
            Text(highlighted)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, indent ? CGFloat(paragraph.level) * 16 : 0)
    }

    /// Highlights the search term inside the paragraph.
    private var highlighted: AttributedString {
        var s = AttributedString(paragraph.text)
        guard !query.isEmpty else { return s }
        var search = s.startIndex..<s.endIndex
        while let r = s[search].range(of: query, options: .caseInsensitive) {
            s[r].backgroundColor = .yellow.opacity(0.45)
            s[r].foregroundColor = .black
            guard r.upperBound < s.endIndex else { break }
            search = r.upperBound..<s.endIndex
        }
        return s
    }
}

struct DropPrompt: View {
    let isTargeted: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.secondary)
            Text("hwp 파일을 여기로 끌어다 놓으세요")
                .font(.title3)
            Text("한컴오피스 없이 내용을 읽고 텍스트로 저장합니다")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("hwp · hwpx 지원")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isTargeted ? Color.accentColor.opacity(0.06) : Color.clear)
    }
}


/// Renders a reconstructed table as a real grid. Column spans widen a cell;
/// row spans are drawn in their starting row (merged heights are not simulated).
struct TableGrid: View {
    let table: HwpKit.Table

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        CellView(cell: cell)
                    }
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(.separator, lineWidth: 1))
    }
}

struct CellView: View {
    let cell: TableCell

    private var minWidth: CGFloat { 96 * CGFloat(cell.columnSpan) }
    private var maxWidth: CGFloat { 420 * CGFloat(cell.columnSpan) }

    var body: some View {
        Text(cell.text)
            .textSelection(.enabled)
            .font(.callout)
            .frame(minWidth: minWidth, maxWidth: maxWidth, alignment: .topLeading)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .overlay(alignment: .topTrailing) { spanBadge }
            .background(.quaternary.opacity(0.25))
            .border(.separator, width: 0.5)
    }

    @ViewBuilder
    private var spanBadge: some View {
        if cell.rowSpan > 1 {
            Text("↕\(cell.rowSpan)")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .padding(2)
        }
    }
}

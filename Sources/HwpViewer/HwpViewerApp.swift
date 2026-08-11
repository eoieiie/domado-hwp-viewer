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
                .navigationTitle(model.fileName.isEmpty ? "도마도 HWP 뷰어" : model.fileName)
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
    @Published var expandCells = false
    @Published var images: [HwpImage] = []
    @Published var showImages = false
    private var fileURL: URL?

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
            // Only the compressed bytes are held; nothing is decoded until the
            // image panel asks for a thumbnail.
            images = (try? HwpDocument.images(at: url)) ?? []
        } catch {
            document = nil
            errorMessage = error.localizedDescription
            images = []
        }
        fileURL = url
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

    /// Held here, not in `ImagePanel`. A `@StateObject` declared inside sheet
    /// content is re-allocated on every body evaluation, so the store the panel
    /// rendered from was never the one being filled.
    @StateObject private var thumbnails = ThumbnailStore()

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
        .sheet(isPresented: $model.showImages) {
            ImagePanel(images: model.images, documentName: model.fileName, store: thumbnails)
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
                    Toggle("긴 셀 펼치기", isOn: $model.expandCells)
                        .toggleStyle(.checkbox)
                        .disabled(!model.showTableGrid || !model.query.isEmpty)
                    if !model.images.isEmpty {
                        Button {
                            model.showImages = true
                        } label: {
                            Label("이미지 \(model.images.count)", systemImage: "photo")
                        }
                    }
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
            BlocksView(blocks: doc.blocks, expandCells: model.expandCells)
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


/// Document body: loose paragraphs and reconstructed tables, in order.
///
/// Every width here is a constant. An earlier version read the container width
/// with a GeometryReader and sized columns from it, which fed the content size
/// back into the geometry that produced it — layout never settled, and memory
/// climbed past a gigabyte. Nothing in this view may depend on measured geometry.
struct BlocksView: View {
    let blocks: [Block]
    let expandCells: Bool

    var body: some View {
        // A List is backed by NSTableView and only materialises the rows on
        // screen. ScrollView + VStack builds every block up front (334MB on a
        // 590-paragraph form); LazyVStack virtualises but re-measures the grids
        // continuously and pegged the CPU. List is the container that does both.
        List(Array(blocks.enumerated()), id: \.offset) { _, block in
            row(for: block)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func row(for block: Block) -> some View {
        switch block {
        case .paragraph(let p):
            Text(p.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .table(let table):
            TableGrid(table: table, expanded: expandCells)
        }
    }
}

/// Renders a reconstructed table as a real grid.
///
/// Column widths are resolved up front and every cell gets an exact width. Giving
/// cells flexible min/max frames instead makes HStack search for a layout, and
/// with multi-thousand-character cells each probe re-lays out the whole string —
/// that combination pegs the main thread.
struct TableGrid: View {
    let table: HwpKit.Table
    let expanded: Bool

    /// Target width for a whole table. Columns split this, so a one-column table
    /// gets the full width instead of the 150pt a fixed per-column size gave it.
    private static let tableWidth: CGFloat = 860

    /// Beyond this many columns a grid is unreadable anyway, and laying one out
    /// is what blanked the window on a real 사업계획서 양식. Fall back to text.
    private static let maxRenderableColumns = 24

    private var columnWidth: CGFloat {
        max(110, Self.tableWidth / CGFloat(max(1, table.columnCount)))
    }

    var body: some View {
        if table.columnCount > Self.maxRenderableColumns {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    Text(row.map(\.text).joined(separator: "  |  "))
                        .font(.callout)
                        .lineLimit(expanded ? nil : 4)
                        .frame(width: Self.tableWidth, alignment: .topLeading)
                }
            }
            .padding(8)
            .overlay(Rectangle().stroke(.separator, lineWidth: 1))
        } else {
            grid
        }
    }

    private var grid: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 1, verticalSpacing: 1) {
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        CellView(cell: cell, columnWidth: columnWidth, expanded: expanded)
                            .gridCellColumns(cell.columnSpan)
                    }
                }
            }
        }
        .padding(1)
        .background(Color(nsColor: .separatorColor))
    }
}

struct CellView: View {
    let cell: TableCell

    /// Every dimension here is a concrete number.
    ///
    /// `maxWidth: .infinity` inside a `Grid` makes every column ask for unbounded
    /// width, so the grid can never settle on a column layout — that is what sent
    /// memory past a gigabyte. `textSelection` and `fixedSize` are left off too:
    /// each adds per-cell work that a hundred-cell form multiplies.
    private static let collapsedLines = 6
    let columnWidth: CGFloat

    /// Whether long cells are shown in full. Driven from one control in the
    /// toolbar rather than a tap handler per cell: attaching a gesture to every
    /// cell put a hundred-odd hit-test targets under the cursor, and AppKit
    /// walked all of them on each mouse move — the window stuttered on hover.
    let expanded: Bool

    var body: some View {
        Text(cell.text)
            .font(.callout)
            .lineLimit(expanded ? nil : Self.collapsedLines)
            .frame(width: columnWidth * CGFloat(cell.columnSpan) - 18,
                   alignment: .topLeading)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            // Grid lines come from the 1pt gaps between cells showing the grid's
            // background, not from a stroke on each cell: 420 stroke shapes were
            // 420 extra views to lay out and keep alive.
            .background(Color(nsColor: .textBackgroundColor))
            .allowsHitTesting(false)
    }
}

import AppKit
import HwpKit
import SwiftUI

/// Counts matches for the rows being typed, off the main thread.
///
/// Owned by `ContentView` rather than declared inside the sheet: a `@StateObject`
/// in sheet content is rebuilt on every body evaluation, which is what kept the
/// image panel's thumbnails from ever appearing.
@MainActor
final class EditPreview: ObservableObject {
    @Published private(set) var counts: [HwpChange: (found: Int, skipped: Int)] = [:]
    @Published private(set) var working = false

    private var pending: Task<Void, Never>?

    /// Recounts after a pause in typing. Each keystroke would otherwise
    /// decompress the whole body again.
    func refresh(_ changes: [HwpChange], in url: URL?) {
        pending?.cancel()
        guard let url, !changes.isEmpty else { counts = [:]; return }
        working = true
        pending = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            let found = await Task.detached(priority: .userInitiated) { () -> [HwpChange: (found: Int, skipped: Int)] in
                guard let data = try? Data(contentsOf: url) else { return [:] }
                return HwpEditor.preview(changes, in: data)
            }.value
            guard !Task.isCancelled else { return }
            counts = found
            working = false
        }
    }

    func clear() {
        pending?.cancel()
        counts = [:]
        working = false
    }
}

/// Find-and-replace over the body text, saved to a new file.
///
/// The original is never a possible destination. The save panel starts on a
/// `_수정` name and the write refuses the source path outright, so the document
/// being edited cannot be the one overwritten even by accident.
struct EditPanel: View {
    let sourceURL: URL?
    let documentName: String
    /// Whatever is in the document search box. Someone who has just found a term
    /// and opened this panel means to replace that term.
    let seed: String
    @ObservedObject var preview: EditPreview
    @Environment(\.dismiss) private var dismiss

    @State private var rows: [Row] = [Row()]
    @State private var status: Status?
    @State private var saving = false

    private struct Row: Identifiable {
        let id = UUID()
        var find = ""
        var replaceWith = ""

        var change: HwpChange? {
            find.isEmpty ? nil : HwpChange(find: find, replaceWith: replaceWith)
        }
    }

    private enum Status {
        case saved(URL, Int)
        case skipped([String])
        case failed(String)
    }

    private var changes: [HwpChange] { rows.compactMap(\.change) }
    private var totalFound: Int { changes.reduce(0) { $0 + (preview.counts[$1]?.found ?? 0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($rows) { $row in
                        rowView($row)
                    }
                    Button {
                        rows.append(Row())
                    } label: {
                        Label("줄 추가", systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 340)
        .onAppear {
            if rows.count == 1, rows[0].find.isEmpty, !seed.isEmpty {
                rows[0].find = seed
                preview.refresh(changes, in: sourceURL)
            }
        }
        .onChange(of: rows.map { "\($0.find)\u{0}\($0.replaceWith)" }) { _ in
            status = nil
            preview.refresh(changes, in: sourceURL)
        }
        .onDisappear { preview.clear() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("텍스트 바꾸기")
                .font(.headline)
            Text("원본은 고치지 않습니다. 바꾼 내용은 새 파일로 저장됩니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    private func rowView(_ row: Binding<Row>) -> some View {
        HStack(spacing: 8) {
            TextField("찾을 말", text: row.find)
                .textFieldStyle(.roundedBorder)
            Image(systemName: "arrow.right")
                .foregroundStyle(.tertiary)
            TextField("바꿀 말", text: row.replaceWith)
                .textFieldStyle(.roundedBorder)
            countLabel(for: row.wrappedValue)
                .frame(width: 62, alignment: .trailing)
            Button {
                rows.removeAll { $0.id == row.wrappedValue.id }
                if rows.isEmpty { rows = [Row()] }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(rows.count == 1 && rows[0].find.isEmpty)
        }
    }

    @ViewBuilder
    private func countLabel(for row: Row) -> some View {
        if let change = row.change, let n = preview.counts[change] {
            if n.found > 0 {
                Text("\(n.found)곳")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text("없음")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        } else if row.change != nil, preview.working {
            ProgressView().controlSize(.small)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            statusView
            Spacer()
            Button("닫기") { dismiss() }
            Button("새 파일로 저장…") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(totalFound == 0 || saving)
        }
        .padding(14)
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .saved(let url, let n):
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label("\(n)곳 바꿔 \(url.lastPathComponent) 저장 — Finder에서 보기",
                      systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            .buttonStyle(.plain)
        case .skipped(let notes):
            Label(notes.joined(separator: " / "), systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(3)
        case nil:
            if totalFound > 0 {
                Text("모두 \(totalFound)곳")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func save() {
        guard let sourceURL else { return }
        let base = (documentName as NSString).deletingPathExtension
        let ext = (documentName as NSString).pathExtension

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(base)_수정.\(ext)"
        panel.directoryURL = sourceURL.deletingLastPathComponent()
        panel.message = "원본과 다른 이름으로 저장하세요."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard destination.standardizedFileURL != sourceURL.standardizedFileURL else {
            status = .failed("원본을 덮어쓸 수는 없습니다. 다른 이름을 쓰세요.")
            return
        }

        saving = true
        let list = changes
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<HwpEditReport, Error> in
                Result { try HwpEditor.apply(list, to: sourceURL) }
            }.value
            saving = false
            switch outcome {
            case .failure(let error):
                status = .failed(error.localizedDescription)
            case .success(let report):
                do {
                    try report.data.write(to: destination)
                    status = report.skipped.isEmpty
                        ? .saved(destination, report.replacements)
                        : .skipped(report.skipped)
                } catch {
                    status = .failed("저장하지 못했습니다: \(error.localizedDescription)")
                }
            }
        }
    }
}

import AppKit
import HwpKit
import SwiftUI

/// A zip whose names have been read correctly, ready to unpack.
///
/// Kept as a plain value on the model rather than holding the `ZipArchive`:
/// the archive keeps the whole file in memory, and a list of names and sizes is
/// all the view needs until someone asks to unpack.
struct ArchiveContents {
    let url: URL
    let rows: [Row]
    let health: ZipArchive.NameHealth

    struct Row: Identifiable {
        let id = UUID()
        let name: String
        let size: Int
        let repaired: Bool
    }

    var repairedCount: Int { rows.filter(\.repaired).count }
    var totalBytes: Int { rows.reduce(0) { $0 + $1.size } }

    /// Reads the listing, or nil when the file is not a zip this can open.
    init?(url: URL) {
        guard let data = try? Data(contentsOf: url), let zip = ZipArchive(data: data) else {
            return nil
        }
        self.url = url
        self.health = zip.nameHealth
        self.rows = zip.entries
            .filter { !$0.isDirectory }
            .map { Row(name: $0.name, size: $0.uncompressedSize,
                       repaired: $0.nameEncoding == .cp949) }
    }
}

/// Listing and unpacking for a zip.
///
/// The reason this screen exists is the one line at the bottom: Finder will
/// unpack these names as `????`, and there is no way to tell from Finder that it
/// has done so. Showing the corrected names next to that warning is the whole
/// feature.
struct ArchivePanel: View {
    let contents: ArchiveContents
    @State private var status: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            List(contents.rows) { row in
                HStack(spacing: 8) {
                    Image(systemName: icon(for: row.name))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text(row.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if row.repaired {
                        Text("이름 복구")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.22), in: Capsule())
                    }
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(row.size),
                                                   countStyle: .file))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            verdict
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.zipper")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(contents.url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(contents.rows.count)개 · "
                     + ByteCountFormatter.string(fromByteCount: Int64(contents.totalBytes),
                                                 countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if working { ProgressView().controlSize(.small) }
            Button("풀기…") { unpack() }
                .keyboardShortcut(.defaultAction)
                .disabled(working)
        }
        .padding(12)
    }

    /// Says which side this archive breaks on, because neither side can see its
    /// own damage: one made on Windows reads as `????` here, one made here reads
    /// as mojibake there.
    @ViewBuilder
    private var verdict: some View {
        let health = contents.health
        if health.isClean {
            banner("이름이 정상입니다. 맥에서도 윈도우에서도 안 깨집니다.",
                   icon: "checkmark.seal.fill", tint: .green)
        } else if health.breaksOnMac {
            banner("윈도우에서 만든 압축입니다. Finder로 풀면 \(health.cp949)개의 이름이 "
                   + "????로 깨집니다. 여기서 풀면 제대로 나옵니다.",
                   icon: "exclamationmark.triangle.fill", tint: .orange)
        } else {
            var why: [String] = []
            if health.decomposed > 0 { why.append("자음·모음이 분리됨 \(health.decomposed)개") }
            if health.undeclared > 0 { why.append("UTF-8 표시 없음 \(health.undeclared)개") }
            banner("이대로 윈도우에 보내면 이름이 깨집니다 (" + why.joined(separator: ", ")
                   + "). 풀어서 다시 묶으면 고쳐집니다.",
                   icon: "exclamationmark.triangle.fill", tint: .orange)
        }
    }

    private func banner(_ text: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.caption)
            Spacer()
        }
        .padding(10)
        .background(tint.opacity(0.10))
    }

    private func icon(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "hwp", "hwpx": return "doc.text"
        case "png", "jpg", "jpeg", "gif", "bmp", "heic": return "photo"
        case "pdf": return "doc.richtext"
        case "zip": return "doc.zipper"
        default: return "doc"
        }
    }

    private func unpack() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "여기에 풀기"
        panel.directoryURL = contents.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        let base = contents.url.deletingPathExtension().lastPathComponent
        let destination = folder.appendingPathComponent(base)
        let source = contents.url
        working = true
        status = nil

        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                () -> Result<ZipArchive.ExtractReport, Error> in
                Result {
                    guard let data = try? Data(contentsOf: source),
                          let zip = ZipArchive(data: data) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    return try zip.extract(to: destination)
                }
            }.value
            working = false
            switch outcome {
            case .failure(let error):
                status = "풀지 못했습니다: \(error.localizedDescription)"
            case .success(let report):
                status = report.repairedNames
                    ? "\(report.written.count)개를 풀었습니다. 한글 이름을 고쳤습니다."
                    : "\(report.written.count)개를 풀었습니다."
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            }
        }
    }
}

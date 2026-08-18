import AppKit
import HwpKit
import SwiftUI

/// Files waiting to be packed.
struct CompressRequest {
    var urls: [URL]

    var suggestedName: String {
        guard let first = urls.first else { return "압축.zip" }
        let base = urls.count == 1
            ? first.deletingPathExtension().lastPathComponent
            : first.deletingLastPathComponent().lastPathComponent
        return (base.isEmpty ? "압축" : base) + ".zip"
    }
}

/// Making an archive that survives the trip to Windows.
///
/// The reason to do this here rather than in Finder is invisible from this Mac:
/// Finder writes filenames decomposed, so `보고서` leaves as `ᄇ`+`ᅩ`+`ᄀ`… and
/// arrives looking wrong, while showing correctly the whole time on the machine
/// that made it. There is no way to notice the damage locally, which is why the
/// panel says what it is doing.
struct CompressPanel: View {
    let request: CompressRequest
    let onCancel: () -> Void

    @State private var status: String?
    @State private var working = false
    @State private var packed: [ZipWriter.File] = []

    private var totalBytes: Int { packed.reduce(0) { $0 + $1.data.count } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if packed.isEmpty {
                Spacer()
                ProgressView("읽는 중…").frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(Array(packed.enumerated()), id: \.offset) { _, file in
                    HStack(spacing: 8) {
                        Image(systemName: "doc")
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        Text(file.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Int64(file.data.count),
                                                       countStyle: .file))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            note
        }
        .task { packed = await Task.detached { ZipWriter.files(at: request.urls) }.value }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "archivebox")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("압축 만들기")
                    .font(.headline)
                Text("\(packed.count)개 · "
                     + ByteCountFormatter.string(fromByteCount: Int64(totalBytes),
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
            Button("취소") { onCancel() }
            Button("압축하기…") { compress() }
                .keyboardShortcut(.defaultAction)
                .disabled(packed.isEmpty || working)
        }
        .padding(12)
    }

    private var note: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
            // No count here: whether a name arrives decomposed depends on which
            // API handed it over, so claiming "N개를 고쳤다" would be a number
            // this screen cannot actually stand behind. What it can state is
            // what the writer always does.
            Text("파일 이름을 UTF-8로 쓰고 자음·모음을 합쳐서 저장합니다. "
                 + "맥 기본 압축은 둘 다 안 해서 윈도우에서 이름이 깨집니다.")
                .font(.caption)
            Spacer()
        }
        .padding(10)
        .background(.green.opacity(0.10))
    }

    private func compress() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = request.suggestedName
        panel.directoryURL = request.urls.first?.deletingLastPathComponent()
        panel.message = "윈도우에서 이름이 깨지지 않는 zip으로 저장합니다."
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let files = packed
        working = true
        status = nil
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<Int, Error> in
                Result {
                    let bytes = ZipWriter.archive(files)
                    try bytes.write(to: destination)
                    return bytes.count
                }
            }.value
            working = false
            switch outcome {
            case .failure(let error):
                status = "저장하지 못했습니다: \(error.localizedDescription)"
            case .success(let size):
                status = "\(files.count)개를 묶었습니다 ("
                    + ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) + ")"
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            }
        }
    }
}

import AppKit
import HwpKit
import ImageIO
import SwiftUI

/// Thumbnails for embedded images.
///
/// Decoding is done one image at a time and the full-size bitmap is dropped as
/// soon as a thumbnail exists. A 한글 form can hold a dozen uncompressed BMPs of
/// several megabytes each; keeping them decoded would dwarf the rest of the app.
@MainActor
final class ThumbnailStore: ObservableObject {
    @Published private(set) var thumbnails: [String: NSImage] = [:]
    @Published private(set) var loading = false

    private static let maxEdge = 220

    func load(_ images: [HwpImage]) {
        guard !loading, thumbnails.count < images.count else { return }
        loading = true
        Task.detached(priority: .utility) {
            for image in images {
                guard await self.thumbnails[image.id] == nil else { continue }
                guard let data = image.data() else { continue }
                if let thumb = Self.thumbnail(from: data) {
                    await MainActor.run { self.thumbnails[image.id] = thumb }
                } else if let fallback = NSImage(data: data) {
                    // ImageIO declined the format; hand the raw image to AppKit.
                    await MainActor.run { self.thumbnails[image.id] = fallback }
                }
            }
            await MainActor.run { self.loading = false }
        }
    }

    /// Decodes straight to thumbnail size with ImageIO.
    ///
    /// `NSImage.lockFocus()` is main-thread-only AppKit drawing — calling it from
    /// a background task silently produced blank images. `CGImageSource` is
    /// thread-safe and, more importantly, never materialises the full bitmap: a
    /// 6MB BMP is read straight down to a 220px thumbnail.
    nonisolated private static func thumbnail(from data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge as NSNumber,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

struct ImagePanel: View {
    let images: [HwpImage]
    let documentName: String
    @StateObject private var store = ThumbnailStore()
    @Environment(\.dismiss) private var dismiss

    private var totalBytes: Int { images.reduce(0) { $0 + $1.storedByteCount } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("이미지 \(images.count)개")
                    .font(.headline)
                Text(ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if store.loading {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("모두 내보내기…") { exportAll() }
                Button("닫기") { dismiss() }
            }
            .padding(12)
            Divider()

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(images) { image in
                        VStack(spacing: 5) {
                            Group {
                                if let thumb = store.thumbnails[image.id] {
                                    Image(nsImage: thumb)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                } else {
                                    Image(systemName: "photo")
                                        .font(.largeTitle)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .frame(height: 120)
                            .frame(maxWidth: .infinity)
                            .background(.quaternary.opacity(0.25))

                            Text(image.name)
                                .font(.caption2)
                                .lineLimit(1)
                            Text("\(image.format) · "
                                 + ByteCountFormatter.string(fromByteCount: Int64(image.storedByteCount),
                                                             countStyle: .file) + " (압축)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(12)
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .onAppear { store.load(images) }
    }

    private func exportAll() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "여기에 저장"
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        let base = (documentName as NSString).deletingPathExtension
        let dir = folder.appendingPathComponent("\(base)_이미지")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        for image in images {
            guard let data = image.data() else { continue }
            let ext = image.detectedFormat() ?? image.format
            let name = (image.name as NSString).deletingPathExtension + "." + ext
            try? data.write(to: dir.appendingPathComponent(name))
        }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }
}

import AppKit
import HwpKit

/// The Finder entry: select files, right-click, 서비스 → 윈도우 전송용으로 압축.
///
/// A top-level Finder context menu item needs a Finder extension, which runs into
/// the same signing wall the Spotlight importer does. A Service needs nothing but
/// an entry in `Info.plist`, appears under the right-click menu, and works with the
/// signature this app already has.
///
/// The whole point is that the damage this prevents is invisible on the machine
/// doing the damage: a zip made by Finder carries decomposed names and no UTF-8
/// flag, and looks perfect here right up until it arrives on Windows.
@objc final class WindowsPackService: NSObject {
    @objc func packForWindows(_ pasteboard: NSPasteboard, userData: String,
                              error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        guard let first = urls.first else {
            error.pointee = "압축할 파일을 선택하세요." as NSString
            return
        }

        let folder = first.deletingLastPathComponent()
        let base = urls.count == 1
            ? first.deletingPathExtension().lastPathComponent
            : folder.lastPathComponent
        let destination = Self.available(in: folder, named: base.isEmpty ? "압축" : base)

        let files = ZipWriter.files(at: urls)
        guard !files.isEmpty else {
            error.pointee = "읽을 수 있는 파일이 없습니다." as NSString
            return
        }
        do {
            try ZipWriter.archive(files).write(to: destination, options: .withoutOverwriting)
        } catch let failure {
            error.pointee = "압축하지 못했습니다: \(failure.localizedDescription)" as NSString
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([destination])
        Self.announce(destination, count: files.count)
    }

    /// Never overwrites. A service fires from a menu with no confirmation step, so
    /// it has no business replacing a file that is already there.
    private static func available(in folder: URL, named base: String) -> URL {
        let name = "\(base)_윈도우전송"
        var candidate = folder.appendingPathComponent(name).appendingPathExtension("zip")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(name) \(n)").appendingPathExtension("zip")
            n += 1
        }
        return candidate
    }

    private static func announce(_ url: URL, count: Int) {
        let alert = NSAlert()
        alert.messageText = "\(url.lastPathComponent) 만들었습니다"
        alert.informativeText = "\(count)개를 묶었습니다. 파일 이름을 UTF-8로 쓰고 자음·모음을 "
            + "합쳤기 때문에 윈도우에서 이름이 깨지지 않습니다."
        alert.alertStyle = .informational
        alert.runModal()
    }
}

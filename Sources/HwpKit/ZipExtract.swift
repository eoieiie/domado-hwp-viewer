import Foundation

/// Unpacking a zip whose names came from Korean Windows.
///
/// The names are the whole point — see `ZipArchive.decodeName`. What this adds is
/// writing them out without letting an archive decide where on the disk its
/// contents land.
extension ZipArchive {
    public struct ExtractReport {
        public let written: [URL]
        /// Entries left alone, each with the reason.
        public let skipped: [(name: String, reason: String)]
        /// True when any name had to be read as CP949, which is worth telling the
        /// user: it means the archive came from Windows and other tools on this
        /// Mac will show those names as `????`.
        public let repairedNames: Bool
    }

    /// Writes every entry under `destination`.
    ///
    /// An entry name is a string chosen by whoever built the archive, not a path
    /// this program picked. `../../../.ssh/authorized_keys` is a legal zip entry
    /// name, so each destination is resolved and checked to be inside the folder
    /// before anything is written. Entries that are not are skipped and reported.
    public func extract(to destination: URL) throws -> ExtractReport {
        let root = destination.standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var written: [URL] = []
        var skipped: [(name: String, reason: String)] = []
        var repaired = false

        for entry in entries {
            if entry.nameEncoding == .cp949 { repaired = true }

            guard let target = safeURL(for: entry.name, under: root) else {
                skipped.append((entry.name, "압축 파일 밖을 가리켜서 건너뜀"))
                continue
            }
            if entry.isDirectory {
                try FileManager.default.createDirectory(at: target,
                                                        withIntermediateDirectories: true)
                continue
            }
            guard let bytes = read(entry) else {
                skipped.append((entry.name, "풀지 못함 (지원하지 않는 압축 방식일 수 있음)"))
                continue
            }
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: target)
            written.append(target)
        }
        return ExtractReport(written: written, skipped: skipped, repairedNames: repaired)
    }

    /// Where an entry may be written, or nil when its name points outside.
    private func safeURL(for name: String, under root: URL) -> URL? {
        // Drop anything that makes the name absolute or drive-relative before it
        // is joined, then confirm the resolved path is still inside.
        let cleaned = name
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .filter { $0 != "." && !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }

        var target = root
        for part in cleaned { target.appendPathComponent(String(part)) }
        let resolved = target.standardizedFileURL

        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard resolved.path.hasPrefix(rootPath) else { return nil }
        return resolved
    }
}

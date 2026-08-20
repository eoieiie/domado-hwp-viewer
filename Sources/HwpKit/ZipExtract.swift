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
        /// Guards the whole operation, not just each entry: a thousand entries
        /// each under the per-file ceiling still add up to a full disk.
        var totalBytes = 0

        for entry in entries {
            if entry.nameEncoding == .cp949 { repaired = true }

            guard let parts = safeComponents(of: entry.name) else {
                skipped.append((entry.name, "압축 파일 밖을 가리켜서 건너뜀"))
                continue
            }
            let path = ([root.path] + parts).joined(separator: "/")

            if entry.isDirectory {
                try Self.makeDirectory(path)
                continue
            }
            guard entry.uncompressedSize <= Self.maxEntryBytes else {
                skipped.append((entry.name, "너무 큽니다 — 압축 폭탄일 수 있어 건너뜀"))
                continue
            }
            guard totalBytes + entry.uncompressedSize <= Self.maxTotalBytes else {
                skipped.append((entry.name, "전체 용량 한도를 넘어 건너뜀"))
                continue
            }
            guard let bytes = read(entry) else {
                skipped.append((entry.name, "풀지 못함 (지원하지 않는 압축 방식일 수 있음)"))
                continue
            }
            totalBytes += bytes.count
            try Self.makeDirectory(([root.path] + parts.dropLast()).joined(separator: "/"))
            try Self.write(bytes, to: path)
            written.append(URL(fileURLWithPath: path))
        }
        return ExtractReport(written: written, skipped: skipped, repairedNames: repaired)
    }

    /// An entry's path split into components, or nil when it points outside.
    ///
    /// An entry name is a string chosen by whoever built the archive. `..` is
    /// rejected outright rather than resolved: with no `..` left, joining the
    /// parts onto the destination cannot leave it, and there is nothing to get
    /// subtly wrong about the comparison afterwards.
    private func safeComponents(of name: String) -> [String]? {
        // Normalised here, not at decode time: the reader has to be able to
        // report that an archive holds decomposed names, but what lands on disk
        // must be composed or the problem simply moves to the next hop.
        let parts = name.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .map(String.init)
            .filter { $0 != "." && !$0.isEmpty }
        guard !parts.isEmpty, !parts.contains("..") else { return nil }
        return parts
    }

    /// Creates a file with exactly these path bytes.
    ///
    /// `FileManager` and `URL` route paths through `fileSystemRepresentation`,
    /// which decomposes them — a name stored as `한` comes back on disk as
    /// `ᄒ`+`ᅡ`+`ᆫ`. That is invisible in Finder and reappears the moment the
    /// user re-sends the file, which is the exact problem this feature exists to
    /// remove. POSIX takes the bytes as given, and APFS keeps them.
    private static func write(_ bytes: Data, to path: String) throws {
        let fd = path.withCString { open($0, O_WRONLY | O_CREAT | O_TRUNC, 0o644) }
        guard fd >= 0 else { throw posixError(path) }
        defer { close(fd) }

        try bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                guard n > 0 else { throw posixError(path) }
                offset += n
            }
        }
    }

    /// `mkdir -p` over exact bytes, for the same reason as `write`.
    private static func makeDirectory(_ path: String) throws {
        var built = ""
        for part in path.split(separator: "/") {
            built += "/" + part
            let made = built.withCString { mkdir($0, 0o755) }
            if made != 0, errno != EEXIST { throw posixError(built) }
        }
    }

    private static func posixError(_ path: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey:
                            "\(path): \(String(cString: strerror(errno)))"])
    }
}

extension ZipArchive {
    /// What is wrong with this archive's names, and for whom.
    ///
    /// The two failure directions are not symmetric, and neither is visible on
    /// the machine that caused it. An archive from Korean Windows reads as `????`
    /// here; one made here reads as mojibake there. Being able to say which is
    /// the difference between "trust this" and "repack it before sending".
    public struct NameHealth {
        /// Names stored in CP949 — the archive came from Korean Windows and
        /// other tools on this Mac will show them as `????`.
        public let cp949: Int
        /// Names with Hangul split into jamo. macOS writes these.
        public let decomposed: Int
        /// Non-ASCII names the archive does not declare UTF-8, so a Windows
        /// reader falls back to its own code page and sees mojibake.
        public let undeclared: Int

        public var breaksOnMac: Bool { cp949 > 0 }
        public var breaksOnWindows: Bool { decomposed > 0 || undeclared > 0 }
        public var isClean: Bool { !breaksOnMac && !breaksOnWindows }
    }

    public var nameHealth: NameHealth {
        let real = entries.filter { !$0.name.hasPrefix("__MACOSX/") }
        return NameHealth(
            cp949: real.filter { $0.nameEncoding == .cp949 }.count,
            decomposed: real.filter { $0.isDecomposed }.count,
            undeclared: real.filter { !$0.declaresUTF8 && !$0.name.allSatisfy(\.isASCII) }.count)
    }
}

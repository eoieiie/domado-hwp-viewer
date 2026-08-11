import Foundation

/// In-place replacement of a single stream inside a compound file.
///
/// The safe part of this design is what it refuses to do. Rebuilding the
/// container would mean re-deriving the FAT, the DIFAT, the directory and the
/// mini stream, and a mistake in any of them produces a file that 한글 opens as
/// garbage — with no warning that anything went wrong. So nothing is rebuilt.
/// The stream's existing sector chain is overwritten, its recorded length is
/// updated, and every other byte of the original file is copied through
/// untouched. If the new contents do not fit the sectors already allocated to
/// the stream, the write is refused rather than made to fit.
extension CompoundFile {
    enum WriteError: LocalizedError {
        case noSuchStream(String)
        case tooLarge(needed: Int, available: Int)
        case miniStreamUnsupported(String)
        case unalignedContainer
        case sectorNotFree(UInt32)

        var errorDescription: String? {
            switch self {
            case .noSuchStream(let name):
                return "문서 안에 \(name) 스트림이 없습니다."
            case .tooLarge(let needed, let available):
                return "수정한 본문을 담을 자리를 문서 안에서 확보하지 못했습니다 "
                    + "(\(needed)바이트 필요, \(available)바이트까지 가능)."
            case .miniStreamUnsupported(let name):
                return "\(name)이(가) 너무 작아(4KB 미만) 이 방식으로는 고칠 수 없습니다."
            case .unalignedContainer:
                return "문서 크기가 섹터 경계에 맞지 않습니다. 손상된 파일일 수 있습니다."
            case .sectorNotFree(let s):
                return "\(s)번 자리가 비어 있지 않아 늘리지 않았습니다."
            }
        }
    }

    /// Sectors of a stream in chain order, or nil when there is no such stream.
    private func chainSectors(from start: UInt32, byteCount: Int) -> [UInt32] {
        var out: [UInt32] = []
        var s = start
        var covered = 0
        while s != 0xFFFF_FFFE, s != 0xFFFF_FFFF, Int(s) < fatTable.count, covered < byteCount {
            out.append(s)
            covered += sectorSize
            s = fatTable[Int(s)]
        }
        return out
    }

    private func fileOffset(ofSector s: UInt32) -> Int { 512 + Int(s) * sectorSize }

    /// Where sector `s`'s own allocation-table entry lives in the file.
    private func fileOffset(ofAllocationEntry s: UInt32) -> Int? {
        let perSector = sectorSize / 4
        let which = Int(s) / perSector
        guard which < allocationTableSectors.count else { return nil }
        return fileOffset(ofSector: allocationTableSectors[which]) + (Int(s) % perSector) * 4
    }

    private static func write(_ value: UInt32, into data: inout Data, at offset: Int) {
        let i = data.startIndex + offset
        guard i + 4 <= data.endIndex else { return }
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.replaceSubrange(i..<(i + 4), with: $0) }
    }

    /// Extends a stream's sector chain to `needed` sectors by adding sectors at
    /// the end of the file.
    ///
    /// New sectors are only ever appended, never taken from gaps inside the file:
    /// a sector the allocation table calls free might still be referenced by
    /// something this reader does not model, and reusing it would overwrite live
    /// data. Appending cannot collide with anything. The table has to already
    /// have a free entry covering the new sector — creating one would mean
    /// growing the table and its index, which is where this stops and refuses.
    private func grown(_ chain: [UInt32], to needed: Int,
                       in file: inout Data) throws -> [UInt32] {
        guard (file.count - 512) % sectorSize == 0 else { throw WriteError.unalignedContainer }
        var next = UInt32((file.count - 512) / sectorSize)
        var full = chain
        while full.count < needed {
            guard Int(next) < fatTable.count else {
                throw WriteError.tooLarge(needed: needed * sectorSize,
                                          available: chain.count * sectorSize)
            }
            guard fatTable[Int(next)] == CompoundFile.unusedSector else {
                throw WriteError.sectorNotFree(next)
            }
            file.append(Data(count: sectorSize))
            full.append(next)
            next += 1
        }
        // Re-link the whole chain. Only the last original entry actually changes;
        // rewriting the rest costs nothing and keeps the chain self-consistent
        // even if it was already odd.
        for (i, s) in full.enumerated() {
            guard let at = fileOffset(ofAllocationEntry: s) else {
                throw WriteError.tooLarge(needed: needed * sectorSize,
                                          available: chain.count * sectorSize)
            }
            Self.write(i + 1 < full.count ? full[i + 1] : CompoundFile.chainEnd,
                       into: &file, at: at)
        }
        return full
    }

    /// Byte offset of a directory entry's own 128-byte record.
    private func fileOffset(ofDirectoryEntry index: Int) -> Int? {
        let perSector = sectorSize / 128
        let which = index / perSector
        guard which < directoryChain.count else { return nil }
        return fileOffset(ofSector: directoryChain[which]) + (index % perSector) * 128
    }

    /// Bytes a stream currently occupies, and bytes its sector chain could hold.
    func space(of name: String) -> (stored: Int, allocated: Int, sectorSize: Int)? {
        guard let entry = entries.first(where: { $0.name == name && $0.type == 2 }),
              entry.size >= UInt64(miniStreamCutoff) else { return nil }
        let sectors = chainSectors(from: entry.start, byteCount: Int(entry.size))
        return (Int(entry.size), sectors.count * sectorSize, sectorSize)
    }

    /// The original file with `name`'s contents replaced by `new`.
    ///
    /// Only the stream's own sectors and its 128-byte directory record change.
    /// Sectors past the new length stay chained but unread — the recorded size is
    /// what a reader uses, and leaving the chain intact avoids touching the FAT.
    func replacing(stream name: String, with new: Data) throws -> Data {
        guard let entry = entries.first(where: { $0.name == name && $0.type == 2 }) else {
            throw WriteError.noSuchStream(name)
        }
        guard entry.size >= UInt64(miniStreamCutoff) else {
            throw WriteError.miniStreamUnsupported(name)
        }
        guard let dirOffset = fileOffset(ofDirectoryEntry: entry.index) else {
            throw WriteError.noSuchStream(name)
        }

        var out = rawBytes
        var sectors = chainSectors(from: entry.start, byteCount: Int(entry.size))
        let needed = max(1, (new.count + sectorSize - 1) / sectorSize)
        if needed > sectors.count {
            sectors = try grown(sectors, to: needed, in: &out)
        }
        let capacity = sectors.count * sectorSize
        guard new.count <= capacity else {
            throw WriteError.tooLarge(needed: new.count, available: capacity)
        }

        for (i, s) in sectors.enumerated() {
            let start = i * sectorSize
            guard start < new.count else { break }
            let slice = new[new.startIndex + start ..< min(new.endIndex, new.startIndex + start + sectorSize)]
            let at = out.startIndex + fileOffset(ofSector: s)
            guard at + slice.count <= out.endIndex else {
                throw WriteError.tooLarge(needed: new.count, available: capacity)
            }
            out.replaceSubrange(at ..< (at + slice.count), with: slice)
            // Zero the tail of the final sector so no fragment of the old body
            // survives past the new end.
            if slice.count < sectorSize {
                let padStart = at + slice.count
                let padEnd = min(out.endIndex, at + sectorSize)
                out.replaceSubrange(padStart ..< padEnd, with: Data(count: padEnd - padStart))
            }
        }

        // Directory record: stream size is a 64-bit little-endian field at 0x78.
        let sizeAt = out.startIndex + dirOffset + 0x78
        guard sizeAt + 8 <= out.endIndex else { throw WriteError.noSuchStream(name) }
        var size = UInt64(new.count).littleEndian
        withUnsafeBytes(of: &size) { out.replaceSubrange(sizeAt ..< (sizeAt + 8), with: $0) }
        return out
    }
}

import Foundation

/// Reader for the OLE Compound File (CFBF) container that an .hwp file is stored in.
///
/// The format is a FAT-like filesystem inside a single file: a header, a sector
/// allocation table, and a directory of named streams. Small streams live in a
/// separate "mini" stream with its own allocation table.
struct CompoundFile {
    private static let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
    private static let endOfChain: UInt32 = 0xFFFF_FFFE
    private static let freeSector: UInt32 = 0xFFFF_FFFF

    struct Entry {
        let name: String
        let type: UInt8      // 1 = storage, 2 = stream, 5 = root
        let start: UInt32
        let size: UInt64
    }

    private let data: Data
    private let sectorSize: Int
    private let miniSectorSize: Int
    private let miniCutoff: UInt32
    private var fat: [UInt32] = []
    private var miniFat: [UInt32] = []
    private var miniStream = Data()
    private(set) var entries: [Entry] = []

    init(data: Data) throws {
        guard data.count > 512, Array(data.prefix(8)) == Self.signature else {
            throw HwpError.notCompoundFile
        }
        self.data = data
        self.sectorSize = 1 << Int(data.u16(at: 0x1E))
        self.miniSectorSize = 1 << Int(data.u16(at: 0x20))
        self.miniCutoff = data.u32(at: 0x38)

        let fatCount = Int(data.u32(at: 0x2C))
        let dirStart = data.u32(at: 0x30)
        let miniStart = data.u32(at: 0x3C)
        let miniCount = Int(data.u32(at: 0x40))
        let difatStart = data.u32(at: 0x44)
        let difatCount = Int(data.u32(at: 0x48))

        // DIFAT: 109 entries inline in the header, then a chain of sectors.
        var difat: [UInt32] = (0..<109).map { data.u32(at: 0x4C + $0 * 4) }
        var sector = difatStart
        var remaining = difatCount
        while sector != Self.endOfChain, sector != Self.freeSector, remaining > 0 {
            let raw = self.sector(sector)
            let per = sectorSize / 4 - 1
            difat.append(contentsOf: (0..<per).map { raw.u32(at: $0 * 4) })
            sector = raw.u32(at: sectorSize - 4)
            remaining -= 1
        }

        for s in difat.prefix(fatCount) where s != Self.freeSector && s != Self.endOfChain {
            let raw = self.sector(s)
            fat.append(contentsOf: (0..<(sectorSize / 4)).map { raw.u32(at: $0 * 4) })
        }

        sector = miniStart
        remaining = miniCount
        while sector != Self.endOfChain, sector != Self.freeSector, remaining > 0 {
            let raw = self.sector(sector)
            miniFat.append(contentsOf: (0..<(sectorSize / 4)).map { raw.u32(at: $0 * 4) })
            sector = fat[Int(sector)]
            remaining -= 1
        }

        entries = readDirectory(start: dirStart)
        if let root = entries.first {
            miniStream = chain(start: root.start, size: Int(root.size))
        }
    }

    private func sector(_ n: UInt32) -> Data {
        let off = 512 + Int(n) * sectorSize
        guard off >= 0, off + sectorSize <= data.count else { return Data(count: sectorSize) }
        return data.subdata(in: off..<(off + sectorSize))
    }

    private func chain(start: UInt32, size: Int) -> Data {
        var out = Data()
        var s = start
        while s != Self.endOfChain, s != Self.freeSector, out.count < size, Int(s) < fat.count {
            out.append(sector(s))
            s = fat[Int(s)]
        }
        return out.prefix(size)
    }

    private func miniChain(start: UInt32, size: Int) -> Data {
        var out = Data()
        var s = start
        while s != Self.endOfChain, s != Self.freeSector, out.count < size, Int(s) < miniFat.count {
            let off = Int(s) * miniSectorSize
            guard off + miniSectorSize <= miniStream.count else { break }
            out.append(miniStream.subdata(in: off..<(off + miniSectorSize)))
            s = miniFat[Int(s)]
        }
        return out.prefix(size)
    }

    private func readDirectory(start: UInt32) -> [Entry] {
        // The directory is itself a stream; walk its sector chain directly since
        // `chain` needs a size we do not know yet.
        var raw = Data()
        var s = start
        while s != Self.endOfChain, s != Self.freeSector, Int(s) < fat.count {
            raw.append(sector(s))
            s = fat[Int(s)]
        }

        var result: [Entry] = []
        for i in 0..<(raw.count / 128) {
            let e = raw.subdata(in: (i * 128)..<((i + 1) * 128))
            let nameLen = Int(e.u16(at: 0x40))
            let nameBytes = e.prefix(max(0, nameLen - 2))
            let name = String(data: nameBytes, encoding: .utf16LittleEndian) ?? ""
            result.append(Entry(name: name,
                                type: e[e.startIndex + 0x42],
                                start: e.u32(at: 0x74),
                                size: e.u64(at: 0x78)))
        }
        return result
    }

    /// Contents of a named stream, or nil when the document has no such stream.
    func read(_ name: String) -> Data? {
        guard let e = entries.first(where: { $0.name == name && $0.type == 2 }) else { return nil }
        return e.size < UInt64(miniCutoff)
            ? miniChain(start: e.start, size: Int(e.size))
            : chain(start: e.start, size: Int(e.size))
    }

    var streamNames: [String] { entries.filter { $0.type == 2 }.map(\.name) }
}

// MARK: - Little-endian reads

extension Data {
    func u16(at offset: Int) -> UInt16 {
        let i = startIndex + offset
        guard i + 2 <= endIndex else { return 0 }
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    func u32(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        guard i + 4 <= endIndex else { return 0 }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[i + $1]) << (8 * UInt32($1)) }
    }

    func u64(at offset: Int) -> UInt64 {
        let i = startIndex + offset
        guard i + 8 <= endIndex else { return 0 }
        return (0..<8).reduce(UInt64(0)) { $0 | UInt64(self[i + $1]) << (8 * UInt64($1)) }
    }
}

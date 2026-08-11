import CoreFoundation
import Foundation
import HwpKit

// A Spotlight importer is a CFPlugIn: a COM-style object whose vtable macOS calls
// to pull searchable text out of a file. There is no Swift-native API for this, so
// the interface is laid out by hand.

private let importerTypeUUID = CFUUIDGetConstantUUIDWithBytes(
    nil, 0x8B, 0x08, 0xC4, 0xBF, 0x41, 0x5B, 0x11, 0xD8,
    0xB3, 0xF9, 0x00, 0x03, 0x93, 0x67, 0x26, 0xFC)

private let importerInterfaceUUID = CFUUIDGetConstantUUIDWithBytes(
    nil, 0x6E, 0xBC, 0x27, 0xC4, 0x89, 0x9C, 0x11, 0xD8,
    0x84, 0xA6, 0x00, 0x03, 0x93, 0x67, 0x26, 0xFC)

private let unknownInterfaceUUID = CFUUIDGetConstantUUIDWithBytes(
    nil, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46)

/// Must match `CFPlugInFactories` in the bundle's Info.plist.
private let factoryUUID = CFUUIDGetConstantUUIDWithBytes(
    nil, 0xE9, 0xA3, 0xB7, 0xD1, 0x4F, 0x2C, 0x4A, 0x88,
    0x9B, 0x31, 0x7C, 0x5D, 0x0E, 0x6F, 0x1A, 0x20)

private struct MDImporterInterface {
    var _reserved: UnsafeMutableRawPointer?
    var queryInterface: @convention(c) (UnsafeMutableRawPointer?, CFUUIDBytes,
                                        UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32
    var addRef: @convention(c) (UnsafeMutableRawPointer?) -> UInt32
    var release: @convention(c) (UnsafeMutableRawPointer?) -> UInt32
    var importData: @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary?,
                                    CFString?, CFString?) -> DarwinBoolean
}

private struct ImporterPlugin {
    var interface: UnsafeMutablePointer<MDImporterInterface>
    var factoryID: Unmanaged<CFUUID>?
    var refCount: UInt32
}

// MARK: - Metadata extraction

/// Spotlight indexes what we put in `attributes`. Only a handful of keys matter:
/// the text content (what full-text search matches on) and a few display fields.
private func debugLog(_ s: String) {
    guard ProcessInfo.processInfo.environment["HWP_IMPORTER_DEBUG"] != nil
            || FileManager.default.fileExists(atPath: "/tmp/hwpimporter.debug") else { return }
    if let h = FileHandle(forWritingAtPath: "/tmp/hwpimporter.log") {
        h.seekToEndOfFile(); h.write(Data((s + "\n").utf8)); h.closeFile()
    } else {
        try? (s + "\n").write(toFile: "/tmp/hwpimporter.log", atomically: true, encoding: .utf8)
    }
}

private func importData(file path: String, into attributes: CFMutableDictionary) -> Bool {
    debugLog("호출됨: \(path)")
    guard let document = try? HwpDocument(url: URL(fileURLWithPath: path)) else {
        debugLog("  파싱 실패"); return false
    }
    debugLog("  파싱 성공: \(document.blocks.count)블록")

    let dict = attributes as NSMutableDictionary
    let text = document.text
    guard !text.isEmpty else { return false }

    debugLog("  본문 \(text.count)자 기록")
    dict[kMDItemTextContent as String] = text
    dict[kMDItemNumberOfPages as String] = document.blocks.count
    dict[kMDItemKind as String] = document.format == .owpml ? "한글 문서 (hwpx)" : "한글 문서 (hwp)"

    // The first non-empty line of a 한글 form is nearly always its title.
    if let title = document.paragraphs.first(where: { $0.text.count > 1 })?.text {
        dict[kMDItemTitle as String] = String(title.prefix(200))
    }
    return true
}

// MARK: - COM plumbing

private func makeInterface() -> UnsafeMutablePointer<MDImporterInterface> {
    let p = UnsafeMutablePointer<MDImporterInterface>.allocate(capacity: 1)
    p.initialize(to: MDImporterInterface(
        _reserved: nil,
        queryInterface: { instance, iid, outInterface in
            guard let instance, let outInterface else { return -1 }
            let requested = CFUUIDCreateFromUUIDBytes(nil, iid)
            if CFEqual(requested, importerInterfaceUUID) || CFEqual(requested, unknownInterfaceUUID) {
                let plugin = instance.assumingMemoryBound(to: ImporterPlugin.self)
                plugin.pointee.refCount += 1
                outInterface.pointee = instance
                return 0                                  // S_OK
            }
            outInterface.pointee = nil
            return Int32(bitPattern: 0x8000_4002)         // E_NOINTERFACE
        },
        addRef: { instance in
            guard let instance else { return 0 }
            let plugin = instance.assumingMemoryBound(to: ImporterPlugin.self)
            plugin.pointee.refCount += 1
            return plugin.pointee.refCount
        },
        release: { instance in
            guard let instance else { return 0 }
            let plugin = instance.assumingMemoryBound(to: ImporterPlugin.self)
            plugin.pointee.refCount -= 1
            let remaining = plugin.pointee.refCount
            if remaining == 0 {
                if let id = plugin.pointee.factoryID {
                    CFPlugInRemoveInstanceForFactory(id.takeUnretainedValue())
                    id.release()
                }
                plugin.pointee.interface.deinitialize(count: 1)
                plugin.pointee.interface.deallocate()
                plugin.deinitialize(count: 1)
                plugin.deallocate()
            }
            return remaining
        },
        importData: { _, attributes, _, pathToFile in
            guard let attributes, let pathToFile else { return false }
            return DarwinBoolean(importData(file: pathToFile as String, into: attributes))
        }))
    return p
}

/// Entry point named in `CFPlugInFactories`. macOS calls this to instantiate us.
///
/// The second parameter is a `CFUUIDRef` — a pointer — not the 16-byte
/// `CFUUIDBytes` struct. Declaring the struct here compiles fine but breaks the
/// calling convention, so the type check never matched and instantiation failed.
@_cdecl("HwpImporterPluginFactory")
public func HwpImporterPluginFactory(allocator: CFAllocator?,
                                     typeID: CFUUID?) -> UnsafeMutableRawPointer? {
    guard let typeID, CFEqual(typeID, importerTypeUUID) else { return nil }

    guard let factory = factoryUUID else { return nil }
    let plugin = UnsafeMutablePointer<ImporterPlugin>.allocate(capacity: 1)
    plugin.initialize(to: ImporterPlugin(interface: makeInterface(),
                                         factoryID: Unmanaged.passRetained(factory),
                                         refCount: 1))
    CFPlugInAddInstanceForFactory(factory)
    return UnsafeMutableRawPointer(plugin)
}

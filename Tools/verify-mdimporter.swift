import CoreFoundation
import Foundation

struct MDIface {
    var _reserved: UnsafeMutableRawPointer?
    var queryInterface: @convention(c) (UnsafeMutableRawPointer?, CFUUIDBytes, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32
    var addRef: @convention(c) (UnsafeMutableRawPointer?) -> UInt32
    var release: @convention(c) (UnsafeMutableRawPointer?) -> UInt32
    var importData: @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary?, CFString?, CFString?) -> DarwinBoolean
}

let path = "/Users/eoieiie/Library/Spotlight/HwpImporter.mdimporter"
let url = URL(fileURLWithPath: path) as CFURL
guard let bundle = CFBundleCreate(nil, url) else { print("번들 실패"); exit(1) }
let typeUUID = CFUUIDGetConstantUUIDWithBytes(nil, 0x8B,0x08,0xC4,0xBF,0x41,0x5B,0x11,0xD8,0xB3,0xF9,0x00,0x03,0x93,0x67,0x26,0xFC)
guard let arr = CFPlugInFindFactoriesForPlugInTypeInPlugIn(typeUUID, CFBundleGetPlugIn(bundle)),
      CFArrayGetCount(arr) > 0 else { print("팩토리 실패"); exit(1) }
let fid = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFUUID.self)
guard let raw = CFPlugInInstanceCreate(nil, fid, typeUUID) else { print("인스턴스 실패"); exit(1) }
print("✅ 인스턴스 생성")

// 첫 멤버가 vtable 포인터
let pluginPtr = raw.assumingMemoryBound(to: UnsafeMutablePointer<MDIface>.self)
let iface = pluginPtr.pointee.pointee

let dict = NSMutableDictionary()
let file = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
let ok = iface.importData(raw, dict as CFMutableDictionary, "kr.co.hancom.hwp" as CFString, file as CFString)
print("✅ importData 반환: \(ok.boolValue)")
print("   기록된 키: \(dict.allKeys.map { "\($0)" }.sorted())")
if let text = dict["kMDItemTextContent"] as? String {
    print("   본문 \(text.count)자 — 앞부분: \(text.prefix(50).replacingOccurrences(of: "\n", with: " "))")
}
if let t = dict["kMDItemTitle"] as? String { print("   제목: \(t)") }

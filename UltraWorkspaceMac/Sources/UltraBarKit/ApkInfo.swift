import Foundation

/// Package name and version of an APK, read from its binary `AndroidManifest.xml` before anything is installed.
/// Only the manifest element's attributes are decoded (Android's AXML: string pool, resource map, start-element chunks).
public struct ApkInfo: Sendable, Equatable {
    public var package: String
    public var versionCode: Int
    public var versionName: String

    /// Reads the manifest out of the archive with the system's `unzip` (Foundation has no zip reader).
    public static func read(apk: URL) throws -> ApkInfo {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-p", apk.path, "AndroidManifest.xml"]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0, !data.isEmpty else { throw UltraBarError.protocolError("no AndroidManifest.xml in \(apk.lastPathComponent)") }
        return try parseManifest(data)
    }

    public static func parseManifest(_ b: Data) throws -> ApkInfo {
        let bytes = [UInt8](b)
        func u16(_ o: Int) -> Int { o + 1 < bytes.count ? Int(bytes[o]) | Int(bytes[o + 1]) << 8 : 0 }
        func u32(_ o: Int) -> Int { o + 3 < bytes.count ? u16(o) | u16(o + 2) << 16 : 0 }
        guard bytes.count > 8, u16(0) == 0x0003 else { throw UltraBarError.protocolError("not a binary XML manifest") }
        var strings: [String] = [], resmap: [Int] = []
        var pkg: String?, code: Int?, name: String?
        var off = 8
        while off + 8 <= bytes.count {
            let type = u16(off), size = u32(off + 4)
            guard size >= 8, off + size <= bytes.count else { break }
            switch type {
            case 0x0001: // string pool
                let n = u32(off + 8), flags = u32(off + 16), stringsStart = u32(off + 20)
                let utf8 = flags & 0x100 != 0
                for i in 0..<n {
                    var p = off + stringsStart + u32(off + 28 + 4 * i)
                    guard p < bytes.count else { strings.append(""); continue }
                    if utf8 {
                        if bytes[p] & 0x80 != 0 { p += 2 } else { p += 1 }          // UTF-16 length, skipped
                        var len = Int(bytes[p]); p += 1
                        if len & 0x80 != 0 { len = (len & 0x7f) << 8 | Int(bytes[p]); p += 1 }
                        let end = min(p + len, bytes.count)
                        strings.append(String(decoding: bytes[p..<end], as: UTF8.self))
                    } else {
                        var len = u16(p); p += 2
                        if len & 0x8000 != 0 { len = (len & 0x7fff) << 16 | u16(p); p += 2 }
                        let end = min(p + 2 * len, bytes.count)
                        var u: [UInt16] = []; var q = p
                        while q + 1 < end { u.append(UInt16(u16(q))); q += 2 }
                        strings.append(String(decoding: u, as: UTF16.self))
                    }
                }
            case 0x0180: // resource ids, parallel to the first strings
                resmap = stride(from: off + 8, to: off + size, by: 4).map { u32($0) }
            case 0x0102: // start element
                let nameIdx = u32(off + 20)
                guard nameIdx < strings.count, strings[nameIdx] == "manifest" else { break }
                let attrStart = off + 16 + u16(off + 24), attrCount = u16(off + 28)
                for i in 0..<attrCount {
                    let a = attrStart + 20 * i
                    let ni = u32(a + 4), raw = u32(a + 8), data = u32(a + 16)
                    let rid = ni < resmap.count ? resmap[ni] : 0
                    let attrName = ni < strings.count ? strings[ni] : ""
                    if rid == 0x0101021b { code = data }
                    else if rid == 0x0101021c { name = raw != 0xffff_ffff && raw < strings.count ? strings[raw] : String(data) }
                    else if attrName == "package", raw < strings.count { pkg = strings[raw] }
                }
            default: break
            }
            off += size
        }
        guard let pkg, let code else { throw UltraBarError.protocolError("manifest without package or versionCode") }
        return ApkInfo(package: pkg, versionCode: code, versionName: name ?? "")
    }
}

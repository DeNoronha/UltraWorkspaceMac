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
        // A manifest is a few kB; at most 4 MB is read (an archive that unpacks to more is not an APK we install).
        var data = Data()
        while true {
            let chunk = out.fileHandleForReading.readData(ofLength: 1 << 16)
            if chunk.isEmpty { break }
            data.append(chunk)
            if data.count > 4_000_000 { p.terminate(); p.waitUntilExit(); throw UltraBarError.protocolError("AndroidManifest.xml in \(apk.lastPathComponent) is too large") }
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0, !data.isEmpty else { throw UltraBarError.protocolError("no AndroidManifest.xml in \(apk.lastPathComponent)") }
        return try parseManifest(data)
    }

    public static func parseManifest(_ b: Data) throws -> ApkInfo {
        let bytes = [UInt8](b)
        func u16(_ o: Int) -> Int { o + 1 < bytes.count ? Int(bytes[o]) | Int(bytes[o + 1]) << 8 : 0 }
        func u32(_ o: Int) -> Int { o + 3 < bytes.count ? u16(o) | u16(o + 2) << 16 : 0 }
        func u8(_ o: Int) -> Int { o >= 0 && o < bytes.count ? Int(bytes[o]) : 0 }
        guard bytes.count > 8, u16(0) == 0x0003 else { throw UltraBarError.protocolError("not a binary XML manifest") }
        var strings: [String] = [], resmap: [Int] = []
        var pkg: String?, code: Int?, name: String?
        var off = 8
        while off + 8 <= bytes.count {
            let type = u16(off), size = u32(off + 4)
            guard size >= 8, off + size <= bytes.count else { break }
            switch type {
            case 0x0001: // string pool
                // The count comes from the file: never more offsets than the chunk can hold (L3).
                let n = min(u32(off + 8), size / 4), flags = u32(off + 16), stringsStart = u32(off + 20)
                let utf8 = flags & 0x100 != 0
                for i in 0..<n {
                    var p = off + stringsStart + u32(off + 28 + 4 * i)
                    guard p < bytes.count else { strings.append(""); continue }
                    if utf8 {
                        if u8(p) & 0x80 != 0 { p += 2 } else { p += 1 }          // UTF-16 length, skipped
                        var len = u8(p); p += 1
                        if len & 0x80 != 0 { len = (len & 0x7f) << 8 | u8(p); p += 1 }
                        let end = min(p + len, bytes.count)
                        guard p <= end else { strings.append(""); continue }
                        strings.append(String(decoding: bytes[p..<end], as: UTF8.self))
                    } else {
                        var len = u16(p); p += 2
                        if len & 0x8000 != 0 { len = (len & 0x7fff) << 16 | u16(p); p += 2 }
                        let end = min(p + 2 * len, bytes.count)
                        guard p <= end else { strings.append(""); continue }
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
                let attrStart = off + 16 + u16(off + 24), attrCount = min(u16(off + 28), max(0, (bytes.count - attrStart) / 20))
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

import Foundation
import Compression
import UltraBarKit

setvbuf(stdout, nil, _IONBF, 0) // line-by-line output even when piped/killed

// `kitcheck discover` — run the app's real Discovery from the terminal (which
// already has Local Network permission) to prove the code works against hardware.
if CommandLine.arguments.contains("weather") {
    let city = CommandLine.arguments.last ?? "Amsterdam"
    do {
        guard let p = try await OpenMeteo.geocode(city) else { print("no geocode for \(city)"); exit(2) }
        print("geocoded \(city) -> \(p.name), \(p.country)  (\(p.latitude), \(p.longitude))")
        let now = try await OpenMeteo.current(latitude: p.latitude, longitude: p.longitude, metric: true, placeName: p.name)
        print("now: \(Int(now.temperature.rounded()))\(now.unitSuffix)  code=\(now.code) sky=\(now.sky.label) day=\(now.isDay) hum=\(now.humidity ?? -1)% wind=\(now.windSpeed ?? 0)\(now.windSuffix) @ \(now.place)")
    } catch { print("weather error: \(error)"); exit(1) }
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "e2e") {
    let ip = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : "127.0.0.1"
    exit(Int32(await E2E.run(ip: ip)))
}

if CommandLine.arguments.contains("discover") {
    print("scanning UDP \(Proto.discoveryPort) for 8s…")
    let bars = await Discovery.listen(timeout: 8)
    print("discovered \(bars.count):")
    for b in bars { print("  \(b.name)  ip=\(b.ip)  sn=\(b.serialNo)  ver=\(b.version)  tcp=\(b.tcpPort)") }
    exit(bars.isEmpty ? 2 : 0)
}

var failures = 0
@MainActor func check(_ cond: Bool, _ name: String) {
    print("\(cond ? "ok  " : "FAIL") \(name)")
    if !cond { failures += 1 }
}

// CRC32 known vector
check(DeployPackager.crc32(Array("123456789".utf8)) == 0xCBF4_3926, "crc32('123456789') == 0xCBF43926")

// DeviceImage opaque header
do {
    let w = 4, h = 2
    let rgba = [UInt8](repeating: 0xFF, count: w * h * 4)
    let out = DeviceImage.encode(width: w, height: h, rgba: rgba)
    let word = UInt32(out[0]) | UInt32(out[1]) << 8 | UInt32(out[2]) << 16 | UInt32(out[3]) << 24
    check(Int(word & 0x3FF) == 4, "opaque marker == 4")
    check(Int((word >> 10) & 0x7FF) == w, "width encoded")
    check(Int(word >> 21) == h, "height encoded")
    let payload = UInt32(out[4]) | UInt32(out[5]) << 8 | UInt32(out[6]) << 16 | UInt32(out[7]) << 24
    check(Int(payload) == w * h * 2, "opaque payload size")
    check(out.count == 8 + w * h * 2, "opaque total size")
    check(out[8] == 0xFF && out[9] == 0xFF, "white -> 0xFFFF")
}

// DeviceImage alpha header
do {
    let w = 2, h = 2
    var rgba = [UInt8](repeating: 0xFF, count: w * h * 4)
    rgba[3] = 0x00
    let flat = DeviceImage.encode(width: w, height: h, rgba: rgba)
    check(Int((UInt32(flat[0]) | UInt32(flat[1]) << 8) & 0x3FF) == 4 && flat.count == 8 + w * h * 2, "default encode flattens to opaque (marker 4)")
    let out = DeviceImage.encode(width: w, height: h, rgba: rgba, allowAlpha: true)
    let word = UInt32(out[0]) | UInt32(out[1]) << 8 | UInt32(out[2]) << 16 | UInt32(out[3]) << 24
    check(Int(word & 0x3FF) == 5, "alpha marker == 5 (opt-in)")
    check(out.count == 8 + w * h * 3, "alpha total size")
    check(out[10] == 0x00, "first pixel alpha preserved")
}

// tgz = gzip + ustar, inflates back to a valid tar
do {
    let layer = DeployPackager.Layer(layerId: 1, widgetId: 101, defaultBin: [1, 2, 3], pressedBin: [4, 5, 6])
    let tgz = DeployPackager.buildTgz(layers: [layer], defaultLayer: 1)
    check(tgz[0] == 0x1f && tgz[1] == 0x8b && tgz[2] == 0x08, "gzip magic + deflate method")

    let body = tgz.subdata(in: 10..<(tgz.count - 8))
    var dst = [UInt8](repeating: 0, count: 65536)
    let n = body.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
        dst.withUnsafeMutableBufferPointer { d in
            compression_decode_buffer(d.baseAddress!, d.count,
                                      src.bindMemory(to: UInt8.self).baseAddress!, body.count,
                                      nil, COMPRESSION_ZLIB)
        }
    }
    let tar = Array(dst[0..<n])
    check(n > 0, "deflate body inflates")
    let magic = String(bytes: tar[257..<262], encoding: .ascii)
    check(magic == "ustar", "ustar magic at offset 257")
    let name = String(bytes: tar[0..<15], encoding: .ascii)
    check(name == "com_res101/defa", "first member name")

    // verify stored CRC32 matches the inflated->? no; verify gzip ISIZE trailer
    let isize = UInt32(tgz[tgz.count-4]) | UInt32(tgz[tgz.count-3]) << 8 | UInt32(tgz[tgz.count-2]) << 16 | UInt32(tgz[tgz.count-1]) << 24
    check(Int(isize) == tar.count, "gzip ISIZE == uncompressed length")
}

print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)

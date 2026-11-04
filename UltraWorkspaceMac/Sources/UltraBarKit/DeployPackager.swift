import Foundation
import Compression

/// Builds the gzip-compressed tar ("tgz") a CoreBar module expects on
/// `POST /upload`: one `com_res<widgetId>/default.bin` + `pressed.bin` per
/// layer, plus a `config.json` describing the layers.
public enum DeployPackager {
    public struct Layer {
        public var layerId: Int
        public var widgetId: Int
        public var defaultBin: [UInt8]
        public var pressedBin: [UInt8]
        public init(layerId: Int, widgetId: Int, defaultBin: [UInt8], pressedBin: [UInt8]) {
            self.layerId = layerId
            self.widgetId = widgetId
            self.defaultBin = defaultBin
            self.pressedBin = pressedBin
        }
    }

    public static func buildTgz(layers: [Layer], defaultLayer: Int, emulateVendorChecksumBug: Bool = false) -> Data {
        var members: [(String, [UInt8])] = []
        for l in layers {
            members.append(("com_res\(l.widgetId)/default.bin", l.defaultBin))
            members.append(("com_res\(l.widgetId)/pressed.bin", l.pressedBin))
        }
        let layersJSON = layers.map {
            "{\"id\":\($0.layerId),\"items\":[{\"id\":\($0.widgetId),\"type\":1}]}"
        }.joined(separator: ",")
        let config = "{\"defaultLayer\":\(defaultLayer),\"layers\":[\(layersJSON)]}"
        members.append(("config.json", Array(config.utf8)))

        let tar = buildUstar(members, emulateVendorChecksumBug: emulateVendorChecksumBug)
        return gzip(tar)
    }

    // MARK: ustar

    private static func buildUstar(_ members: [(name: String, data: [UInt8])], emulateVendorChecksumBug: Bool) -> [UInt8] {
        var out: [UInt8] = []
        for m in members {
            var hdr = [UInt8](repeating: 0, count: 512)
            func put(_ s: String, _ off: Int, _ len: Int) {
                let b = Array(s.utf8)
                for i in 0..<min(b.count, len) { hdr[off + i] = b[i] }
            }
            func octal(_ v: Int, _ len: Int) -> String {
                String(String(v, radix: 8).reversed().prefix(len - 1).reversed())
                    .leftPadded(to: len - 1, with: "0")
            }
            put(m.name, 0, 100)
            put(octal(0o644, 8) + "\0", 100, 8)
            put(octal(0, 8) + "\0", 108, 8)
            put(octal(0, 8) + "\0", 116, 8)
            put(octal(m.data.count, 12) + "\0", 124, 12)
            put(octal(0, 12) + "\0", 136, 12)
            for i in 148..<156 { hdr[i] = 32 }   // checksum field = spaces
            hdr[156] = 48                          // typeflag '0'
            put("ustar\0", 257, 6)
            put("00", 263, 2)
            put("root", 265, 32)
            put("root", 297, 32)

            let sum = hdr.reduce(0) { $0 + Int($1) }
            var chk = String(sum, radix: 8).leftPadded(to: 6, with: "0")
            if emulateVendorChecksumBug { chk = String(chk.prefix(5)) }
            let chkBytes = Array(chk.utf8)
            for i in 148..<156 { hdr[i] = 0 }
            for (i, b) in chkBytes.enumerated() { hdr[148 + i] = b }
            hdr[148 + chkBytes.count] = 0
            hdr[155] = 32

            out.append(contentsOf: hdr)
            out.append(contentsOf: m.data)
            let pad = (512 - m.data.count % 512) % 512
            if pad > 0 { out.append(contentsOf: [UInt8](repeating: 0, count: pad)) }
        }
        out.append(contentsOf: [UInt8](repeating: 0, count: 1024)) // two empty blocks
        return out
    }

    // MARK: gzip

    public static func gzip(_ input: [UInt8]) -> Data {
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xFF])
        out.append(contentsOf: deflate(input))
        var crc = crc32(input).littleEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        var isize = UInt32(truncatingIfNeeded: input.count).littleEndian
        withUnsafeBytes(of: &isize) { out.append(contentsOf: $0) }
        return out
    }

    /// Raw DEFLATE of `input`. `compression_encode_buffer` returns 0 when its output buffer is too small,
    /// which happens for incompressible input of some size (random bytes past about 13 MB with the old
    /// `count + 4096` buffer); an empty body then made a corrupt tgz. Try a buffer with headroom, once more
    /// with half again as much, and otherwise emit stored (uncompressed) blocks, which always fit.
    public static func deflate(_ input: [UInt8]) -> [UInt8] {
        if input.isEmpty { return [0x01, 0x00, 0x00, 0xFF, 0xFF] } // one final stored block of length 0
        for capacity in [input.count + 4096, input.count + input.count / 2 + 65536] {
            var deflated = [UInt8](repeating: 0, count: capacity)
            let written = input.withUnsafeBufferPointer { src in
                deflated.withUnsafeMutableBufferPointer { dst in
                    compression_encode_buffer(dst.baseAddress!, dst.count, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
                }
            }
            if written > 0 { return Array(deflated[0..<written]) }
        }
        return storedBlocks(input)
    }

    /// DEFLATE stored blocks (BTYPE 00): 5 bytes of header per up to 65 535 bytes of payload, last one final.
    public static func storedBlocks(_ input: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(input.count + input.count / 65535 * 5 + 5)
        var off = 0
        repeat {
            let n = min(65535, input.count - off)
            let final: UInt8 = off + n >= input.count ? 1 : 0
            let len = UInt16(n)
            out.append(final)
            out.append(UInt8(len & 0xFF)); out.append(UInt8(len >> 8))
            out.append(UInt8(~len & 0xFF)); out.append(UInt8(~len >> 8))
            out.append(contentsOf: input[off..<(off + n)])
            off += n
        } while off < input.count
        return out
    }

    public static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            crc ^= UInt32(b)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension String {
    func leftPadded(to len: Int, with pad: Character) -> String {
        count >= len ? self : String(repeating: pad, count: len - count) + self
    }
}

import Foundation
import CoreGraphics

/// Encodes an image into the CoreBar module's on-wire pixel format:
/// an 8-byte header followed by RGB565 (2 bytes/pixel), or RGB565+Alpha
/// (3 bytes/pixel) when the image has any transparency.
public enum DeviceImage {
    /// `rgba` must be row-major RGBA8888, `width*height*4` bytes.
    public static func encode(width: Int, height: Int, rgba: [UInt8]) -> [UInt8] {
        precondition(rgba.count >= width * height * 4)

        var hasAlpha = false
        outer: for y in 0..<height {
            for x in 0..<width where rgba[(y * width + x) * 4 + 3] != 0xFF {
                hasAlpha = true
                break outer
            }
        }

        let bpp = hasAlpha ? 3 : 2
        let payload = width * height * bpp
        var out = [UInt8](repeating: 0, count: 8 + payload)

        let word = UInt32((((width & 0x7FF) | (height << 11)) << 10) | (hasAlpha ? 5 : 4))
        out[0] = UInt8(word & 0xFF)
        out[1] = UInt8((word >> 8) & 0xFF)
        out[2] = UInt8((word >> 16) & 0xFF)
        out[3] = UInt8((word >> 24) & 0xFF)
        let ps = UInt32(payload)
        out[4] = UInt8(ps & 0xFF)
        out[5] = UInt8((ps >> 8) & 0xFF)
        out[6] = UInt8((ps >> 16) & 0xFF)
        out[7] = UInt8((ps >> 24) & 0xFF)

        var i = 8
        for y in 0..<height {
            for x in 0..<width {
                let p = (y * width + x) * 4
                let r = Int(rgba[p]); let g = Int(rgba[p + 1]); let b = Int(rgba[p + 2])
                let v = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
                out[i] = UInt8((v >> 8) & 0xFF); i += 1
                out[i] = UInt8(v & 0xFF); i += 1
                if hasAlpha { out[i] = rgba[p + 3]; i += 1 }
            }
        }
        return out
    }

    /// Render a CGImage into row-major RGBA8888 at the given size.
    public static func rgba(from image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: width * height * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = buf.withUnsafeMutableBytes({ raw in
            CGContext(data: raw.baseAddress, width: width, height: height,
                      bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: cs, bitmapInfo: info)
        }) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buf
    }
}

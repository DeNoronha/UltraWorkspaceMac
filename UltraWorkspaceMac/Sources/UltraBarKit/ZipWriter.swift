import Foundation

/// Minimal ZIP archive writer (store / no compression). The CoreBar's big-screen
/// asset route (`POST :8080/upload/zip`) expects a .zip of plain image files; a
/// stored (uncompressed) archive is the simplest valid container and is fine for
/// a handful of small JP/PNGs.
public enum ZipWriter {
    public struct Entry: Sendable {
        public var name: String
        public var data: Data
        public init(name: String, data: Data) { self.name = name; self.data = data }
    }

    public static func archive(_ entries: [Entry]) -> Data {
        var out = Data()
        var central = Data()
        var offset: UInt32 = 0

        for e in entries {
            let nameBytes = Array(e.name.utf8)
            let crc = crc32(e.data)
            let size = UInt32(e.data.count)
            let (dosTime, dosDate) = dosDateTime()

            // Local file header
            var local = Data()
            local.append(le32(0x04034b50))      // signature
            local.append(le16(20))              // version needed
            local.append(le16(0))               // flags
            local.append(le16(0))               // method 0 = store
            local.append(le16(dosTime))
            local.append(le16(dosDate))
            local.append(le32(crc))
            local.append(le32(size))            // compressed size
            local.append(le32(size))            // uncompressed size
            local.append(le16(UInt16(nameBytes.count)))
            local.append(le16(0))               // extra len
            local.append(contentsOf: nameBytes)

            let localHeaderOffset = offset
            out.append(local)
            out.append(e.data)
            offset += UInt32(local.count) + size

            // Central directory record
            central.append(le32(0x02014b50))    // signature
            central.append(le16(20))            // version made by
            central.append(le16(20))            // version needed
            central.append(le16(0))             // flags
            central.append(le16(0))             // method
            central.append(le16(dosTime))
            central.append(le16(dosDate))
            central.append(le32(crc))
            central.append(le32(size))
            central.append(le32(size))
            central.append(le16(UInt16(nameBytes.count)))
            central.append(le16(0))             // extra len
            central.append(le16(0))             // comment len
            central.append(le16(0))             // disk number start
            central.append(le16(0))             // internal attrs
            central.append(le32(0))             // external attrs
            central.append(le32(localHeaderOffset))
            central.append(contentsOf: nameBytes)
        }

        let centralOffset = offset
        let centralSize = UInt32(central.count)
        out.append(central)

        // End of central directory
        var eocd = Data()
        eocd.append(le32(0x06054b50))
        eocd.append(le16(0))                    // disk number
        eocd.append(le16(0))                    // disk with central dir
        eocd.append(le16(UInt16(entries.count)))
        eocd.append(le16(UInt16(entries.count)))
        eocd.append(le32(centralSize))
        eocd.append(le32(centralOffset))
        eocd.append(le16(0))                    // comment len
        out.append(eocd)

        return out
    }

    // little-endian helpers
    private static func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff)]) }
    private static func le32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)])
    }

    private static func dosDateTime(_ date: Date = Date()) -> (time: UInt16, date: UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, c.year ?? 1980)
        let dosDate = UInt16(((year - 1980) << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1))
        let dosTime = UInt16(((c.hour ?? 0) << 11) | ((c.minute ?? 0) << 5) | (((c.second ?? 0) / 2)))
        return (dosTime, dosDate)
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : (crc >> 1)
            }
        }
        return crc ^ 0xffffffff
    }
}

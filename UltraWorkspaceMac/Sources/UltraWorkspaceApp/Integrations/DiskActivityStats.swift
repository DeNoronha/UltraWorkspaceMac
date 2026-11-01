import Foundation
import IOKit

/// Live disk throughput (read/write bytes per second), summed over all
/// IOBlockStorageDriver services. Stateful: the first sample seeds the
/// counters and reads 0 (mirrors NetworkStats).
final class DiskActivityStats: @unchecked Sendable {
    struct Sample: Sendable {
        var readBytesPerSec: Double
        var writeBytesPerSec: Double
    }

    private var prevRead: UInt64 = 0
    private var prevWrite: UInt64 = 0
    private var prevTime: Date?

    init() {}

    func sample() -> Sample {
        let (readB, writeB) = counters()
        let now = Date()
        defer { prevRead = readB; prevWrite = writeB; prevTime = now }
        guard let t = prevTime else { return Sample(readBytesPerSec: 0, writeBytesPerSec: 0) }
        let dt = now.timeIntervalSince(t)
        guard dt > 0 else { return Sample(readBytesPerSec: 0, writeBytesPerSec: 0) }
        let dRead = readB >= prevRead ? readB - prevRead : 0
        let dWrite = writeB >= prevWrite ? writeB - prevWrite : 0
        return Sample(readBytesPerSec: Double(dRead) / dt, writeBytesPerSec: Double(dWrite) / dt)
    }

    /// Sum "Bytes (Read)"/"Bytes (Write)" across every IOBlockStorageDriver.
    private func counters() -> (UInt64, UInt64) {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOBlockStorageDriver")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return (0, 0)
        }
        defer { IOObjectRelease(iterator) }

        var totalRead: UInt64 = 0, totalWrite: UInt64 = 0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            guard let stats = IORegistryEntryCreateCFProperty(
                service, "Statistics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any] else { continue }
            if let r = stats["Bytes (Read)"] as? NSNumber {
                totalRead &+= r.uint64Value
            }
            if let w = stats["Bytes (Write)"] as? NSNumber {
                totalWrite &+= w.uint64Value
            }
        }
        return (totalRead, totalWrite)
    }
}

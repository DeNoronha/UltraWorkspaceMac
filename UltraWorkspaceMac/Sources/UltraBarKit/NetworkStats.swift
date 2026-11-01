import Foundation
import Darwin

/// Live network throughput (up/down bytes per second), summed over physical
/// interfaces. Stateful: the first sample seeds the counters and reads 0.
public final class NetworkStats: @unchecked Sendable {
    public struct Sample: Sendable {
        public var downBytesPerSec: Double
        public var upBytesPerSec: Double
    }

    private var prevIn: UInt64 = 0
    private var prevOut: UInt64 = 0
    private var prevTime: Date?

    public init() {}

    public func sample() -> Sample {
        let (inB, outB) = counters()
        let now = Date()
        defer { prevIn = inB; prevOut = outB; prevTime = now }
        guard let t = prevTime else { return Sample(downBytesPerSec: 0, upBytesPerSec: 0) }
        let dt = now.timeIntervalSince(t)
        guard dt > 0 else { return Sample(downBytesPerSec: 0, upBytesPerSec: 0) }
        let dIn = inB >= prevIn ? inB - prevIn : 0
        let dOut = outB >= prevOut ? outB - prevOut : 0
        return Sample(downBytesPerSec: Double(dIn) / dt, upBytesPerSec: Double(dOut) / dt)
    }

    /// Cumulative bytes received/sent since boot (all physical interfaces).
    /// The CoreBar's NETWORK card wants these totals and derives rates itself.
    public func totals() -> (received: UInt64, sent: UInt64) { counters() }

    private func counters() -> (UInt64, UInt64) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return (0, 0) }
        defer { freeifaddrs(ifaddr) }
        var totalIn: UInt64 = 0, totalOut: UInt64 = 0
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let ifa = p.pointee
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK) {
                let name = String(cString: ifa.ifa_name)
                // Skip loopback and virtual/bridge interfaces.
                if !name.hasPrefix("lo") && !name.hasPrefix("bridge") && !name.hasPrefix("utun")
                    && !name.hasPrefix("awdl") && !name.hasPrefix("llw") && !name.hasPrefix("gif") && !name.hasPrefix("stf") {
                    if let data = ifa.ifa_data?.assumingMemoryBound(to: if_data.self) {
                        totalIn &+= UInt64(data.pointee.ifi_ibytes)
                        totalOut &+= UInt64(data.pointee.ifi_obytes)
                    }
                }
            }
            ptr = ifa.ifa_next
        }
        return (totalIn, totalOut)
    }
}

public enum ByteFormat {
    /// Human throughput, e.g. "1.2 MB/s", "840 KB/s".
    public static func perSec(_ bytes: Double) -> String {
        let b = max(0, bytes)
        if b >= 1_000_000 { return String(format: "%.1f MB/s", b / 1_048_576) }
        if b >= 1_000 { return String(format: "%.0f KB/s", b / 1024) }
        return String(format: "%.0f B/s", b)
    }
}

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

    /// Interfaces whose traffic is not "the network": loopback, bridges, tunnels, Apple's peer-to-peer links.
    public static func isCounted(_ name: String) -> Bool {
        !name.hasPrefix("lo") && !name.hasPrefix("bridge") && !name.hasPrefix("utun")
            && !name.hasPrefix("awdl") && !name.hasPrefix("llw") && !name.hasPrefix("gif") && !name.hasPrefix("stf")
    }

    /// 64-bit per-interface counters from the interface MIB (`net.link.generic.ifdata.<index>.general`, a
    /// `struct ifmibdata` whose `ifmd_data` is an `if_data64`): the same source `netstat -ib` prints.
    /// `getifaddrs` hands out `if_data`, whose byte counters are 32-bit on Darwin and wrap every 4 GB (the
    /// totals sent to the bar then jumped backwards), and `NET_RT_IFLIST2` was found to report the low
    /// 32 bits as well on macOS 26 (checked against netstat, 2026-11-05).
    private func counters() -> (UInt64, UInt64) {
        guard let list = if_nameindex() else { return (0, 0) }
        defer { if_freenameindex(list) }
        var totalIn: UInt64 = 0, totalOut: UInt64 = 0
        var p = list
        while p.pointee.if_index != 0, let cname = p.pointee.if_name {
            defer { p = p.advanced(by: 1) }
            let name = String(cString: cname)
            guard Self.isCounted(name) else { continue }
            var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, Int32(p.pointee.if_index), IFDATA_GENERAL]
            var md = ifmibdata()
            var len = MemoryLayout<ifmibdata>.size
            guard sysctl(&mib, UInt32(mib.count), &md, &len, nil, 0) == 0, len >= MemoryLayout<ifmibdata>.size else { continue }
            if Int32(bitPattern: md.ifmd_flags) & IFF_LOOPBACK != 0 { continue }
            totalIn &+= md.ifmd_data.ifi_ibytes
            totalOut &+= md.ifmd_data.ifi_obytes
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

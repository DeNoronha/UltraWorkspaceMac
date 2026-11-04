import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// LAN discovery of CoreBars. Mirrors the official client: bind UDP 5319,
/// broadcast `{"act":"discover"}` every 2s, and parse replies that carry a
/// `tcpPort` field.
public enum Discovery {
    public static func listen(timeout: TimeInterval) async -> [CoreBar] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: blockingListen(timeout: timeout))
            }
        }
    }

    private static func blockingListen(timeout: TimeInterval) -> [CoreBar] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        // fdSet() writes bit `fd` into a 1024-bit fd_set (FD_SETSIZE); a larger descriptor would
        // write past it. Only reachable with over a thousand open files, but it is memory corruption.
        guard fd < 1024 else { return [] }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        #if canImport(Darwin)
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        #endif

        // Bind to 0.0.0.0:5319 so replies to the broadcast come back to us.
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Proto.discoveryPort.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        _ = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        // Non-blocking receive via select loop.
        let probe = Array(#"{"act":"discover"}"#.utf8)
        var found: [String: CoreBar] = [:]
        let deadline = Date().addingTimeInterval(timeout)
        var lastProbe = Date.distantPast

        func broadcast() {
            var dst = sockaddr_in()
            dst.sin_family = sa_family_t(AF_INET)
            dst.sin_port = Proto.discoveryPort.bigEndian
            dst.sin_addr.s_addr = INADDR_BROADCAST
            probe.withUnsafeBufferPointer { buf in
                _ = withUnsafePointer(to: &dst) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        sendto(fd, buf.baseAddress, buf.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }

        var rbuf = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            if Date().timeIntervalSince(lastProbe) >= 2 {
                broadcast()
                lastProbe = Date()
            }
            var readfds = fd_set()
            fdZero(&readfds)
            fdSet(fd, &readfds)
            var tv = timeval(tv_sec: 0, tv_usec: 300_000)
            let r = select(fd + 1, &readfds, nil, nil, &tv)
            if r > 0 {
                var from = sockaddr_in()
                var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &from) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        recvfrom(fd, &rbuf, rbuf.count, 0, sa, &fromLen)
                    }
                }
                if n > 0 {
                    let data = Data(rbuf[0..<n])
                    var ipStr = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    inet_ntop(AF_INET, &from.sin_addr, &ipStr, socklen_t(INET_ADDRSTRLEN))
                    let fromIp = String(cString: ipStr)
                    if let bar = parse(data, from: fromIp) {
                        found[bar.serialNo] = bar
                    }
                }
            }
        }
        return Array(found.values).sorted { $0.name < $1.name }
    }

    /// Targeted (unicast) discovery of a single CoreBar at a known IP — used by
    /// "Add by IP", e.g. to reach a mock running on localhost (where broadcast
    /// discovery doesn't cross Docker's NAT). Returns the CoreBar if it replies.
    public static func probe(ip: String, timeout: TimeInterval = 3) async -> CoreBar? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: blockingProbe(ip: ip, timeout: timeout))
            }
        }
    }

    private static func blockingProbe(ip: String, timeout: TimeInterval) -> CoreBar? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard fd < 1024 else { return nil } // see blockingListen

        var dst = sockaddr_in()
        dst.sin_family = sa_family_t(AF_INET)
        dst.sin_port = Proto.discoveryPort.bigEndian
        guard inet_pton(AF_INET, ip, &dst.sin_addr) == 1 else { return nil }

        let probe = Array(#"{"act":"discover"}"#.utf8)
        func send() {
            probe.withUnsafeBufferPointer { buf in
                _ = withUnsafePointer(to: &dst) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        sendto(fd, buf.baseAddress, buf.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }

        var rbuf = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        var lastSend = Date.distantPast
        while Date() < deadline {
            // UDP is lossy (and a sleeping device may miss the first datagram):
            // re-send the probe every 600 ms until something answers.
            if Date().timeIntervalSince(lastSend) >= 0.6 { send(); lastSend = Date() }
            var readfds = fd_set(); fdZero(&readfds); fdSet(fd, &readfds)
            var tv = timeval(tv_sec: 0, tv_usec: 300_000)
            if select(fd + 1, &readfds, nil, nil, &tv) > 0 {
                var from = sockaddr_in()
                var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &from) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        recvfrom(fd, &rbuf, rbuf.count, 0, sa, &fromLen)
                    }
                }
                if n > 0, let bar = parse(Data(rbuf[0..<n]), from: ip) { return bar }
            }
        }
        return nil
    }

    /// One discovery reply datagram → CoreBar (nil unless it carries `tcpPort` and a serial). `from` is the
    /// sender's address, used when the reply has no `ip` or an `ip` that is not an IPv4 literal. The reply is
    /// unauthenticated LAN data: the port must be a port, the strings are capped (they go into the UI and into
    /// file names), and an `ip` that is not an address cannot send a later connection somewhere else.
    public static func parse(_ data: Data, from: String) -> CoreBar? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["tcpPort"] != nil else { return nil }
        func s(_ k: String, max: Int) -> String {
            let v: String
            if let x = obj[k] as? String { v = x } else if let x = obj[k] { v = String(describing: x) } else { return "" }
            let clean = v.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }
            return String(String.UnicodeScalarView(clean).prefix(max))
        }
        func i(_ k: String) -> Int? {
            if let v = obj[k] as? Int { return v }
            if let v = obj[k] as? NSNumber { return v.intValue }
            if let v = obj[k] as? String, let n = Int(v) { return n }
            return nil
        }
        guard let port = i("tcpPort"), (0...65535).contains(port) else { return nil }
        let serial = s("serialNo", max: 64)
        guard !serial.isEmpty else { return nil }
        let ipField = s("ip", max: 45)
        var a = in_addr()
        let ip = (!ipField.isEmpty && inet_pton(AF_INET, ipField, &a) == 1) ? ipField : from
        return CoreBar(serialNo: serial, version: s("ver", max: 32), ip: ip, name: s("name", max: 80), tcpPort: port)
    }
}

// fd_set helpers (the C macros are not imported into Swift).
private func fdZero(_ set: inout fd_set) {
    withUnsafeMutableBytes(of: &set) { p in p.initializeMemory(as: UInt8.self, repeating: 0) }
}
private func fdSet(_ fd: Int32, _ set: inout fd_set) {
    let intOffset = Int(fd) / 32
    let bitOffset = Int(fd) % 32
    let mask: Int32 = 1 << bitOffset
    withUnsafeMutablePointer(to: &set.fds_bits) { p in
        p.withMemoryRebound(to: Int32.self, capacity: 32) { bits in
            bits[intOffset] |= mask
        }
    }
}

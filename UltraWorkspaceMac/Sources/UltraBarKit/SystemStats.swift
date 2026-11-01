import Foundation
import Darwin

/// Live Mac CPU + memory usage (iStat-style). Stateful: call `sample()` on a
/// cadence; CPU% is the busy fraction since the previous sample.
public final class SystemStats: @unchecked Sendable {
    public struct Sample: Sendable {
        public var cpuPercent: Double     // 0…100 overall
        public var memUsedGB: Double
        public var memTotalGB: Double
        public var memPercent: Double     // 0…100
    }

    private var prevBusy: UInt64 = 0
    private var prevTotal: UInt64 = 0

    public init() {}

    public func sample() -> Sample {
        let cpu = cpuPercent()
        let (usedGB, totalGB, pct) = memory()
        return Sample(cpuPercent: cpu, memUsedGB: usedGB, memTotalGB: totalGB, memPercent: pct)
    }

    private func cpuPercent() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        let busy = user &+ system &+ nice
        let total = busy &+ idle
        defer { prevBusy = busy; prevTotal = total }
        let dBusy = busy &- prevBusy
        let dTotal = total &- prevTotal
        guard prevTotal != 0, dTotal > 0 else { return 0 }
        return min(100, max(0, Double(dBusy) / Double(dTotal) * 100))
    }

    private func memory() -> (Double, Double, Double) {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &vm) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var ps: vm_size_t = 0
        host_page_size(mach_host_self(), &ps)
        let pageSize = UInt64(ps == 0 ? 4096 : ps)
        let total = ProcessInfo.processInfo.physicalMemory
        guard kr == KERN_SUCCESS, total > 0 else { return (0, Double(total) / 1e9, 0) }
        let used = (UInt64(vm.active_count) + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * pageSize
        let totalGB = Double(total) / 1_073_741_824
        let usedGB = Double(used) / 1_073_741_824
        return (usedGB, totalGB, min(100, usedGB / totalGB * 100))
    }
}

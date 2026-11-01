import Foundation
import IOKit.ps

/// Live Mac battery + power state via IOKit power sources. Stateless; call
/// `sample()` on a cadence. Desktop Macs (no internal battery) report
/// `hasBattery == false` so the UI can show an "On AC power" state.
enum BatteryStats {
    struct Sample: Sendable {
        var percent: Double        // 0…100
        var isCharging: Bool
        var isPluggedIn: Bool
        var minutesRemaining: Int? // nil if unknown/calculating
        var hasBattery: Bool
    }

    static func sample() -> Sample {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return Sample(percent: 0, isCharging: false, isPluggedIn: true,
                          minutesRemaining: nil, hasBattery: false)
        }

        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                as? [String: Any] else { continue }

            // Only consider an internal battery; skip UPS/other sources.
            if let type = desc[kIOPSTypeKey as String] as? String,
               type != (kIOPSInternalBatteryType as String) { continue }

            let maxCap = (desc[kIOPSMaxCapacityKey as String] as? Double) ?? 0
            guard maxCap > 0 else { continue }
            let curCap = (desc[kIOPSCurrentCapacityKey as String] as? Double) ?? 0
            let percent = max(0, min(100, curCap / maxCap * 100))

            let isCharging = (desc[kIOPSIsChargingKey as String] as? Bool) ?? false
            let state = (desc[kIOPSPowerSourceStateKey as String] as? String) ?? ""
            let isPluggedIn = state == (kIOPSACPowerValue as String)

            // -1 means "still calculating" → unknown.
            let rawMinutes: Int
            if isCharging {
                rawMinutes = (desc[kIOPSTimeToFullChargeKey as String] as? Int) ?? -1
            } else {
                rawMinutes = (desc[kIOPSTimeToEmptyKey as String] as? Int) ?? -1
            }
            let minutesRemaining = rawMinutes > 0 ? rawMinutes : nil

            return Sample(percent: percent, isCharging: isCharging, isPluggedIn: isPluggedIn,
                          minutesRemaining: minutesRemaining, hasBattery: true)
        }

        // No internal battery (e.g. Mac Studio / desktop): running on AC.
        return Sample(percent: 0, isCharging: false, isPluggedIn: true,
                      minutesRemaining: nil, hasBattery: false)
    }
}

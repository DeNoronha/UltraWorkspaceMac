import Foundation
import UltraBarKit

/// What the bar's firewall looks like from this Mac.
enum BarFirewallState: Equatable {
    case unknown
    case off
    /// On, letting in this address (normally this Mac's).
    case on(allowing: String)
    case failed(String)
}

/// Bar hardening (2026-11-06). The bar is an Android 10 eng build: adbd runs as root on port 5555 without key
/// checks (`ro.adb.secure` is empty and read-only), and the vendor's launcher (8080), hub (7431), audio service
/// (14035) and radio app listen on every interface. Deckhand can put a firewall in front of them: on the bar's
/// home-network interface (`wlan0`) only this Mac may open TCP connections. Loopback, the bar's own hotspot for the
/// VivoCube (`wlan1`), replies to the bar's own connections and UDP (the beacon) are untouched.
///
/// The rules live in iptables, which Android does not keep across a reboot (and netd rebuilds the tables while the
/// bar starts): Deckhand sets them again once the bar has finished starting after the link comes back, and checks
/// every two minutes that they are still there. That is also the way out when this Mac changes address and is locked out: restart the
/// bar and the rules are gone until Deckhand sets them with the new address.
@MainActor
extension AppModel {
    /// The address the bar sees this Mac as (the one the beacon names).
    func macAddressForBar() -> String? {
        guard let bar = ipForSelected() else { return nil }
        return LocalIP.address(reaching: bar)
    }

    func setBarFirewall(_ on: Bool) {
        barFirewallWanted = on
        Task { await self.applyBarFirewall() }
        barFirewallTask?.cancel(); barFirewallTask = nil
        guard on else { return }
        // Android's netd rebuilds the firewall tables while the bar starts, and other things on the bar may touch
        // them later: check every two minutes that the rules are still there, and put them back if not.
        barFirewallTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                guard let self, !Task.isCancelled, self.barFirewallWanted, self.link.isConnected else { continue }
                await self.applyBarFirewall()
            }
        }
    }

    /// Bring the bar's firewall in line with `barFirewallWanted` and refresh `barFirewall`.
    func applyBarFirewall() async {
        guard let adb = AdbBridge.find(), let ip = ipForSelected() else { barFirewall = .unknown; return }
        let bridge = AdbBridge(path: adb, ip: ip)
        guard await bridge.connect() else { barFirewall = .failed("The bar refuses ADB on \(ip):5555 — Settings → Debug bridge."); return }
        if barFirewallWanted {
            guard let mac = macAddressForBar() else { barFirewall = .failed("This Mac's address on the bar's network is not known."); return }
            if await bridge.firewallAllowing() != mac {
                await bridge.enableFirewall(allowing: mac)
                WireLog.shared.event("hardening: bar firewall on, allowing \(mac)")
            }
        } else if await bridge.firewallAllowing() != nil {
            await bridge.disableFirewall()
            WireLog.shared.event("hardening: bar firewall off")
        }
        barFirewall = await bridge.firewallAllowing().map { .on(allowing: $0) } ?? .off
        if barFirewallWanted, barFirewall != .on(allowing: macAddressForBar() ?? "") {
            barFirewall = .failed("The bar did not accept the firewall rules.")
        }
    }

    /// Runs whenever the link to the bar is (re)established. Detects a bar restart by its boot id and then puts
    /// back what a restart loses: the firewall, and the VivoCube's screen (a bar restart can leave it dark).
    func afterBarConnected() {
        guard let adb = AdbBridge.find(), let ip = ipForSelected() else { return }
        Task {
            let bridge = AdbBridge(path: adb, ip: ip)
            guard await bridge.connect() else { return }
            let boot = (await bridge.shell("cat /proc/sys/kernel/random/boot_id")).trimmingCharacters(in: .whitespacesAndNewlines)
            let restarted = lastBarBootID != nil && !boot.isEmpty && boot != lastBarBootID
            if !boot.isEmpty { lastBarBootID = boot }
            // Rules set before Android has finished starting are wiped by netd: wait for boot_completed (2 min at most).
            for _ in 0..<40 {
                if (await bridge.shell("getprop sys.boot_completed")).trimmingCharacters(in: .whitespacesAndNewlines) == "1" { break }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            if barFirewallWanted { await applyBarFirewall() }
            if restarted, let cube = vivoCubeSerial {
                WireLog.shared.event("hardening: the bar restarted; waking the VivoCube's screen")
                try? await Task.sleep(nanoseconds: 10_000_000_000)   // let the bar find its modules first
                recoverVivoDisplay(serial: cube)
            }
        }
    }
}

extension AdbBridge {
    /// The address the bar's firewall lets in, or nil when Deckhand's firewall is not active.
    func firewallAllowing() async -> String? {
        let out = await shell("iptables -C INPUT -j deckhand_in 2>/dev/null && iptables -S deckhand_in")
        guard let line = out.split(separator: "\n").first(where: { $0.contains("-s ") && $0.contains("RETURN") }) else { return nil }
        let parts = line.split(separator: " ")
        guard let i = parts.firstIndex(of: "-s"), i + 1 < parts.count else { return nil }
        return String(parts[i + 1].split(separator: "/").first ?? "")
    }

    /// Only `allowing` may open TCP connections over the bar's home-network interface (IPv4); over IPv6 nobody may.
    func enableFirewall(allowing mac: String) async {
        guard mac.split(separator: ".").count == 4, mac.allSatisfy({ $0.isNumber || $0 == "." }) else { return }
        let rules = { (t: String, allow: String) in
            "\(t) -N deckhand_in 2>/dev/null; \(t) -F deckhand_in; " +
            "\(t) -A deckhand_in -i lo -j RETURN; \(t) -A deckhand_in ! -i wlan0 -j RETURN; " +
            "\(t) -A deckhand_in -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN; " + allow +
            "\(t) -A deckhand_in -p tcp -j DROP; " +
            "\(t) -C INPUT -j deckhand_in 2>/dev/null || \(t) -I INPUT 1 -j deckhand_in; "
        }
        _ = await shell(rules("iptables", "iptables -A deckhand_in -s \(mac) -j RETURN; ") + rules("ip6tables", ""))
    }

    func disableFirewall() async {
        _ = await shell("for t in iptables ip6tables; do $t -D INPUT -j deckhand_in 2>/dev/null; $t -F deckhand_in 2>/dev/null; $t -X deckhand_in 2>/dev/null; done; true")
    }
}

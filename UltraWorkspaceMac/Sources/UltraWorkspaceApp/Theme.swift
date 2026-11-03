import Foundation

/// A display widget (card) that can be shown on a VivoCube, alone or rotating.
enum Theme: String, CaseIterable, Codable, Identifiable {
    case weather, music, claude, cpu, network, battery, disk, worldclock, crypto, calendar, diskio, topcpu, uptime, picture
    case clock, date, crypto2, crypto3, crypto4, crypto5

    var id: String { rawValue }

    /// Cards offered in the library / "Add a card". The extra crypto slots are internal:
    /// one "Crypto" entry expands to one card per coin at send time.
    static var library: [Theme] { allCases.filter { !$0.isHiddenCryptoSlot && !$0.isLiveFeed } }
    /// Cards whose value is a live reading (CPU, network, …) or a running clock. The cube only
    /// gets a new picture every 5 minutes at most, so these are shown stale there; the bar draws
    /// its own live versions. Not offered for the cube since 2026-11-03.
    var isLiveFeed: Bool { [.cpu, .network, .battery, .disk, .worldclock, .diskio, .topcpu, .uptime, .clock].contains(self) }
    var isHiddenCryptoSlot: Bool { [.crypto2, .crypto3, .crypto4, .crypto5].contains(self) }

    var title: String {
        switch self {
        case .weather: return "Weather"
        case .music: return "Music (album art)"
        case .claude: return "Claude Code monitor"
        case .cpu: return "CPU & memory"
        case .network: return "Network"
        case .battery: return "Battery & power"
        case .disk: return "Storage"
        case .worldclock: return "World clock"
        case .crypto: return "Crypto"
        case .calendar: return "Calendar"
        case .diskio: return "Disk I/O"
        case .topcpu: return "Top CPU"
        case .uptime: return "Uptime"
        case .picture: return "Picture"
        case .clock: return "Clock"
        case .date: return "Date"
        case .crypto2: return "Crypto 2"
        case .crypto3: return "Crypto 3"
        case .crypto4: return "Crypto 4"
        case .crypto5: return "Crypto 5"
        }
    }

    /// Which crypto slot (0-based) a card shows, if it is a crypto card.
    var cryptoSlot: Int? {
        switch self {
        case .crypto: return 0
        case .crypto2: return 1
        case .crypto3: return 2
        case .crypto4: return 3
        case .crypto5: return 4
        default: return nil
        }
    }

    var icon: String {
        switch self {
        case .weather: return "cloud.sun"
        case .music: return "music.note"
        case .claude: return "sparkles"
        case .cpu: return "cpu"
        case .network: return "network"
        case .battery: return "battery.100"
        case .disk: return "internaldrive"
        case .worldclock: return "globe"
        case .crypto: return "bitcoinsign.circle"
        case .calendar: return "calendar"
        case .diskio: return "internaldrive.fill"
        case .topcpu: return "speedometer"
        case .uptime: return "clock.arrow.circlepath"
        case .picture: return "photo"
        case .clock: return "clock"
        case .date: return "calendar.badge.clock"
        case .crypto2, .crypto3, .crypto4, .crypto5: return "bitcoinsign.circle"
        }
    }
}

import Foundation

/// A display theme (card) that can be shown on a VivoCube, alone or rotating.
enum Theme: String, CaseIterable, Codable, Identifiable {
    case weather, music, claude, cpu, network

    var id: String { rawValue }

    var title: String {
        switch self {
        case .weather: return "Weather & time"
        case .music: return "Music (album art)"
        case .claude: return "Claude Code monitor"
        case .cpu: return "CPU & memory"
        case .network: return "Network"
        }
    }

    var icon: String {
        switch self {
        case .weather: return "cloud.sun"
        case .music: return "music.note"
        case .claude: return "sparkles"
        case .cpu: return "cpu"
        case .network: return "network"
        }
    }
}

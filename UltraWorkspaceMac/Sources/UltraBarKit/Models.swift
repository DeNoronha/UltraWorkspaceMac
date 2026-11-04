import Foundation

/// Well-known numbers for the local CoreBar protocol, recovered from the
/// official client behaviour. All device control happens over a line-delimited
/// JSON-over-TLS channel to the CoreBar; the CoreBar relays to its attached
/// QuantumLink modules (VivoCube, SenseCube, KnobKey, DotKey).
public enum Proto {
    /// UDP port the CoreBar listens on for `{"act":"discover"}` broadcasts.
    public static let discoveryPort: UInt16 = 5319
    /// Default TLS control port on the CoreBar.
    public static let controlPort: UInt16 = 7431
    /// HTTP port used for module image/config uploads.
    public static let uploadPort: UInt16 = 8080
    /// TLS SNI the CoreBar certificate is issued for.
    public static let tlsHost = "ultrabar.local"

    // Control "act" codes (from LineOS `MessageAction` enum).
    public static let actAuth = 100               // AUTH — data = token
    public static let actPair = 101               // REQ_AUTH_TOKEN — data = {id, clientType:"pc", name}
    public static let actGetDevice = 1300         // GET_DEVICE — list all devices/modules
    public static let actTriggerProfileChange = 1103 // TRIGGER_PROFILE_CHANGE — data = profile id (switch page)
    public static let actBatchSaveProfile = 1108  // BATCH_SAVE_PROFILE — data = [ProfileDTO] (REPLACES all pages)
    public static let actIntegratedConfigSet = 1010 // INTEGRATED_CONFIG_SET — {packageName, config}; "com.ultrabar.weather" = the built-in weather card's AccuWeather key
    public static let actSceneDependsProfile = 30710 // SCENE_DEPENDS_PROFILE — [{label:name, value:id, last}] (the only way to list page ids)
    public static let actPreviewScreensaver = 30742 // PREVIEW_SCREENSAVER — {url, mediaType} one-shot full-screen
    public static let actPushMessage = 1000000    // PUSH_MESSAGE — device→client {type:PushType, payload} (SET_VOLUME, PC_CONTROL, CPU/MEMORY/STORAGE/NETWORK requests, …)
    public static let actModuleStartDiscovery = 30100 // MODULE_START_DISCOVERY — scan the bus
    public static let actModuleDiscoveryReplay = 30102 // MODULE_START_DISCOVERY_REPLAY — pushed per found module
    public static let actSetGatewayConfig = 30300 // SET_GATEWAY_CONFIG — body is a CoreBarConfiguration directly
    public static let actReadProp = 30200         // MODULE_PROPERTY_READ — {serialNo, deviceId, propertyId, extra}
    public static let actWriteProp = 30201        // MODULE_PROPERTY_WRITE — {serialNo, deviceId, propertyId, value}
    public static let actGetCoreBarConfig = 30740 // GET_COREBAR_CONFIG

    // Logical device id addressed inside a module.
    public static let deviceMain = 256

    // Known property ids on a VivoCube main device.
    public enum Property {
        public static let runTime = 3   // uptime seconds (read)
        public static let screen = 4    // 0 = off, 1 = on (write)
        public static let reboot = 5    // true (write)
        public static let wifi = 6        // Wi-Fi state (read; 3 seen while connected)
        public static let wifiConfig = 7  // hex([len]ssid[len]password) — read/write
        public static let layerWidget = 9
    }
}

/// A CoreBar discovered on the LAN.
public struct CoreBar: Identifiable, Hashable, Sendable, Codable {
    public var serialNo: String
    public var version: String
    public var ip: String
    public var name: String
    public var tcpPort: Int
    public var id: String { serialNo }

    public init(serialNo: String, version: String, ip: String, name: String, tcpPort: Int) {
        self.serialNo = serialNo
        self.version = version
        self.ip = ip
        self.name = name
        self.tcpPort = tcpPort > 0 ? tcpPort : Int(Proto.controlPort)
    }
}

/// A device/module reported by the CoreBar (GET_DEVICE / act 1300): a VivoCube,
/// SenseCube, KnobKey, DotKey, PC-Boot card, or an integration entity.
public struct AttachedModule: Identifiable, Hashable, Sendable {
    public var deviceId: String       // CoreBar "id"
    public var name: String
    public var type: String           // DeviceEnum, e.g. "VIVO_CUBE"
    public var online: Bool
    public var serial: String         // serialNo for module control (from attr, else id)
    public var upSeconds: Int64?
    public var id: String { deviceId }

    public init(deviceId: String, name: String, type: String, online: Bool, serial: String, upSeconds: Int64? = nil) {
        self.deviceId = deviceId
        self.name = name
        self.type = type
        self.online = online
        self.serial = serial
        self.upSeconds = upSeconds
    }

    public var isVivoCube: Bool { type == "VIVO_CUBE" }
    public var displayName: String { name.isEmpty ? (serial.isEmpty ? deviceId : serial) : name }
    public var prettyType: String {
        switch type {
        case "VIVO_CUBE": return "VivoCube"
        case "SENSE_CUBE": return "SenseCube"
        case "KNOB_KEY": return "KnobKey"
        case "DOT_KEY": return "DotKey"
        case "PC_BOOT", "PC_BOOT_CARD": return "PC-Boot"
        case "EXT_SCREEN": return "CoreBar screen"
        case "GATEWAY": return "Gateway"
        case "COMPUTER_INFO": return "Computer"
        case "ACTION": return "Action"
        case "AUDIO_PLAYER": return "Audio"
        default: return type.capitalized.replacingOccurrences(of: "_", with: " ")
        }
    }
}

public enum UltraBarError: Error, LocalizedError, Sendable {
    case notConnected
    case tlsFailed(String)
    case certPinMismatch(presented: String, pinned: String)
    case authRejected
    case pairingTimedOut
    case pairingNoToken
    /// The bar answered the PAIR request with a failure code: Reject was tapped, or the device could not pair.
    case pairingRejected(code: Int, message: String?)
    case timeout
    case protocolError(String)
    case uploadRejected(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to the CoreBar."
        case .tlsFailed(let m): return "TLS handshake failed: \(m)"
        case .certPinMismatch(let p, let pin):
            return "The CoreBar presented a different certificate (\(p.prefix(16))…) than the one recorded at pairing (\(pin.prefix(16))…). The token was not sent."
        case .authRejected: return "The CoreBar rejected the pairing token."
        case .pairingTimedOut: return "Pairing timed out — no Approve was tapped on the CoreBar."
        case .pairingNoToken: return "The CoreBar did not return a pairing token."
        case .pairingRejected(let code, let m):
            return "The CoreBar refused the pairing (code \(code)\(m.map { ": " + $0 } ?? ""))."
        case .timeout: return "The CoreBar did not reply in time."
        case .protocolError(let m): return "Protocol error: \(m)"
        case .uploadRejected(let b): return "The module did not accept the upload: \(b)"
        }
    }
}

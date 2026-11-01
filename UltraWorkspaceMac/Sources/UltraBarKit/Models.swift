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

    // Control "act" codes.
    public static let actAuth = 100          // data = token
    public static let actPair = 101          // data = {id, clientType:"pc", name}
    public static let actReadProp = 30200    // data = {serialNo, deviceId, propertyId, extra}
    public static let actWriteProp = 30201   // data = {serialNo, deviceId, propertyId, value}
    public static let actListModules = 30730 // data = {} -> array of {serialNo,...}

    // Logical device id addressed inside a module.
    public static let deviceMain = 256

    // Known property ids on a VivoCube main device.
    public enum Property {
        public static let runTime = 3   // uptime seconds (read)
        public static let screen = 4    // 0 = off, 1 = on (write)
        public static let reboot = 5    // true (write)
        public static let wifi = 6
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

/// A VivoCube (or other display module) currently attached to a CoreBar.
public struct AttachedModule: Identifiable, Hashable, Sendable {
    public var serial: String
    public var upSeconds: Int64?
    public var id: String { serial }

    public init(serial: String, upSeconds: Int64?) {
        self.serial = serial
        self.upSeconds = upSeconds
    }
}

public enum UltraBarError: Error, LocalizedError, Sendable {
    case notConnected
    case tlsFailed(String)
    case certPinMismatch(presented: String, pinned: String)
    case authRejected
    case pairingTimedOut
    case pairingNoToken
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
        case .timeout: return "The CoreBar did not reply in time."
        case .protocolError(let m): return "Protocol error: \(m)"
        case .uploadRejected(let b): return "The module did not accept the upload: \(b)"
        }
    }
}

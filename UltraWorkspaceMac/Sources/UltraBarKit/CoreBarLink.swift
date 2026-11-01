import Foundation

/// A persistent, authenticated control connection — the way the vendor client
/// talks to a CoreBar. Needed for everything the DEVICE initiates:
/// PUSH_MESSAGE (1000000) queries for the CoreBar's own CPU / MEMORY / STORAGE /
/// NETWORK cards, KnobKey volume (GET_VOLUME every 5 s, SET_VOLUME per tick),
/// and PC_CONTROL card/key presses. The hub closes a connection after 60 s with
/// neither read nor write, so we send the vendor heartbeat `{"act":20,"id":n}`
/// every 3 s. Pushes are broadcast to every connected client; replies are
/// matched by `id` and the first `code:200` wins.
public actor CoreBarLink {
    public enum State: Sendable, Equatable { case stopped, connecting, connected, reconnecting(String) }

    /// Handles one device push. Return the `payload` to reply with (any JSON
    /// value, or NSNull for "acknowledge without data"), or nil for no reply.
    public typealias PushHandler = @Sendable (_ type: String, _ payload: Any?) async -> Any?

    private let ip: String, token: String, certPin: String?, port: UInt16
    private var client: CoreBarClient?
    private var task: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var heartbeatCounter = 0
    private var handler: PushHandler?
    private var onState: (@Sendable (State) -> Void)?
    public private(set) var state: State = .stopped
    public private(set) var pushesHandled = 0

    public init(ip: String, token: String, certPin: String?, port: UInt16 = Proto.controlPort) {
        self.ip = ip; self.token = token; self.certPin = certPin; self.port = port
    }

    public func start(onState: (@Sendable (State) -> Void)? = nil, handler: @escaping PushHandler) {
        guard task == nil else { return }
        self.handler = handler
        self.onState = onState
        task = Task { await self.runLoop() }
    }

    public func stop() {
        task?.cancel(); task = nil
        heartbeat?.cancel(); heartbeat = nil
        if let c = client { Task { await c.close() } }
        client = nil
        setState(.stopped)
    }

    private func setState(_ s: State) {
        state = s
        onState?(s)
    }

    private func runLoop() async {
        var backoff: UInt64 = 2
        while !Task.isCancelled {
            setState(backoff == 2 ? .connecting : .reconnecting("retry in \(backoff)s"))
            let c = CoreBarClient(host: ip, pinnedCertSHA256: certPin, port: port)
            do {
                try await c.connect()
                guard try await c.authenticate(token: token) else { throw UltraBarError.authRejected }
            } catch {
                await c.close()
                WireLog.shared.event("link: connect failed (\(error.localizedDescription)); retry in \(backoff)s")
                setState(.reconnecting(error.localizedDescription))
                try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                backoff = min(backoff * 2, 30)
                continue
            }
            client = c
            backoff = 2
            setState(.connected)
            WireLog.shared.event("link: connected to \(ip) (persistent, heartbeat 3 s)")
            startHeartbeat(c)
            await readLoop(c)
            heartbeat?.cancel(); heartbeat = nil
            await c.close()
            client = nil
            if Task.isCancelled { break }
            WireLog.shared.event("link: connection closed; reconnecting")
        }
        setState(.stopped)
    }

    private func startHeartbeat(_ c: CoreBarClient) {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self else { return }
                let n = await self.nextHeartbeatId()
                try? await c.sendFrame(["act": 20, "id": String(n)])
            }
        }
    }
    private func nextHeartbeatId() -> Int { heartbeatCounter += 1; return heartbeatCounter }

    private func readLoop(_ c: CoreBarClient) async {
        while !Task.isCancelled {
            guard let line = await c.nextLine(timeout: 90) else {
                if await c.isClosed { return }
                continue // quiet period; heartbeat keeps the socket alive
            }
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            let act = (obj["act"] as? Int) ?? (obj["act"] as? NSNumber)?.intValue ?? -1
            guard act == Proto.actPushMessage else { continue } // heartbeat acks etc.
            let id = (obj["id"] as? String) ?? ""
            let data = obj["data"] as? [String: Any]
            let type = (data?["type"] as? String) ?? ""
            let payload = data?["payload"]
            pushesHandled += 1
            guard let handler else { continue }
            if let reply = await handler(type, payload) {
                var d: [String: Any] = ["type": type]
                if !(reply is NSNull) { d["payload"] = reply }
                let frame: [String: Any] = ["act": Proto.actPushMessage, "id": id, "code": 200, "data": d]
                try? await c.sendFrame(frame)
            }
        }
    }
}

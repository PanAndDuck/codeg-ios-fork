import Foundation

// MARK: - WebSocket attach-protocol messages

/// Client→server attach-protocol message (Rust `ClientMsg`, tagged `action`).
/// Encode-only; snake_case wire keys are spelled explicitly (request encoder
/// does not convert keys).
enum WSClientMessage: Encodable, Sendable {
    case attach(subscriptionId: String, connectionId: String, sinceSeq: UInt64?)
    case detach(subscriptionId: String)
    case ping

    private enum CodingKeys: String, CodingKey {
        case action
        case subscriptionId = "subscription_id"
        case connectionId = "connection_id"
        case sinceSeq = "since_seq"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .attach(let sub, let conn, let since):
            try c.encode("attach", forKey: .action)
            try c.encode(sub, forKey: .subscriptionId)
            try c.encode(conn, forKey: .connectionId)
            try c.encodeIfPresent(since, forKey: .sinceSeq)
        case .detach(let sub):
            try c.encode("detach", forKey: .action)
            try c.encode(sub, forKey: .subscriptionId)
        case .ping:
            try c.encode("ping", forKey: .action)
        }
    }
}

/// Server→client attach-protocol message (Rust `ServerMsg`, tagged `type`).
/// Decoded with the shared `.convertFromSnakeCase` decoder, so keys are
/// camelCase here.
enum WSServerMessage: Decodable, Sendable {
    case snapshot(LiveSessionSnapshot)
    case replay([EventEnvelope])
    case event(EventEnvelope)
    case detached(reason: String)
    case pong
    case unknown

    private enum CodingKeys: String, CodingKey {
        case type, snapshot, events, envelope, reason
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "snapshot":
            self = .snapshot(try c.decode(LiveSessionSnapshot.self, forKey: .snapshot))
        case "replay":
            self = .replay(try c.decodeIfPresent([EventEnvelope].self, forKey: .events) ?? [])
        case "event":
            self = .event(try c.decode(EventEnvelope.self, forKey: .envelope))
        case "detached":
            self = .detached(reason: try c.decodeIfPresent(String.self, forKey: .reason) ?? "")
        case "pong":
            self = .pong
        default:
            self = .unknown
        }
    }
}

// MARK: - EventStream

/// A live WebSocket connection to `/ws/events`. Emits decoded frames on
/// `frames`. Lifecycle: `start()` → await `.ready` → `attach(...)` → consume
/// `.event` frames → `close()`. Reconnection is the caller's responsibility
/// (Phase 1 reconnects by creating a fresh stream).
final class EventStream: @unchecked Sendable {
    enum CloseReason {
        static let keepaliveTimeout = "keepalive timeout"
        static let networkChanged = "network changed"
    }

    enum Frame: Sendable {
        case ready
        case snapshot(LiveSessionSnapshot)
        case replay([EventEnvelope])
        case event(EventEnvelope)
        case detached(reason: String)
        case pong
        case closed(reason: String?)
    }

    let frames: AsyncStream<Frame>
    private let continuation: AsyncStream<Frame>.Continuation
    private let url: URL
    private let token: String
    private let session: URLSession
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var healthMonitor: WebSocketHealthMonitor?
    private var isClosed = false

    /// Dedicated session for the long-lived event socket. `URLSession.shared`'s
    /// default `timeoutIntervalForRequest` (60s) is an *inactivity* timeout that,
    /// on a WebSocket, fires whenever the agent goes quiet — a long tool call, a
    /// pause for a permission prompt — and tears down a perfectly healthy stream,
    /// surfacing a spurious error even though the server is fine. A live agent
    /// owns the pacing, so the socket must be allowed to sit idle indefinitely;
    /// genuine death is instead detected by the keepalive ping below. (The
    /// browser WebSocket the web client uses has no such idle timeout — this
    /// brings parity.)
    static let streamSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 604_800   // 7 days — effectively no idle timeout
        cfg.timeoutIntervalForResource = 604_800
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    init(baseURL: URL, token: String, session: URLSession = EventStream.streamSession) {
        self.token = token
        self.session = session
        self.url = EventStream.websocketURL(from: baseURL)
        var captured: AsyncStream<Frame>.Continuation!
        self.frames = AsyncStream(bufferingPolicy: .unbounded) { captured = $0 }
        self.continuation = captured
    }

    func start() {
        lock.lock()
        guard !isClosed, task == nil else { lock.unlock(); return }
        let newTask = Self.makeWebSocketTask(session: session, url: url, token: token)
        let monitor = WebSocketHealthMonitor(task: newTask) { [weak self] reason in
            self?.finish(reason: reason)
        }
        task = newTask
        healthMonitor = monitor
        newTask.resume()
        monitor.start()
        lock.unlock()
        receiveLoop()
    }

    func attach(subscriptionId: String, connectionId: String, sinceSeq: UInt64? = nil) {
        send(.attach(subscriptionId: subscriptionId, connectionId: connectionId, sinceSeq: sinceSeq))
    }

    func detach(subscriptionId: String) { send(.detach(subscriptionId: subscriptionId)) }

    /// Use only protocol ping: application-level ping can deadlock older servers.
    func ping() { lock.withLock { healthMonitor }?.sendPing() }

    func close() { shutdown(reason: nil, notify: false) }

    deinit { close() }

    // MARK: - Private

    private func send(_ message: WSClientMessage) {
        guard let data = try? CodegJSON.encoder.encode(message),
              let text = String(data: data, encoding: .utf8) else { return }
        let t = lock.withLock { isClosed ? nil : task }
        t?.send(.string(text)) { _ in }
    }

    private func receiveLoop() {
        let t = lock.withLock { isClosed ? nil : task }
        t?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.finish(reason: error.localizedDescription)
            case .success(let message):
                self.lock.withLock { self.healthMonitor }?.recordMessage()
                self.handle(message)
                self.lock.lock(); let closed = self.isClosed; self.lock.unlock()
                if !closed { self.receiveLoop() }
            }
        }
    }

    private func finish(reason: String?) {
        shutdown(reason: reason, notify: true)
    }

    private func shutdown(reason: String?, notify: Bool) {
        lock.lock()
        guard !isClosed else { lock.unlock(); return }
        isClosed = true
        let t = task
        let monitor = healthMonitor
        task = nil
        healthMonitor = nil
        lock.unlock()
        monitor?.stop()
        t?.cancel(with: .goingAway, reason: nil)
        if notify { continuation.yield(.closed(reason: reason)) }
        continuation.finish()
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let s): data = Data(s.utf8)
        case .data(let d): data = d
        @unknown default: return
        }
        decode(data)
    }

    private func decode(_ data: Data) {
        // The socket multiplexes the legacy firehose ({channel, payload}) with
        // the attach protocol ({type, ...}). Route on which key is present.
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let channel = obj["channel"] as? String {
                if channel == "__ready__" { continuation.yield(.ready) }
                return // ignore other legacy global events in Phase 1
            }
            guard obj["type"] is String else { return }
        }
        guard let message = try? CodegJSON.decoder.decode(WSServerMessage.self, from: data) else { return }
        switch message {
        case .snapshot(let snapshot): continuation.yield(.snapshot(snapshot))
        case .replay(let events): continuation.yield(.replay(events))
        case .event(let envelope): continuation.yield(.event(envelope))
        case .detached(let reason): continuation.yield(.detached(reason: reason))
        case .pong: continuation.yield(.pong)
        case .unknown: break
        }
    }

    // MARK: - Helpers

    static func makeWebSocketTask(session: URLSession, url: URL, token: String) -> URLSessionWebSocketTask {
        let protocols = ["codeg-events", "codeg-token.\(base64URLNoPad(token))"]
        let task = session.webSocketTask(with: url, protocols: protocols)
        task.maximumMessageSize = 64 * 1024 * 1024
        return task
    }

    static func base64URLNoPad(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func websocketURL(from baseURL: URL) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.scheme = (baseURL.scheme?.lowercased() == "https") ? "wss" : "ws"
        let prefix = components?.percentEncodedPath ?? ""
        components?.percentEncodedPath = prefix + (prefix.hasSuffix("/") ? "" : "/") + "ws/events"
        components?.query = nil
        components?.fragment = nil
        return components?.url ?? baseURL
    }
}

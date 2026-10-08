import Foundation

/// A live WebSocket to `/ws/events` that surfaces **only** the terminal firehose
/// frames. PTY output/exit are broadcast by the server as legacy
/// `{channel, payload}` frames (NOT the attach protocol that ``EventStream``
/// speaks), e.g. `{channel:"terminal://output/<id>", payload:{terminal_id,data}}`.
/// ``EventStream`` deliberately drops those, so the terminal feature gets its own
/// thin socket here — keeping the streaming-critical session stream untouched.
///
/// The broadcaster only sends while at least one receiver is subscribed, so a
/// consumer must `start()` and await `.ready` (the server's `__ready__` frame)
/// **before** calling `terminal_spawn`, or the first output is lost.
///
/// Reuses ``EventStream``'s connection plumbing (token subprotocol, websocket
/// URL, the no-idle-timeout `streamSession`, and a keepalive ping that detects a
/// genuinely dead socket).
final class TerminalSocket: @unchecked Sendable {
    typealias CloseReason = EventStream.CloseReason

    enum Frame: Sendable {
        case ready
        case output(id: String, data: String)
        case exit(id: String)
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

    private static let outputPrefix = "terminal://output/"
    private static let exitPrefix = "terminal://exit/"

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
        let newTask = EventStream.makeWebSocketTask(session: session, url: url, token: token)
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

    func close() { shutdown(reason: nil, notify: false) }

    deinit { close() }

    // MARK: - Receive

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
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let channel = obj["channel"] as? String else {
            return  // attach-protocol ({type,…}) or malformed — not ours
        }
        if channel == "__ready__" {
            continuation.yield(.ready)
        } else if channel.hasPrefix(Self.outputPrefix) {
            let id = String(channel.dropFirst(Self.outputPrefix.count))
            let payload = obj["payload"] as? [String: Any]
            let text = payload?["data"] as? String ?? ""
            if !text.isEmpty { continuation.yield(.output(id: id, data: text)) }
        } else if channel.hasPrefix(Self.exitPrefix) {
            let id = String(channel.dropFirst(Self.exitPrefix.count))
            continuation.yield(.exit(id: id))
        }
        // Other legacy channels (folder/conversation upserts, …) are ignored.
    }
}

import Foundation

/// Pure liveness state; callers serialize access and supply a monotonic clock.
struct LivenessTracker {
    static let pingInterval: TimeInterval = 15
    static let timeout: TimeInterval = 45

    private let clock: () -> TimeInterval
    private var lastActivity: TimeInterval
    private var lastBytesReceived: Int64 = 0

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
        self.lastActivity = clock()
    }

    mutating func recordPong() { lastActivity = clock() }
    mutating func recordMessage() { lastActivity = clock() }

    mutating func hasTimedOut(bytesReceived: Int64) -> Bool {
        let now = clock()
        // A large frame may not produce a receive callback for several minutes.
        // Check progress BEFORE the deadline so that frame keeps the socket alive.
        if bytesReceived > lastBytesReceived {
            lastBytesReceived = bytesReceived
            lastActivity = now
        }
        return now - lastActivity >= Self.timeout
    }
}

protocol WebSocketHeartbeatTask: AnyObject {
    var countOfBytesReceived: Int64 { get }
    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void)
}

extension URLSessionWebSocketTask: WebSocketHeartbeatTask {}

/// Owns the periodic watchdog and path observation for either socket type.
/// The timer is independent of sendPing's completion: a lost pong cannot stall it.
final class WebSocketHealthMonitor: @unchecked Sendable {
    private let task: any WebSocketHeartbeatTask
    private let onClose: @Sendable (String) -> Void
    private let lock = NSLock()
    private var tracker: LivenessTracker
    private var timer: DispatchSourceTimer?
    private var networkObservation: NetworkMonitor.Observation?
    private var stopped = false

    init(task: any WebSocketHeartbeatTask,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         onClose: @escaping @Sendable (String) -> Void) {
        self.task = task
        self.tracker = LivenessTracker(clock: clock)
        self.onClose = onClose
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + LivenessTracker.pingInterval,
                       repeating: LivenessTracker.pingInterval)
        timer.setEventHandler { [weak self] in self?.checkLiveness() }
        self.timer = timer
        networkObservation = NetworkMonitor.shared.observe { [weak self] old, new in
            self?.pathChanged(old: old, new: new)
        }
        // Activate before releasing the lock: stop() must never cancel a
        // suspended source whose activation could be skipped by a close race.
        timer.resume()
    }

    func stop() { _ = stopMonitoring() }

    func sendPing() {
        guard lock.withLock({ !stopped }) else { return }
        task.sendPing { [weak self] error in
            // A failed ping is not proof of inactivity if messages or a large
            // frame are still arriving. Receive errors close at the transport;
            // otherwise the independent watchdog decides the liveness deadline.
            guard error == nil, let self else { return }
            self.lock.withLock {
                if !self.stopped { self.tracker.recordPong() }
            }
        }
    }

    func recordMessage() {
        lock.withLock {
            if !stopped { tracker.recordMessage() }
        }
    }

    func checkLiveness() {
        let timedOut: Bool? = lock.withLock {
            guard !stopped else { return nil }
            return tracker.hasTimedOut(bytesReceived: task.countOfBytesReceived)
        }
        guard let timedOut else { return }
        if timedOut {
            finish(reason: EventStream.CloseReason.keepaliveTimeout)
        } else {
            sendPing()
        }
    }

    func pathChanged(old: NetworkMonitor.Snapshot?, new: NetworkMonitor.Snapshot) {
        if NetworkMonitor.isMeaningfulChange(old: old, new: new) {
            finish(reason: EventStream.CloseReason.networkChanged)
        }
    }

    private func finish(reason: String) {
        guard stopMonitoring() else { return }
        onClose(reason)
    }

    private func stopMonitoring() -> Bool {
        lock.lock()
        guard !stopped else { lock.unlock(); return false }
        stopped = true
        let timer = timer
        let observation = networkObservation
        self.timer = nil
        networkObservation = nil
        lock.unlock()
        timer?.cancel()
        observation?.cancel()
        return true
    }

    deinit { stop() }
}

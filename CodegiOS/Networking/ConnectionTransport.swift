import Foundation

/// A stable handle retained by feature models. Each operation captures one
/// immutable generation, so URL, credentials and TLS policy cannot be mixed.
final class ConnectionTransport: @unchecked Sendable {
    let chatAvailability = ChatEndpointAvailability()
    typealias Source = EndpointSelector.Source
    struct Snapshot: Sendable {
        let generation = UUID()
        let baseURL: URL
        let token: String
        let customHeaders: [HeaderPair]
        let sessions: SessionFactory.Sessions
        let sessionOverride: URLSession?
        let retryFromGeneration: UUID?

        func session(_ kind: SessionFactory.Kind) -> URLSession { sessionOverride ?? sessions[kind] }
    }

    final class Registration: @unchecked Sendable {
        private let cancel: @Sendable () -> Void
        init(cancel: @escaping @Sendable () -> Void) { self.cancel = cancel }
        deinit { cancel() }
    }

    private let lock = NSLock()
    private var current: Snapshot
    private var invalidated = false
    private var closers: [UUID: @Sendable () -> Void] = [:]
    private let onOutcome: @Sendable (UUID, Source, Bool) -> Void
    private let onConnectivityFailure: @Sendable (UUID, Source) async -> Void

    init(baseURL: URL, token: String, customHeaders: [HeaderPair], sessions: SessionFactory.Sessions,
         sessionOverride: URLSession? = nil,
         onConnectivityFailure: @escaping @Sendable (UUID, Source) async -> Void = { _, _ in },
         onOutcome: @escaping @Sendable (UUID, Source, Bool) -> Void = { _, _, _ in }) {
        current = Snapshot(baseURL: baseURL, token: token, customHeaders: customHeaders,
                           sessions: sessions, sessionOverride: sessionOverride, retryFromGeneration: nil)
        self.onOutcome = onOutcome
        self.onConnectivityFailure = onConnectivityFailure
    }

    var snapshot: Snapshot { lock.withLock { current } }
    func isCurrent(_ generation: UUID) -> Bool { lock.withLock { !invalidated && current.generation == generation } }

    func report(_ snapshot: Snapshot, source: Source, success: Bool) {
        guard isCurrent(snapshot.generation) else { return }
        onOutcome(snapshot.generation, source, success)
    }

    func canRetry(_ snapshot: Snapshot) -> Bool {
        lock.withLock {
            !invalidated && current.retryFromGeneration == snapshot.generation && current.baseURL != snapshot.baseURL
        }
    }

    func recover(_ snapshot: Snapshot, source: Source) async -> Bool {
        guard !Task.isCancelled else { return false }
        if isCurrent(snapshot.generation) { await onConnectivityFailure(snapshot.generation, source) }
        return !Task.isCancelled && canRetry(snapshot)
    }

    func register(generation: UUID, close: @escaping @Sendable () -> Void) -> Registration {
        let id = UUID()
        let stale = lock.withLock {
            guard !invalidated, current.generation == generation else { return true }
            closers[id] = close
            return false
        }
        // A socket constructed across a switch must close before it can start.
        if stale { close() }
        return Registration { [weak self] in
            self?.lock.withLock { _ = self?.closers.removeValue(forKey: id) }
        }
    }

    func replace(baseURL: URL, token: String, customHeaders: [HeaderPair],
                 sessions: SessionFactory.Sessions, sessionOverride: URLSession? = nil,
                 retryFromGeneration: UUID? = nil) {
        let (old, callbacks) = lock.withLock {
            let old = current
            invalidated = false
            current = Snapshot(baseURL: baseURL, token: token, customHeaders: customHeaders,
                               sessions: sessions, sessionOverride: sessionOverride, retryFromGeneration: retryFromGeneration)
            let callbacks = Array(closers.values)
            closers.removeAll()
            return (old, callbacks)
        }
        // Publish the new generation BEFORE waking recovery consumers. Do not
        // call callbacks while holding the lock (closure teardown unregisters).
        callbacks.forEach { $0() }
        old.sessions.invalidate(cancelOutstanding: true)
    }

    func invalidate() {
        let (sessions, callbacks) = lock.withLock {
            invalidated = true
            let callbacks = Array(closers.values)
            closers.removeAll()
            return (current.sessions, callbacks)
        }
        callbacks.forEach { $0() }
        sessions.invalidate(cancelOutstanding: true)
    }

    // Sessions clean up when their last owner releases them. In particular a
    // temporary editor client borrows a bundle retained by SessionFactory;
    // destroying that facade must not invalidate the factory's cached bundle.
    // ServerStore explicitly invalidates on removal, and replace handles switches.
}

import Foundation

/// Owns the sessions for saved profiles; editor probes use their own factory.
/// Replacement drains existing tasks and prevents reuse of the old trust policy.
final class SessionFactory: @unchecked Sendable {
    static let shared = SessionFactory()

    enum Kind: CaseIterable {
        case standard, read, probe, install, stream

        var configuration: URLSessionConfiguration {
            let config = URLSessionConfiguration.default
            switch self {
            case .standard:
                config.timeoutIntervalForRequest = 30
                config.timeoutIntervalForResource = 120
            case .read:
                config.timeoutIntervalForRequest = 15
                config.timeoutIntervalForResource = 60
            case .probe:
                config.timeoutIntervalForRequest = 90
                config.timeoutIntervalForResource = 150
            case .install:
                config.timeoutIntervalForRequest = 120
                config.timeoutIntervalForResource = 900
            case .stream:
                config.timeoutIntervalForRequest = 604_800
                config.timeoutIntervalForResource = 604_800
            }
            config.waitsForConnectivity = self != .stream
            return config
        }
    }

    final class Sessions: @unchecked Sendable {
        let baseURL: URL
        let pin: String?
        private let values: [Kind: URLSession]
        private let lifecycleLock = NSLock()
        private var invalidated = false

        init(baseURL: URL, pin: String?) {
            self.baseURL = baseURL
            self.pin = pin
            values = Dictionary(uniqueKeysWithValues: Kind.allCases.map { kind in
                (kind, URLSession(configuration: kind.configuration,
                                  delegate: TrustEvaluator(baseURL: baseURL, pin: pin), delegateQueue: nil))
            })
        }

        subscript(_ kind: Kind) -> URLSession { values[kind]! }

        func requestEvaluator() -> TrustEvaluator { TrustEvaluator(baseURL: baseURL, pin: pin) }

        /// URLSession raises an Objective-C exception if a task is constructed
        /// after invalidation. Serialize synchronous task creation against
        /// invalidate; checking the transport generation alone has a race.
        func data(for request: URLRequest, session: URLSession, delegate: TrustEvaluator) async throws -> (Data, URLResponse) {
            let cancellation = RequestCancellation()
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    lifecycleLock.withLock {
                        guard !invalidated else {
                            continuation.resume(throwing: URLError(.cancelled))
                            return
                        }
                        let task = session.dataTask(with: request) { data, response, error in
                            if let error { continuation.resume(throwing: error) }
                            else if let data, let response { continuation.resume(returning: (data, response)) }
                            else { continuation.resume(throwing: APIError.transport("Malformed response")) }
                        }
                        task.delegate = delegate
                        cancellation.install(task)
                        task.resume()
                    }
                }
            } onCancel: {
                cancellation.cancel()
            }
        }

        func invalidate(cancelOutstanding: Bool = false) {
            let shouldInvalidate = lifecycleLock.withLock {
                guard !invalidated else { return false }
                invalidated = true
                return true
            }
            guard shouldInvalidate else { return }
            values.values.forEach {
                if cancelOutstanding { $0.invalidateAndCancel() }
                else { $0.finishTasksAndInvalidate() }
            }
        }

        deinit { invalidate() }
    }

    private struct Entry {
        let url: String
        let pin: String?
        let sessions: Sessions
    }
    private let lock = NSLock()
    private var cache: [UUID: Entry] = [:]

    func sessions(for profile: ServerProfile) -> Sessions {
        lock.lock()
        defer { lock.unlock() }
        if let entry = cache[profile.id], entry.url == profile.urlString, entry.pin == profile.pinnedCertSHA256 {
            return entry.sessions
        }
        cache[profile.id]?.sessions.invalidate()
        // Callers validate the URL before creating a client. Invalid profiles
        // get no usable endpoint; this placeholder is never used for a request.
        let sessions = Sessions(baseURL: profile.baseURL ?? URL(string: "https://invalid.invalid")!,
                                pin: profile.pinnedCertSHA256)
        cache[profile.id] = Entry(url: profile.urlString, pin: profile.pinnedCertSHA256, sessions: sessions)
        return sessions
    }

    func invalidate(_ id: UUID) {
        lock.lock()
        let removed = cache.removeValue(forKey: id)
        lock.unlock()
        removed?.sessions.invalidate()
    }

    deinit { cache.values.forEach { $0.sessions.invalidate() } }
}

private final class RequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func install(_ task: URLSessionTask) {
        let shouldCancel = lock.withLock {
            self.task = task
            return cancelled
        }
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        let task = lock.withLock {
            cancelled = true
            return self.task
        }
        task?.cancel()
    }
}

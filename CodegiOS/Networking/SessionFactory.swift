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
            config.waitsForConnectivity = true
            return config
        }
    }

    final class Sessions: @unchecked Sendable {
        let baseURL: URL
        let pin: String?
        private let values: [Kind: URLSession]

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

        func invalidate() {
            values.values.forEach { $0.finishTasksAndInvalidate() }
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

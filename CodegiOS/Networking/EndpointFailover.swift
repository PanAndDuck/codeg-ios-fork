import Foundation

enum EndpointFailover {
    static func isConnectivityFailure(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else { return false }
        return [URLError.cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                .timedOut, .networkConnectionLost, .notConnectedToInternet].contains(URLError.Code(rawValue: error.code))
    }

    /// A response lost after a mutation was sent is ambiguous. Let the owning
    /// feature reconcile it (especially acp_prompt); never submit it twice.
    static func mayReplay(path: String, kind: SessionFactory.Kind, sentBodyBytes: Int64) -> Bool {
        if sentBodyBytes == 0 { return true }
        return kind == .read || kind == .health || path.hasPrefix("get_") || path.hasPrefix("list_")
            || path.hasPrefix("acp_get_") || path.hasPrefix("acp_list_")
            || path == "acp_find_connection_for_conversation"
    }
}

/// A connection budget, not an operation/response deadline. Once bytes are
/// sent the existing read/probe/install timeouts remain authoritative.
struct ConnectionDeadline {
    private let clock: () -> TimeInterval
    private let deadline: TimeInterval
    private var connected = false

    init(timeout: TimeInterval, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
        deadline = clock() + timeout
    }

    mutating func expired(bytesSent: Int64) -> Bool {
        if bytesSent > 0 { connected = true }
        return !connected && clock() >= deadline
    }
}

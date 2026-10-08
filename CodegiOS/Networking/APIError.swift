import Foundation

/// Typed errors surfaced by `CodegClient`.
enum APIError: LocalizedError, Sendable, Equatable, CustomDebugStringConvertible {
    case invalidURL
    case unauthorized
    case turnInProgress
    case server(status: Int, code: String?, message: String)
    case cancelled
    case timedOut(String)
    case offline(String)
    case connectionLost(String)
    case serverUnreachable(String)
    // TLS/pinning extension point: I5 adds untrustedCertificate(fingerprint:)
    // here. Keep it non-transient and preserve it in fromTransport(_:).
    case tls(String)
    case relayAgentOffline(String)
    case relayStreamFailed(String)
    case tooManyAuthFailures(retryAfterSeconds: Int?, detail: String)
    case relayTooManyConnections(String)
    case payloadTooLarge(String)
    case gateway(status: Int, detail: String)
    case transport(String)
    case decoding(String)
    /// A live agent connection vanished server-side (a WS attach returned
    /// `detached { reason: "connection_gone" }`). Like an HTTP stale connection,
    /// the right recovery is a fresh `acp_connect` + retry.
    case streamGone

    var errorDescription: String? {
        localizedMessage()
    }

    /// Bundle is explicit so callers can also render in a chosen app language.
    func localizedMessage(bundle: Bundle = .main) -> String {
        switch self {
        case .invalidURL:
            return String(localized: "The server address is not a valid URL.", bundle: bundle)
        case .unauthorized:
            return String(localized: "Authentication failed. Check the server token.", bundle: bundle)
        case .turnInProgress:
            return String(localized: "A turn is already running on this session.", bundle: bundle)
        case .cancelled:
            // Diagnostic only. Display sites must use userMessage(_:) or isCancellation(_:).
            return String(localized: "Request cancelled.", bundle: bundle)
        case .timedOut:
            return String(localized: "The server took too long to respond. Please try again.", bundle: bundle)
        case .offline:
            return String(localized: "No network connection. Check Wi-Fi or cellular access.", bundle: bundle)
        case .connectionLost:
            return String(localized: "The connection was interrupted. Please try again.", bundle: bundle)
        case .serverUnreachable:
            return String(localized: "Cannot reach the server. Check its address and whether it is running.", bundle: bundle)
        case .tls:
            return String(localized: "A secure connection could not be established. Check the server certificate and your device’s date and time.", bundle: bundle)
        case .relayAgentOffline:
            return String(localized: "Home codeg is not connected to the relay", bundle: bundle)
        case .relayStreamFailed:
            return String(localized: "The relay connection to home Codeg failed. Please try again.", bundle: bundle)
        case .tooManyAuthFailures(let seconds, _):
            if let seconds {
                return String(localized: "Too many authentication attempts. Try again in \(seconds) seconds.", bundle: bundle)
            }
            return String(localized: "Too many authentication attempts. Please wait before trying again.", bundle: bundle)
        case .relayTooManyConnections:
            return String(localized: "Too many connections to the relay. Close unused connections and try again.", bundle: bundle)
        case .payloadTooLarge:
            return String(localized: "The request exceeds the server’s size limit. Remove or reduce attachments and try again.", bundle: bundle)
        case .gateway:
            return String(localized: "The gateway or relay could not reach the server. Please try again.", bundle: bundle)
        case .server(let status, _, let message):
            if status == 501 {
                return String(localized: "This feature is not supported by this server.", bundle: bundle)
            }
            if (500..<600).contains(status) || message.isEmpty {
                return String(localized: "The server could not complete the request. Please try again.", bundle: bundle)
            }
            return message
        case .transport:
            return String(localized: "The request could not be sent. Please check your connection and try again.", bundle: bundle)
        case .decoding:
            return String(localized: "Could not read the server response. Check that the server is up to date.", bundle: bundle)
        case .streamGone:
            return String(localized: "The agent connection is no longer available.", bundle: bundle)
        }
    }

    /// Technical context stays available without putting transport jargon in banners.
    var debugDescription: String {
        switch self {
        case .invalidURL: return "invalidURL"
        case .unauthorized: return "unauthorized (HTTP 401)"
        case .turnInProgress: return "turnInProgress (HTTP 409 / turn_in_progress)"
        case .cancelled: return "cancelled (NSURLErrorCancelled)"
        case .timedOut(let detail): return "timedOut: \(detail)"
        case .offline(let detail): return "offline: \(detail)"
        case .connectionLost(let detail): return "connectionLost: \(detail)"
        case .serverUnreachable(let detail): return "serverUnreachable: \(detail)"
        case .tls(let detail): return "tls: \(detail)"
        case .relayAgentOffline(let detail): return "HTTP 503 relay_agent_offline: \(detail)"
        case .relayStreamFailed(let detail): return "HTTP 502 relay_stream_failed: \(detail)"
        case .tooManyAuthFailures(let seconds, let detail):
            return "HTTP 429 too_many_auth_failures retry_after_secs=\(seconds.map(String.init) ?? "unknown"): \(detail)"
        case .relayTooManyConnections(let detail): return "HTTP 429 relay_too_many_connections: \(detail)"
        case .payloadTooLarge(let detail): return "HTTP 413: \(detail)"
        case .gateway(let status, let detail): return "HTTP \(status) gateway: \(detail)"
        case .server(let status, let code, let message): return "HTTP \(status) \(code ?? "unknown"): \(message)"
        case .transport(let detail): return "transport: \(detail)"
        case .decoding(let detail): return "decoding: \(detail)"
        case .streamGone: return "streamGone (connection_gone)"
        }
    }

    static func fromTransport(_ error: Error) -> APIError {
        if isCancellation(error) { return .cancelled }
        if let api = error as? APIError { return api }
        guard let urlError = error as? URLError else { return .transport(error.localizedDescription) }
        let detail = "NSURLErrorDomain \(urlError.code.rawValue): \(urlError.localizedDescription)"
        switch urlError.code {
        case .cancelled: return .cancelled
        case .timedOut: return .timedOut(detail)
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: return .offline(detail)
        case .networkConnectionLost: return .connectionLost(detail)
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return .serverUnreachable(detail)
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .serverCertificateHasBadDate,
             .clientCertificateRejected, .clientCertificateRequired:
            return .tls(detail)
        default: return .transport(detail)
        }
    }

    static func fromHTTP(status: Int, body: Data, retryAfter: String? = nil) -> APIError {
        let envelope = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let code = envelope?["code"] as? String
        let message = envelope?["message"] as? String ?? HTTPURLResponse.localizedString(forStatusCode: status)
        if status == 401 { return .unauthorized }
        if status == 409 || code == "turn_in_progress" { return .turnInProgress }
        switch (status, code) {
        case (503, "relay_agent_offline"): return .relayAgentOffline(message)
        case (502, "relay_stream_failed"): return .relayStreamFailed(message)
        case (429, "too_many_auth_failures"):
            // Decode the integer separately so malformed retry metadata cannot hide the code.
            let seconds = (try? JSONDecoder().decode(AuthRetry.self, from: body))?.retryAfterSeconds
            let validSeconds = seconds.flatMap { $0 >= 0 ? $0 : nil }
            let headerSeconds = retryAfter.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                .flatMap { $0 >= 0 ? $0 : nil }
            return .tooManyAuthFailures(retryAfterSeconds: validSeconds ?? headerSeconds, detail: message)
        case (429, "relay_too_many_connections"): return .relayTooManyConnections(message)
        case (413, _): return .payloadTooLarge(message)
        case (502, nil), (504, nil): return .gateway(status: status, detail: message)
        default: return .server(status: status, code: code, message: message)
        }
    }

    private struct AuthRetry: Decodable {
        let retryAfterSeconds: Int?
        enum CodingKeys: String, CodingKey { case retryAfterSeconds = "retry_after_secs" }
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case .cancelled = error as? APIError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    /// A nil message means cancellation: callers must not create an error UI.
    static func userMessage(_ error: Error) -> String? {
        guard !isCancellation(error) else { return nil }
        if let api = error as? APIError { return api.errorDescription }
        if error is URLError { return fromTransport(error).errorDescription }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// The folder isn't a git repository — the server's git endpoints guard with
    /// `ensure_git_repo`, returning HTTP 422 `not_a_git_repository`. Lets the
    /// Changes/Commits views show a calm "not a repo" state instead of an error.
    var isNotAGitRepository: Bool {
        if case .server(_, let code, _) = self { return code == "not_a_git_repository" }
        return false
    }

    /// A remote git operation (push/pull/fetch) failed to authenticate — the
    /// server returns `authentication_failed`, or git's own message leaks through.
    /// Mirrors the web `isAuthError` so the credential-retry flow can decide to
    /// prompt for a token/credentials and retry.
    var isAuthFailure: Bool {
        switch self {
        case .unauthorized:
            // Server-token auth, not a git remote — never trigger the git prompt.
            return false
        case .server(_, let code, let message):
            if code == "authentication_failed" { return true }
            let lower = message.lowercased()
            return lower.contains("authentication failed")
                || lower.contains("could not read username")
                || lower.contains("could not read password")
                || lower.contains("logon failed")
        default:
            return false
        }
    }

    /// True for conditions where a fresh `acp_connect` + retry is the right fix.
    var isStaleConnection: Bool {
        switch self {
        case .streamGone:
            return true
        case .server(let status, let code, _):
            return status == 404 || code == "connection_not_found" || code == "unknown_connection"
        default:
            return false
        }
    }

    /// Transient failures worth a brief, silent retry before alarming the user: a
    /// dropped/timed-out transport, or a 5xx (the server hiccuped). Auth (401),
    /// other 4xx (turn-in-progress, not-a-repo, …), and decoding errors are
    /// deterministic — retrying only delays the inevitable, so they fail fast.
    var isTransient: Bool {
        switch self {
        case .transport, .timedOut, .offline, .connectionLost, .serverUnreachable,
             .relayAgentOffline, .relayStreamFailed, .gateway:
            return true
        case .server(let status, _, _):
            return (500..<600).contains(status)
        default:
            return false
        }
    }
}

/// Run a network read up to `attempts` times, retrying ONLY transient failures
/// (see ``APIError/isTransient``) with a short exponential backoff. Most of the
/// "network error" banners users hit are a single momentary blip — Wi-Fi waking,
/// one dropped packet, a brief AP roam — that a sub-second retry rides out
/// invisibly. Non-transient errors and task cancellation propagate immediately,
/// so a real auth/decoding failure (or a disappearing view) isn't delayed.
func withNetworkRetry<T>(
    attempts: Int = 2,
    _ operation: () async throws -> T
) async throws -> T {
    var attempt = 0
    while true {
        attempt += 1
        try Task.checkCancellation()
        do {
            return try await operation()
        } catch let error as APIError where error.isTransient && attempt < attempts {
            // 0.4s, 0.8s, … — long enough to clear a transient drop, short enough
            // to stay below notice. Cancellation aborts the wait promptly.
            try await Task.sleep(for: .milliseconds(400 * (1 << (attempt - 1))))
        }
    }
}

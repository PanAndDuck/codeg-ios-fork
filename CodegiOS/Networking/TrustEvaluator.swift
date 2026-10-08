import Foundation
import Security

/// One immutable trust policy per server/session. HTTP requests use a fresh
/// instance as their task delegate so rejected fingerprints cannot cross requests.
final class TrustEvaluator: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    enum Decision: Equatable {
        case accept, reject, systemDefault, recordUntrusted
    }

    let baseURL: URL
    let pin: String?
    private let lock = NSLock()
    private var rejectedFingerprint: String?
    private var bodyBytes: Int64 = 0

    var sentBodyBytes: Int64 { lock.withLock { bodyBytes } }
    func recordSentBodyBytes(_ bytes: Int64) { lock.withLock { bodyBytes = max(bodyBytes, bytes) } }

    init(baseURL: URL, pin: String?) {
        self.baseURL = baseURL
        // Invalid non-nil pins must fail closed, never turn into unpinned trust.
        self.pin = pin.map { (try? CertificateFingerprint.normalize($0)) ?? $0 }
    }

    var untrustedFingerprint: String? {
        lock.lock()
        defer { lock.unlock() }
        return rejectedFingerprint
    }

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        FailoverDiagnostics.record("http waiting-for-connectivity path=\(task.originalRequest?.url?.lastPathComponent ?? "unknown") port=\(baseURL.port ?? 0)")
    }

    static func decision(pin: String?, presented: String?, systemTrusted: Bool) -> Decision {
        if let pin {
            guard let normalized = try? CertificateFingerprint.normalize(pin),
                  let presented, normalized == presented else { return .reject }
            return .accept
        }
        return systemTrusted ? .systemDefault : .recordUntrusted
    }

    static func fingerprint(of trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return nil }
        return CertificateFingerprint.sha256(of: SecCertificateCopyData(leaf) as Data)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        evaluate(challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        evaluate(challenge, completionHandler: completionHandler)
    }

    private func evaluate(_ challenge: URLAuthenticationChallenge,
                          completionHandler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(pin == nil ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
            return
        }
        // A pin is scoped to this origin, including its port. It must never
        // become a blanket trust exception for redirected requests.
        guard challenge.protectionSpace.host.lowercased() == baseURL.host?.lowercased(),
              challenge.protectionSpace.port == (baseURL.port ?? 443) else {
            completionHandler(pin == nil ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
            return
        }
        let systemTrusted = SecTrustEvaluateWithError(trust, nil)
        let fingerprint = Self.fingerprint(of: trust)
        switch Self.decision(pin: pin, presented: fingerprint, systemTrusted: systemTrusted) {
        case .accept:
            completionHandler(.useCredential, URLCredential(trust: trust))
        case .systemDefault:
            completionHandler(.performDefaultHandling, nil)
        case .reject, .recordUntrusted:
            lock.lock()
            rejectedFingerprint = fingerprint
            lock.unlock()
            // Unpinned connections retain URLSession's normal system handling.
            completionHandler(pin == nil ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
        }
    }

    func allowsRedirect(to url: URL) -> Bool {
        // Authenticated requests may carry proxy credentials even without a
        // certificate pin. Never forward those headers to another origin.
        let scheme = baseURL.scheme?.lowercased()
        let defaultPort = scheme == "https" ? 443 : 80
        return url.scheme?.lowercased() == scheme
            && (pin == nil || scheme == "https")
            && url.host?.lowercased() == baseURL.host?.lowercased()
            && (url.port ?? defaultPort) == (baseURL.port ?? defaultPort)
            && url.user == nil && url.password == nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(allowsRedirect(to:)) == true ? request : nil)
    }
}

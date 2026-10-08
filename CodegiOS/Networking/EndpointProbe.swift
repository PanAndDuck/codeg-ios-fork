import Foundation

enum EndpointProbe {
    typealias Operation = @Sendable (ServerEndpoint, String, [HeaderPair], TimeInterval) async -> Bool

    static func configuration(timeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return configuration
    }

    static func check(_ endpoint: ServerEndpoint, token: String, headers: [HeaderPair], timeout: TimeInterval) async -> Bool {
        guard let baseURL = endpoint.baseURL else { return false }
        let trust = TrustEvaluator(baseURL: baseURL, pin: endpoint.pinnedCertSHA256)
        let session = URLSession(configuration: configuration(timeout: timeout), delegate: trust, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/health"), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        RequestHeaders.apply(headers, to: &request)
        do {
            let (data, response) = try await session.data(for: request, delegate: trust)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let health = try? CodegJSON.decoder.decode(HealthResponse.self, from: data) else { return false }
            return health.status == "ok"
        } catch { return false }
    }
}

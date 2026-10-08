import XCTest
@testable import Codeg

final class APIErrorTests: XCTestCase {
    func testCancelledRequestDoesNotRetry() async throws {
        let error = try await send(failure: URLError(.cancelled))
        XCTAssertFalse(error.isTransient)
    }

    func testTLSFailureDoesNotRetry() async throws {
        let error = try await send(failure: URLError(.serverCertificateUntrusted))
        XCTAssertFalse(error.isTransient)
    }

    func testRelayOfflineResponseExplainsHomeConnection() async throws {
        let error = try await send(status: 503, body: #"{"code":"relay_agent_offline"}"#)
        guard case .relayAgentOffline = error else { return XCTFail("Unexpected error: \(error)") }
    }

    func testTransportMappingTable() {
        let rows: [(URLError.Code, (String) -> APIError)] = [
            (.timedOut, APIError.timedOut),
            (.notConnectedToInternet, APIError.offline),
            (.dataNotAllowed, APIError.offline),
            (.internationalRoamingOff, APIError.offline),
            (.networkConnectionLost, APIError.connectionLost),
            (.cannotFindHost, APIError.serverUnreachable),
            (.cannotConnectToHost, APIError.serverUnreachable),
            (.dnsLookupFailed, APIError.serverUnreachable),
            (.secureConnectionFailed, APIError.tls),
            (.serverCertificateUntrusted, APIError.tls),
            (.serverCertificateHasUnknownRoot, APIError.tls),
            (.serverCertificateNotYetValid, APIError.tls),
            (.serverCertificateHasBadDate, APIError.tls),
            (.clientCertificateRejected, APIError.tls),
            (.clientCertificateRequired, APIError.tls),
            (.badServerResponse, APIError.transport)
        ]
        for (code, expected) in rows {
            let source = URLError(code)
            let detail = "NSURLErrorDomain \(code.rawValue): \(source.localizedDescription)"
            XCTAssertEqual(APIError.fromTransport(source), expected(detail), "\(code)")
        }
        XCTAssertEqual(APIError.fromTransport(URLError(.cancelled)), .cancelled)
        XCTAssertEqual(APIError.fromTransport(CancellationError()), .cancelled)
        XCTAssertEqual(APIError.fromTransport(APIError.tls("pinning detail")), .tls("pinning detail"))
    }

    func testHTTPMappingTable() {
        let rows: [(Int, String, String?, APIError)] = [
            (503, #"{"code":"relay_agent_offline","message":"home offline"}"#, nil, .relayAgentOffline("home offline")),
            (502, #"{"code":"relay_stream_failed","message":"stream closed"}"#, nil, .relayStreamFailed("stream closed")),
            (429, #"{"code":"too_many_auth_failures","retry_after_secs":42,"message":"wait"}"#, "99", .tooManyAuthFailures(retryAfterSeconds: 42, detail: "wait")),
            (429, #"{"code":"too_many_auth_failures","message":"wait"}"#, " 30 ", .tooManyAuthFailures(retryAfterSeconds: 30, detail: "wait")),
            (429, #"{"code":"too_many_auth_failures","retry_after_secs":-1,"message":"wait"}"#, "-2", .tooManyAuthFailures(retryAfterSeconds: nil, detail: "wait")),
            (429, #"{"code":"too_many_auth_failures","retry_after_secs":"bad","message":"wait"}"#, "7", .tooManyAuthFailures(retryAfterSeconds: 7, detail: "wait")),
            (429, #"{"code":"too_many_auth_failures","retry_after_secs":true,"message":"wait"}"#, "bad", .tooManyAuthFailures(retryAfterSeconds: nil, detail: "wait")),
            (429, #"{"code":"too_many_auth_failures","retry_after_secs":0,"message":"wait"}"#, nil, .tooManyAuthFailures(retryAfterSeconds: 0, detail: "wait")),
            (429, #"{"code":"relay_too_many_connections","message":"busy"}"#, nil, .relayTooManyConnections("busy")),
            (413, #"{"message":"huge"}"#, nil, .payloadTooLarge("huge")),
            (502, #"{"message":"bad gateway"}"#, nil, .gateway(status: 502, detail: "bad gateway")),
            (504, #"{"message":"gateway timeout"}"#, nil, .gateway(status: 504, detail: "gateway timeout")),
            (401, #"{"code":"turn_in_progress"}"#, nil, .unauthorized),
            (409, "not JSON", nil, .turnInProgress),
            (400, #"{"code":"turn_in_progress"}"#, nil, .turnInProgress),
            (501, #"{"code":"not_implemented","message":"unsupported"}"#, nil, .server(status: 501, code: "not_implemented", message: "unsupported")),
            (422, #"{"code":"not_a_git_repository","message":"not repo"}"#, nil, .server(status: 422, code: "not_a_git_repository", message: "not repo")),
            (502, #"{"code":"future_code","message":"new failure"}"#, nil, .server(status: 502, code: "future_code", message: "new failure")),
            (400, #"{"code":"relay_agent_offline","message":"wrong status"}"#, nil, .server(status: 400, code: "relay_agent_offline", message: "wrong status"))
        ]
        for (status, body, retryAfter, expected) in rows {
            XCTAssertEqual(APIError.fromHTTP(status: status, body: Data(body.utf8), retryAfter: retryAfter), expected)
        }
        for body in ["", "<html>bad gateway</html>", "null", "[]", #"{"code":123}"#] {
            guard case .gateway(status: 502, _) = APIError.fromHTTP(status: 502, body: Data(body.utf8)) else {
                return XCTFail("Malformed proxy response was not classified")
            }
        }
    }

    func testTransientTable() {
        for (error, expected) in Self.allCases {
            XCTAssertEqual(error.isTransient, expected, error.debugDescription)
        }
        XCTAssertFalse(APIError.server(status: 600, code: nil, message: "outside HTTP 5xx").isTransient)
    }

    func testEveryCaseHasEnglishAndChineseMessagesAndDiagnostics() throws {
        let en = try XCTUnwrap(Bundle(path: XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj"))))
        let zh = try XCTUnwrap(Bundle(path: XCTUnwrap(Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"))))
        for (error, _) in Self.allCases {
            XCTAssertFalse(try XCTUnwrap(error.errorDescription).isEmpty)
            XCTAssertFalse(error.debugDescription.isEmpty)
            let english = error.localizedMessage(bundle: en)
            let chinese = error.localizedMessage(bundle: zh)
            XCTAssertFalse(english.isEmpty)
            XCTAssertFalse(chinese.isEmpty)
            XCTAssertNotEqual(english, chinese, error.debugDescription)
        }
        let rateLimit = APIError.tooManyAuthFailures(retryAfterSeconds: 42, detail: "ban")
        XCTAssertTrue(rateLimit.localizedMessage(bundle: en).contains("42"))
        XCTAssertTrue(rateLimit.localizedMessage(bundle: zh).contains("42"))
        XCTAssertEqual(APIError.relayAgentOffline("").localizedMessage(bundle: zh), "家里的 Codeg 未连接到中继")
    }

    func testCancellationHasNoUserMessage() {
        for error: Error in [APIError.cancelled, CancellationError(), URLError(.cancelled),
                             NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)] {
            XCTAssertTrue(APIError.isCancellation(error))
            XCTAssertNil(APIError.userMessage(error))
        }
        XCTAssertFalse(APIError.isCancellation(APIError.tls("TLS")))
        XCTAssertNotNil(APIError.userMessage(APIError.offline("offline")))
    }

    func testDiagnosticDetailsRemainAvailable() {
        XCTAssertTrue(APIError.fromTransport(URLError(.timedOut)).debugDescription.contains("-1001"))
        let error = APIError.fromHTTP(status: 429, body: Data(#"{"code":"too_many_auth_failures","retry_after_secs":12,"message":"raw detail"}"#.utf8))
        XCTAssertTrue(error.debugDescription.contains("429"))
        XCTAssertTrue(error.debugDescription.contains("too_many_auth_failures"))
        XCTAssertTrue(error.debugDescription.contains("12"))
        XCTAssertTrue(error.debugDescription.contains("raw detail"))
    }

    func testNonTransientErrorsAreAttemptedOnlyOnce() async {
        for error in [APIError.cancelled, .tls("TLS"), .unauthorized, .payloadTooLarge("large"),
                      .tooManyAuthFailures(retryAfterSeconds: 60, detail: "wait")] {
            var calls = 0
            do {
                try await withNetworkRetry {
                    calls += 1
                    throw error
                }
                XCTFail("Expected failure")
            } catch {}
            XCTAssertEqual(calls, 1)
        }
    }

    private static let allCases: [(APIError, Bool)] = [
        (.invalidURL, false), (.unauthorized, false), (.turnInProgress, false), (.cancelled, false),
        (.timedOut("timeout"), true), (.offline("offline"), true), (.connectionLost("lost"), true),
        (.serverUnreachable("host"), true), (.tls("TLS"), false), (.relayAgentOffline("offline"), true),
        (.relayStreamFailed("stream"), true), (.tooManyAuthFailures(retryAfterSeconds: 42, detail: "ban"), false),
        (.tooManyAuthFailures(retryAfterSeconds: nil, detail: "ban"), false), (.relayTooManyConnections("busy"), false),
        (.payloadTooLarge("large"), false), (.gateway(status: 502, detail: "gateway"), true),
        (.server(status: 500, code: nil, message: "internal"), true),
        (.server(status: 501, code: nil, message: "unsupported"), true),
        (.server(status: 400, code: nil, message: ""), false),
        (.transport("other"), true), (.decoding("JSON"), false), (.streamGone, false)
    ]

    func testRetryAfterHeaderReachesHTTPMapping() async throws {
        let error = try await send(status: 429, body: #"{"code":"too_many_auth_failures","message":"wait"}"#, retryAfter: "23")
        XCTAssertEqual(error, .tooManyAuthFailures(retryAfterSeconds: 23, detail: "wait"))
    }

    private func send(failure: Error? = nil, status: Int = 200, body: String = "", retryAfter: String? = nil) async throws -> APIError {
        let client = makeClient(failure: failure, status: status, body: body, retryAfter: retryAfter)
        defer { client.session.invalidateAndCancel() }
        do {
            _ = try await client.send("test", rawBody: Data("{}".utf8))
            XCTFail("Expected the request to fail")
            return .invalidURL
        } catch let error as APIError {
            return error
        }
    }

    private func makeClient(failure: Error? = nil, status: Int = 200, body: String = "", retryAfter: String? = nil) -> CodegClient {
        ErrorURLProtocol.failure = failure
        ErrorURLProtocol.status = status
        ErrorURLProtocol.body = Data(body.utf8)
        ErrorURLProtocol.retryAfter = retryAfter
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ErrorURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return CodegClient(baseURL: URL(string: "https://errors.invalid")!, token: "test-only", session: session)
    }
}

private final class ErrorURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var failure: Error?
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var retryAfter: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let failure = Self.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let headers = Self.retryAfter.map { ["Retry-After": $0] }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

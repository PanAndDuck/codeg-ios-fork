import XCTest
@testable import Codeg

final class RequestHeaderTests: XCTestCase {
    func testReservedAndMalformedHeadersAreRejectedCaseInsensitively() {
        for name in ["Authorization", "authorization", "HOST", "Connection", "Upgrade", "Content-Length", "Sec-WebSocket-Protocol", "sec-websocket-key", " X-Test", "X Test", "", "X:Test"] {
            XCTAssertNotNil(RequestHeaders.validationError([HeaderPair(name: name, value: "x")] ), name)
        }
        for value in ["a\r\nb", "a\nb", "a\u{0}b"] {
            XCTAssertNotNil(RequestHeaders.validationError([HeaderPair(name: "X-Test", value: value)]))
        }
        XCTAssertNotNil(RequestHeaders.validationError([.init(name: "X-Test", value: "a"), .init(name: "x-test", value: "b")]))
        XCTAssertNil(RequestHeaders.validationError([.init(name: "CF-Access-Client-Secret", value: "secret")]))
    }

    func testHTTPIncludesHeadersButNeverOverridesBearer() async throws {
        HeaderHTTPFixture.inspect = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/prefix/api/health")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "CF-Access-Client-Id"), "id")
            XCTAssertEqual(request.value(forHTTPHeaderField: "CF-Access-Client-Secret"), "secret")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Bad"))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeaderHTTPFixture.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); HeaderHTTPFixture.inspect = nil }
        let client = CodegClient(baseURL: URL(string: "https://headers.invalid/prefix")!, token: "fixture-token", session: session,
                                 customHeaders: [.init(name: "CF-Access-Client-Id", value: "id"),
                                                 .init(name: "CF-Access-Client-Secret", value: "secret"),
                                                 .init(name: "authorization", value: "wrong"),
                                                 .init(name: "X-Bad", value: "a\r\nb")])
        _ = try await client.health()
    }

    func testWebSocketUpgradeUsesRequestHeadersAndKeepsAuthSubprotocol() {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = EventStream.makeWebSocketTask(session: session, url: URL(string: "wss://headers.invalid/prefix/ws/events")!, token: "fixture",
                                                 customHeaders: [.init(name: "CF-Access-Client-Secret", value: "secret"),
                                                                 .init(name: "Sec-WebSocket-Protocol", value: "evil")])
        defer { task.cancel() }
        XCTAssertEqual(task.originalRequest?.value(forHTTPHeaderField: "CF-Access-Client-Secret"), "secret")
        XCTAssertEqual(task.originalRequest?.value(forHTTPHeaderField: "Sec-WebSocket-Protocol"), "codeg-events, codeg-token.Zml4dHVyZQ")
        XCTAssertEqual(task.maximumMessageSize, 64 * 1024 * 1024)
    }
}

private final class HeaderHTTPFixture: URLProtocol {
    static var inspect: ((URLRequest) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "headers.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.inspect?(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"status":"ok","version":"test"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

import XCTest
@testable import Codeg

final class CodegClientLiveTests: XCTestCase {
    private func client(response: String, inspect: @escaping (URLRequest) -> Void = { _ in }) -> CodegClient {
        LiveHTTPFixture.reply = { request in
            inspect(request)
            return Data(response.utf8)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveHTTPFixture.self]
        return CodegClient(baseURL: URL(string: "https://i2-fixture.invalid/base")!, token: "fixture-token",
                           session: URLSession(configuration: configuration))
    }

    func testTouchUsesCamelCaseBodyAndBooleanResponse() async throws {
        let api = client(response: "true") { request in
            XCTAssertEqual(request.url?.path, "/base/api/acp_touch_connection")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            let body = LiveHTTPFixture.body(of: request)
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: String]
            XCTAssertEqual(json, ["connectionId": "connection-1"])
        }
        let touched = try await api.touchConnection(connectionId: "connection-1")
        XCTAssertTrue(touched)
    }

    func testLiveSnapshotUsesExistingEndpointAndDecodesTurnState() async throws {
        let api = client(response: """
        {"connection_id":"connection-1","status":"prompting","event_seq":42,
         "pending_user_message":{"message_id":"client-message","blocks":[]},
         "live_message":{"content":[{"kind":"text","text":"hello"}]}}
        """) { request in
            XCTAssertEqual(request.url?.path, "/base/api/acp_get_session_snapshot")
        }
        let snapshot = try await api.connectionSnapshot(connectionId: "connection-1", as: LiveSessionSnapshot.self)
        XCTAssertEqual(snapshot?.status, .prompting)
        XCTAssertEqual(snapshot?.eventSeq, 42)
        XCTAssertEqual(snapshot?.pendingUserMessage?.messageId, "client-message")
        XCTAssertEqual(snapshot?.liveMessage?.content.count, 1)
    }

    func testMissingConnectionSnapshotIsNil() async throws {
        let snapshot = try await client(response: "null").connectionSnapshot(connectionId: "missing", as: LiveSessionSnapshot.self)
        XCTAssertNil(snapshot)
    }
}

private final class LiveHTTPFixture: URLProtocol {
    static var reply: ((URLRequest) -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let reply = Self.reply else { return }
        let data = reply(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                                                            httpVersion: "HTTP/1.1", headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            body.append(contentsOf: buffer.prefix(count))
        }
        return body
    }
}

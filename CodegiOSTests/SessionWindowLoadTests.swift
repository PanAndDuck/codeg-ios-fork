import XCTest
@testable import Codeg

final class SessionWindowLoadTests: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(WindowURLProtocol.self)
        WindowURLProtocol.reset()
    }

    override func tearDown() {
        WindowURLProtocol.reset()
        URLProtocol.unregisterClass(WindowURLProtocol.self)
        super.tearDown()
    }

    @MainActor
    func testFolderFailureDoesNotFailTranscriptAndDetailRetries() async throws {
        let payload = try WindowFixtures.detail(ids: ["latest"], offset: 60, total: 61, hash: "seam")
        WindowURLProtocol.respond = { request, attempt in
            if request.url?.lastPathComponent == "list_all_folder_details" { return (500, Data()) }
            return attempt == 1 ? (503, Data()) : (200, payload)
        }
        let model = makeModel()
        await model.load()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.turns.map(\.id), ["latest"])
        XCTAssertNil(model.folder)
        XCTAssertEqual(WindowURLProtocol.bodies("get_folder_conversation"),
                       [["conversationId": 42, "tailTurns": 60], ["conversationId": 42, "tailTurns": 60]])
        model.teardown()
    }

    @MainActor
    func testSlowFolderRequestDoesNotDelayTranscript() async throws {
        let payload = try WindowFixtures.detail(ids: ["latest"])
        WindowURLProtocol.respond = { request, _ in
            request.url?.lastPathComponent == "list_all_folder_details" ? nil : (200, payload)
        }
        let model = makeModel()
        let loaded = expectation(description: "Transcript loads while folder response is pending")
        let task = Task { await model.load(); loaded.fulfill() }
        await fulfillment(of: [loaded], timeout: 2)
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.turns.map(\.id), ["latest"])
        task.cancel()
        model.teardown()
    }

    @MainActor
    func testForegroundRefreshUsesLoadedOffsetAndResetsOnPrefixMismatch() async throws {
        let first = try WindowFixtures.detail(ids: ["latest"], offset: 60, total: 61, hash: "seam")
        let mismatch = try WindowFixtures.detail(ids: ["wrong"], offset: 60, total: 61, hash: "changed")
        let reset = try WindowFixtures.detail(ids: ["reset"], offset: 20, total: 21, hash: "new")
        WindowURLProtocol.respond = { request, attempt in
            if request.url?.lastPathComponent == "list_all_folder_details" { return (200, Data("[]".utf8)) }
            return (200, attempt == 1 ? first : (attempt == 2 ? mismatch : reset))
        }
        let model = makeModel()
        await model.load()
        await model.refreshOnForeground()
        XCTAssertEqual(model.turns.map(\.id), ["reset"])
        XCTAssertEqual(WindowURLProtocol.bodies("get_folder_conversation"), [
            ["conversationId": 42, "tailTurns": 60],
            ["conversationId": 42, "fromIndex": 60],
            ["conversationId": 42, "tailTurns": 60]
        ])
        model.teardown()
    }

    @MainActor
    func testOlderPagePrependsAndNextRefreshUsesNewOffset() async throws {
        let first = try WindowFixtures.detail(ids: ["c", "d"], offset: 2, total: 4, hash: "seam")
        let refreshed = try WindowFixtures.detail(ids: ["a", "b", "c", "d", "e"], offset: 0, total: 5, hash: "head")
        let page = try JSONSerialization.data(withJSONObject: [
            "turns": WindowFixtures.turns(["a", "b"]), "turns_offset": 0, "turns_total": 4,
            "assistant_turns_before_offset": 0, "prefix_hash": "head", "prefix_hash_before_index": "seam"
        ])
        WindowURLProtocol.respond = { request, attempt in
            switch request.url?.lastPathComponent {
            case "list_all_folder_details": return (200, Data("[]".utf8))
            case "get_folder_conversation_turns": return (200, page)
            default: return (200, attempt == 1 ? first : refreshed)
            }
        }
        let model = makeModel()
        await model.load()
        await model.loadEarlierTurns()
        XCTAssertEqual(model.turns.map(\.id), ["a", "b", "c", "d"])
        XCTAssertFalse(model.hasEarlierTurns)
        XCTAssertFalse(model.isLoadingEarlierTurns)
        XCTAssertEqual(WindowURLProtocol.bodies("get_folder_conversation_turns"),
                       [["conversationId": 42, "beforeIndex": 2, "limit": 60]])
        await model.refreshOnForeground()
        XCTAssertEqual(model.turns.map(\.id), ["a", "b", "c", "d", "e"])
        XCTAssertEqual(WindowURLProtocol.bodies("get_folder_conversation").last,
                       ["conversationId": 42, "fromIndex": 0])
        model.teardown()
    }

    @MainActor
    func testLateOlderPageCannotOverwriteForegroundResetAndIsSingleFlight() async throws {
        let first = try WindowFixtures.detail(ids: ["c", "d"], offset: 2, total: 4, hash: "seam")
        let reset = try WindowFixtures.detail(ids: ["reset"], offset: 0, total: 1, hash: "head")
        let page = try JSONSerialization.data(withJSONObject: [
            "turns": WindowFixtures.turns(["a", "b"]), "turns_offset": 0, "turns_total": 4,
            "assistant_turns_before_offset": 0, "prefix_hash": "head", "prefix_hash_before_index": "seam"
        ])
        let pageRequested = expectation(description: "Older page pending")
        WindowURLProtocol.respond = { request, attempt in
            switch request.url?.lastPathComponent {
            case "list_all_folder_details": return (200, Data("[]".utf8))
            case "get_folder_conversation_turns": pageRequested.fulfill(); return nil
            default: return (200, attempt == 1 ? first : reset)
            }
        }
        let model = makeModel()
        await model.load()
        let paging = Task { await model.loadEarlierTurns() }
        await fulfillment(of: [pageRequested], timeout: 2)
        await model.loadEarlierTurns()
        XCTAssertEqual(WindowURLProtocol.bodies("get_folder_conversation_turns").count, 1)
        await model.refreshOnForeground()
        WindowURLProtocol.completePending("get_folder_conversation_turns", status: 200, data: page)
        await paging.value
        XCTAssertEqual(model.turns.map(\.id), ["reset"])
        XCTAssertFalse(model.hasEarlierTurns)
        model.teardown()
    }

    @MainActor
    func testPagingFailureKeepsTranscriptAndCanRetry() async throws {
        let first = try WindowFixtures.detail(ids: ["c"], offset: 2, total: 3, hash: "seam")
        let page = try JSONSerialization.data(withJSONObject: [
            "turns": WindowFixtures.turns(["a", "b"]), "turns_offset": 0, "turns_total": 3,
            "assistant_turns_before_offset": 0, "prefix_hash": "head", "prefix_hash_before_index": "seam"
        ])
        WindowURLProtocol.respond = { request, attempt in
            switch request.url?.lastPathComponent {
            case "list_all_folder_details": return (200, Data("[]".utf8))
            case "get_folder_conversation_turns": return attempt == 1 ? (404, Data()) : (200, page)
            default: return (200, first)
            }
        }
        let model = makeModel()
        await model.load()
        await model.loadEarlierTurns()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.turns.map(\.id), ["c"])
        XCTAssertNotNil(model.earlierTurnsError)
        XCTAssertTrue(model.hasEarlierTurns)
        await model.loadEarlierTurns()
        XCTAssertEqual(model.turns.map(\.id), ["a", "b", "c"])
        XCTAssertNil(model.earlierTurnsError)
        model.teardown()
    }

    @MainActor
    private func makeModel() -> SessionDetailViewModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WindowURLProtocol.self]
        let client = CodegClient(baseURL: URL(string: "https://i3-window.invalid")!, token: "test-only",
                                 session: URLSession(configuration: configuration))
        return SessionDetailViewModel(client: client, conversationID: 42)
    }
}

/// Intercepts only this test host, including the existing shared folder session.
private final class WindowURLProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    private static var handler: ((URLRequest, Int) -> (Int, Data)?)?
    private static var requests: [URLRequest] = []
    private static var pending: [WindowURLProtocol] = []

    static var respond: ((URLRequest, Int) -> (Int, Data)?)? {
        get { lock.lock(); defer { lock.unlock() }; return handler }
        set { lock.lock(); defer { lock.unlock() }; handler = newValue }
    }

    static func reset() {
        lock.lock()
        let unfinished = pending
        pending = []
        handler = nil
        requests = []
        lock.unlock()
        for request in unfinished { request.client?.urlProtocol(request, didFailWithError: URLError(.cancelled)) }
    }

    static func bodies(_ path: String) -> [[String: Int]] {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0.url?.lastPathComponent == path }.compactMap {
            guard let data = $0.httpBody else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Int]
        }
    }

    static func completePending(_ path: String, status: Int, data: Data) {
        lock.lock()
        let matching = pending.filter { $0.request.url?.lastPathComponent == path }
        pending.removeAll { $0.request.url?.lastPathComponent == path }
        lock.unlock()
        for request in matching { request.finish(status: status, data: data) }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "i3-window.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            captured.httpBody = data
        }
        Self.lock.lock()
        Self.requests.append(captured)
        let attempt = Self.requests.filter { $0.url?.lastPathComponent == captured.url?.lastPathComponent }.count
        let response = Self.handler?(captured, attempt)
        if response == nil { Self.pending.append(self) }
        Self.lock.unlock()
        guard let (status, data) = response else { return }
        finish(status: status, data: data)
    }

    private func finish(status: Int, data: Data) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                                                            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.pending.removeAll { $0 === self }
    }
}

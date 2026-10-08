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

    @MainActor
    func testRecoveryAdoptsCountUnchangedContentUpdate() async throws {
        let partial = try recoveryDetail(text: "partial", running: true)
        let finished = try recoveryDetail(text: "complete reply", running: false)
        WindowURLProtocol.respond = { request, attempt in
            switch request.url?.lastPathComponent {
            case "list_all_folder_details": return (200, Data("[]".utf8))
            case "acp_find_connection_for_conversation": return (200, Data("null".utf8))
            default: return (200, attempt == 1 ? partial : finished)
            }
        }
        let model = makeModel()
        await model.load()
        XCTAssertEqual(model.turns.last?.blocks, [.text("complete reply")])
        XCTAssertNil(model.liveTurn)
        XCTAssertFalse(model.isInFlight)
        XCTAssertEqual(WindowURLProtocol.bodies("get_folder_conversation"), [
            ["conversationId": 42, "tailTurns": 60], ["conversationId": 42, "fromIndex": 60]
        ])
        model.teardown()
    }

    @MainActor
    func testRecoveryAdoptsCountIncreasedReply() async throws {
        let partial = try recoveryDetail(text: "partial", running: true)
        let finished = try recoveryDetail(text: "new reply", running: false, extraTurn: true)
        WindowURLProtocol.respond = { request, attempt in
            switch request.url?.lastPathComponent {
            case "list_all_folder_details": return (200, Data("[]".utf8))
            case "acp_find_connection_for_conversation": return (200, Data("null".utf8))
            default: return (200, attempt == 1 ? partial : finished)
            }
        }
        let model = makeModel()
        await model.load()
        XCTAssertEqual(model.turns.last?.id, "new")
        XCTAssertEqual(model.turns.last?.blocks, [.text("new reply")])
        XCTAssertNil(model.liveTurn)
        model.teardown()
    }

    @MainActor
    func testRecoveryKeepsRetryingUntilContentChanges() async throws {
        let partial = try recoveryDetail(text: "partial", running: true)
        let unchanged = try recoveryDetail(text: "partial", running: false)
        let finished = try recoveryDetail(text: "complete reply", running: false)
        let retried = expectation(description: "Retry fetch after an unchanged persisted reply")
        WindowURLProtocol.respond = { request, attempt in
            switch request.url?.lastPathComponent {
            case "list_all_folder_details": return (200, Data("[]".utf8))
            case "acp_find_connection_for_conversation": return (200, Data("null".utf8))
            default:
                if attempt == 3 { retried.fulfill() }
                return (200, attempt == 1 ? partial : (attempt == 2 ? unchanged : finished))
            }
        }
        let model = makeModel()
        model.screenDidAppear()
        await model.load()
        XCTAssertTrue(model.isReconnecting)
        XCTAssertNotNil(model.liveTurn)
        XCTAssertEqual(model.turns.last?.blocks, [.text("partial")])
        await fulfillment(of: [retried], timeout: 3)
        // HTTP delivery precedes the model's main-actor continuation.
        for _ in 0..<100 where model.liveTurn != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.turns.last?.blocks, [.text("complete reply")])
        XCTAssertNil(model.liveTurn)
        model.teardown()
    }

    private func recoveryDetail(text: String, running: Bool, extraTurn: Bool = false) throws -> Data {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with:
            WindowFixtures.detail(ids: extraTurn ? ["reply", "new"] : ["reply"],
                                  offset: 60, total: extraTurn ? 62 : 61, hash: "seam")) as? [String: Any])
        var summary = try XCTUnwrap(json["summary"] as? [String: Any])
        summary["status"] = running ? "in_progress" : "completed"
        json["summary"] = summary
        var turns = try XCTUnwrap(json["turns"] as? [[String: Any]])
        turns[turns.count - 1]["role"] = "assistant"
        turns[turns.count - 1]["blocks"] = [["type": "text", "text": text]]
        json["turns"] = turns
        return try JSONSerialization.data(withJSONObject: json)
    }

    @MainActor
    func testRelayOfflineMessageCoexistsWithContinuingRecovery() async throws {
        let partial = try recoveryDetail(text: "partial", running: true)
        let retried = expectation(description: "Discovery retries while relay is offline")
        WindowURLProtocol.respond = { request, attempt in
            switch request.url?.lastPathComponent {
            case "list_all_folder_details": return (200, Data("[]".utf8))
            case "acp_find_connection_for_conversation":
                if attempt == 2 { retried.fulfill() }
                return (503, Data(#"{"code":"relay_agent_offline","message":"offline"}"#.utf8))
            default: return (200, partial)
            }
        }
        let model = makeModel()
        model.screenDidAppear()
        await model.load()
        XCTAssertEqual(model.recoveryMessage, APIError.relayAgentOffline("offline").errorDescription)
        XCTAssertTrue(model.isReconnecting)
        XCTAssertTrue(model.isInFlight)
        await fulfillment(of: [retried], timeout: 3)
        model.teardown()
    }

    @MainActor
    func testCancelledDiscoveryDoesNotShowRecoveryError() async throws {
        let partial = try recoveryDetail(text: "partial", running: true)
        WindowURLProtocol.respond = { request, _ in
            switch request.url?.lastPathComponent {
            case "list_all_folder_details": return (200, Data("[]".utf8))
            case "acp_find_connection_for_conversation": return nil
            default: return (200, partial)
            }
        }
        let model = makeModel()
        let task = Task { await model.load() }
        for _ in 0..<100 where model.liveTurn == nil { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        await task.value
        XCTAssertNil(model.recoveryMessage)
        XCTAssertNil(model.notice)
        model.teardown()
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

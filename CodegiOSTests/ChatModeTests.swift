import XCTest
@testable import Codeg

final class ChatModeTests: XCTestCase {
    override func tearDown() {
        ChatHTTPFixture.respond = nil
        super.tearDown()
    }

    private func client(_ respond: @escaping (URLRequest) throws -> (Int, String)) -> CodegClient {
        ChatHTTPFixture.respond = respond
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChatHTTPFixture.self]
        return CodegClient(baseURL: URL(string: "https://f6.invalid")!, token: "fixture",
                           session: URLSession(configuration: config))
    }

    func testChatRequestKeysAndSnakeCaseResponse() async throws {
        let api = client { request in
            let body = ChatHTTPFixture.body(request)
            switch request.url?.lastPathComponent {
            case "create_chat_dir":
                XCTAssertTrue(body.isEmpty)
                return (200, #"{"path":"/scratch/chat"}"#)
            case "create_chat_conversation":
                XCTAssertEqual(Set(body.keys), ["agentType", "title", "existingDir"])
                XCTAssertEqual(body["agentType"] as? String, "custom:e2e-mock")
                XCTAssertEqual(body["existingDir"] as? String, "/scratch/chat")
                XCTAssertEqual(body["title"] as? String, "Hello")
                return (200, Self.created)
            default: throw URLError(.badURL)
            }
        }
        let dir = try await api.createChatDirectory()
        let result = try await api.createChatConversation(agentType: .custom("custom:e2e-mock"), title: "Hello", existingDir: dir)
        XCTAssertEqual(result.conversationId, 42)
        XCTAssertEqual(result.folderId, 7)
        XCTAssertEqual(result.folder.kind, .chat)
        XCTAssertEqual(result.folder.path, dir)
    }

    func testNilChatRequestValuesEncodeAsNullLikeWeb() throws {
        let data = try JSONEncoder().encode(CreateChatConversationBody(agentType: .unknown("future"), title: nil, existingDir: nil))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["agentType", "title", "existingDir"])
        XCTAssertTrue(json["title"] is NSNull)
        XCTAssertTrue(json["existingDir"] is NSNull)
        XCTAssertEqual(json["agentType"] as? String, "future")
    }

    @MainActor
    func testEagerDirectoryAndConcurrentCreationAreReused() async throws {
        var dirs = 0
        var creates = 0
        let api = client { request in
            switch request.url?.lastPathComponent {
            case "create_chat_dir": dirs += 1; return (200, #"{"path":"/scratch/chat"}"#)
            case "create_chat_conversation": creates += 1; return (200, Self.created)
            default: throw URLError(.badURL)
            }
        }
        let draft = ChatDraftSession(client: api)
        let eager = try await draft.prepareDirectory()
        async let first = draft.createConversation(agent: .custom("custom:e2e-mock"), title: "Hello")
        async let second = draft.createConversation(agent: .custom("custom:e2e-mock"), title: "Hello")
        let results = try await [first, second]
        let retry = try await draft.createConversation(agent: .custom("custom:e2e-mock"), title: "Hello")
        XCTAssertEqual(results.map(\.conversationId), [42, 42])
        XCTAssertEqual(retry.folder.path, eager)
        XCTAssertEqual(dirs, 1)
        XCTAssertEqual(creates, 1)
    }

    @MainActor
    func testLostCreationResponseReconcilesSameDirectoryBeforeRetry() async throws {
        var creates = 0
        let api = client { request in
            switch request.url?.lastPathComponent {
            case "create_chat_dir": return (200, #"{"path":"/scratch/chat"}"#)
            case "create_chat_conversation": creates += 1; throw URLError(.networkConnectionLost)
            case "list_all_folder_details": return (200, "[\(Self.folder)]")
            case "list_all_conversations":
                XCTAssertEqual(ChatHTTPFixture.body(request)["folderIds"] as? [Int], [7])
                return (200, "[\(Self.summary)]")
            default: throw URLError(.badURL)
            }
        }
        let draft = ChatDraftSession(client: api)
        _ = try? await draft.createConversation(agent: .custom("custom:e2e-mock"), title: "Hello")
        let recovered = try await draft.createConversation(agent: .custom("custom:e2e-mock"), title: "Hello")
        XCTAssertEqual(recovered.conversationId, 42)
        XCTAssertEqual(recovered.folder.path, "/scratch/chat")
        XCTAssertEqual(creates, 1)
    }

    @MainActor
    func testMissingEndpointsDisableChatButNetworkFailuresDoNot() async throws {
        for code in [404, 501, 503] {
            let api = client { _ in (code, #"{"message":"unavailable"}"#) }
            let draft = ChatDraftSession(client: api)
            _ = try? await draft.prepareDirectory()
            XCTAssertEqual(draft.isAvailable, code == 503)
        }
    }

    @MainActor
    func testZeroFoldersDefaultsToChatAndFailedSendDoesNotRecreate() async throws {
        var creates = 0
        var dirs = 0
        var connects = 0
        let api = client { request in
            switch request.url?.lastPathComponent {
            case "list_open_folder_details", "list_all_folder_details": return (200, "[]")
            case "acp_list_agents": return (200, Self.agents)
            case "create_chat_dir": dirs += 1; return (200, #"{"path":"/scratch/chat"}"#)
            case "create_chat_conversation": creates += 1; return (200, Self.created)
            case "get_folder_conversation": return (200, "{\"summary\":\(Self.summary),\"turns\":[]}")
            case "acp_find_connection_for_conversation": return (200, "null")
            case "acp_connect":
                connects += 1
                XCTAssertEqual(ChatHTTPFixture.body(request)["workingDir"] as? String, "/scratch/chat")
                return (400, #"{"message":"synthetic connection failure"}"#)
            case "delete_conversation": XCTFail("Chat must survive a rejected first send"); return (200, "null")
            default: return (200, "null")
            }
        }
        let model = SessionDetailViewModel(client: api, newSession: NewSessionRequest())
        defer { model.teardown() }
        await model.load()
        XCTAssertTrue(model.isChatMode)
        XCTAssertEqual(model.workingDirectory, "/scratch/chat")
        XCTAssertFalse(model.showsRepositoryControls)
        model.draft = "Hello\nNext line"
        model.send()
        model.send()
        for _ in 0..<200 where model.isInFlight { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.conversationID, 42)
        XCTAssertEqual(model.draft, "Hello\nNext line")
        model.send()
        for _ in 0..<200 where model.isInFlight { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.conversationID, 42)
        XCTAssertEqual(creates, 1)
        XCTAssertEqual(dirs, 1)
        XCTAssertEqual(connects, 2)
    }

    @MainActor
    func testChatGroupingSurvivesHiddenAndUnavailableFolders() async throws {
        let api = client { request in
            switch request.url?.lastPathComponent {
            case "list_all_folder_details", "list_open_folder_details": return (200, "[]")
            case "list_all_conversations": return (200, "[\(Self.summary)]")
            default: return (200, "null")
            }
        }
        let list = SessionListViewModel(client: api)
        await list.load()
        XCTAssertEqual(list.chats(searchText: "").map(\.id), [42])
        XCTAssertEqual(list.chats(searchText: "Hello").count, 1)
        XCTAssertTrue(list.chats(searchText: "absent").isEmpty)
        XCTAssertTrue(list.ungrouped(searchText: "").isEmpty)
        await list.setPinned(try XCTUnwrap(list.conversations.first), pinned: true)
        XCTAssertEqual(list.pinned(searchText: "").map(\.id), [42])
        XCTAssertTrue(list.chats(searchText: "").isEmpty)
    }

    func testChatFolderExcludedFromProjectPicker() throws {
        let folder = try CodegJSON.decoder.decode(FolderDetail.self, from: Data(Self.folder.utf8))
        XCTAssertTrue(FolderVisibility.filterTopLevel([folder]).isEmpty)
    }

    @MainActor
    func testCancelDuringCreationStillBindsTheRowWithoutSendingPrompt() async throws {
        let creating = expectation(description: "Server is creating the chat")
        let releaseResponse = DispatchSemaphore(value: 0)
        var creates = 0
        var connects = 0
        let api = client { request in
            switch request.url?.lastPathComponent {
            case "list_open_folder_details", "list_all_folder_details": return (200, "[]")
            case "acp_list_agents": return (200, Self.agents)
            case "create_chat_dir": return (200, #"{"path":"/scratch/chat"}"#)
            case "create_chat_conversation":
                creates += 1
                creating.fulfill()
                guard releaseResponse.wait(timeout: .now() + 3) == .success else { throw URLError(.timedOut) }
                return (200, Self.created)
            case "get_folder_conversation": return (200, "{\"summary\":\(Self.summary),\"turns\":[]}")
            case "acp_connect": connects += 1; return (400, #"{"message":"fixture"}"#)
            default: return (200, "null")
            }
        }
        let model = SessionDetailViewModel(client: api, newSession: NewSessionRequest(isChat: true))
        defer { model.teardown() }
        await model.load()
        model.draft = "Cancel me"
        model.send()
        await fulfillment(of: [creating], timeout: 2)
        model.cancel()
        releaseResponse.signal()
        for _ in 0..<200 where model.conversationID == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.conversationID, 42)
        XCTAssertFalse(model.isInFlight)
        XCTAssertEqual(connects, 0)
        model.draft = "Retry"
        model.send()
        for _ in 0..<200 where model.isInFlight { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.conversationID, 42)
        XCTAssertEqual(creates, 1)
    }

    @MainActor
    func testOptionsConnectionUsesPreparedDirectoryAndIsReused() async throws {
        var connects = 0
        let api = client { request in
            switch request.url?.lastPathComponent {
            case "list_open_folder_details", "list_all_folder_details": return (200, "[]")
            case "acp_list_agents": return (200, Self.agents)
            case "create_chat_dir": return (200, #"{"path":"/scratch/chat"}"#)
            case "acp_connect":
                connects += 1
                XCTAssertEqual(ChatHTTPFixture.body(request)["workingDir"] as? String, "/scratch/chat")
                return (200, #""mock-connection""#)
            default: return (200, "null")
            }
        }
        let model = SessionDetailViewModel(client: api, newSession: NewSessionRequest(isChat: true))
        defer { model.teardown() }
        await model.load()
        let first = try await model.resolveConnectionForOptions()
        let second = try await model.resolveConnectionForOptions()
        XCTAssertEqual(first, "mock-connection")
        XCTAssertEqual(second, first)
        XCTAssertEqual(connects, 1)
        XCTAssertNil(model.conversationID)
    }

    @MainActor
    func testCreationEndpointUnavailableDisablesAllDraftsForThisServer() async throws {
        for status in [404, 501] {
            let api = client { request in
                request.url?.lastPathComponent == "create_chat_dir"
                    ? (200, #"{"path":"/scratch/chat"}"#) : (status, #"{"message":"unsupported"}"#)
            }
            let draft = ChatDraftSession(client: api)
            _ = try? await draft.createConversation(agent: .custom("custom:e2e-mock"), title: nil)
            XCTAssertFalse(draft.isAvailable)
            XCTAssertFalse(ChatDraftSession(client: api).isAvailable)
            XCTAssertFalse(draft.hasUnresolvedCreation)
        }
    }

    static let folder = ##"{"id":7,"name":"Chat","path":"/scratch/chat","kind":"chat","last_opened_at":"2026-10-09T00:00:00Z","sort_order":0,"color":"#000000"}"##
    static let summary = #"{"id":42,"folder_id":7,"title":"Hello","kind":"chat","agent_type":"custom:e2e-mock","status":"pending_review","message_count":0,"created_at":"2026-10-09T00:00:00Z","updated_at":"2026-10-09T00:00:00Z"}"#
    static var created: String { "{\"conversation_id\":42,\"folder_id\":7,\"folder\":\(folder)}" }
    static let agents = #"[{"agent_type":"custom:e2e-mock","name":"E2E scripted mock","description":"Fixture","enabled":true,"available":true,"sort_order":0}]"#
}

private final class ChatHTTPFixture: URLProtocol {
    static var respond: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "f6.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, json) = try Self.respond!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(json.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func body(_ request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 2048)
            while stream.hasBytesAvailable {
                let n = stream.read(&bytes, maxLength: bytes.count)
                if n <= 0 { break }
                data.append(contentsOf: bytes.prefix(n))
            }
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

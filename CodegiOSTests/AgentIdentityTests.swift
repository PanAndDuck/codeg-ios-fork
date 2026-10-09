import XCTest
@testable import Codeg

final class AgentIdentityTests: XCTestCase {
    func testKnownTypesKeepTheirWireValuesAndIdentity() throws {
        let cases: [(String, AgentType)] = [
            ("claude_code", .claudeCode), ("codex", .codex), ("open_code", .openCode),
            ("gemini", .gemini), ("open_claw", .openClaw), ("cline", .cline),
            ("hermes", .hermes), ("code_buddy", .codeBuddy), ("kimi_code", .kimiCode),
            ("pi", .pi), ("grok", .grok), ("cursor", .cursor),
        ]
        XCTAssertEqual(AgentType.allCases, cases.map(\.1))
        for (raw, expected) in cases {
            XCTAssertEqual(try roundTrip(raw), expected)
        }
    }

    func testCustomAndFutureTypesRoundTripWithoutBecomingClaude() throws {
        for raw in ["custom:foo", "custom:e2e-mock", "future_agent_v2", "deepseek"] {
            let agent = try roundTrip(raw)
            XCTAssertNotEqual(agent, .claudeCode)
            XCTAssertEqual(agent.id, raw)
        }
    }

    func testCustomAgentsRemainDistinctInFiltersAndRequestBodies() throws {
        let agents = try ["claude_code", "custom:foo", "custom:bar", "future_agent_v2"].map {
            try CodegJSON.decoder.decode(AgentType.self, from: Data("\"\($0)\"".utf8))
        }
        XCTAssertEqual(Set(agents).count, 4)
        XCTAssertEqual(agents.filter { $0 == .claudeCode }.count, 1)
        let body = CreateConversationBody(folderId: 7, agentType: agents[1], title: nil)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: CodegJSON.encoder.encode(body)) as? [String: Any])
        XCTAssertEqual(json["agentType"] as? String, "custom:foo")
    }

    func testCustomAndUnknownNamesComeFromTheirOwnServerCatalog() throws {
        let custom = try AgentIdentityFixtures.agent()
        let future = try AgentIdentityFixtures.agent(raw: "future_agent_v2", name: "Future helper")
        let catalog = AgentDisplayNames(agents: [custom, future, custom,
            try AgentIdentityFixtures.agent(raw: "claude_code", name: "Server alias")])
        XCTAssertEqual(catalog.name(for: custom.agentType, abbreviated: true), "E2E scripted mock")
        XCTAssertEqual(catalog.name(for: future.agentType), "Future helper")
        XCTAssertEqual(catalog.name(for: .claudeCode), "Claude Code")
        XCTAssertEqual(catalog.name(for: .claudeCode, abbreviated: true), "Claude")
        let otherServer = AgentDisplayNames(agents: [
            try AgentIdentityFixtures.agent(name: "Another server's agent")])
        XCTAssertEqual(otherServer.name(for: custom.agentType), "Another server's agent")
        XCTAssertEqual(catalog.name(for: custom.agentType), "E2E scripted mock")
        XCTAssertEqual(AgentDisplayNames().name(for: custom.agentType), "e2e-mock")
        XCTAssertEqual(AgentDisplayNames().name(for: future.agentType), "future_agent_v2")
    }

    func testConnectionSettingsAndReorderRequestsPreserveWireIdentity() throws {
        for raw in ["custom:foo", "future_agent_v2", "claude_code"] {
            let agent = try roundTrip(raw)
            XCTAssertEqual(try json(ConnectBody(agentType: agent))["agentType"] as? String, raw)
            XCTAssertEqual(try json(FindConnectionBody(conversationId: 7, agentType: agent))["agentType"] as? String, raw)
            XCTAssertEqual(try json(AgentSkillsListBody(agentType: agent))["agentType"] as? String, raw)
            XCTAssertEqual(try json(AgentInstallBody(agentType: agent, taskId: "test"))["agentType"] as? String, raw)
        }
        let order = ReorderAgentsBody(agentTypes: [.custom("custom:foo"), .unknown("future_agent_v2"), .codex])
        XCTAssertEqual(try json(order)["agentTypes"] as? [String], ["custom:foo", "future_agent_v2", "codex"])
    }

    func testCustomAndUnknownUseGenericMarksAndLosslessRawInitializer() throws {
        for raw in ["custom:foo", "future_agent_v2"] {
            let agent = AgentType(rawValue: raw)
            XCTAssertEqual(agent.rawValue, raw)
            XCTAssertFalse(agent.isBuiltIn)
            XCTAssertNil(agent.iconAsset)
            XCTAssertEqual(agent.symbolName, "questionmark.circle")
        }
        XCTAssertEqual(AgentType(rawValue: "custom:foo"), .custom("custom:foo"))
        XCTAssertEqual(AgentType(rawValue: "future_agent_v2"), .unknown("future_agent_v2"))
        for agent in AgentType.allCases {
            XCTAssertTrue(agent.isBuiltIn)
            XCTAssertNotNil(agent.iconAsset)
        }
    }

    func testDelegationCardsKeepCustomAndFutureTypesButMissingIdentityStaysNil() {
        for raw in ["custom:foo", "future_agent_v2", "claude_code"] {
            XCTAssertEqual(DelegationModel.parseInput("{\"agent_type\":\"\(raw)\"}").agentType?.rawValue, raw)
        }
        XCTAssertNil(DelegationModel.parseInput("{}").agentType)
        XCTAssertNil(DelegationModel.parseInput("{\"agent_type\":\"\"}").agentType)
        XCTAssertNil(DelegationModel.parseInput("{\"agent_type\":17}").agentType)
    }

    @MainActor
    func testMentionUsesAPINameAndExactDesktopURI() throws {
        let model = makeModel()
        for raw in ["custom:e2e-mock", "future_agent_v2", "claude_code", "codex"] {
            let agent = try AgentIdentityFixtures.agent(raw: raw)
            let result = model.draftInsertingAgentMention(agent, to: "@E2E")
            XCTAssertEqual(result.draft, "[@E2E scripted mock](codeg://agent/\(raw)) ")
            XCTAssertEqual(result.cursorUTF16Offset, result.draft.utf16.count)
        }
    }

    @MainActor
    func testCursorInsertionAtStartMiddleAndEndPreservesSurroundingText() throws {
        let model = makeModel()
        let agent = try AgentIdentityFixtures.agent()
        let badge = "[@E2E scripted mock](codeg://agent/custom:e2e-mock) "
        let cases = [
            ("@E2E", " AFTER", ""),
            ("BEFORE  @E2E", "AFTER", "BEFORE  "),
            ("BEFORE @E2E", "", "BEFORE "),
            ("👩🏽‍💻 中文 @E2E", " 后文", "👩🏽‍💻 中文 "),
        ]
        for (prefix, suffix, expectedHead) in cases {
            let draft = prefix + suffix
            let cursor = String.Index(utf16Offset: prefix.utf16.count, in: draft)
            XCTAssertEqual(model.trailingMentionToken(in: draft, upTo: cursor)?.token, "E2E")
            let result = model.draftInsertingAgentMention(agent, to: draft, cursor: cursor)
            XCTAssertEqual(result.draft, expectedHead + badge + suffix)
            XCTAssertEqual(result.cursorUTF16Offset, (expectedHead + badge).utf16.count)
            var typed = result.draft
            typed.insert(contentsOf: "CURSOR ", at: String.Index(utf16Offset: result.cursorUTF16Offset, in: typed))
            XCTAssertEqual(typed, expectedHead + badge + "CURSOR " + suffix)
        }
    }

    @MainActor
    func testInsertionWithoutLiveTokenUsesActualCaret() throws {
        let model = makeModel()
        let draft = "BEFORE AFTER"
        let cursor = draft.index(draft.startIndex, offsetBy: 7)
        let result = model.draftInsertingAgentMention(try AgentIdentityFixtures.agent(), to: draft, cursor: cursor)
        XCTAssertEqual(result.draft, "BEFORE [@E2E scripted mock](codeg://agent/custom:e2e-mock) AFTER")
        XCTAssertEqual(result.cursorUTF16Offset, result.draft.utf16.count - "AFTER".utf16.count)
    }

    @MainActor
    func testMentionPickerKeepsCustomNamesAndExcludesDisabledOrUnavailableAgents() async throws {
        let model = makeModel()
        let loaded = expectation(description: "Agent catalog returned")
        model.loadAgentsAction = {
            defer { loaded.fulfill() }
            return try [
                AgentIdentityFixtures.agent(),
                AgentIdentityFixtures.agent(raw: "future_agent_v2", name: "Future helper"),
                AgentIdentityFixtures.agent(raw: "custom:disabled", enabled: false),
                AgentIdentityFixtures.agent(raw: "custom:missing", available: false),
            ]
        }
        model.loadAgentsIfNeeded()
        await fulfillment(of: [loaded], timeout: 2)
        XCTAssertEqual(model.matchingAgents(for: "e2e").map(\.agentType.rawValue), ["custom:e2e-mock"])
        XCTAssertEqual(model.matchingAgents(for: "future").map(\.name), ["Future helper"])
        XCTAssertEqual(model.matchingAgents(for: "").count, 2)
        model.teardown()
    }

    private func roundTrip(_ raw: String) throws -> AgentType {
        let data = try JSONEncoder().encode(raw)
        let agent = try CodegJSON.decoder.decode(AgentType.self, from: data)
        XCTAssertEqual(agent.rawValue, raw)
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: CodegJSON.encoder.encode(agent)), raw)
        return agent
    }

    private func json<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: CodegJSON.encoder.encode(value)) as? [String: Any])
    }

    @MainActor
    private func makeModel() -> ComposeInsertModel {
        ComposeInsertModel(client: CodegClient(baseURL: URL(string: "http://127.0.0.1:18482")!, token: "f2-test"))
    }
}

enum AgentIdentityFixtures {
    static func agent(raw: String = "custom:e2e-mock", name: String = "E2E scripted mock",
                      enabled: Bool = true, available: Bool = true) throws -> AcpAgentInfo {
        let payload: [String: Any] = [
            "agent_type": raw, "registry_id": raw.hasPrefix("custom:") ? String(raw.dropFirst(7)) : raw, "name": name,
            "description": "Local deterministic test agent; no LLM/network calls",
            "enabled": enabled, "available": available, "sort_order": 0,
        ]
        return try CodegJSON.decoder.decode(AcpAgentInfo.self, from: JSONSerialization.data(withJSONObject: payload))
    }
}

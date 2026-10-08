import XCTest
@testable import Codeg

final class ConversationWindowTests: XCTestCase {
    func testWindowRequestKeysAreCamelCaseAndSelectorsAreExclusive() throws {
        XCTAssertEqual(try json(ConversationDetailBody(conversationId: 42, window: .tail(60))),
                       ["conversationId": 42, "tailTurns": 60])
        XCTAssertEqual(try json(ConversationDetailBody(conversationId: 42, window: .fromIndex(120))),
                       ["conversationId": 42, "fromIndex": 120])
        XCTAssertEqual(try json(ConversationTurnsBody(conversationId: 42, beforeIndex: 120, limit: 60)),
                       ["conversationId": 42, "beforeIndex": 120, "limit": 60])
    }

    func testDecodeWindowAndLegacyFullHistory() throws {
        let window = try detail(ids: ["a", "b"], offset: 60, total: 62, hash: "prefix")
        XCTAssertEqual(window.turnsOffset, 60)
        XCTAssertEqual(window.turnsTotal, 62)
        XCTAssertEqual(window.assistantTurnsBeforeOffset, 30)
        XCTAssertEqual(window.prefixHash, "prefix")
        XCTAssertTrue(window.hasEarlierTurns)
        let legacy = try detail(ids: ["a", "b"])
        XCTAssertNil(legacy.turnsOffset)
        XCTAssertEqual(legacy.loadedTurnsOffset, 0)
        XCTAssertEqual(legacy.totalTurns, 2)
        XCTAssertFalse(legacy.hasEarlierTurns)
    }

    func testPrependAlignedPageDeduplicatesAndPreservesCurrentTail() throws {
        let current = try detail(ids: ["c", "d"], offset: 3, total: 5, hash: "seam")
        // Round alignment can return more than the requested limit. Duplicate
        // ids at the boundary must keep the newer, live-correlated current turn.
        let page = try older(ids: ["a", "b", "c"], offset: 0, total: 4, hash: "head", seam: "seam")
        let merged = try XCTUnwrap(TurnWindowMerger.prepending(page, to: current))
        XCTAssertEqual(merged.turns.map(\.id), ["a", "b", "c", "d"])
        XCTAssertEqual(merged.turnsOffset, 0)
        XCTAssertEqual(merged.turnsTotal, 5)
        XCTAssertEqual(merged.prefixHash, "head")
        XCTAssertFalse(merged.hasEarlierTurns)
    }

    func testRefreshReplacesOverlapAndAcceptsTruncatedLoadedTail() throws {
        let current = try detail(ids: ["a", "b", "c"], offset: 60, total: 63, hash: "seam")
        let update = try detail(ids: ["a", "replacement", "new"], offset: 60, total: 63, hash: "seam")
        let merged = try XCTUnwrap(TurnWindowMerger.refreshing(update, current: current))
        XCTAssertEqual(merged.turns.map(\.id), ["a", "replacement", "new"])
        let shortened = try detail(ids: ["a"], offset: 60, total: 61, hash: "seam")
        XCTAssertEqual(TurnWindowMerger.refreshing(shortened, current: current)?.turns.count, 1)
    }

    func testPrefixMismatchAndShiftedOffsetRequireFreshTail() throws {
        let current = try detail(ids: ["a"], offset: 60, total: 61, hash: "seam")
        let compacted = try detail(ids: ["b"], offset: 60, total: 61, hash: "changed")
        XCTAssertNil(TurnWindowMerger.refreshing(compacted, current: current))
        let shifted = try detail(ids: ["b"], offset: 20, total: 21, hash: "seam")
        XCTAssertNil(TurnWindowMerger.refreshing(shifted, current: current))
        let page = try older(ids: ["old"], offset: 59, total: 61, hash: "before", seam: "changed")
        XCTAssertNil(TurnWindowMerger.prepending(page, to: current))
    }

    func testRejectsPageGapOrEmptyPageWithoutProgress() throws {
        let current = try detail(ids: ["a"], offset: 60, total: 61, hash: "seam")
        XCTAssertNil(TurnWindowMerger.prepending(
            try older(ids: ["old"], offset: 50, total: 61, hash: "before", seam: "seam"), to: current))
        XCTAssertNil(TurnWindowMerger.prepending(
            try older(ids: [], offset: 60, total: 61, hash: "seam", seam: "seam"), to: current))
    }

    func testLegacyFullResponseReplacesWindowAndDisablesPaging() throws {
        let current = try detail(ids: ["c"], offset: 2, total: 3, hash: "seam")
        let full = try detail(ids: ["a", "b", "c", "d"])
        let merged = try XCTUnwrap(TurnWindowMerger.refreshing(full, current: current))
        XCTAssertEqual(merged.turns.map(\.id), ["a", "b", "c", "d"])
        XCTAssertFalse(merged.hasEarlierTurns)
    }

    private func json<T: Encodable>(_ value: T) throws -> [String: Int] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: CodegJSON.encoder.encode(value)) as? [String: Int])
    }

    private func detail(ids: [String], offset: Int? = nil, total: Int? = nil, hash: String? = nil) throws -> ConversationDetail {
        try CodegJSON.decoder.decode(ConversationDetail.self, from: WindowFixtures.detail(ids: ids, offset: offset, total: total, hash: hash))
    }

    private func older(ids: [String], offset: Int, total: Int, hash: String, seam: String) throws -> ConversationTurnsPage {
        let object: [String: Any] = ["turns": WindowFixtures.turns(ids), "turns_offset": offset,
                                   "turns_total": total, "assistant_turns_before_offset": 0,
                                   "prefix_hash": hash, "prefix_hash_before_index": seam]
        return try CodegJSON.decoder.decode(ConversationTurnsPage.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

enum WindowFixtures {
    static func turns(_ ids: [String]) -> [[String: Any]] {
        ids.map { ["id": $0, "role": "user", "blocks": [["type": "text", "text": $0]],
                   "timestamp": "2026-10-09T00:00:00Z"] }
    }

    static func detail(ids: [String], offset: Int? = nil, total: Int? = nil, hash: String? = nil) throws -> Data {
        var object: [String: Any] = [
            "summary": ["id": 42, "folder_id": 7, "title": "Window test", "agent_type": "claude-code",
                        "status": "completed", "message_count": total ?? ids.count,
                        "created_at": "2026-10-09T00:00:00Z", "updated_at": "2026-10-09T00:00:00Z"],
            "turns": turns(ids)
        ]
        if let offset, let total, let hash {
            object["turns_offset"] = offset
            object["turns_total"] = total
            object["prefix_hash"] = hash
            object["assistant_turns_before_offset"] = 30
        }
        return try JSONSerialization.data(withJSONObject: object)
    }
}

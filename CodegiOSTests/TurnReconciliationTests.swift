import XCTest
@testable import Codeg

final class TurnReconciliationTests: XCTestCase {
    private func detail(text: String, id: String = "reply", total: Int = 61,
                        running: Bool = false, inFlight: String? = nil) throws -> ConversationDetail {
        let data = try WindowFixtures.detail(ids: [id], offset: total - 1, total: total, hash: "seam")
        let base = try CodegJSON.decoder.decode(ConversationDetail.self, from: data)
        var summary = base.summary
        summary.status = running ? .inProgress : .completed
        return ConversationDetail(summary: summary,
            turns: [MessageTurn(id: id, role: .assistant, blocks: [.text(text)], timestamp: .distantPast)],
            sessionStats: nil, inFlightUserTurnId: inFlight,
            turnsOffset: total - 1, turnsTotal: total, prefixHash: "seam")
    }

    func testSameCountUpdatedContentIsAdopted() throws {
        let partial = try detail(text: "partial")
        let baseline = TurnReconciliation(totalTurns: partial.totalTurns, turns: partial.turns)
        XCTAssertTrue(baseline.canAdopt(try detail(text: "final"), preservingReply: true))
    }

    func testTotalGrowthDoesNotDependOnLoadedWindowLength() throws {
        let partial = try detail(text: "previous")
        let baseline = TurnReconciliation(totalTurns: partial.totalTurns, turns: partial.turns)
        XCTAssertTrue(baseline.canAdopt(try detail(text: "final", id: "new", total: 63), preservingReply: true))
    }

    func testSameCountNewAssistantIdentityIsAdopted() throws {
        let partial = try detail(text: "same text")
        let baseline = TurnReconciliation(totalTurns: partial.totalTurns, turns: partial.turns)
        XCTAssertTrue(baseline.canAdopt(try detail(text: "same text", id: "replacement"), preservingReply: true))
    }

    func testUnchangedReadRetriesBeforeBoundedIdleFallback() throws {
        let partial = try detail(text: "partial")
        let baseline = TurnReconciliation(totalTurns: partial.totalTurns, turns: partial.turns)
        XCTAssertFalse(baseline.canAdopt(partial, preservingReply: true))
        XCTAssertTrue(baseline.canAdopt(partial, preservingReply: true,
            streamedReply: [.text("partial")], retriesExhausted: true))
        XCTAssertTrue(baseline.canAdopt(partial, preservingReply: false, retriesExhausted: true))
    }

    func testRunningOrInFlightTranscriptCannotFinalizeEvenAfterRetries() throws {
        let partial = try detail(text: "partial")
        let baseline = TurnReconciliation(totalTurns: partial.totalTurns, turns: partial.turns)
        for updated in [try detail(text: "final", running: true), try detail(text: "final", inFlight: "user")] {
            XCTAssertFalse(baseline.canAdopt(updated, preservingReply: true, retriesExhausted: true))
        }
    }

    func testEmptyPersistedPlaceholderDoesNotReplaceStreamedReply() throws {
        let partial = try detail(text: "partial")
        let baseline = TurnReconciliation(totalTurns: partial.totalTurns, turns: partial.turns)
        XCTAssertFalse(baseline.canAdopt(try detail(text: "  ", total: 62), preservingReply: true, retriesExhausted: true))
    }

    func testStalePreviousReplyCannotReplaceNewStreamedContentAfterRetries() throws {
        let previous = try detail(text: "previous reply")
        let baseline = TurnReconciliation(totalTurns: previous.totalTurns, turns: previous.turns)
        XCTAssertFalse(baseline.canAdopt(previous, preservingReply: true, retriesExhausted: true))
        XCTAssertFalse(baseline.canAdopt(previous, preservingReply: true,
            streamedReply: [.text("new reply")], retriesExhausted: true))
    }
}

import XCTest
@testable import Codeg

final class StreamRecoveryTests: XCTestCase {
    private func snapshot(_ fields: String) throws -> LiveSessionSnapshot {
        try CodegJSON.decoder.decode(LiveSessionSnapshot.self, from: Data("{\(fields)}".utf8))
    }

    func testSnapshotOutcomeTruthTable() throws {
        for active in [false, true] {
            XCTAssertEqual(SnapshotOutcome.classify(isTurnActive: active, snapshot: try snapshot("\"status\":\"prompting\"")), .adoptLive)
            XCTAssertEqual(SnapshotOutcome.classify(isTurnActive: active, snapshot: try snapshot("\"status\":\"connected\",\"live_message\":{\"content\":[{\"kind\":\"text\",\"text\":\"reply\"}]}")), .adoptLive)
            for pending in ["\"pending_permission\":{}", "\"pending_question\":{}", "\"pending_plan_approval\":{}"] {
                XCTAssertEqual(SnapshotOutcome.classify(isTurnActive: active, snapshot: try snapshot("\"status\":\"connected\",\(pending)")), .restorePendingOnly)
            }
            for status in ["connected", "disconnected", "error"] {
                XCTAssertEqual(SnapshotOutcome.classify(isTurnActive: active, snapshot: try snapshot("\"status\":\"\(status)\",\"live_message\":null")), active ? .finalize : .ignore)
            }
            XCTAssertEqual(SnapshotOutcome.classify(isTurnActive: active, snapshot: try snapshot("")), .ignore)
        }
    }

    func testSequenceDedupeAndConnectionScope() {
        var tracker = SeqTracker()
        tracker.bind(to: "a")
        XCTAssertNil(tracker.sinceSeq)
        tracker.adoptSnapshot(10)
        XCTAssertFalse(tracker.accept(10))
        XCTAssertFalse(tracker.accept(9))
        XCTAssertTrue(tracker.accept(11))
        tracker.bind(to: "a")
        XCTAssertEqual(tracker.sinceSeq, 11)
        tracker.bind(to: "b")
        XCTAssertNil(tracker.sinceSeq)
        XCTAssertTrue(tracker.accept(1))
    }

    func testReplayIsOrderedAndAppliedOnce() throws {
        let events = try CodegJSON.decoder.decode([EventEnvelope].self, from: Data("""
        [{"seq":13,"connection_id":"a","type":"content_delta","text":"C"},
         {"seq":11,"connection_id":"a","type":"content_delta","text":"A"},
         {"seq":12,"connection_id":"a","type":"content_delta","text":"B"},
         {"seq":12,"connection_id":"a","type":"content_delta","text":"B"},
         {"seq":10,"connection_id":"a","type":"content_delta","text":"old"}]
        """.utf8))
        var tracker = SeqTracker()
        tracker.bind(to: "a")
        tracker.adoptSnapshot(10)
        let applied = tracker.orderedReplay(events)
        XCTAssertEqual(applied.map(\.seq), [11, 12, 13])
        XCTAssertEqual(tracker.sinceSeq, 13)
        XCTAssertTrue(tracker.orderedReplay(events).isEmpty)
        let data = try CodegJSON.encoder.encode(WSClientMessage.attach(subscriptionId: "s", connectionId: "a", sinceSeq: tracker.sinceSeq))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["since_seq"] as? Int, 13)
    }

    func testReconnectScheduleNeverExhaustsAndResets() {
        var schedule = ReconnectSchedule()
        XCTAssertEqual((0..<9).map { _ in schedule.next(unitRandom: 0.5) }, [0.5, 1, 2, 4, 8, 16, 30, 30, 30])
        XCTAssertEqual(schedule.attempt, 9)
        schedule.reset()
        XCTAssertEqual(schedule.attempt, 0)
        XCTAssertEqual(schedule.next(unitRandom: 0.5), 0.5)
    }

    func testReconnectJitterBounds() {
        var low = ReconnectSchedule()
        var high = ReconnectSchedule()
        for base in [0.5, 1, 2, 4, 8, 16, 30, 30] {
            XCTAssertEqual(low.next(unitRandom: 0), base * 0.8, accuracy: 0.0001)
            XCTAssertEqual(high.next(unitRandom: 1), base * 1.2, accuracy: 0.0001)
        }
    }

    func testPromptAcceptanceUsesEvidenceAndNeverTreatsIdleAsRejection() throws {
        let idle = try snapshot("\"status\":\"connected\"")
        let prompting = try snapshot("\"status\":\"prompting\"")
        let matching = try snapshot("\"pending_user_message\":{\"message_id\":\"mine\",\"blocks\":[]}")
        let other = try snapshot("\"pending_user_message\":{\"message_id\":\"other\",\"blocks\":[]}")
        XCTAssertEqual(PromptAcceptance.decide(requestStarted: false, observedTurnEvent: false, clientMessageID: "mine", snapshot: nil, confirmedRejection: false), .rejected)
        XCTAssertEqual(PromptAcceptance.decide(requestStarted: true, observedTurnEvent: true, clientMessageID: "mine", snapshot: idle, confirmedRejection: false), .accepted)
        for snap in [prompting, matching] {
            XCTAssertEqual(PromptAcceptance.decide(requestStarted: true, observedTurnEvent: false, clientMessageID: "mine", snapshot: snap, confirmedRejection: false), .accepted)
        }
        for snap in [nil, idle, other] {
            XCTAssertEqual(PromptAcceptance.decide(requestStarted: true, observedTurnEvent: false, clientMessageID: "mine", snapshot: snap, confirmedRejection: false), .unknown)
        }
        XCTAssertEqual(PromptAcceptance.decide(requestStarted: true, observedTurnEvent: false, clientMessageID: "mine", snapshot: idle, confirmedRejection: true), .rejected)
        // A 409 rejects this request even if another client's turn is prompting.
        XCTAssertEqual(PromptAcceptance.decide(requestStarted: true, observedTurnEvent: false, clientMessageID: "mine", snapshot: prompting, confirmedRejection: true), .rejected)
    }

    func testPromptEchoAndAdmissionStatusAreDistinguished() throws {
        let echoed = try CodegJSON.decoder.decode(AcpEvent.self, from: Data("""
        {"type":"user_message","message_id":"mine","blocks":[{"type":"text","text":"hello"}]}
        """.utf8))
        XCTAssertTrue(PromptAcceptance.isTurnEvidence(echoed, clientMessageID: "mine"))
        XCTAssertFalse(PromptAcceptance.isTurnEvidence(echoed, clientMessageID: "other"))
        XCTAssertFalse(PromptAcceptance.isTurnEvidence(.conversationStatusChanged(conversationId: 1, status: .inProgress), clientMessageID: "mine"))
        XCTAssertFalse(PromptAcceptance.isTurnEvidence(.statusChanged(status: .connected), clientMessageID: "mine"))
        XCTAssertTrue(PromptAcceptance.isTurnEvidence(.turnComplete(stopReason: "end_turn"), clientMessageID: "mine"))
    }

    func testSnapshotWireCursorAndPendingMessage() throws {
        let snap = try snapshot("\"connection_id\":\"c\",\"event_seq\":81,\"pending_user_message\":{\"message_id\":\"mine\",\"blocks\":[{\"type\":\"text\",\"text\":\"hello\"}]}")
        XCTAssertEqual(snap.connectionId, "c")
        XCTAssertEqual(snap.eventSeq, 81)
        XCTAssertEqual(snap.pendingUserMessage?.messageId, "mine")
        XCTAssertEqual(snap.pendingUserMessage?.blocks, [.text("hello")])
    }

    func testPendingUserMessageBeforePromptingIsStillLive() throws {
        let snap = try snapshot("\"status\":\"connected\",\"live_message\":null,\"pending_user_message\":{\"message_id\":\"mine\",\"blocks\":[]}")
        XCTAssertEqual(SnapshotOutcome.classify(isTurnActive: true, snapshot: snap), .adoptLive)
        XCTAssertEqual(SnapshotOutcome.classify(isTurnActive: false, snapshot: snap), .adoptLive)
    }

    func testReplayIgnoresDifferentConnection() throws {
        let events = try CodegJSON.decoder.decode([EventEnvelope].self, from: Data("""
        [{"seq":100,"connection_id":"other","type":"content_delta","text":"wrong"},
         {"seq":2,"connection_id":"mine","type":"content_delta","text":"right"}]
        """.utf8))
        var tracker = SeqTracker()
        tracker.bind(to: "mine")
        tracker.adoptSnapshot(1)
        XCTAssertEqual(tracker.orderedReplay(events).map(\.seq), [2])
        XCTAssertEqual(tracker.sinceSeq, 2)
    }
}

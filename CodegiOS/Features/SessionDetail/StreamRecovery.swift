import Foundation

/// Shared by socket snapshots and the quiet-turn HTTP probe.
enum SnapshotOutcome: Equatable {
    case adoptLive, finalize, restorePendingOnly, ignore

    static func classify(isTurnActive: Bool, snapshot: LiveSessionSnapshot) -> Self {
        if snapshot.status == .prompting || snapshot.pendingUserMessage != nil
            || !(snapshot.liveMessage?.content.isEmpty ?? true) {
            return .adoptLive
        }
        if snapshot.pendingPermission != nil || snapshot.pendingQuestion != nil || snapshot.pendingPlanApproval != nil {
            return .restorePendingOnly
        }
        // Missing status is not proof of completion on an older/malformed response.
        return isTurnActive && snapshot.status != nil ? .finalize : .ignore
    }
}

/// A cursor belongs to one ACP connection, not to a WebSocket or a UI turn.
struct SeqTracker {
    private var connectionID: String?
    private(set) var lastAppliedSeq: UInt64?
    var sinceSeq: UInt64? { lastAppliedSeq }

    mutating func bind(to connectionID: String) {
        if self.connectionID != connectionID {
            self.connectionID = connectionID
            lastAppliedSeq = nil
        }
    }

    mutating func adoptSnapshot(_ seq: UInt64?) {
        lastAppliedSeq = seq
    }

    mutating func accept(_ seq: UInt64) -> Bool {
        guard lastAppliedSeq.map({ seq > $0 }) ?? true else { return false }
        lastAppliedSeq = seq
        return true
    }

    mutating func orderedReplay(_ events: [EventEnvelope]) -> [EventEnvelope] {
        // ws_attach.rs guarantees a nonempty replay whose high_water_seq equals
        // its maximum envelope.seq. Derive it from the applied events: I1 owns
        // EventStream's frame API, which currently exposes only the array.
        events.sorted { $0.seq < $1.seq }.filter { envelope in
            guard connectionID == nil || envelope.connectionId == connectionID else { return false }
            return accept(envelope.seq)
        }
    }
}

struct ReconnectSchedule {
    private(set) var attempt = 0

    mutating func next(closeReason: String? = nil, unitRandom: Double = Double.random(in: 0...1)) -> TimeInterval {
        let base = min(30, 0.5 * pow(2, Double(min(attempt, 6))))
        attempt += 1
        if closeReason == EventStream.CloseReason.networkChanged { return 0 }
        return base * (0.8 + 0.4 * min(1, max(0, unitRandom)))
    }

    mutating func reset() { attempt = 0 }
}

enum PromptAcceptance: Equatable {
    case accepted, rejected, unknown

    static func isConfirmedRejection(_ error: Error) -> Bool {
        switch error as? APIError {
        case .unauthorized?, .turnInProgress?, .payloadTooLarge?,
             .tooManyAuthFailures?, .relayTooManyConnections?: return true
        case .server(let status, _, _)?: return (400..<500).contains(status)
        default: return false
        }
    }

    static func decide(requestStarted: Bool, observedTurnEvent: Bool, clientMessageID: String,
                       snapshot: LiveSessionSnapshot?, confirmedRejection: Bool) -> Self {
        guard requestStarted else { return .rejected }
        // A definitive HTTP rejection (e.g. 409 for another client's turn) is
        // stronger than generic activity on the shared ACP connection.
        if confirmedRejection { return .rejected }
        if observedTurnEvent || snapshot?.status == .prompting
            || snapshot?.pendingUserMessage?.messageId == clientMessageID {
            return .accepted
        }
        // TurnComplete clears pending_user_message. Idle alone cannot establish
        // rejection, nor can a transport timeout after the request was sent.
        return .unknown
    }

    static func isTurnEvidence(_ event: AcpEvent, clientMessageID: String?) -> Bool {
        switch event {
        case .userMessage(let id, _): return id == clientMessageID
        case .statusChanged(let status): return status == .prompting
        case .contentDelta, .thinking, .toolCall, .toolCallUpdate, .turnComplete,
             .permissionRequest, .questionRequest, .planApprovalRequest, .planUpdate:
            return true
        default:
            // conversation_status_changed(in_progress) precedes admission and
            // may be followed by a failed enqueue. It is not acceptance evidence.
            return false
        }
    }
}

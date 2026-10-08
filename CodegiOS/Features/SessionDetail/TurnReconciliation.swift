import Foundation

/// Captured before sending or discovering a live turn. Paging may change the
/// loaded window length, and persistence may update an existing assistant row.
struct TurnReconciliation {
    let totalTurns: Int
    private let assistant: MessageTurn?

    init(totalTurns: Int, turns: [MessageTurn]) {
        self.totalTurns = totalTurns
        assistant = turns.last(where: { $0.role == .assistant })
    }

    func canAdopt(_ detail: ConversationDetail, preservingReply: Bool,
                  streamedReply: [ContentBlock] = [], retriesExhausted: Bool = false) -> Bool {
        // A persisted partial can grow before completion; neither content nor
        // count growth alone establishes that the turn ended.
        guard detail.inFlightUserTurnId == nil, detail.summary.status != .inProgress else { return false }
        let last = detail.turns.last
        let changed = last?.role == .assistant
            && (last?.id != assistant?.id || last?.blocks != assistant?.blocks)
        // A stale previous reply may stay queryable after the new turn finishes.
        // Exhausting retries must never discard newer content held only locally.
        let safeFallback = retriesExhausted && (!preservingReply
            || (!streamedReply.isEmpty && last?.blocks == streamedReply))
        guard detail.totalTurns > totalTurns || changed || safeFallback else { return false }
        return !preservingReply || Self.hasReply(detail.turns)
    }

    private static func hasReply(_ turns: [MessageTurn]) -> Bool {
        guard let last = turns.last, last.role == .assistant else { return false }
        return last.blocks.contains { block in
            switch block {
            case .text(let text), .thinking(let text):
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .image, .toolUse, .toolResult, .unknown:
                return true
            case .imageGeneration(let prompt, let image):
                return image != nil || !(prompt ?? "").isEmpty
            }
        }
    }
}

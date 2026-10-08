import Foundation

/// Pure window reconciliation. `nil` means the coordinates are no longer safe
/// to join; callers must request a fresh tail instead of stitching transcripts.
enum TurnWindowMerger {
    static func refreshing(_ incoming: ConversationDetail, current: ConversationDetail?) -> ConversationDetail? {
        guard let current, current.isWindowed, incoming.isWindowed else { return incoming }
        guard incoming.turnsOffset == current.turnsOffset,
              incoming.prefixHash == current.prefixHash,
              incoming.totalTurns >= current.loadedTurnsOffset else { return nil }
        // fromIndex covers the entire loaded region, including content backfills
        // and removals. Retaining an old suffix here would resurrect stale turns.
        return incoming
    }

    static func prepending(_ page: ConversationTurnsPage, to current: ConversationDetail) -> ConversationDetail? {
        guard current.isWindowed,
              page.prefixHashBeforeIndex == current.prefixHash,
              page.turnsOffset >= 0,
              page.turnsOffset < current.loadedTurnsOffset,
              page.turnsOffset + page.turns.count == current.loadedTurnsOffset,
              page.turnsTotal >= current.loadedTurnsOffset else { return nil }

        // The currently rendered copy wins if live correlation repeats an id.
        var seen = Set(current.turns.map(\.id))
        var older: [MessageTurn] = []
        older.reserveCapacity(page.turns.count)
        for turn in page.turns where seen.insert(turn.id).inserted { older.append(turn) }
        var merged = current
        merged.turns = older + current.turns
        merged.turnsOffset = page.turnsOffset
        merged.assistantTurnsBeforeOffset = page.assistantTurnsBeforeOffset
        merged.prefixHash = page.prefixHash
        merged.uncoveredPrefixMaxTs = page.uncoveredPrefixMaxTs
        // Keep the current tail's total/stats: the page snapshot may be older.
        return merged
    }
}

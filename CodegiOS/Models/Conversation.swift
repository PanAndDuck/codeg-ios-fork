import SwiftUI

/// A project/workspace on a codeg server (Rust `FolderDetail`). The iOS app
/// treats folders as a filter dimension under a server, and uses `path` as the
/// `workingDir` when (re)connecting an agent.
struct FolderDetail: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let path: String
    let gitBranch: String?
    let defaultAgentType: AgentType?
    let lastOpenedAt: Date
    let sortOrder: Int
    let color: String
    /// Root folder this one was created under (worktree folders only); `nil` for
    /// a top-level folder. Drives the sidebar worktree-child hide and the branch
    /// switcher's root resolution. Decoded from `parent_id`; absent on older
    /// servers → `nil`.
    var parentId: Int?
    /// Server `kind`. `chat` scratch folders are hidden from the folder lists;
    /// `regular` is a user folder. Absent / unknown on older servers → `.regular`.
    var kind: FolderKind

    private enum CodingKeys: String, CodingKey {
        case id, name, path, gitBranch, defaultAgentType, lastOpenedAt, sortOrder, color, parentId, kind
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        gitBranch = try c.decodeIfPresent(String.self, forKey: .gitBranch)
        defaultAgentType = try c.decodeIfPresent(AgentType.self, forKey: .defaultAgentType)
        lastOpenedAt = try c.decode(Date.self, forKey: .lastOpenedAt)
        sortOrder = try c.decode(Int.self, forKey: .sortOrder)
        color = try c.decode(String.self, forKey: .color)
        parentId = try c.decodeIfPresent(Int.self, forKey: .parentId)
        // Tolerate an absent key (older server) and an unknown value (lenient
        // `FolderKind` decode) — neither should fail the whole folder.
        kind = (try? c.decodeIfPresent(FolderKind.self, forKey: .kind)) ?? .regular
    }

    /// Memberwise initializer (preserved for the few call sites that build a
    /// `FolderDetail` directly, e.g. previews/tests).
    init(
        id: Int, name: String, path: String, gitBranch: String?,
        defaultAgentType: AgentType?, lastOpenedAt: Date, sortOrder: Int,
        color: String, parentId: Int? = nil, kind: FolderKind = .regular
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.gitBranch = gitBranch
        self.defaultAgentType = defaultAgentType
        self.lastOpenedAt = lastOpenedAt
        self.sortOrder = sortOrder
        self.color = color
        self.parentId = parentId
        self.kind = kind
    }

    /// True when this folder is a git worktree created under another folder.
    var isWorktree: Bool { parentId != nil }
}

/// Folder classification (Rust `FolderKind`). `chat` folders back chat-mode
/// scratch dirs and are hidden from folder lists; `regular` is a user folder.
/// `.other` is the escape hatch for an unknown wire value.
enum FolderKind: String, Codable, Hashable, Sendable {
    case regular
    case chat
    case other = ""

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = FolderKind(rawValue: raw) ?? .other
    }
}

/// Lifecycle status of a conversation row. Stored as a free-form string on the
/// wire; modeled as an enum with an `.other` escape hatch.
enum ConversationStatus: String, Codable, Hashable, Sendable {
    case inProgress = "in_progress"
    case pendingReview = "pending_review"
    case completed = "completed"
    case cancelled = "cancelled"
    case other = ""

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ConversationStatus(rawValue: raw) ?? .other
    }

    var label: LocalizedStringKey {
        switch self {
        case .inProgress: return "Running"
        case .pendingReview: return "Review"
        case .completed: return "Done"
        case .cancelled: return "Cancelled"
        case .other: return "—"
        }
    }

    var tint: Color {
        switch self {
        case .inProgress: return Color(red: 0.42, green: 0.78, blue: 0.95)
        case .pendingReview: return Theme.warning
        case .completed: return Color(red: 0.52, green: 0.82, blue: 0.56)
        case .cancelled: return Color.secondary
        case .other: return Color.secondary
        }
    }

    var isLive: Bool { self == .inProgress }

    /// The real statuses a user can assign from the actions menu (excludes the
    /// `.other` decode escape hatch), in the order the web client lists them.
    static let selectable: [ConversationStatus] = [.inProgress, .pendingReview, .completed, .cancelled]
}

/// Posted (no payload) whenever a conversation is mutated from the detail
/// screen — renamed, pinned, status-changed, or deleted. The session list is a
/// separate view model with no `onAppear` reload, so it observes this to refetch
/// instead of showing a stale title/status or a still-tappable deleted row.
extension Notification.Name {
    static let conversationsDidChange = Notification.Name("codeg.conversationsDidChange")
    /// Posted (no payload) when the folder set changes outside the normal poll —
    /// e.g. a worktree folder was just registered from the branch switcher. Folder-
    /// backed lists (Folders tab, Chats grouping) observe it to refetch promptly
    /// instead of waiting for the 25s pulse.
    static let foldersDidChange = Notification.Name("codeg.foldersDidChange")
}

/// A conversation/session persisted on a server (Rust `DbConversationSummary`).
struct ConversationSummary: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let folderId: Int
    /// `var` so the detail screen can optimistically reflect a rename before the
    /// server confirms (mirrors `pinnedAt`).
    var title: String?
    let agentType: AgentType
    /// `var` so a status change applies optimistically from the actions menu.
    var status: ConversationStatus
    let model: String?
    let gitBranch: String?
    let externalId: String?
    let messageCount: Int
    let createdAt: Date
    let updatedAt: Date
    /// When the user pinned this conversation (server `pinned_at`), or `nil` when
    /// not pinned. The default makes the key optional during decode, so servers
    /// that predate pinning (no field) decode cleanly to `nil`. A `var` so the
    /// list can optimistically flip it on a pin/unpin before the server confirms.
    /// Note: pinning does NOT bump `updatedAt` server-side — the "Pinned" group
    /// sorts by this timestamp instead.
    var pinnedAt: Date? = nil
    /// Absent on older servers. Kept independently of the optional folder list.
    var kind: String? = nil

    var isChat: Bool { kind == "chat" }

    /// Non-empty, trimmed user-provided title, or `nil` for an unnamed session.
    /// Render this verbatim (user data, never localized) and fall back to a
    /// localized "Untitled session" only when it is `nil`.
    var trimmedTitle: String? {
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return title
    }

    /// Plain-text title for search/filtering (NOT for localized display — use
    /// `trimmedTitle` + a literal fallback at the render site for that).
    var displayTitle: String { trimmedTitle ?? "Untitled session" }

    var isPinned: Bool { pinnedAt != nil }
}

/// Aggregate token/timing stats for a session (Rust `SessionStats`).
struct SessionStats: Codable, Hashable, Sendable {
    let totalUsage: TurnUsage?
    let totalTokens: Int?
    let totalDurationMs: Int
    let contextWindowUsedTokens: Int?
    let contextWindowMaxTokens: Int?
    let contextWindowUsagePercent: Double?
}

/// Session detail with optional windowed history (Rust `DbConversationDetail`).
/// Decode-only: `MessageTurn`/`ContentBlock` are response shapes we never encode.
struct ConversationDetail: Decodable, Sendable {
    let summary: ConversationSummary
    var turns: [MessageTurn]
    let sessionStats: SessionStats?
    let inFlightUserTurnId: String?
    var turnsOffset: Int? = nil
    var turnsTotal: Int? = nil
    var assistantTurnsBeforeOffset: Int? = nil
    var prefixHash: String? = nil
    var uncoveredPrefixMaxTs: Date? = nil
    var transcriptWatermark: UInt64? = nil

    /// Old servers omit the metadata and return the entire transcript.
    var isWindowed: Bool { turnsOffset != nil && turnsTotal != nil && prefixHash != nil }
    var loadedTurnsOffset: Int { isWindowed ? max(0, turnsOffset ?? 0) : 0 }
    var totalTurns: Int { isWindowed ? (turnsTotal ?? turns.count) : turns.count }
    var hasEarlierTurns: Bool { loadedTurnsOffset > 0 }
}

/// The older-page endpoint returns no summary/stats and includes a seam proof.
struct ConversationTurnsPage: Decodable, Sendable {
    let turns: [MessageTurn]
    let turnsOffset: Int
    let turnsTotal: Int
    let assistantTurnsBeforeOffset: Int
    let prefixHash: String
    let prefixHashBeforeIndex: String
    let uncoveredPrefixMaxTs: Date?
}

/// Returned by `acp_find_connection_for_conversation` when a live ACP
/// connection already owns a conversation.
struct ConversationConnectionInfo: Codable, Sendable {
    let connectionId: String
    let eventSeq: UInt64
}

/// `health` endpoint response — used to validate a server profile.
struct HealthResponse: Codable, Sendable {
    let status: String
    let version: String
}

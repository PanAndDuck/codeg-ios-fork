import SwiftUI

/// Agent identity is the server's exact wire token, including `custom:<id>`
/// and types introduced after this client shipped. Never substitute another
/// agent: these values also drive requests, mentions and preference keys.
enum AgentType: RawRepresentable, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case claudeCode, codex, openCode, gemini, openClaw, cline
    case hermes, codeBuddy, kimiCode, pi, grok, cursor
    /// Associated values contain the FULL wire token, including `custom:`.
    case custom(String)
    case unknown(String)

    /// Offline fallback only; custom/unknown choices come from the API catalog.
    static let allCases: [AgentType] = [
        .claudeCode, .codex, .openCode, .gemini, .openClaw, .cline,
        .hermes, .codeBuddy, .kimiCode, .pi, .grok, .cursor,
    ]

    init(rawValue: String) {
        switch rawValue {
        case "claude_code": self = .claudeCode
        case "codex": self = .codex
        case "open_code": self = .openCode
        case "gemini": self = .gemini
        case "open_claw": self = .openClaw
        case "cline": self = .cline
        case "hermes": self = .hermes
        case "code_buddy": self = .codeBuddy
        case "kimi_code": self = .kimiCode
        case "pi": self = .pi
        case "grok": self = .grok
        case "cursor": self = .cursor
        default: self = rawValue.hasPrefix("custom:") ? .custom(rawValue) : .unknown(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .claudeCode: return "claude_code"
        case .codex: return "codex"
        case .openCode: return "open_code"
        case .gemini: return "gemini"
        case .openClaw: return "open_claw"
        case .cline: return "cline"
        case .hermes: return "hermes"
        case .codeBuddy: return "code_buddy"
        case .kimiCode: return "kimi_code"
        case .pi: return "pi"
        case .grok: return "grok"
        case .cursor: return "cursor"
        case .custom(let raw), .unknown(let raw): return raw
        }
    }

    var isBuiltIn: Bool {
        switch self {
        case .custom, .unknown: return false
        default: return true
        }
    }

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self.init(rawValue: raw)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex CLI"
        case .openCode: return "OpenCode"
        case .gemini: return "Gemini CLI"
        case .openClaw: return "OpenClaw"
        case .cline: return "Cline"
        case .hermes: return "Hermes"
        case .codeBuddy: return "CodeBuddy"
        case .kimiCode: return "Kimi Code"
        case .pi: return "Pi"
        case .grok: return "Grok"
        case .cursor: return "Cursor"
        case .custom(let raw):
            let name = String(raw.dropFirst("custom:".count))
            return name.isEmpty ? "Custom agent" : name
        case .unknown(let raw): return raw.isEmpty ? "Unknown agent" : raw
        }
    }

    /// Short label for dense badges.
    var shortName: String {
        switch self {
        case .claudeCode: return "Claude"
        case .codex: return "Codex"
        case .openCode: return "OpenCode"
        case .gemini: return "Gemini"
        case .openClaw: return "OpenClaw"
        case .cline: return "Cline"
        case .hermes: return "Hermes"
        case .codeBuddy: return "CodeBuddy"
        case .kimiCode: return "Kimi"
        case .pi: return "Pi"
        case .grok: return "Grok"
        case .cursor: return "Cursor"
        case .custom, .unknown: return displayName
        }
    }

    /// SF Symbol fallback (used only if the brand asset is ever missing).
    var symbolName: String {
        switch self {
        case .claudeCode: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .openCode: return "curlybraces"
        case .gemini: return "diamond"
        case .openClaw: return "pawprint"
        case .cline: return "terminal"
        case .hermes: return "bolt.horizontal.circle"
        case .codeBuddy: return "hammer"
        case .kimiCode: return "moon.stars"
        case .pi: return "pi"
        case .grok: return "line.diagonal"
        case .cursor: return "cursorarrow"
        case .custom, .unknown: return "questionmark.circle"
        }
    }

    /// Name of the brand-icon image set in `Assets.xcassets` (the per-agent SVGs
    /// ported verbatim from the web client's `agent-icon.tsx`). Rendered by
    /// `AgentIcon`.
    var iconAsset: String? {
        switch self {
        case .claudeCode: return "AgentClaudeCode"
        case .codex: return "AgentCodex"
        case .openCode: return "AgentOpenCode"
        case .gemini: return "AgentGemini"
        case .openClaw: return "AgentOpenClaw"
        case .cline: return "AgentCline"
        case .hermes: return "AgentHermes"
        case .codeBuddy: return "AgentCodeBuddy"
        case .kimiCode: return "AgentKimiCode"
        case .pi: return "AgentPi"
        case .grok: return "AgentGrok"
        case .cursor: return "AgentCursor"
        case .custom, .unknown: return nil
        }
    }

    /// Whether the brand asset is a monochrome (template) glyph that should be
    /// tinted by the caller. Mirrors the web's `MONO_ICONS` set (OpenCode, Cline,
    /// Hermes, CodeBuddy, Grok, Cursor); the others carry their own brand
    /// colors/gradients and render as-is.
    var iconIsTemplate: Bool {
        switch self {
        case .openCode, .cline, .hermes, .codeBuddy, .grok, .cursor, .custom, .unknown: return true
        case .claudeCode, .codex, .gemini, .openClaw, .kimiCode, .pi: return false
        }
    }

    /// Accent color used for badges / avatars per agent.
    var accent: Color {
        switch self {
        case .claudeCode: return Color(red: 0.85, green: 0.52, blue: 0.34) // claude clay
        case .codex: return Color(red: 0.45, green: 0.78, blue: 0.66)      // teal
        case .openCode: return Color(red: 0.55, green: 0.62, blue: 0.95)   // indigo
        case .gemini: return Color(red: 0.50, green: 0.70, blue: 0.98)     // blue
        case .openClaw: return Color(red: 0.92, green: 0.62, blue: 0.42)   // amber
        case .cline: return Color(red: 0.62, green: 0.78, blue: 0.50)      // green
        case .hermes: return Color(red: 0.60, green: 0.50, blue: 0.85)     // violet
        case .codeBuddy: return Color(red: 0.20, green: 0.47, blue: 0.96)  // tencent blue
        case .kimiCode: return Color(red: 0.09, green: 0.51, blue: 1.0)    // moonshot blue
        case .pi: return Color(red: 0.22, green: 0.22, blue: 0.26)         // pi slate
        // xAI's mark is monochrome (web `bg-neutral-900`); a static near-black
        // would vanish on the dark card, so tint dynamically — near-black in
        // light, near-white in dark — mirroring the brand while staying legible.
        case .grok: return Color(light: Color(white: 0.12), dark: Color(white: 0.92))
        // Cursor's cube mark is monochrome too (web renders it at plain
        // `text-foreground`), so it gets the same appearance-following tint.
        case .cursor: return Color(light: Color(white: 0.12), dark: Color(white: 0.92))
        case .custom, .unknown: return Color(light: Color(white: 0.35), dark: Color(white: 0.75))
        }
    }
}

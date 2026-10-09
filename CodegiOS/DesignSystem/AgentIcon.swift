import SwiftUI
import UIKit

/// The per-agent brand icon, mirroring the web client's `AgentIcon`
/// (`src/components/agent-icon.tsx`). Color agents (Claude Code, Codex, Gemini,
/// OpenClaw, Kimi Code, Pi) render their own colors/gradients from a vector
/// asset; monochrome agents (OpenCode, Cline, Hermes, CodeBuddy, Grok) are
/// template glyphs tinted by `tint`.
///
/// The icons live in `Assets.xcassets` as vector SVGs ported verbatim from the
/// web, so they scale crisply at any size — render inside a fixed frame.
struct AgentIcon: View {
    let agent: AgentType
    /// Tint applied to monochrome (template) agents. Color agents ignore it.
    var tint: Color

    init(agent: AgentType, tint: Color? = nil) {
        self.agent = agent
        self.tint = tint ?? agent.accent
    }

    var body: some View {
        if let asset = agent.iconAsset, UIImage(named: asset) != nil {
            Image(asset)
                // Be explicit about intent rather than relying on the asset's
                // configured rendering intent: mono agents tint, color render as-is.
                .renderingMode(agent.iconIsTemplate ? .template : .original)
                .resizable()
                .scaledToFit()
                // A template image adopts this; an original (color) image ignores it.
                .foregroundStyle(tint)
        } else {
            // Generic custom/unknown mark, also used if a brand asset is missing.
            Image(systemName: agent.symbolName)
                .resizable()
                .scaledToFit()
                .foregroundStyle(tint)
        }
    }
}

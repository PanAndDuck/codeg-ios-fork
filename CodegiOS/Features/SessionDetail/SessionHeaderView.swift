import SwiftUI

/// The session header: a flat card carrying identity (title, agent, status),
/// the model + git branch, and a compact token / context-window readout
/// derived from `SessionStats`. Intentionally shadowless (a plain tinted
/// surface, not Liquid Glass) so the banner sits calmly atop the transcript.
struct SessionHeaderView: View {
    let summary: ConversationSummary
    let stats: SessionStats?
    var agentNames = AgentDisplayNames()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Title + badges
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                (summary.trimmedTitle.map { Text(verbatim: $0) } ?? Text("Untitled session"))
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                StatusBadge(status: summary.status)
            }

            // Meta row: agent · model · branch
            HStack(spacing: 8) {
                AgentBadge(agent: summary.agentType, names: agentNames)
                if let model = summary.model, !model.isEmpty {
                    MetaChip(symbol: "cpu", text: model, mono: true)
                }
                if !summary.isChat, let branch = summary.gitBranch, !branch.isEmpty {
                    MetaChip(symbol: "arrow.triangle.branch", text: branch, mono: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let usage = UsageReadout(stats: stats) {
                Divider().overlay(Theme.hairline)
                usage
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .hairlineBorder(Theme.Radius.lg)
    }
}

/// A small icon+text chip used in the header meta row.
private struct MetaChip: View {
    let symbol: String
    let text: String
    var mono: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(mono ? .mono(11) : .caption2.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.05), in: Capsule())
    }
}

/// Token + context-window summary. Initializer fails when there is nothing to
/// show, so the header can omit the whole row.
private struct UsageReadout: View {
    let tokensLabel: String?
    let contextPercent: Double?
    let contextLabel: String?

    init?(stats: SessionStats?) {
        guard let stats else { return nil }

        let tokenCount = stats.totalTokens ?? stats.totalUsage?.total
        if let tokenCount, tokenCount > 0 {
            tokensLabel = TokenFormat.compact(tokenCount) + " tokens"
        } else {
            tokensLabel = nil
        }

        if let pct = stats.contextWindowUsagePercent {
            contextPercent = max(0, min(1, pct / 100))
        } else if let used = stats.contextWindowUsedTokens, let max = stats.contextWindowMaxTokens, max > 0 {
            contextPercent = Double(used) / Double(max)
        } else {
            contextPercent = nil
        }

        if let used = stats.contextWindowUsedTokens, let max = stats.contextWindowMaxTokens, max > 0 {
            contextLabel = "\(TokenFormat.compact(used)) / \(TokenFormat.compact(max))"
        } else {
            contextLabel = nil
        }

        if tokensLabel == nil && contextPercent == nil { return nil }
    }

    var body: some View {
        HStack(spacing: 10) {
            if let tokensLabel {
                HStack(spacing: 4) {
                    Image(systemName: "circle.hexagongrid.fill").font(.system(size: 9))
                    Text(tokensLabel).font(.mono(11))
                }
                .foregroundStyle(Theme.textSecondary)
            }

            if let contextPercent {
                HStack(spacing: 6) {
                    ContextGauge(fraction: contextPercent)
                        .frame(width: 54, height: 5)
                    Text(percentText(contextPercent))
                        .font(.mono(11))
                        .foregroundStyle(contextTint(contextPercent))
                    if let contextLabel {
                        Text(contextLabel)
                            .font(.mono(10))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func percentText(_ f: Double) -> String {
        "\(Int((f * 100).rounded()))%"
    }

    private func contextTint(_ f: Double) -> Color {
        switch f {
        case ..<0.7: return Theme.textSecondary
        case ..<0.9: return Theme.warning
        default: return Theme.danger
        }
    }
}

/// A slim capsule progress bar for context-window usage.
private struct ContextGauge: View {
    let fraction: Double

    private var tint: Color {
        switch fraction {
        case ..<0.7: return Theme.accent
        case ..<0.9: return Theme.warning
        default: return Theme.danger
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(tint)
                    .frame(width: max(3, geo.size.width * fraction))
            }
        }
    }
}

import SwiftUI

/// Built-in expert skill packs, grouped by category in workflow order. Tapping
/// one opens its detail (markdown preview + per-agent enable/disable matrix).
struct ExpertsSettingsView: View {
    let client: CodegClient?
    @State private var model: ExpertsSettingsModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(client: CodegClient?) {
        self.client = client
        _model = State(initialValue: ExpertsSettingsModel(client: client))
    }

    var body: some View {
        ZStack {
            CodegBackground()
            content
        }
        // A standard large title (not the pinned `inlineLarge` other settings
        // pages use): on compact it sits big at the top and collapses to a
        // centered inline title as the list scrolls up — matching the Skills
        // page. iPad keeps the system default for a detail pane.
        .navigationTitle("Experts")
        .navigationBarTitleDisplayMode(horizontalSizeClass == .compact ? .large : .automatic)
        .task { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        if model.experts.isEmpty {
            switch model.phase {
            case .loading:
                LoadingView(label: "Loading experts…")
            case .failed(let message):
                InlineErrorView(message: message) { Task { await model.load() } }
            case .loaded:
                EmptyStateView(
                    icon: "graduationcap",
                    title: "No Experts",
                    message: "This server has no built-in expert skill packs."
                )
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let error = model.refreshError {
                        RefreshErrorBanner(
                            message: error,
                            retry: { Task { await model.load() } },
                            dismiss: { model.refreshError = nil }
                        )
                    }
                    ForEach(model.grouped, id: \.category) { group in
                        Text("\(group.label.uppercased()) · \(group.items.count)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .tracking(0.5)
                            .padding(.top, 6)
                            .padding(.leading, 4)
                        ForEach(group.items) { expert in
                            NavigationLink {
                                ExpertDetailView(expert: expert, agents: model.agents, agentNames: model.agentNames, client: client)
                            } label: {
                                ExpertRow(expert: expert)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, Theme.Layout.screenHMargin)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .scrollContentBackground(.hidden)
            .refreshable { await model.load() }
        }
    }
}

/// One expert card: a tinted icon tile, the localized name, and a short
/// description, with a chevron hinting it opens.
private struct ExpertRow: View {
    let expert: ExpertListItem

    var body: some View {
        GlassCard(cornerRadius: Theme.Radius.md, padding: 13) {
            HStack(spacing: 13) {
                ExpertIconTile(icon: expert.metadata.icon, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(expert.metadata.localizedName)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if let description = expert.metadata.localizedDescription, !description.isEmpty {
                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .contentShape(Rectangle())
    }
}

/// A rounded, accent-tinted tile holding an expert's glyph — the polished
/// "app icon" treatment shared by the list row and the detail hero. Internal so
/// `ExpertDetailView` can reuse it at a larger size.
struct ExpertIconTile: View {
    let icon: String?
    var size: CGFloat = 40

    var body: some View {
        // Delegates to the shared tile so the Experts and Skills rows stay visually
        // identical; this type keeps the expert-specific lucide→SF icon mapping.
        AccentIconTile(symbol: Self.symbol(for: icon), size: size)
    }

    /// Resolve an expert's icon to a renderable SF Symbol. The server sends
    /// *lucide* icon names (e.g. `Lightbulb`), so map the known ones; if a value
    /// is already a valid SF Symbol (older data / customizations) use it directly.
    /// Every branch is validated with `UIImage(systemName:)` because
    /// `Image(systemName:)` renders a *blank* — not a fallback — for an unknown
    /// name, so an un-validated guess would leave an empty tile.
    static func symbol(for icon: String?) -> String {
        guard let icon, !icon.isEmpty else { return "sparkles" }
        if let mapped = lucideToSF[icon], UIImage(systemName: mapped) != nil { return mapped }
        if UIImage(systemName: icon) != nil { return icon }
        return "sparkles"
    }

    /// Every lucide name used by the bundled experts (`experts.toml`) → an SF
    /// Symbol. Resolution above still validates each, so any future mismatch
    /// degrades to `sparkles` rather than a blank tile.
    private static let lucideToSF: [String: String] = [
        "Lightbulb": "lightbulb",
        "ListTodo": "checklist",
        "PlayCircle": "play.circle",
        "Bot": "cpu",
        "GitFork": "arrow.triangle.branch",
        "GitBranch": "arrow.triangle.branch",
        "FlaskConical": "testtube.2",
        "CheckCheck": "checkmark.seal",
        "Bug": "ladybug",
        "MessageSquareQuote": "quote.bubble",
        "MessageSquareReply": "arrowshape.turn.up.left",
        "GitMerge": "arrow.triangle.merge",
        "Sparkles": "sparkles",
        "FileCode2": "doc.text",
    ]
}

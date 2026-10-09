import SwiftUI

/// One folder's home: a compact identity header, then a browser over the
/// folder's **files**, working-tree **changes**, and commit **history** — the
/// things you actually want when inspecting a project. (Sessions live in the
/// Chats/Activity tabs; this screen is about the code in the folder.) Files data
/// is fetched on demand from the same HTTP API the codeg desktop/web client uses
/// (`list_directory_with_files`, `git_status`, `git_log`, …).
struct ProjectDetailView: View {
    let client: CodegClient
    let folderID: Int
    let activity: ActivityModel
    /// Start a new task in this folder (the only session affordance left here).
    let onNewSession: (FolderDetail) -> Void

    var body: some View {
        ZStack {
            CodegBackground()
            content
        }
        .navigationTitle(folder?.name ?? "Folder")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if folder != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if let folder { onNewSession(folder) }
                    } label: {
                        Image(systemName: "plus.bubble")
                    }
                    .tint(Theme.accent)
                    .accessibilityLabel("New Task")
                }
            }
        }
        .task {
            if !activity.hasLoaded {
                await activity.refresh(client: client)
            }
        }
    }

    private var folder: FolderDetail? {
        activity.folders.first { $0.id == folderID }
    }

    // MARK: - Content states

    @ViewBuilder
    private var content: some View {
        if let folder {
            // `.id(folder.id)` gives each folder a fresh `FolderDetailContent`
            // (and thus a fresh `FolderGitModel`) when navigating between folders.
            FolderDetailContent(
                client: client,
                folder: folder,
                activity: activity
            )
            .id(folder.id)
        } else if !activity.hasLoaded {
            LoadingView(label: "Loading folder…")
        } else {
            EmptyStateView(
                icon: "folder.badge.questionmark",
                title: "Folder Not Found",
                message: "This folder no longer exists on the server."
            )
        }
    }
}

// MARK: - Detail content (per resolved folder)

/// The body of a resolved folder: identity header + Files/Changes/Commits tabs,
/// owning the shared ``FolderGitModel`` and hosting the commit + credential
/// sheets. Split out from ``ProjectDetailView`` so the git model can be created
/// in `init` (the folder is known) and live for the screen's lifetime.
private struct FolderDetailContent: View {
    let client: CodegClient
    let folder: FolderDetail
    let activity: ActivityModel

    @State private var tab: FolderTab = .files
    @State private var git: FolderGitModel
    @State private var terminal: TerminalSession
    @State private var showCommit = false
    @State private var agentNames = AgentDisplayNames()

    init(client: CodegClient, folder: FolderDetail, activity: ActivityModel) {
        self.client = client
        self.folder = folder
        self.activity = activity
        _git = State(initialValue: FolderGitModel(client: client, rootPath: folder.path, folderId: folder.id))
        _terminal = State(initialValue: TerminalSession(client: client, folder: folder))
    }

    var body: some View {
        @Bindable var git = git
        VStack(spacing: 0) {
            // Pinned identity + tab selector; the selected tab scrolls below.
            // The picker is always shown — the cached `gitBranch` is an
            // unreliable repo signal (it's `nil` for a freshly opened repo until
            // the server backfills it), so the git tabs decide repo-ness live
            // from their own calls and show a calm non-repo state when needed.
            VStack(spacing: 14) {
                FolderHeader(
                    folder: folder,
                    agentNames: agentNames,
                    sessionCount: activity.conversations(in: folder.id).count,
                    runningCount: activity.runningCount(folderID: folder.id)
                )
                tabPicker
            }
            .padding(.horizontal, Theme.Layout.screenHMargin)
            .padding(.top, 10)
            .padding(.bottom, 12)

            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The commit composer; on dismiss, run the deferred push for "Commit &
        // Push" so its credential sheet doesn't stack on top of the composer.
        .sheet(isPresented: $showCommit, onDismiss: {
            if git.pushAfterCommitDismiss {
                git.pushAfterCommitDismiss = false
                Task { await git.push() }
            }
        }) {
            CommitSheet(model: git)
        }
        // A single credential sheet for every push/pull/fetch, regardless of which
        // tab (or the commit composer) initiated the operation.
        .sheet(item: $git.credentialPrompt) { prompt in
            GitCredentialSheet(model: git, prompt: prompt)
        }
        .task(id: folder.defaultAgentType) {
            guard let agent = folder.defaultAgentType, !agent.isBuiltIn,
                  let agents = try? await client.listAgents(), !Task.isCancelled else { return }
            agentNames = AgentDisplayNames(agents: agents)
        }
    }

    private var tabPicker: some View {
        Picker("View", selection: $tab) {
            ForEach(FolderTab.allCases) { tab in
                Text(tab.label).tag(tab)
            }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .files:
            FolderFilesView(client: client, rootPath: folder.path, dirPath: folder.path, embedded: true)
                .padding(.horizontal, Theme.Layout.screenHMargin)
        case .changes:
            FolderChangesView(model: git, onCommit: { showCommit = true })
                .padding(.horizontal, Theme.Layout.screenHMargin)
        case .commits:
            FolderCommitsView(model: git)
                .padding(.horizontal, Theme.Layout.screenHMargin)
        case .terminal:
            // Edge-to-edge: the terminal manages its own internal inset.
            FolderTerminalView(session: terminal)
        }
    }
}

/// The Files / Changes / Commits selector — mirrors the codeg desktop aux panel.
enum FolderTab: String, CaseIterable, Identifiable {
    case files, changes, commits, terminal
    var id: String { rawValue }
    var label: LocalizedStringKey {
        switch self {
        case .files: "Files"
        case .changes: "Changes"
        case .commits: "Commits"
        case .terminal: "Terminal"
        }
    }
}

// MARK: - Header

/// The folder's identity hero, rendered flat on the screen background (no card
/// box, so it reads as a screen header rather than another stacked block): a large
/// color tile + name + full path, then a meta row of branch / default-agent chips
/// with a live session/running stat trailing. The stats ride the shared
/// ``ActivityModel`` snapshot — no extra requests.
private struct FolderHeader: View {
    let folder: FolderDetail
    let agentNames: AgentDisplayNames
    let sessionCount: Int
    let runningCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                FolderBadge(color: folderColor, size: 52)

                VStack(alignment: .leading, spacing: 4) {
                    Text(folder.name)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(folder.path)
                        .font(.mono(12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if hasMeta {
                HStack(spacing: 8) {
                    if let branch = folder.gitBranch, !branch.isEmpty {
                        chip(symbol: "arrow.triangle.branch", text: branch)
                    }
                    if let agent = folder.defaultAgentType {
                        AgentBadge(agent: agent, names: agentNames)
                    }
                    Spacer(minLength: 8)
                    sessionStat
                }
            }
        }
    }

    /// Whether the meta row has anything to show — suppresses a stray gap for a
    /// brand-new folder with no branch, agent, or sessions yet.
    private var hasMeta: Bool {
        (folder.gitBranch?.isEmpty == false)
            || folder.defaultAgentType != nil
            || sessionCount > 0
    }

    /// Trailing live stat: a running pulse + count when active, then the total
    /// session count. Preserved at full width (`fixedSize`) so the branch chip
    /// truncates first under pressure.
    @ViewBuilder
    private var sessionStat: some View {
        HStack(spacing: 8) {
            if runningCount > 0 {
                HStack(spacing: 4) {
                    LivePulse()
                    Text("\(runningCount)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.accent)
                }
            }
            if sessionCount > 0 {
                Text("\(sessionCount) sessions")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .fixedSize()
        .layoutPriority(1)
    }

    private var folderColor: Color {
        Color(hexString: folder.color) ?? Theme.accent
    }

    private func chip(symbol: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.05), in: Capsule())
    }
}

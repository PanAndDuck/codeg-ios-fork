import SwiftUI

/// A folder's uncommitted working-tree changes (`git_status`): each changed file
/// with a status badge. Tapping a tracked change shows its diff against HEAD; an
/// untracked file opens its preview (it has no diff yet). A trailing menu on each
/// row offers Discard / Stage / Delete, and a bottom bar opens the commit
/// composer. Embedded in the Changes tab of ``ProjectDetailView``.
struct FolderChangesView: View {
    let model: FolderGitModel
    /// Open the commit composer (hosted by ``FolderDetailContent``).
    let onCommit: () -> Void

    private var client: CodegClient { model.client }
    private var rootPath: String { model.rootPath }

    @State private var entries: [GitStatusEntry] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var notARepo = false
    @State private var loaded = false
    @State private var pendingDiscard: GitStatusEntry?
    @State private var pendingDelete: GitStatusEntry?

    var body: some View {
        content
            .task { if !loaded { await load() } }
            // Reload after any working-tree mutation (commit/discard/stage/delete/pull).
            .onChange(of: model.reloadToken) { Task { await load(force: true) } }
            .confirmationDialog(
                "Discard Changes",
                isPresented: confirmBinding($pendingDiscard),
                presenting: pendingDiscard
            ) { entry in
                Button("Discard Changes", role: .destructive) {
                    Task { await model.discard(file: entry.path, displayName: fileName(entry)) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { entry in
                Text("Discard all changes to \(fileName(entry))? This can't be undone.")
            }
            .confirmationDialog(
                "Delete File",
                isPresented: confirmBinding($pendingDelete),
                presenting: pendingDelete
            ) { entry in
                Button("Delete", role: .destructive) {
                    Task { await model.delete(file: entry.path, displayName: fileName(entry)) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { entry in
                Text("Delete \(fileName(entry)) from disk? This can't be undone.")
            }
    }

    /// `confirmationDialog(isPresented:)` from an optional "pending item": true
    /// while set, clears the item when the dialog dismisses.
    private func confirmBinding(_ item: Binding<GitStatusEntry?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }

    private func fileName(_ entry: GitStatusEntry) -> String {
        (entry.path as NSString).lastPathComponent
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && !loaded {
            LoadingView(label: "Loading changes…")
        } else if notARepo {
            // A folder can stop being a repo after a successful load (e.g. its
            // .git was removed); the non-repo state takes precedence over any
            // stale rows, and stays pull-to-refreshable so it can recover.
            ScrollView { NotAGitRepoState() }
                .scrollContentBackground(.hidden)
                .refreshable { await load(force: true) }
        } else if let error, !loaded {
            InlineErrorView(message: error) { Task { await load() } }
        } else {
            // Loaded (possibly empty) — one refreshable scroll so an empty tree is
            // still pull-to-refreshable and a failed refresh surfaces a banner.
            loadedList
        }
    }

    private var loadedList: some View {
        ScrollView {
            VStack(spacing: 8) {
                // The operation status strip (busy spinner / result banner) sits
                // above the list so commit/discard/stage/delete/pull feedback is
                // visible without covering the rows.
                GitStatusStrip(model: model)
                    .padding(.bottom, model.isBusy || model.banner != nil ? 4 : 0)

                // A refresh that fails over an already-loaded view keeps what's
                // shown but surfaces the failure rather than silently going stale.
                // It stays OUTSIDE the grouped card (its own danger-tinted surface).
                if let error, loaded {
                    RefreshErrorBanner(message: error, retry: { Task { await load(force: true) } }, dismiss: { self.error = nil })
                }
                if entries.isEmpty {
                    EmptyStateView(
                        icon: "checkmark.seal",
                        title: "Working Tree Clean",
                        message: "No uncommitted changes in this repository."
                    )
                    .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    // A slim overview line (file count + colored breakdown) and the
                    // primary Commit action, above the list — mirrors the Commits
                    // tab's branch row + sync pills, and keeps the action with the
                    // content rather than in a detached bottom bar.
                    VStack(alignment: .leading, spacing: 12) {
                        ChangesSummary(entries: entries)
                        AccentPillButton(title: "Commit Changes", systemImage: "checkmark", prominent: true) {
                            onCommit()
                        }
                        .disabled(model.isBusy)
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 2)

                    // One continuous grouped surface — borderless rows split by
                    // inset hairlines — rather than a stack of per-row cards.
                    // Flat (no glass shadow) so the white list sits flat on the bg.
                    // Lazy: `git_status(showAllUntracked:)` lists every untracked
                    // file individually, so a freshly-opened/ungitignored tree can
                    // produce a very large set — don't build all rows eagerly.
                    FlatCard(cornerRadius: Theme.Radius.lg) {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                if index > 0 {
                                    InsetDivider(leading: ChangeRowMetrics.dividerInset)
                                }
                                ChangeRow(
                                    entry: entry,
                                    client: client,
                                    rootPath: rootPath,
                                    isBusy: model.isBusy,
                                    onDiscard: { pendingDiscard = entry },
                                    onStage: { Task { await model.stage(file: entry.path, displayName: fileName(entry)) } },
                                    onDelete: { pendingDelete = entry }
                                )
                            }
                        }
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollContentBackground(.hidden)
        .refreshable { await load(force: true) }
    }

    private func load(force: Bool = false) async {
        if loaded && !force { return }
        isLoading = true
        error = nil
        notARepo = false
        do {
            // Individual untracked files (not collapsed dirs) so each is tappable.
            entries = try await client.gitStatus(path: rootPath, showAllUntracked: true)
            loaded = true
        } catch {
            if (error as? APIError)?.isNotAGitRepository == true {
                notARepo = true
            } else {
                self.error = APIError.userMessage(error)
            }
        }
        isLoading = false
    }
}

// MARK: - Summary

/// A slim overview above the changes list: the total file count and a compact,
/// color-coded breakdown by category (e.g. `M 2 · A 1 · U 2`). Only categories
/// that are present appear, in a stable order, so the line stays short.
private struct ChangesSummary: View {
    let entries: [GitStatusEntry]

    /// Present categories with their counts, in a fixed display order.
    private var breakdown: [(change: GitChange, count: Int)] {
        let order: [GitChange] = [.conflicted, .modified, .added, .deleted, .renamed, .copied, .typeChanged, .untracked, .other]
        var counts: [GitChange: Int] = [:]
        for entry in entries { counts[entry.change, default: 0] += 1 }
        return order.compactMap { change in counts[change].map { (change, $0) } }
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("\(entries.count) Changed Files")
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 8)
            HStack(spacing: 9) {
                ForEach(Array(breakdown.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 3) {
                        Text(item.change.letter)
                            .font(.system(size: 10, weight: .heavy, design: .monospaced))
                            .foregroundStyle(item.change.tint)
                        Text("\(item.count)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .fixedSize()
                }
            }
        }
    }
}

// MARK: - Row

/// Shared metrics so the inset divider lines up under the filename, past the
/// leading status badge.
private enum ChangeRowMetrics {
    static let badgeWidth: CGFloat = 18
    static let iconGap: CGFloat = 11
    static var dividerInset: CGFloat { SettingsRowMetrics.hInset + badgeWidth + iconGap }
}

/// One changed file: status badge, path, and the change's label, with a chevron.
/// Borderless: the enclosing grouped card draws the surface. Tapping the row
/// navigates to the file's diff (tracked) or content (untracked); a trailing menu
/// — also available via long-press context menu (`.swipeActions` don't work in a
/// `ScrollView`+`LazyVStack`) — offers Discard / Stage / Delete.
private struct ChangeRow: View {
    let entry: GitStatusEntry
    let client: CodegClient
    let rootPath: String
    let isBusy: Bool
    let onDiscard: () -> Void
    let onStage: () -> Void
    let onDelete: () -> Void

    private var isUntracked: Bool { entry.change == .untracked }

    var body: some View {
        HStack(spacing: ChangeRowMetrics.iconGap) {
            NavigationLink {
                destination
            } label: {
                rowContent
            }
            .buttonStyle(.plain)

            menu
        }
        .padding(.horizontal, SettingsRowMetrics.hInset)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .contextMenu { menuItems }
    }

    private var rowContent: some View {
        HStack(spacing: ChangeRowMetrics.iconGap) {
            ChangeBadge(change: entry.change)

            VStack(alignment: .leading, spacing: 2) {
                Text(fileName)
                    .font(.callout)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let renamedFrom = entry.renamedFrom {
                    Text("from \(renamedFrom)")
                        .font(.mono(10))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                } else if !directory.isEmpty {
                    Text(directory)
                        .font(.mono(10))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // The change category is already carried by the colored letter badge
            // (and read by VoiceOver via its accessibility label), so the redundant
            // word label is dropped — it only crowded the row and the trailing menu.
            // A chevron signals the row opens the file's diff / preview. Decorative
            // — the whole row is one NavigationLink, so hide it from VoiceOver.
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }

    private var menu: some View {
        Menu {
            menuItems
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body)
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .disabled(isBusy)
    }

    @ViewBuilder
    private var menuItems: some View {
        if isUntracked {
            Button { onStage() } label: { Label("Stage", systemImage: "plus.circle") }
            Button(role: .destructive) { onDelete() } label: { Label("Delete", systemImage: "trash") }
        } else {
            Button(role: .destructive) { onDiscard() } label: { Label("Discard Changes", systemImage: "arrow.uturn.backward") }
        }
    }

    /// Untracked files have no HEAD diff — open their content instead. Uses the
    /// resolved current path so a `old -> new` rename routes to the new file.
    @ViewBuilder
    private var destination: some View {
        if isUntracked {
            FilePreviewView(client: client, rootPath: rootPath, absPath: absolutePath)
        } else {
            WorkingDiffView(client: client, rootPath: rootPath, file: entry.path)
        }
    }

    /// git reports repo-root-relative paths; the file preview wants an absolute
    /// path it can re-relativize against the folder root.
    private var absolutePath: String {
        var base = rootPath
        if !base.hasSuffix("/") { base += "/" }
        return base + entry.path
    }

    private var fileName: String { (entry.path as NSString).lastPathComponent }
    private var directory: String { (entry.path as NSString).deletingLastPathComponent }
}

// MARK: - Working-tree diff

/// One file's uncommitted diff against HEAD (`git_diff` scoped to the file),
/// rendered with the shared ``DiffView``.
struct WorkingDiffView: View {
    let client: CodegClient
    let rootPath: String
    /// Repo-root-relative path of the changed file.
    let file: String

    @State private var diffFiles: [DiffFile]?
    @State private var isLoading = false
    @State private var error: String?

    private var name: String { (file as NSString).lastPathComponent }

    var body: some View {
        ZStack {
            CodegBackground()
            ScrollView {
                content
                    .padding(.horizontal, Theme.Layout.screenHMargin)
                    .padding(.top, 12)
                    .padding(.bottom, 28)
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            LoadingView(label: "Loading diff…")
                .frame(maxWidth: .infinity, minHeight: 200)
        } else if let diffFiles, !diffFiles.isEmpty {
            DiffView(files: diffFiles)
        } else if let error {
            InlineErrorView(message: error) { Task { await load() } }
        } else {
            EmptyStateView(
                icon: "doc.plaintext",
                title: "No Textual Diff",
                message: "This change has no line-level diff to show (it may be a binary or mode change)."
            )
            .frame(maxWidth: .infinity, minHeight: 200)
        }
    }

    private func load() async {
        guard diffFiles == nil else { return }
        isLoading = true
        error = nil
        do {
            let raw = try await client.gitDiff(path: rootPath, file: file)
            diffFiles = UnifiedDiff.parse(raw) ?? []
        } catch {
            self.error = APIError.userMessage(error)
        }
        isLoading = false
    }
}

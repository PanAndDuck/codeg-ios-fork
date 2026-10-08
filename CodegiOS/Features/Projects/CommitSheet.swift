import SwiftUI

/// The commit composer, presented as a sheet from the Changes tab. Lists the
/// working-tree changes with per-file selection (tracked auto-selected, untracked
/// unselected — matching the web commit dialog), takes a commit message, and
/// commits the selected files (optionally pushing afterward). The server stages
/// the chosen files itself, so untracked files can be selected and committed
/// directly. Modeled on ``CloneRepoView``.
struct CommitSheet: View {
    let model: FolderGitModel

    @Environment(\.dismiss) private var dismiss
    @FocusState private var messageFocused: Bool

    @State private var entries: [GitStatusEntry] = []
    @State private var selected: Set<String> = []
    @State private var message = ""
    @State private var loading = true
    @State private var committing = false
    @State private var loadError: String?
    @State private var commitError: String?

    private var trackedEntries: [GitStatusEntry] { entries.filter { $0.change != .untracked } }
    private var untrackedEntries: [GitStatusEntry] { entries.filter { $0.change == .untracked } }

    private var trimmedMessage: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canCommit: Bool {
        !trimmedMessage.isEmpty && !selected.isEmpty && !committing && !loading
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CodegBackground()
                content
            }
            .navigationTitle("Commit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .tint(Theme.textSecondary)
                        .disabled(committing)
                }
            }
            .safeAreaInset(edge: .bottom) { commitBar }
            .task { await load() }
        }
        .presentationDragIndicator(.visible)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if loading {
            LoadingView(label: "Loading changes…")
        } else if let loadError {
            InlineErrorView(message: loadError) { Task { await load() } }
        } else if entries.isEmpty {
            EmptyStateView(
                icon: "checkmark.seal",
                title: "Nothing to Commit",
                message: "The working tree is clean."
            )
        } else {
            ScrollView {
                VStack(spacing: 18) {
                    // Message first — it's the required input, so it shouldn't sit
                    // below a long file list the user has to scroll past to reach.
                    messageSection
                    // Then "what to commit": a selection summary + the file groups.
                    VStack(spacing: 10) {
                        selectionHeader
                        if !trackedEntries.isEmpty {
                            fileSection(title: "Changes", entries: trackedEntries)
                        }
                        if !untrackedEntries.isEmpty {
                            fileSection(title: "Untracked", entries: untrackedEntries)
                        }
                    }
                    if let commitError {
                        CommitErrorBanner(message: commitError)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var selectionHeader: some View {
        HStack(spacing: 8) {
            Text("\(selected.count) of \(entries.count) selected")
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 8)
            Button(allSelected ? "Deselect All" : "Select All") {
                if allSelected {
                    selected.removeAll()
                } else {
                    selected = Set(entries.map(\.path))
                }
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .disabled(committing)
        }
        .padding(.horizontal, 4)
    }

    private var allSelected: Bool {
        !entries.isEmpty && selected.count == entries.count
    }

    private func fileSection(title: LocalizedStringKey, entries: [GitStatusEntry]) -> some View {
        EditorSection(title: title, flat: true) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { SettingsRowDivider() }
                fileRow(entry)
            }
        }
    }

    private func fileRow(_ entry: GitStatusEntry) -> some View {
        Button {
            toggle(entry.path)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: selected.contains(entry.path) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(selected.contains(entry.path) ? Theme.accent : Theme.textTertiary)
                ChangeBadge(change: entry.change)
                VStack(alignment: .leading, spacing: 2) {
                    Text((entry.path as NSString).lastPathComponent)
                        .font(.callout)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    let dir = (entry.path as NSString).deletingLastPathComponent
                    if !dir.isEmpty {
                        Text(dir)
                            .font(.mono(10))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // The colored letter badge already conveys the change category,
                // so the trailing word label is dropped to declutter the row.
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableRowStyle())
        .disabled(committing)
    }

    private var messageSection: some View {
        // The section header ("MESSAGE") already labels the field, so the inner
        // FieldRow label is dropped (it doubled the section title above the
        // placeholder) — just the editable field with a guiding placeholder.
        EditorSection(title: "Message", flat: true) {
            TextField("Describe your changes", text: $message, axis: .vertical)
                .lineLimit(3...8)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.accent)
                .focused($messageFocused)
                .submitLabel(.return)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .disabled(committing)
        }
    }

    private var commitBar: some View {
        VStack(spacing: 6) {
            FlatPrimaryButton(
                title: "Commit \(selected.count) Files",
                systemImage: "checkmark",
                isLoading: committing
            ) {
                runCommit(andPush: false)
            }
            .disabled(!canCommit)

            // Secondary action, deliberately lighter than the primary CTA: a plain
            // accent-text button (not a second full-width slab) so the hierarchy is
            // unambiguous — Commit is the default, "& Push" the extra.
            Button {
                runCommit(andPush: true)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up").font(.caption.weight(.semibold))
                    Text("Commit & Push").font(.subheadline.weight(.medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(canCommit ? Theme.accent : Theme.textTertiary)
            .disabled(!canCommit)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        // Opaque backdrop matching the sheet — masks content scrolling behind the
        // bar with NO frosted material panel (the prior `.ultraThinMaterial` read as
        // a distinct shaded plate on the light background) and no shadow.
        .background(Theme.bg)
    }

    // MARK: - Actions

    private func toggle(_ path: String) {
        if selected.contains(path) {
            selected.remove(path)
        } else {
            selected.insert(path)
        }
    }

    private func load() async {
        loading = true
        loadError = nil
        do {
            let result = try await model.client.gitStatus(path: model.rootPath, showAllUntracked: true)
            entries = result
            // Tracked changes start selected; untracked start unselected (web parity).
            selected = Set(result.filter { $0.change != .untracked }.map(\.path))
        } catch {
            loadError = APIError.userMessage(error)
        }
        loading = false
    }

    private func runCommit(andPush: Bool) {
        guard canCommit else { return }
        messageFocused = false
        committing = true
        commitError = nil
        Task {
            do {
                try await model.commit(message: trimmedMessage, files: Array(selected))
                // Commit succeeded. The push (if requested) runs after this sheet
                // dismisses, so its credential sheet doesn't stack on top of us.
                if andPush { model.pushAfterCommitDismiss = true }
                committing = false
                dismiss()
            } catch {
                committing = false
                commitError = APIError.userMessage(error)
            }
        }
    }
}

/// Inline error shown in the commit sheet when the commit itself fails (the sheet
/// stays open so the user can adjust and retry).
private struct CommitErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.danger)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.danger)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Theme.danger.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md, color: Theme.danger.opacity(0.35))
    }
}

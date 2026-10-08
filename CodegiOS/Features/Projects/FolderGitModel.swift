import SwiftUI

/// Drives the git **operations** layered onto a folder's Changes / Commits tabs:
/// commit, push, pull, fetch, and the per-file working-tree actions (discard,
/// stage, delete). Owned by ``ProjectDetailView`` and shared by both tab views so
/// they show one busy/feedback surface and refresh together after a mutation.
///
/// Push/pull/fetch route through ``withCredentialRetry(_:)`` — a faithful port of
/// the web `git-credential-context`: first try with the server's stored GitHub
/// accounts, and on an `authentication_failed` error prompt for a token (GitHub)
/// or username/password (other hosts) and retry.
@MainActor
@Observable
final class FolderGitModel {
    let client: CodegClient
    let rootPath: String
    let folderId: Int?

    /// A tab-level operation (push/pull/fetch/discard/stage/delete) is running.
    /// Commit has its own spinner inside ``CommitSheet`` and doesn't set this.
    var isBusy = false
    /// Label for the in-flight operation (shown next to the spinner).
    var busyTitle: LocalizedStringKey?
    /// The most recent operation outcome, shown as a strip atop the active tab.
    var banner: GitBanner?
    /// Bumped after any successful mutation so the Changes/Commits lists reload.
    private(set) var reloadToken = 0
    /// A pending credential request — drives the single `GitCredentialSheet`
    /// presented by ``ProjectDetailView``.
    var credentialPrompt: GitCredentialPrompt?
    /// Set by ``CommitSheet`` when the user chose "Commit & Push": the push runs
    /// *after* the sheet dismisses (so its credential sheet doesn't stack).
    var pushAfterCommitDismiss = false

    @ObservationIgnored
    private var credentialContinuation: CheckedContinuation<GitCredentialOutcome?, Never>?
    /// Identity of the prompt whose continuation is currently suspended — lets the
    /// sheet's teardown safety net cancel only the request it was showing.
    @ObservationIgnored
    private var pendingPromptID: UUID?

    init(client: CodegClient, rootPath: String, folderId: Int?) {
        self.client = client
        self.rootPath = rootPath
        self.folderId = folderId
    }

    // MARK: - Commit (driven by CommitSheet)

    /// Commit the selected `files` with `message`. The server stages them itself.
    /// Throws on failure so the sheet can show an inline error and stay open; on
    /// success it sets the banner and signals a reload, and the sheet dismisses.
    func commit(message: String, files: [String]) async throws {
        let result = try await client.gitCommit(
            path: rootPath, message: message, files: files, folderId: folderId
        )
        banner = GitBanner(kind: .success, message: "Committed \(result.committedFiles) files")
        didMutate()
    }

    // MARK: - Remote operations (credential-aware)

    func push() async {
        await perform("Pushing…") {
            let result = try await self.withCredentialRetry { creds in
                try await self.client.gitPush(
                    path: self.rootPath, remote: nil, credentials: creds, folderId: self.folderId
                )
            }
            return Self.pushBanner(result)
        }
    }

    func pull() async {
        await perform("Pulling…") {
            let result = try await self.withCredentialRetry { creds in
                try await self.client.gitPull(path: self.rootPath, credentials: creds)
            }
            return Self.pullBanner(result)
        }
    }

    func fetch() async {
        await perform("Fetching…") {
            _ = try await self.withCredentialRetry { creds in
                try await self.client.gitFetch(path: self.rootPath, credentials: creds)
            }
            return GitBanner(kind: .success, message: "Fetched from remote")
        }
    }

    // MARK: - Working-tree file actions

    /// Discard a tracked file's changes (`git restore`). `displayName` is shown in
    /// the success banner.
    func discard(file: String, displayName: String) async {
        await perform("Discarding…") {
            try await self.client.gitRollbackFile(path: self.rootPath, file: file)
            return GitBanner(kind: .success, message: "Discarded changes in \(displayName)")
        }
    }

    /// Stage an untracked/modified file so git starts tracking it.
    func stage(file: String, displayName: String) async {
        await perform("Staging…") {
            try await self.client.gitAddFiles(path: self.rootPath, files: [file])
            return GitBanner(kind: .success, message: "Staged \(displayName)")
        }
    }

    /// Delete an untracked file from disk. `file` is repo-root-relative (which, for
    /// the common folder == repo-root case, is also relative to `rootPath`).
    func delete(file: String, displayName: String) async {
        await perform("Deleting…") {
            try await self.client.deleteFileTreeEntry(rootPath: self.rootPath, path: file)
            return GitBanner(kind: .warning, message: "Deleted \(displayName)")
        }
    }

    // MARK: - Credential sheet plumbing (called by GitCredentialSheet)

    /// Resolve the pending prompt with entered credentials (sheet "Authenticate").
    func submitCredentials(_ outcome: GitCredentialOutcome) {
        resolveCredentials(with: outcome)
    }

    /// Resolve the pending prompt as cancelled (sheet "Cancel").
    func cancelCredentials() {
        resolveCredentials(with: nil)
    }

    /// Teardown safety net: if the credential sheet for `id` disappeared without a
    /// button action (e.g. the whole screen was popped), cancel its still-pending
    /// request so the awaiting push/pull/fetch doesn't hang with `isBusy` stuck
    /// true. A no-op once a newer prompt is pending (the stale disappearance of an
    /// already-resolved/re-presented prompt must not cancel the live one).
    func cancelCredentials(ifShowing id: UUID) {
        guard pendingPromptID == id else { return }
        resolveCredentials(with: nil)
    }

    /// Single resume path — idempotent (only resumes a still-pending continuation).
    private func resolveCredentials(with outcome: GitCredentialOutcome?) {
        credentialPrompt = nil
        pendingPromptID = nil
        credentialContinuation?.resume(returning: outcome)
        credentialContinuation = nil
    }

    // MARK: - Internals

    /// Bump the reload signal and broadcast so other screens (e.g. the folder
    /// header's cached branch) refresh too.
    private func didMutate() {
        reloadToken += 1
        NotificationCenter.default.post(name: .foldersDidChange, object: nil)
    }

    /// Run a tab-level operation with the shared busy + banner lifecycle. Bumps
    /// the reload signal only on success.
    private func perform(_ title: LocalizedStringKey, _ body: () async throws -> GitBanner?) async {
        guard !isBusy else { return }
        isBusy = true
        busyTitle = title
        banner = nil
        do {
            if let result = try await body() {
                banner = result
            }
            didMutate()
        } catch where APIError.isCancellation(error) {
            // View went away — leave state untouched.
        } catch let error as APIError where error.isAuthFailure {
            // The user cancelled the credential prompt (withCredentialRetry only
            // rethrows an auth failure on cancel). Surface the server's guidance
            // calmly rather than as a red error, and don't signal a reload.
            banner = GitBanner(kind: .warning, message: LocalizedStringKey(stringLiteral: error.errorDescription ?? "Authentication required."))
        } catch {
            banner = GitBanner(kind: .error, message: LocalizedStringKey(stringLiteral: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
        }
        isBusy = false
        busyTitle = nil
    }

    /// Port of web `withCredentialRetry`: run `operation` with the server's stored
    /// credentials; on an auth failure, prompt for credentials (GitHub token or
    /// username/password by remote host) and retry until success or the user
    /// cancels. A cancel rethrows the original auth error.
    private func withCredentialRetry<T>(_ operation: (GitCredentials?) async throws -> T) async throws -> T {
        do {
            return try await operation(nil)
        } catch let firstError as APIError where firstError.isAuthFailure {
            let host = await resolveRemoteHost()
            let mode: GitCredentialPrompt.Mode = (host == "github.com") ? .github : .generic

            guard var outcome = await requestCredentials(mode: mode, host: host, retry: false) else {
                throw firstError
            }
            while true {
                do {
                    let result = try await operation(outcome.credentials)
                    if outcome.saveAfterSuccess {
                        await saveGenericAccount(host: host, credentials: outcome.credentials)
                    }
                    return result
                } catch let retryError as APIError where retryError.isAuthFailure {
                    guard let next = await requestCredentials(mode: mode, host: host, retry: true) else {
                        throw retryError
                    }
                    outcome = next
                }
            }
        }
    }

    /// Suspend until ``GitCredentialSheet`` resolves the prompt.
    private func requestCredentials(mode: GitCredentialPrompt.Mode, host: String?, retry: Bool) async -> GitCredentialOutcome? {
        let prompt = GitCredentialPrompt(mode: mode, host: host, isRetry: retry)
        return await withCheckedContinuation { continuation in
            credentialContinuation = continuation
            pendingPromptID = prompt.id
            credentialPrompt = prompt
        }
    }

    /// The origin remote's host (e.g. "github.com"), used to choose the prompt
    /// mode. Falls back to nil (→ generic mode) on any failure.
    private func resolveRemoteHost() async -> String? {
        guard let remotes = try? await client.gitListRemotes(path: rootPath) else { return nil }
        let origin = remotes.first { $0.name == "origin" } ?? remotes.first
        guard let url = origin?.url else { return nil }
        return Self.extractHost(url)
    }

    /// Persist generic credentials as a GitHub-style account for reuse, mirroring
    /// web `saveGenericAccount`. Best-effort — failures are swallowed.
    private func saveGenericAccount(host: String?, credentials: GitCredentials) async {
        let serverUrl = host.map { "https://\($0)" } ?? "https://unknown"
        do {
            let existing = try await client.githubAccounts()
            let isDuplicate = existing.contains {
                $0.username == credentials.username && Self.extractHost($0.serverUrl) == host
            }
            guard !isDuplicate else { return }
            let account = GitHubAccount(
                id: UUID().uuidString,
                serverUrl: serverUrl,
                username: credentials.username,
                scopes: [],
                avatarUrl: nil,
                isDefault: existing.isEmpty,
                createdAt: Self.iso8601Now()
            )
            try await client.saveAccountToken(accountId: account.id, token: credentials.password)
            try await client.updateGithubAccounts(existing + [account])
        } catch {
            // Non-critical — the operation already succeeded.
        }
    }

    // MARK: - Banner builders

    private static func pushBanner(_ result: GitPushResult) -> GitBanner {
        if result.pushedCommits == 0 {
            return GitBanner(kind: .success, message: "Everything is up to date")
        }
        if result.upstreamSet {
            return GitBanner(kind: .success, message: "Pushed \(result.pushedCommits) commits · set upstream")
        }
        return GitBanner(kind: .success, message: "Pushed \(result.pushedCommits) commits")
    }

    private static func pullBanner(_ result: GitPullResult) -> GitBanner {
        if let conflict = result.conflict, conflict.hasConflicts {
            return GitBanner(kind: .warning, message: "Pull produced conflicts in \(conflict.conflictedFiles.count) files — resolve them on desktop or via an agent")
        }
        if result.updatedFiles == 0 {
            return GitBanner(kind: .success, message: "Already up to date")
        }
        return GitBanner(kind: .success, message: "Pulled — updated \(result.updatedFiles) files")
    }

    // MARK: - URL helpers (ported from web git-credential-context)

    /// Host from an https or ssh remote URL, lowercased; nil if unrecognized.
    static func extractHost(_ url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        // https://[user@]host[:port]/...
        if let match = trimmed.range(of: #"^https?://(?:[^@/]+@)?([^/:]+)"#, options: .regularExpression) {
            let host = trimmed[match]
                .replacingOccurrences(of: #"^https?://(?:[^@/]+@)?"#, with: "", options: .regularExpression)
            if !host.isEmpty { return host.lowercased() }
        }
        // git@host:owner/repo.git
        if let at = trimmed.firstIndex(of: "@") {
            let rest = trimmed[trimmed.index(after: at)...]
            if let sep = rest.firstIndex(where: { $0 == ":" || $0 == "/" }) {
                let host = rest[..<sep]
                if !host.isEmpty { return host.lowercased() }
            }
        }
        return nil
    }

    /// RFC3339 timestamp for a newly created account record (matches the web's
    /// `new Date().toISOString()`). Internal so ``GitCredentialSheet`` reuses it.
    static func iso8601Now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}

// MARK: - Supporting types

/// Severity + message for the inline operation banner. `message` is a
/// `LocalizedStringKey` so count-bearing strings localize via catalog `%lld`
/// keys; dynamic server errors are wrapped with `stringLiteral:`.
struct GitBanner: Identifiable {
    enum Kind { case success, warning, error }
    let id = UUID()
    let kind: Kind
    let message: LocalizedStringKey
}

/// A pending credential request that presents ``GitCredentialSheet``.
struct GitCredentialPrompt: Identifiable {
    enum Mode { case github, generic }
    let id = UUID()
    let mode: Mode
    /// Remote host (e.g. "github.com"), for the GitHub server URL + token link.
    let host: String?
    /// True when re-prompting after a failed retry (the sheet shows a hint).
    let isRetry: Bool
}

/// What ``GitCredentialSheet`` returns: the credentials to retry with, and (for
/// generic, non-GitHub hosts) whether to persist them as an account on success.
/// GitHub-mode credentials are validated and saved inside the sheet, so
/// `saveAfterSuccess` is false there.
struct GitCredentialOutcome {
    let credentials: GitCredentials
    let saveAfterSuccess: Bool
}

// MARK: - Status strip

/// Shown at the top of the Changes / Commits tabs: a busy row while a git
/// operation runs, otherwise the most recent ``GitBanner`` (dismissible). Driven
/// by the shared ``FolderGitModel``.
struct GitStatusStrip: View {
    let model: FolderGitModel

    var body: some View {
        Group {
            if model.isBusy {
                busyRow
            } else if let banner = model.banner {
                bannerRow(banner)
            }
        }
        .animation(Theme.Motion.chrome, value: model.isBusy)
        .animation(Theme.Motion.chrome, value: model.banner?.id)
    }

    private var busyRow: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small).tint(Theme.accent)
            Text(model.busyTitle ?? "Working…")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        // Flat fill, not `.glassEffect` — neutral glass renders as a muddy plate on
        // the light backdrop (matches the feature's flat error banners instead).
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md)
        .transition(.opacity)
    }

    private func bannerRow(_ banner: GitBanner) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon(banner.kind))
                .font(.caption)
                .foregroundStyle(tint(banner.kind))
            Text(banner.message)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.banner = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        // Flat tinted fill (mirrors CommitErrorBanner / CredentialErrorBanner) so a
        // result banner reads as a colored surface, not a frosted glass plate.
        .background(tint(banner.kind).opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md, color: tint(banner.kind).opacity(0.35))
        .transition(.opacity)
    }

    private func icon(_ kind: GitBanner.Kind) -> String {
        switch kind {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private func tint(_ kind: GitBanner.Kind) -> Color {
        switch kind {
        case .success: Color(red: 0.30, green: 0.74, blue: 0.46)
        case .warning: Theme.warning
        case .error: Theme.danger
        }
    }
}

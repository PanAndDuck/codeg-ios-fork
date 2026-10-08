import SwiftUI
import Observation

/// Version Control settings: git availability + a custom git path override, and
/// the GitHub accounts list (full-replace metadata + per-account keyring token).
@MainActor
@Observable
final class VersionControlSettingsModel {
    enum Phase: Equatable { case loading, loaded, failed(String) }

    private(set) var phase: Phase = .loading
    private(set) var git: GitDetectResult?
    var customPath = ""
    private(set) var accounts: [GitHubAccount] = []
    private(set) var testResult: GitDetectResult?
    var testing = false
    var refreshError: String?
    var toast: String?

    private let client: CodegClient?

    init(client: CodegClient?) { self.client = client }

    func load() async {
        guard let client else { phase = .failed("No server selected."); return }
        do {
            async let detect = client.detectGit()
            async let settings = client.gitSettings()
            async let accts = client.githubAccounts()
            git = try await detect
            customPath = (try await settings).customPath ?? ""
            accounts = try await accts
            phase = .loaded
            refreshError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            if case .loaded = phase { refreshError = APIError.userMessage(error) }
            else { phase = .failed(error.localizedDescription) }
        }
    }

    // MARK: - Git path

    func testCustomPath() async {
        guard let client else { return }
        let path = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        testing = true
        defer { testing = false }
        testResult = try? await client.testGitPath(path)
    }

    func saveCustomPath() async {
        guard let client else { return }
        let path = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await client.updateGitSettings(customPath: path.isEmpty ? nil : path)
            git = try await client.detectGit()   // re-detect with the new path
            toast = "Git path saved."
        } catch {
            if let message = APIError.userMessage(error) { toast = "Couldn’t save: \(message)" }
        }
    }

    // MARK: - GitHub accounts

    /// Add or update an account (full-replace metadata + token). A stable `id`
    /// (held by the editor) makes a retry after a token failure replace rather
    /// than duplicate.
    func upsert(_ account: GitHubAccount, token: String?) async throws {
        guard let client else { return }
        var list = accounts
        if account.isDefault { list = list.map { $0.with(isDefault: false) } }
        if let idx = list.firstIndex(where: { $0.id == account.id }) {
            list[idx] = account
        } else {
            list.append(account)
        }
        try await client.updateGithubAccounts(list)
        if let token, !token.isEmpty {
            try await client.saveAccountToken(accountId: account.id, token: token)
        }
        await load()
    }

    func setDefault(_ account: GitHubAccount) async {
        guard let client else { return }
        let list = accounts.map { $0.with(isDefault: $0.id == account.id) }
        do {
            try await client.updateGithubAccounts(list)
            await load()
        } catch {
            if let message = APIError.userMessage(error) { toast = "Couldn’t set default: \(message)" }
        }
    }

    func delete(_ account: GitHubAccount) async {
        guard let client else { return }
        // Delete the keyring token FIRST: if it fails the account stays intact and
        // the user can retry, rather than orphaning a server-side secret with no
        // way to clean it up.
        do {
            try await client.deleteAccountToken(accountId: account.id)
        } catch {
            if let message = APIError.userMessage(error) { toast = "Couldn’t remove token: \(message)" }
            return
        }
        let previous = accounts
        accounts.removeAll { $0.id == account.id }
        do {
            try await client.updateGithubAccounts(accounts)
            toast = "Removed \(account.username)."
        } catch {
            accounts = previous
            if let message = APIError.userMessage(error) { toast = "Couldn’t delete: \(message)" }
        }
    }
}

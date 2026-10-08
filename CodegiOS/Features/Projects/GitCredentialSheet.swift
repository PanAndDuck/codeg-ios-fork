import SwiftUI

/// Prompts for git remote credentials when a push/pull/fetch fails to
/// authenticate, then hands them back to ``FolderGitModel/withCredentialRetry(_:)``
/// to retry. Faithful port of the web `git-credential-context` dialog:
///
/// - **GitHub** hosts: a personal-access-token field (with a "Generate token"
///   link). The token is validated and saved as a GitHub account here, so a later
///   operation reuses it automatically.
/// - **Other** hosts: a username + password/token form, optionally saved as an
///   account after the operation succeeds.
///
/// Presented as `.sheet(item:)` from ``ProjectDetailView``; interactive dismissal
/// is disabled so the only outcomes are Cancel or Authenticate (both resolve the
/// model's pending continuation deterministically).
struct GitCredentialSheet: View {
    let model: FolderGitModel
    let prompt: GitCredentialPrompt

    @Environment(\.openURL) private var openURL

    @State private var token = ""
    @State private var username = ""
    @State private var password = ""
    @State private var revealSecret = false
    @State private var saveCredentials = true
    @State private var submitting = false
    @State private var error: String?

    private var isGitHub: Bool { prompt.mode == .github }
    private var serverURL: String { prompt.host.map { "https://\($0)" } ?? "https://github.com" }
    private var hostLabel: String { prompt.host ?? "github.com" }

    private var canSubmit: Bool {
        if submitting { return false }
        if isGitHub { return !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CodegBackground()
                ScrollView {
                    VStack(spacing: 18) {
                        if prompt.isRetry {
                            retryHint
                        }
                        if isGitHub {
                            githubSection
                        } else {
                            genericSection
                        }
                        if let error {
                            CredentialErrorBanner(message: error)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle(isGitHub ? "GitHub Sign-In" : "Authenticate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancelCredentials() }
                        .tint(Theme.textSecondary)
                        .disabled(submitting)
                }
            }
            .safeAreaInset(edge: .bottom) { authBar }
        }
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(true)
        // Safety net: if this sheet is torn down without Cancel/Authenticate (e.g.
        // the folder screen is popped while it's up), release the model's pending
        // continuation so the awaiting push/pull/fetch doesn't hang. Scoped to this
        // prompt's id so a re-presented prompt isn't cancelled by a stale teardown.
        .onDisappear { model.cancelCredentials(ifShowing: prompt.id) }
    }

    // MARK: - Sections

    private var retryHint: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.warning)
            Text("Authentication failed. Check your credentials and try again.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Theme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md, color: Theme.warning.opacity(0.35))
    }

    private var githubSection: some View {
        EditorSection(
            title: "Personal Access Token",
            footer: "Pushing to \(hostLabel) needs a token with repo access. It's saved as a GitHub account for next time."
        ) {
            FieldRow(label: "Token") {
                HStack(spacing: 8) {
                    secretField(placeholder: "ghp_…", text: $token)
                    Button("Generate") { generateToken() }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                        .disabled(submitting)
                }
            }
        }
    }

    private var genericSection: some View {
        EditorSection(
            title: "Credentials",
            footer: "Pushing to \(hostLabel) requires authentication. Use a personal access token as the password."
        ) {
            FieldRow(label: "Username") {
                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .submitLabel(.next)
                    .disabled(submitting)
            }
            Divider().overlay(Theme.hairline)
            FieldRow(label: "Password / Token") {
                secretField(placeholder: "Password or token", text: $password)
            }
            Divider().overlay(Theme.hairline)
            Toggle(isOn: $saveCredentials) {
                Text("Save for future operations")
                    .font(.callout)
                    .foregroundStyle(Theme.textPrimary)
            }
            .tint(Theme.accent)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .disabled(submitting)
        }
    }

    private func secretField(placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Group {
                if revealSecret {
                    TextField(placeholder, text: text)
                } else {
                    SecureField(placeholder, text: text)
                }
            }
            .font(.mono(15))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .disabled(submitting)

            Button {
                revealSecret.toggle()
            } label: {
                Image(systemName: revealSecret ? "eye.slash" : "eye")
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(revealSecret ? "Hide" : "Show")
        }
    }

    private var authBar: some View {
        PrimaryGlassButton(title: "Authenticate", systemImage: "key.fill", isLoading: submitting) {
            submit()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
        .disabled(!canSubmit)
    }

    // MARK: - Actions

    private func generateToken() {
        var components = URLComponents(string: "\(serverURL)/settings/tokens/new")
        components?.queryItems = [
            URLQueryItem(name: "description", value: "codeg"),
            URLQueryItem(name: "scopes", value: "repo,read:org,workflow,gist,read:user,user:email"),
        ]
        if let url = components?.url { openURL(url) }
    }

    private func submit() {
        guard canSubmit else { return }
        if isGitHub {
            submitGitHub()
        } else {
            let creds = GitCredentials(
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            model.submitCredentials(GitCredentialOutcome(credentials: creds, saveAfterSuccess: saveCredentials))
        }
    }

    /// Validate the token, persist it as a GitHub account (best-effort), then
    /// hand back the credentials. Mirrors the web `handleGitHubSubmit`.
    private func submitGitHub() {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        submitting = true
        error = nil
        Task {
            do {
                let validation = try await model.client.validateGithubToken(serverUrl: serverURL, token: trimmed)
                guard validation.success else {
                    error = validation.message ?? String(localized: "Invalid token.")
                    submitting = false
                    return
                }
                await saveGitHubAccount(validation: validation, token: trimmed)
                let creds = GitCredentials(username: validation.username ?? "unknown", password: trimmed)
                model.submitCredentials(GitCredentialOutcome(credentials: creds, saveAfterSuccess: false))
            } catch {
                self.error = APIError.userMessage(error)
                submitting = false
            }
        }
    }

    private func saveGitHubAccount(validation: GitHubTokenValidation, token: String) async {
        do {
            let existing = try await model.client.githubAccounts()
            let isDuplicate = existing.contains {
                $0.username == validation.username && FolderGitModel.extractHost($0.serverUrl) == prompt.host
            }
            guard !isDuplicate else { return }
            let account = GitHubAccount(
                id: UUID().uuidString,
                serverUrl: serverURL,
                username: validation.username ?? "unknown",
                scopes: validation.scopes,
                avatarUrl: validation.avatarUrl,
                isDefault: existing.isEmpty,
                createdAt: FolderGitModel.iso8601Now()
            )
            try await model.client.saveAccountToken(accountId: account.id, token: token)
            try await model.client.updateGithubAccounts(existing + [account])
        } catch {
            // Non-critical — saving the account failed but we can still authenticate.
        }
    }
}

private struct CredentialErrorBanner: View {
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

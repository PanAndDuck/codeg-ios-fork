import SwiftUI

/// Add / Edit a GitHub account. On add: enter server URL + token, Validate (which
/// fetches the username/scopes), then Save. On edit: the server/username are the
/// account's identity (read-only); only the default flag and an optional token
/// replacement (blank = keep) change. The account `id` is stable across retries
/// (so a token-save failure can be retried without creating a duplicate).
struct GitHubAccountEditorSheet: View {
    let editing: GitHubAccount?
    let client: CodegClient?
    let onSubmit: (_ account: GitHubAccount, _ token: String?) async throws -> Void

    @State private var serverUrl: String
    @State private var token = ""
    @State private var isDefault: Bool
    @State private var validation: GitHubTokenValidation?
    /// The (serverUrl, token) pair the current `validation` was produced for, so a
    /// later edit invalidates a stale success.
    @State private var validatedKey: String?
    @State private var validating = false
    @State private var isSaving = false
    @State private var saveError: String?
    private let stableId: String
    @Environment(\.dismiss) private var dismiss

    init(
        editing: GitHubAccount?,
        client: CodegClient?,
        onSubmit: @escaping (GitHubAccount, String?) async throws -> Void
    ) {
        self.editing = editing
        self.client = client
        self.onSubmit = onSubmit
        _serverUrl = State(initialValue: editing?.serverUrl ?? "https://github.com")
        _isDefault = State(initialValue: editing?.isDefault ?? false)
        stableId = editing?.id ?? UUID().uuidString
    }

    private var isEdit: Bool { editing != nil }
    private var trimmedURL: String { serverUrl.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSave: Bool {
        guard !isSaving else { return false }
        if isEdit { return true }   // toggle default and/or replace token
        // Add: a STILL-CURRENT validated token (gives us the username) is required —
        // editing the URL/token after validating invalidates the result.
        return !trimmedURL.isEmpty && !trimmedToken.isEmpty
            && validation?.success == true && validation?.username != nil
            && validatedKey == Self.key(trimmedURL, trimmedToken)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CodegBackground()
                ScrollView {
                    VStack(spacing: 18) {
                        serverSection
                        authSection
                        if isEdit { defaultSection }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle(isEdit ? "Edit Account" : "Add Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(Theme.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .tint(Theme.accent)
                        .disabled(!canSave)
                }
            }
        }
        .presentationDragIndicator(.visible)
        .alert("Couldn’t Save", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var serverSection: some View {
        EditorSection(title: "Server", footer: isEdit ? nil : "Use https://github.com, or your GitHub Enterprise URL.") {
            FieldRow(label: "Server URL") {
                if isEdit {
                    Text(serverUrl).foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("https://github.com", text: $serverUrl)
                        .font(.mono(15))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                }
            }
            if isEdit, let username = editing?.username {
                Divider().overlay(Theme.hairline)
                FieldRow(label: "Username") {
                    Text("@\(username)").foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var authSection: some View {
        EditorSection(
            title: "Personal Access Token",
            footer: isEdit ? "Leave blank to keep the stored token." : "A token with repo scope. We validate it before saving."
        ) {
            FieldRow(label: "Token") {
                SecureField(isEdit ? "Keep current" : "ghp_…", text: $token)
                    .font(.mono(15))
                    .textContentType(.password)
            }
            if !isEdit {
                Divider().overlay(Theme.hairline)
                validateRow
            }
        }
    }

    @ViewBuilder
    private var validateRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { validate() } label: {
                HStack(spacing: 8) {
                    if validating { ProgressView().controlSize(.small).tint(Theme.accent) }
                    Text(validating ? "Validating…" : "Validate Token")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .disabled(validating || trimmedURL.isEmpty || trimmedToken.isEmpty)

            if let validation {
                if validation.success {
                    Label(validation.username.map { "@\($0)" } ?? "Valid", systemImage: "checkmark.seal.fill")
                        .font(.caption).foregroundStyle(Color(red: 0.30, green: 0.78, blue: 0.38))
                    if !validation.scopes.isEmpty {
                        Text("Scopes: \(validation.scopes.joined(separator: ", "))")
                            .font(.caption2).foregroundStyle(Theme.textTertiary).lineLimit(2)
                    }
                } else {
                    Label(validation.message ?? "Invalid token", systemImage: "xmark.octagon.fill")
                        .font(.caption).foregroundStyle(Theme.danger)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var defaultSection: some View {
        EditorSection(title: "Default") {
            HStack {
                Text("Use as default account").foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                Toggle("", isOn: $isDefault).labelsHidden().tint(Theme.accent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
    }

    // MARK: - Actions

    private func validate() {
        guard let client else { return }
        let url = trimmedURL, tok = trimmedToken
        validating = true
        Task {
            let result = try? await client.validateGithubToken(serverUrl: url, token: tok)
            validation = result
            validatedKey = (result?.success == true) ? Self.key(url, tok) : nil
            validating = false
        }
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        Task {
            do {
                let account: GitHubAccount
                let tokenToSend: String?
                if let editing {
                    // A non-blank replacement token is validated before it's stored
                    // (an invalid/wrong token must not silently overwrite a good one).
                    if trimmedToken.isEmpty {
                        tokenToSend = nil
                    } else {
                        let v = try? await client?.validateGithubToken(serverUrl: editing.serverUrl, token: trimmedToken)
                        guard let v, v.success else {
                            saveError = (v?.message).flatMap { $0.isEmpty ? nil : $0 } ?? "That token isn’t valid."
                            isSaving = false
                            return
                        }
                        tokenToSend = trimmedToken
                    }
                    account = editing.with(isDefault: isDefault)
                } else {
                    guard let validation, validation.success, let username = validation.username,
                          validatedKey == Self.key(trimmedURL, trimmedToken) else {
                        saveError = "Please validate the token first."
                        isSaving = false
                        return
                    }
                    account = GitHubAccount(
                        id: stableId, serverUrl: trimmedURL, username: username,
                        scopes: validation.scopes, avatarUrl: validation.avatarUrl,
                        isDefault: isDefault, createdAt: Self.nowISO()
                    )
                    tokenToSend = trimmedToken
                }
                try await onSubmit(account, tokenToSend)
                dismiss()
            } catch {
                saveError = APIError.userMessage(error)
                isSaving = false
            }
        }
    }

    private static func key(_ url: String, _ token: String) -> String { url + "\u{0}" + token }

    private static func nowISO() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

import SwiftUI

/// Cursor settings panel (ported from the web `CursorConfigPanel`).
///
/// Unlike Kimi/Pi this is NOT self-contained: everything it edits lands in the
/// shared ``AgentDraft`` and is persisted by the host "Save", which already does
/// `acp_update_agent_env` → `acp_update_agent_config` in one pass — exactly what
/// the web panel's own Save button does by hand. The only local state is the two
/// read-only probes (`cursor-agent status` / `models`), which talk to the server
/// directly because they test the key currently on screen, not the saved one.
struct CursorConfigSection: View {
    @Binding var draft: AgentDraft
    let client: CodegClient?

    @State private var auth: CursorAuthStatus?
    @State private var authLoading = false
    @State private var copied = false

    @State private var models: [CursorModelInfo] = []
    @State private var modelsError: String?
    @State private var modelsLoading = false
    /// Latched per authentication method so switching methods re-probes (an API
    /// key and a browser login can list different catalogs).
    @State private var modelsLoaded = false

    private var divider: some View { Divider().overlay(Theme.hairline) }
    private var trimmedKey: String { draft.apiKey.trimmingCharacters(in: .whitespaces) }

    /// The credential the probes should test: the typed key in API-key mode, or
    /// empty in subscription mode (which forces the browser-login credential).
    private var probeKey: String { draft.cursorAuthMode == .custom ? trimmedKey : "" }

    private enum AuthState { case loading, missing, ok, unauthenticated }
    private var authState: AuthState {
        if authLoading && auth == nil { return .loading }
        guard let auth, auth.installed else { return .missing }
        return auth.isAuthenticated ? .ok : .unauthenticated
    }

    var body: some View {
        VStack(spacing: 16) {
            methodCard
            accountCard
            if !models.isEmpty { modelCard }
            permissionsCard
        }
        // Bake the on-screen state into `envText` up front. The panel shows Run
        // Everything ON for a fresh agent, so without this a save that touched
        // nothing else would persist an env that doesn't match what's displayed.
        // `reapply` is idempotent.
        .onAppear { draft.reapply(.cursor) }
        .task(id: draft.cursorAuthMode) {
            // Re-probe on method change: the ref-equivalent of the web's
            // mount + mode effect. Drops the stale catalog first.
            models = []
            modelsError = nil
            modelsLoaded = false
            await refreshAuth()
        }
        .task(id: TaskKey(state: authState, loaded: modelsLoaded)) {
            guard authState == .ok, !modelsLoaded, !modelsLoading else { return }
            await loadModels()
        }
    }

    /// `.task(id:)` needs one equatable key; the model fetch keys off both the
    /// resolved auth state and the loaded latch.
    private struct TaskKey: Equatable { let state: AuthState; let loaded: Bool }

    // MARK: Authentication method

    private var methodCard: some View {
        EditorSection(title: "Cursor Configuration",
                      footer: "Both methods sign in to Cursor’s own backend — cursor-agent has no custom-endpoint support, so there is no API URL to set.") {
            FieldRow(label: "Authentication Method") {
                SelectField(selection: Binding(get: { draft.cursorAuthMode },
                                               set: { draft.cursorAuthMode = $0; draft.reapply(.cursor) }),
                            options: [
                                SelectOption(value: CursorConfig.AuthMethod.subscription, label: "Official Subscription"),
                                SelectOption(value: CursorConfig.AuthMethod.custom, label: "Cursor API Key"),
                            ])
            }
            caption(draft.cursorAuthMode == .subscription
                    ? "Sign in with your Cursor account in a terminal. No credential is stored here."
                    : "A Cursor Dashboard account key for headless or server machines — an alternative to signing in.")
        }
    }

    // MARK: Account (status + credential)

    private var accountCard: some View {
        EditorSection(title: "Account") {
            statusRow
            if draft.cursorAuthMode == .subscription && authState == .unauthenticated {
                divider
                loginCommandRow
            }
            if draft.cursorAuthMode == .custom {
                divider
                FieldRow(label: "API Key") {
                    SecretField(placeholder: "key_…",
                                text: Binding(get: { draft.apiKey },
                                              set: { draft.apiKey = $0; draft.reapply(.cursor) }))
                }
                caption("Create one in the Cursor Dashboard under Integrations.")
            }
            if let error = auth?.error, !error.isEmpty {
                caption(LocalizedStringKey(stringLiteral: error), tone: Theme.danger)
            }
            if authState != .missing, authState != .loading, models.isEmpty {
                caption("Sign in to load the model list.")
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusTint)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let membership = auth?.membership, !membership.isEmpty {
                Text(membership)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.accent.opacity(0.12), in: Capsule())
            }
            Spacer(minLength: 8)
            Button { Task { await refreshAuth() } } label: {
                if authLoading {
                    ProgressView().controlSize(.small).tint(Theme.accent)
                } else {
                    Image(systemName: "arrow.clockwise").font(.system(size: 14, weight: .semibold))
                }
            }
            .tint(Theme.accent)
            .disabled(authLoading)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    /// Same status vocabulary the preflight/version rows use: accent = pass,
    /// warning amber = actionable, muted = unknown/absent.
    private var statusTint: Color {
        switch authState {
        case .ok: return Theme.accent
        case .unauthenticated: return Theme.warning
        case .missing, .loading: return Theme.textTertiary.opacity(0.5)
        }
    }

    private var statusText: LocalizedStringKey {
        switch authState {
        case .loading: return "Checking…"
        case .missing: return "cursor-agent isn’t installed"
        case .unauthenticated: return "Not signed in"
        case .ok:
            if let email = auth?.email, !email.isEmpty { return LocalizedStringKey(stringLiteral: email) }
            return "Signed in"
        }
    }

    /// The managed binary lives in codeg's cache and is not on PATH, so the panel
    /// hands over the fully-resolved command rather than a bare `cursor-agent`.
    private var loginCommandRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Run this on the machine hosting codeg, then refresh:")
                .font(.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(CursorConfig.loginCommand(binaryPath: auth?.binaryPath))
                    .font(.mono(12))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                Button {
                    UIPasteboard.general.string = CursorConfig.loginCommand(binaryPath: auth?.binaryPath)
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 13, weight: .semibold))
                }
                .tint(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 13)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { copied = false }
        }
    }

    // MARK: Model

    /// The fetched catalog, plus a saved-but-unlisted model kept as its own entry
    /// so a hand-set value still displays and isn't silently dropped on save.
    private var modelOptions: [SelectOption<String>] {
        var options = models.map { SelectOption(value: $0.id, label: $0.displayLabel) }
        let saved = draft.cursorModel.trimmingCharacters(in: .whitespaces)
        if !saved.isEmpty, !models.contains(where: { $0.id == saved }) {
            options.insert(SelectOption(value: saved, label: saved), at: 0)
        }
        return options
    }

    private var modelCard: some View {
        EditorSection(title: "Model",
                      footer: "Passed to cursor-agent as its --model flag. Leave unset to use the account default.") {
            FieldRow(label: "Default Model") {
                SelectField(selection: Binding(get: { draft.cursorModel },
                                               set: { draft.cursorModel = $0; draft.reapply(.cursor) }),
                            options: modelOptions,
                            placeholder: "Account default")
            }
            if modelsLoading {
                caption("Loading models…")
            } else if let modelsError, !modelsError.isEmpty {
                caption(LocalizedStringKey(stringLiteral: modelsError), tone: Theme.danger)
            }
        }
    }

    // MARK: Permissions

    private var permissionsCard: some View {
        EditorSection(title: "Permissions",
                      footer: "Rules and sandbox merge into ~/.cursor/cli-config.json, preserving keys the Cursor CLI wrote. Running sessions pick them up after a restart.") {
            Toggle("Run Everything", isOn: Binding(get: { draft.cursorForce },
                                                  set: { draft.cursorForce = $0; draft.reapply(.cursor) }))
                .tint(Theme.accent)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 16).padding(.vertical, 11)
            caption(draft.cursorForce
                    ? "Cursor runs commands without asking. Deny rules below still apply."
                    : "Cursor asks before running commands.")
            divider
            FieldRow(label: "Sandbox") {
                SelectField(selection: $draft.cursorSandboxMode, options: [
                    SelectOption(value: "", label: "Use default"),
                    SelectOption(value: "enabled", label: "Enabled"),
                    SelectOption(value: "disabled", label: "Disabled"),
                ])
            }
            divider
            ruleEditor(label: "Allow Rules", rules: $draft.cursorAllowRules,
                       placeholder: "Shell(ls)", addLabel: "Add allow rule", tone: Theme.textPrimary)
            divider
            ruleEditor(label: "Deny Rules", rules: $draft.cursorDenyRules,
                       placeholder: "Shell(rm)", addLabel: "Add deny rule", tone: Theme.danger)
        }
    }

    private func ruleEditor(label: LocalizedStringKey,
                            rules: Binding<[String]>,
                            placeholder: String,
                            addLabel: LocalizedStringKey,
                            tone: Color) -> some View {
        FieldRow(label: label) {
            VStack(alignment: .leading, spacing: 8) {
                // Indices are stable for the lifetime of a row edit (rows are only
                // appended or removed), and rules are freely duplicable strings, so
                // the value can't be the identity here.
                ForEach(Array(rules.wrappedValue.indices), id: \.self) { index in
                    HStack(spacing: 8) {
                        TextField(placeholder, text: Binding(
                            get: { index < rules.wrappedValue.count ? rules.wrappedValue[index] : "" },
                            set: { if index < rules.wrappedValue.count { rules.wrappedValue[index] = $0 } }
                        ))
                        .agentField()
                        .foregroundStyle(tone)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).stroke(Theme.hairline, lineWidth: 1))

                        Button {
                            rules.wrappedValue.remove(at: index)
                        } label: {
                            Image(systemName: "trash").font(.system(size: 13, weight: .semibold))
                        }
                        .tint(Theme.danger)
                    }
                }
                Button { rules.wrappedValue.append("") } label: {
                    Label(addLabel, systemImage: "plus")
                        .font(.caption.weight(.medium))
                }
                .tint(Theme.accent)
            }
        }
    }

    // MARK: Probes

    private func refreshAuth() async {
        guard let client else { return }
        authLoading = true
        defer { authLoading = false }
        // A transport failure just leaves the card in its previous state — a
        // failed *probe* reports itself through `auth.error`.
        if let status = try? await client.cursorAuthStatus(apiKey: probeKey) { auth = status }
    }

    private func loadModels() async {
        guard let client else { return }
        modelsLoading = true
        defer { modelsLoading = false }
        do {
            let result = try await client.cursorListModels(apiKey: probeKey)
            models = result.models
            modelsError = result.error
        } catch {
            modelsError = APIError.userMessage(error)
        }
        modelsLoaded = true
    }

    // MARK: Chrome

    private func caption(_ text: LocalizedStringKey, tone: Color = Theme.textTertiary) -> some View {
        Text(text)
            .font(.caption).foregroundStyle(tone)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.bottom, 12)
    }
}

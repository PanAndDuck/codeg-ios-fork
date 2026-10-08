import SwiftUI
import Observation

/// System settings: HTTP proxy, reply/UI language, default terminal shell, and a
/// read-only update check. Proxy / language / terminal each persist through their
/// own coalescing serial sender (one request in flight, latest value wins, never
/// drops the final value; reconcile to server truth on failure). The wrapped
/// `{settings:{snake_case}}` bodies are built raw by the client.
@MainActor
@Observable
final class SystemSettingsModel {
    enum Phase: Equatable { case loading, loaded, failed(String) }

    private(set) var phase: Phase = .loading

    // Proxy
    var proxyEnabled = false
    var proxyUrl = ""

    // Language
    var languageMode = "system"   // "system" | "manual"
    var language = "en"

    // Terminal
    private(set) var shellOptions: [TerminalShellOption] = []
    private(set) var resolvedShell = ""
    var selectedShellId = "system"
    var customShellPath = ""
    var probeResult: Bool?
    var probing = false

    // Update (read-only)
    private(set) var updateInfo: AppUpdateCheckResult?
    var checkingUpdate = false

    var saveError: String?
    var toast: String?

    private let client: CodegClient?

    init(client: CodegClient?) { self.client = client }

    private var customOption: TerminalShellOption? { shellOptions.first { $0.acceptsCustomPath } }

    func load() async {
        guard let client else { phase = .failed("No server selected."); return }
        do {
            async let proxy = client.systemProxySettings()
            async let lang = client.systemLanguageSettings()
            async let term = client.systemTerminalSettings()
            async let shells = client.availableTerminalShells()

            let p = try await proxy
            proxyEnabled = p.enabled
            proxyUrl = p.proxyUrl ?? ""

            let l = try await lang
            languageMode = l.mode
            language = l.language

            let sh = try await shells
            shellOptions = sh.options
            resolvedShell = sh.resolvedShell

            applyTerminal((try await term).defaultShell)
            phase = .loaded
        } catch {
            guard !APIError.isCancellation(error) else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    /// Map a stored `default_shell` to the picker selection + custom path.
    private func applyTerminal(_ defaultShell: String?) {
        guard let ds = defaultShell, !ds.isEmpty else {
            selectedShellId = shellOptions.first { $0.id == "system" }?.id ?? "system"
            customShellPath = ""
            return
        }
        if let match = shellOptions.first(where: { $0.value == ds }) {
            selectedShellId = match.id
            customShellPath = ""
        } else {
            selectedShellId = customOption?.id ?? "custom"
            customShellPath = ds
        }
    }

    // MARK: - Proxy (coalescing)

    private var proxySaving = false
    private var proxyPending = false

    func scheduleProxySave() {
        // When enabling, require a URL first (the server rejects enabled+empty);
        // once a URL is typed the next change persists it.
        if proxyEnabled && proxyUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        proxyPending = true
        Task { await drainProxy() }
    }

    private func drainProxy() async {
        guard !proxySaving, let client else { return }
        proxySaving = true
        defer { proxySaving = false }
        while proxyPending {
            proxyPending = false
            let enabled = proxyEnabled
            let url = proxyUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            do { try await client.updateSystemProxySettings(enabled: enabled, proxyUrl: url.isEmpty ? nil : url) }
            catch {
                saveError = APIError.userMessage(error)
                // Reconcile to server truth ONLY if no newer edit is queued (checked
                // around the await); otherwise let the loop send it, so a failure
                // during a concurrent edit can't drop that edit. Don't return.
                if !proxyPending, let p = try? await client.systemProxySettings(), !proxyPending {
                    proxyEnabled = p.enabled
                    proxyUrl = p.proxyUrl ?? ""
                }
            }
        }
    }

    // MARK: - Language (coalescing)

    private var languageSaving = false
    private var languagePending = false

    func scheduleLanguageSave() {
        languagePending = true
        Task { await drainLanguage() }
    }

    private func drainLanguage() async {
        guard !languageSaving, let client else { return }
        languageSaving = true
        defer { languageSaving = false }
        while languagePending {
            languagePending = false
            let mode = languageMode
            let lang = language
            do { try await client.updateSystemLanguageSettings(mode: mode, language: lang) }
            catch {
                saveError = APIError.userMessage(error)
                // Reconcile only when no newer edit is queued; never drop a
                // concurrent edit. Don't return — let the loop drain it.
                if !languagePending, let l = try? await client.systemLanguageSettings(), !languagePending {
                    languageMode = l.mode
                    language = l.language
                }
            }
        }
    }

    // MARK: - Terminal (coalescing)

    private var terminalSaving = false
    private var terminalPending = false

    /// The default_shell value for the current selection, or `.some(nil)` for the
    /// system default. Returns nil (don't save) when a custom path is required but
    /// empty.
    private func terminalValue() -> String?? {
        guard let opt = shellOptions.first(where: { $0.id == selectedShellId }) else { return .some(nil) }
        if opt.acceptsCustomPath {
            let p = customShellPath.trimmingCharacters(in: .whitespacesAndNewlines)
            return p.isEmpty ? nil : .some(p)
        }
        // System option carries no value; concrete shells carry their path.
        return .some(opt.value)
    }

    func scheduleTerminalSave() {
        guard terminalValue() != nil else { return }   // custom path required but empty
        terminalPending = true
        Task { await drainTerminal() }
    }

    private func drainTerminal() async {
        guard !terminalSaving, let client else { return }
        terminalSaving = true
        defer { terminalSaving = false }
        while terminalPending {
            terminalPending = false
            guard let value = terminalValue() else { continue }   // became empty-custom
            do { try await client.updateSystemTerminalSettings(defaultShell: value) }
            catch {
                saveError = APIError.userMessage(error)
                // Reconcile only when no newer edit is queued; never drop a
                // concurrent edit. Don't return — let the loop drain it.
                if !terminalPending, let t = try? await client.systemTerminalSettings(), !terminalPending {
                    applyTerminal(t.defaultShell)
                }
            }
        }
    }

    func probeCustomShell() async {
        guard let client else { return }
        let path = customShellPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        probing = true
        defer { probing = false }
        probeResult = try? await client.probeTerminalShellPath(path)
    }

    // MARK: - Update check (read-only)

    func checkUpdate() async {
        guard let client else { return }
        checkingUpdate = true
        defer { checkingUpdate = false }
        do { updateInfo = try await client.checkAppUpdate() }
        catch { if let message = APIError.userMessage(error) { toast = "Update check failed: \(message)" } }
    }
}

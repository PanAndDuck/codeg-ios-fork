import SwiftUI
import Observation

/// Backs the agent-options sheet: loads the mode/config catalog + current state
/// and applies the user's picks.
///
/// Source of truth is the AUTHORITATIVE live session snapshot
/// (`acp_get_session_snapshot_by_conversation`, injected as `loadSnapshot`), which
/// reflects the real chat session's current mode/config. When no live session
/// exists yet, it falls back to a server-side *probe* agent
/// (`acp_describe_agent_options`) just to enumerate the catalog (its `current_*`
/// are fresh-session defaults). The snapshot query is cheap (no spawn) and the
/// sheet auto-loads it on open; when there's no live session and no cached
/// catalog, it also auto-runs the probe (no manual "Load options" tap).
///
/// Applying targets the live *chat* connection via the injected
/// `resolveConnection` closure (which validates connection liveness — see
/// `SessionDetailViewModel.resolveConnectionForOptions`). Because `set_mode` /
/// `set_config_option` only *enqueue* the change server-side (HTTP 200 ≠ applied),
/// an apply optimistically updates the selection and then RECONCILES by polling
/// the snapshot until it reflects the change (or settles on the agent's
/// normalized value). An HTTP error — including a dead connection — reverts and
/// notices.
@MainActor
@Observable
final class AgentOptionsModel {

    enum Phase: Equatable {
        case idle              // not loaded yet — transient; prepare() auto-loads
        case loading           // probe agent starting
        case loaded            // modes/config available
        case empty             // loaded, but nothing configurable
        case failed(String)
    }

    private let client: CodegClient

    /// Injected by the owner to resolve (and cache) the shared chat connection.
    var resolveConnection: (() async throws -> String)?

    /// Injected by the owner to fetch the authoritative live session snapshot for
    /// this conversation (nil when no live session exists).
    var loadSnapshot: (() async throws -> SessionSnapshot?)?

    private(set) var phase: Phase = .idle
    private(set) var snapshot: AgentOptionsSnapshot?

    /// Current selection. Authoritative when sourced from the live snapshot; a
    /// fresh-session default when only the probe catalog is available.
    private(set) var selectedModeId: String?
    private(set) var selectedConfig: [String: String] = [:]   // configId → valueId

    /// Keys currently being applied ("mode" or a configId) so a row can spin.
    private(set) var applying: Set<String> = []

    /// Transient apply failure surfaced under the selectors.
    var errorNotice: String?

    /// Catalog cache per agent type so re-opening the sheet doesn't re-spawn a
    /// probe when there's no live session.
    private var cache: [AgentType: AgentOptionsSnapshot] = [:]

    private var agentType: AgentType?
    private var workingDir: String?
    private var loadTask: Task<Void, Never>?
    /// The cheap auto snapshot-load kicked off on `prepare`.
    private var autoLoadTask: Task<Void, Never>?
    /// Memoized chat-connection resolution, shared across concurrent applies.
    private var connectionTask: Task<String, Error>?

    /// Bounded reconcile poll after an apply (~2.3s total).
    private static let reconcileAttempts = 6

    init(client: CodegClient) {
        self.client = client
    }

    /// Call when the sheet appears. Sets context and auto-loads: a cheap
    /// authoritative snapshot first (no agent spawn) — if a live session exists the
    /// sheet populates immediately; otherwise it shows a cached catalog, or auto-
    /// runs the probe (`load()`) when there's neither.
    func prepare(agentType: AgentType, workingDir: String?) {
        // Switching agents (draft new-session picker) invalidates the previous
        // catalog + selection — clear them so the new agent's options reload clean.
        if let current = self.agentType, current != agentType {
            snapshot = nil
            selectedModeId = nil
            selectedConfig = [:]
            phase = .idle
        }
        self.agentType = agentType
        self.workingDir = workingDir
        errorNotice = nil
        // A new sheet session should re-validate the chat connection (it may have
        // gone stale since last open). Don't cancel — an in-flight apply still
        // holds its own reference to the prior task.
        connectionTask = nil
        if case .failed = phase { phase = .idle }

        autoLoadTask?.cancel()
        autoLoadTask = Task { [weak self] in
            guard let self else { return }
            // 1) Cheap authoritative snapshot first (no agent spawn).
            if let snap = try? await self.fetchSnapshot(), snap.hasSelectors {
                if Task.isCancelled { return }
                self.cache[agentType] = snap.asOptionsSnapshot
                self.applyAuthoritative(snap)
                return
            }
            if Task.isCancelled { return }
            // 2) No live session — show a previously fetched catalog if we have one
            //    (highlights are defaults, not authoritative).
            if let cached = self.cache[agentType] {
                self.applyCatalog(cached)
                return
            }
            // 3) Otherwise auto-run the probe (formerly the manual "Load options"
            //    tap) so opening the sheet loads the config on its own.
            self.load()
        }
    }

    /// Load the catalog (auto-run by `prepare()`, and by the failure "Try Again").
    /// Prefers the authoritative snapshot (no spawn); only when there's no live
    /// session does it spawn a probe agent to enumerate the catalog (uses the
    /// client's longer probe timeout).
    func load() {
        guard let agentType else { return }
        if case .loading = phase { return }
        errorNotice = nil
        // Neutral loading during the cheap snapshot re-check; switch to the
        // probe-specific phase (`.loading`) only once a probe actually starts, so
        // the "starting an agent" copy never shows for a snapshot/cache result
        // (incl. a "Try Again" where a live session has since appeared).
        phase = .idle
        loadTask?.cancel()
        let workingDir = self.workingDir
        loadTask = Task { [weak self] in
            guard let self else { return }
            if let snap = try? await self.fetchSnapshot(), snap.hasSelectors {
                if Task.isCancelled { return }
                self.cache[agentType] = snap.asOptionsSnapshot
                self.applyAuthoritative(snap)
                return
            }
            if Task.isCancelled { return }
            self.phase = .loading   // no live selectors — a probe agent is now starting
            do {
                let probe = try await self.client.describeAgentOptions(agentType: agentType, workingDir: workingDir)
                if Task.isCancelled { return }
                self.cache[agentType] = probe
                self.applyCatalog(probe)
            } catch where APIError.isCancellation(error) {
                // superseded / torn down
            } catch {
                if Task.isCancelled { return }
                self.phase = .failed(Self.describe(error))
            }
        }
    }

    private func fetchSnapshot() async throws -> SessionSnapshot? {
        guard let loadSnapshot else { return nil }
        return try await loadSnapshot()
    }

    /// Adopt authoritative current mode/config from the live snapshot (overwrites
    /// any optimistic selection — the snapshot IS the truth).
    private func applyAuthoritative(_ snap: SessionSnapshot) {
        let options = snap.asOptionsSnapshot
        snapshot = options
        selectedModeId = snap.modes?.currentModeId ?? snap.currentMode ?? selectedModeId
        for option in snap.configOptions ?? [] {
            if let current = option.kind.selectCurrentValue, !current.isEmpty {
                selectedConfig[option.id] = current
            }
        }
        phase = options.isEmpty ? .empty : .loaded
    }

    /// Adopt a probe catalog (no live session — drafts / fresh agents). Seed
    /// selections, only where the user hasn't already picked, preferring the
    /// LOCALLY CACHED last-used choice (validated against this catalog) and
    /// falling back to the catalog's fresh-session default. This is what makes a
    /// new session's options sheet open on the user's remembered mode/config.
    private func applyCatalog(_ snap: AgentOptionsSnapshot) {
        snapshot = snap
        let prefs = agentType.map { SelectorPrefsStore.prefs(for: $0) } ?? SelectorPrefs()
        if selectedModeId == nil {
            if let saved = prefs.modeId,
               snap.modes?.availableModes.contains(where: { $0.id == saved }) == true {
                selectedModeId = saved
            } else {
                selectedModeId = snap.modes?.currentModeId
            }
        }
        for option in snap.configOptions where selectedConfig[option.id] == nil {
            if let saved = prefs.configValues?[option.id], option.kind.allSelectValues.contains(saved) {
                selectedConfig[option.id] = saved
            } else if let current = option.kind.selectCurrentValue, !current.isEmpty {
                selectedConfig[option.id] = current
            }
        }
        phase = snap.isEmpty ? .empty : .loaded
    }

    // MARK: - Apply

    func selectMode(_ modeId: String) {
        guard modeId != selectedModeId, canApply("mode") else { return }
        let previous = selectedModeId
        selectedModeId = modeId   // optimistic (only after the guards pass)
        // Remember the pick per agent so the next new session starts in this mode
        // (re-applied via acp_connect's preferredModeId). Mirrors the web client.
        if let agentType { SelectorPrefsStore.saveMode(agent: agentType, modeId: modeId) }
        run(key: "mode", desired: modeId, revert: { [weak self] in self?.selectedModeId = previous }) { client, conn in
            try await client.setMode(connectionId: conn, modeId: modeId)
        }
    }

    func selectConfig(optionId: String, valueId: String) {
        guard selectedConfig[optionId] != valueId, canApply(optionId) else { return }
        let previous = selectedConfig[optionId]
        selectedConfig[optionId] = valueId   // optimistic (only after the guards pass)
        if let agentType { SelectorPrefsStore.saveConfig(agent: agentType, configId: optionId, valueId: valueId) }
        run(key: optionId, desired: valueId, revert: { [weak self] in self?.selectedConfig[optionId] = previous }) { client, conn in
            try await client.setConfigOption(connectionId: conn, configId: optionId, valueId: valueId)
        }
    }

    /// True when an apply for `key` can start: a connection resolver is wired and
    /// no apply for the same key is already in flight — so a rapid/second tap can't
    /// move the highlighted selection without sending a matching network command.
    private func canApply(_ key: String) -> Bool {
        resolveConnection != nil && !applying.contains(key)
    }

    private func run(
        key: String,
        desired: String,
        revert: @escaping () -> Void,
        action: @escaping (CodegClient, String) async throws -> Void
    ) {
        guard resolveConnection != nil else { revert(); return }
        applying.insert(key)
        errorNotice = nil
        let client = self.client
        Task { [weak self] in
            guard let self else { return }
            do {
                let conn = try await self.sharedConnection()
                try await action(client, conn)
                // Drop the memoized resolution so the NEXT apply re-validates the
                // connection's liveness (only concurrent in-flight applies, which
                // already hold this task, share one resolve).
                self.connectionTask = nil
                // HTTP 200 only means the command was enqueued — reconcile against
                // the authoritative snapshot of the EXACT connection we targeted
                // (by id, so it works even before the connection binds to the
                // conversation) before trusting the optimistic value.
                await self.reconcile(key: key, desired: desired, connectionId: conn)
            } catch where APIError.isCancellation(error) {
                revert()
                self.connectionTask = nil
            } catch {
                revert()
                self.connectionTask = nil   // re-resolve on the next apply
                self.errorNotice = Self.describe(error)
            }
            self.applying.remove(key)
        }
    }

    /// Resolve the chat connection once and share it across concurrent applies, so
    /// a rapid mode+config change can't each resolve a different connection (which
    /// would strand one setting on an orphan). The model is `@MainActor`, so the
    /// synchronous prologue here is race-free: the first caller installs the task,
    /// later callers await the same one. Cleared after each apply (so the next one
    /// re-validates liveness) and on (re)prepare / teardown.
    private func sharedConnection() async throws -> String {
        if let task = connectionTask {
            return try await task.value
        }
        guard let resolveConnection else { throw APIError.transport("Session closed.") }
        let task = Task { try await resolveConnection() }
        connectionTask = task
        return try await task.value
    }

    /// Poll the authoritative snapshot of the targeted connection until it confirms
    /// `desired` for `key`, or it settles on a different (agent-normalized) value,
    /// or we time out. Adopts the authoritative value when seen; otherwise keeps
    /// the optimistic pick. Queries by `connectionId` so it works even before the
    /// connection is bound to the conversation.
    private func reconcile(key: String, desired: String, connectionId: String) async {
        var lastSeen: String?
        for attempt in 0..<Self.reconcileAttempts {
            try? await Task.sleep(for: .milliseconds(attempt == 0 ? 350 : 400))
            if Task.isCancelled { return }
            guard let snap = try? await client.connectionSnapshot(connectionId: connectionId),
                  let current = currentValue(forKey: key, in: snap) else { continue }
            lastSeen = current
            if current == desired {
                setSelection(key: key, value: current)   // confirmed
                return
            }
        }
        // Settled without confirming the pick — adopt the last authoritative value
        // we saw (the agent may have normalized/rejected it); if we never saw one,
        // keep the optimistic pick as a best effort.
        if let lastSeen { setSelection(key: key, value: lastSeen) }
    }

    private func currentValue(forKey key: String, in snap: SessionSnapshot) -> String? {
        if key == "mode" { return snap.modes?.currentModeId ?? snap.currentMode }
        return snap.configOptions?.first { $0.id == key }?.kind.selectCurrentValue
    }

    private func setSelection(key: String, value: String) {
        if key == "mode" { selectedModeId = value } else { selectedConfig[key] = value }
    }

    func teardown() {
        loadTask?.cancel()
        loadTask = nil
        autoLoadTask?.cancel()
        autoLoadTask = nil
        connectionTask?.cancel()
        connectionTask = nil
        applying.removeAll()
    }

    private static func describe(_ error: Error) -> String {
        if let api = error as? APIError { return api.errorDescription ?? "\(api)" }
        return error.localizedDescription
    }
}

import SwiftUI
import Observation

/// Cancels the independent folder read when its screen is released. Keeping
/// ownership here avoids accessing main-actor state from the model's deinit.
private final class SessionFolderLookup {
    var task: Task<Void, Never>? {
        willSet { task?.cancel() }
    }
    deinit { task?.cancel() }
}

/// Drives the session detail screen: loads the transcript, sends prompts, and
/// consumes the live ACP event stream — mapping each event onto the in-flight
/// assistant turn. All mutable UI state lives here on the main actor, so there
/// are no data races even though the WebSocket delivers frames concurrently
/// (the consuming `Task` is main-actor isolated, so `for await` hops back to the
/// main actor on every frame).
@MainActor
@Observable
final class SessionDetailViewModel {

    // MARK: - Load phase

    enum LoadPhase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    // MARK: - Inputs

    private let client: CodegClient

    /// What this screen is bound to: an existing conversation, or a brand-new
    /// task that adopts its conversation id from the `conversation_linked`
    /// event after the first prompt.
    private enum Mode {
        case existing(conversationID: Int)
        case new(NewSessionRequest)
    }
    private let mode: Mode

    /// The bound conversation id — fixed for an existing conversation; nil for
    /// a new task until the server links one.
    private(set) var conversationID: Int?
    /// The new-task payload (nil when opened on an existing conversation).
    private(set) var newRequest: NewSessionRequest?

    /// Drives the agent-options sheet (mode + config selectors). Shares this
    /// model's chat connection so applying an option targets the same agent the
    /// next send will reuse.
    let agentOptions: AgentOptionsModel

    /// Backs the compose "+" menu's insert pickers (quick messages / experts /
    /// slash commands). Pure-text inserts — no live connection required.
    let insertModel: ComposeInsertModel

    // MARK: - Observable state

    private(set) var phase: LoadPhase = .loading

    /// Authoritative, persisted turns from the server.
    ///
    /// The `didSet` bumps `turnsVersion` on every mutation (assignment or append)
    /// so the transcript can detect a real persisted change cheaply. `@Observable`
    /// preserves the observer (same pattern as `AppModel.selectedServerID`).
    private(set) var turns: [MessageTurn] = [] {
        didSet { turnsVersion &+= 1 }
    }
    /// Monotonic version of `turns`, bumped on every mutation. A content-free
    /// signal the transcript keys its persisted-node memo on, so streamed tokens
    /// no longer force a re-hash of every visible turn's full text (`MessageTurn`
    /// is content-`Hashable`) just to rebuild the node list.
    private(set) var turnsVersion = 0
    /// Optimistic user turns awaiting persistence (spliced out on re-fetch).
    private(set) var pendingUserTurns: [MessageTurn] = []
    /// The assistant reply currently streaming, if any.
    private(set) var liveTurn: LiveTurn?
    /// Whether `liveTurn` was rebuilt from a reattach snapshot (vs. created by a
    /// local send). On reattach the snapshot's `live_message` is the COMPLETE
    /// in-flight reply, but the agent CLI asynchronously persists a PARTIAL copy
    /// of that same reply into `turns` while it streams — so the transcript must
    /// hide the persisted partial to avoid double-rendering the reply (see
    /// `TranscriptTimeline.buildPersisted`'s `suppressInFlight`). False on the send
    /// path, where the optimistic prompt lives in `pendingUserTurns` and `turns`
    /// carries no trailing in-flight reply to hide. Reset on every send (the one
    /// chokepoint that creates a send live turn), set on every reattach build.
    private(set) var liveTurnFromReattach = false

    /// A pending permission request — or ExitPlanMode — awaiting the user's
    /// choice. Rendered as a card above the compose bar; nil when none is pending.
    private(set) var pendingPermission: PendingPermission?
    /// A pending `ask_user_question` awaiting the user's answers.
    private(set) var pendingQuestion: PendingQuestion?
    /// A pending Grok `exit_plan_mode` awaiting approve / request-changes / abandon.
    private(set) var pendingPlanApproval: PendingPlanApproval?
    /// Revision notes waiting to be sent as a follow-up prompt after a
    /// "request changes" decision (see ``answerPlanApproval(decision:feedback:)``).
    private var pendingPlanFollowUp: String?

    private(set) var summary: ConversationSummary?
    private(set) var sessionStats: SessionStats?
    private(set) var folder: FolderDetail?

    /// The working tree's current git branch (for `folder`), shown + checkmarked
    /// in the branch selector. Seeded from conversation/folder metadata and
    /// updated optimistically on checkout / new-branch.
    private(set) var currentBranch: String?

    // MARK: - Draft new-session selection

    /// The draft's chosen agent (new session only; nil for existing). The
    /// authoritative agent for a linked/existing conversation is the summary's.
    private(set) var selectedAgent: AgentType?
    /// Agents offered in the draft's in-page picker (narrowed to installed/enabled).
    private(set) var availableAgents: [AgentType] = AgentType.allCases
    private(set) var agentNames = AgentDisplayNames()
    /// Folders offered in the draft's in-page picker.
    private(set) var availableFolders: [FolderDetail] = []
    /// The full folder set (`list_all_folder_details`), kept so the branch switcher
    /// can resolve a worktree's root and locate a registered target folder by id.
    private(set) var allFolders: [FolderDetail] = []
    /// True once a draft's first send begins — locks the agent/folder pickers.
    private(set) var hasStartedFirstSend = false

    /// Compose-bar text.
    var draft: String = ""

    /// Images staged for the next prompt (added via the "+" menu). Cleared when
    /// the optimistic turn is posted; restored if that send is rolled back.
    private(set) var attachments: [Attachment] = []

    var canAttachMore: Bool {
        attachments.count < AttachmentPrep.maxCount
            && attachments.reduce(0) { $0 + $1.byteCount } < AttachmentPrep.maxTotalBytes
    }

    /// Coarse phase of an in-flight send, for the compose status line.
    enum SendState: Equatable {
        case idle
        case connecting
        case thinking
        case running(tool: String)
        case error(String)
    }
    private(set) var sendState: SendState = .idle

    /// A transient, non-fatal notice (e.g. "a turn is already running").
    var notice: String?

    /// Monotonic token used to scroll-to-bottom; bump it to request a scroll.
    /// The transcript follows this *only while pinned to the bottom* (so streamed
    /// tokens don't yank a user who has scrolled up to read).
    private(set) var scrollTick: Int = 0
    /// Monotonic token that *forces* a re-pin to the bottom regardless of the
    /// user's current scroll position — bumped on the user's own send and on
    /// initial load, where landing at the latest message is always intended.
    private(set) var stickTick: Int = 0
    /// Whether the transcript viewport is parked at the bottom. Reported by the
    /// transcript as the user scrolls; drives the floating "jump to latest" button
    /// (shown when false). Starts true (a fresh open lands at the latest message).
    private(set) var isPinnedToBottom = true
    /// Monotonic token bumped once each time a reply *successfully* finalizes, so
    /// the view can fire a single success haptic. Distinct from `sendState`
    /// reaching `.idle`, which also happens on a pre-acceptance rollback (that
    /// path must NOT feel like success). The error counterpart is `sendState`
    /// transitioning to `.error`, which only `failLive` sets.
    private(set) var completedTurnTick: Int = 0
    /// Monotonic token bumped only when the *user* toggles pin / status, so the
    /// view fires a selection haptic on the action itself. Keying the haptic on the
    /// derived `isPinned` / `currentStatus` instead mis-fires on the async `summary`
    /// load (nil → value), buzzing on every session open.
    private(set) var userToggleTick: Int = 0

    // MARK: - Streaming internals

    private var connectionID: String?
    /// The conversation row THIS draft's first send created up front (via
    /// `create_conversation`). Held until the prompt is accepted; if the send is
    /// rolled back before then, this row is deleted so no empty conversation
    /// lingers on other clients and the draft's pickers re-open.
    private var draftCreatedConversationID: Int?
    private var stream: EventStream?
    /// The outer send pipeline (resolve connection → open stream → prompt).
    private var sendTask: Task<Void, Never>?
    /// The long-lived loop consuming `stream.frames`.
    private var consumerTask: Task<Void, Never>?
    private let subscriptionID = UUID().uuidString
    /// Guards against double-finalizing a turn from racing terminal events.
    private var isTurnActive = false
    /// Bumped every time a new stream is opened. A consumer loop captures the
    /// value at spawn and ignores its own terminal frames once superseded — so
    /// closing an old stream during a stale-connection retry can't end the turn.
    private var streamGeneration = 0
    /// Pending silent reconnect after a transient socket drop (see
    /// `scheduleReconnect`). Cancelled by `closeStream`.
    private var reconnectTask: Task<Void, Never>?
    private var reconnectSchedule = ReconnectSchedule()
    private var seqTracker = SeqTracker()
    private var attachDeadlineTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var touchTask: Task<Void, Never>?
    private var lastFrameAt = ContinuousClock.now
    private var isDiscoveringLive = false
    private var isScreenVisible = false
    private(set) var isReconnecting = false
    private(set) var recoveryMessage: String?
    private var turnReconciliation: TurnReconciliation?
    private var reconciliationAttempts = 0
    private var promptClientMessageID: String?
    private var promptRequestStarted = false
    private var promptRequestInFlight = false
    private var observedPromptAcceptance = false
    private var sendPipelineID: String?

    var reconnectAttempt: Int { reconnectSchedule.attempt }
    var showsRecoveryBanner: Bool { isReconnecting && reconnectAttempt >= 6 }

    private init(client: CodegClient, mode: Mode) {
        self.client = client
        self.mode = mode
        switch mode {
        case .existing(let id):
            self.conversationID = id
        case .new(let request):
            self.newRequest = request
            // Agent/folder are chosen in-page (from the agent button in the
            // navigation bar); their defaults are resolved in `load()` from the
            // server's folder + agent lists, honoring any preselected folder.
        }
        // Initialize both child models BEFORE wiring any closures: the closures
        // below capture `self`, which Swift only allows once every stored property
        // is initialized.
        self.agentOptions = AgentOptionsModel(client: client)
        self.insertModel = ComposeInsertModel(client: client)
        // Apply actions resolve (and cache) the same chat connection the send
        // flow uses, so a mode/config change targets the agent the next prompt
        // will reuse — and never spawns a second one.
        agentOptions.resolveConnection = { [weak self] in
            guard let self else { throw APIError.transport("Session closed.") }
            return try await self.resolveConnectionForOptions()
        }
        // The authoritative current mode/config for this conversation's live
        // session (nil when none is live). Used to load the sheet and to reconcile
        // after an apply, since the set_* routes only enqueue the change.
        agentOptions.loadSnapshot = { [weak self] in
            guard let self, let id = self.conversationID else { return nil }
            return try await self.client.sessionSnapshot(conversationId: id)
        }

        // Quick messages + experts are connection-independent catalog reads.
        // Slash commands come from the cheap by-conversation snapshot (empty until
        // a connection binds — no agent is spawned to list them).
        insertModel.loadQuickMessagesAction = { [weak self] in
            guard let self else { return [] }
            return try await self.client.quickMessages()
        }
        insertModel.loadExpertsAction = { [weak self] in
            guard let self else { return [] }
            return try await self.client.experts(agentType: self.agentTypeForUI)
        }
        insertModel.loadBuiltInExpertsAction = { [weak self] in
            guard let self else { return [] }
            return try await self.client.builtInExperts()
        }
        insertModel.loadCommandsAction = { [weak self] in
            guard let self, let id = self.conversationID else { return [] }
            return try await self.client.sessionSnapshot(conversationId: id)?.availableCommands ?? []
        }
        // Backs the compose bar's inline `@`-mention popup — the same catalog
        // read `AgentsSettingsModel` uses, independent of any live connection.
        insertModel.loadAgentsAction = { [weak self] in
            guard let self else { return [] }
            let agents = try await self.client.listAgents()
            self.agentNames = AgentDisplayNames(agents: agents)
            return agents
        }

    }

    convenience init(client: CodegClient, conversationID: Int) {
        self.init(client: client, mode: .existing(conversationID: conversationID))
    }

    /// A brand-new task: `load()` immediately fires the first prompt composed
    /// in the new-task sheet, and the screen adopts the conversation id the
    /// server links — so the very first reply streams like any other turn.
    convenience init(client: CodegClient, newSession request: NewSessionRequest) {
        self.init(client: client, mode: .new(request))
    }

    // MARK: - Derived

    /// In flight only while the live turn is still streaming. A finalized,
    /// errored, or cancelled live turn stays on screen but is no longer "in
    /// flight", so the compose bar returns to its send state. (Reading the live
    /// turn's `isStreaming` here lets SwiftUI track it transitively.)
    var isInFlight: Bool { liveTurn?.isStreaming == true }

    /// True when there is no content at all to show in the loaded state.
    var isEmptyTranscript: Bool {
        turns.isEmpty && pendingUserTurns.isEmpty && liveTurn == nil
    }

    /// Whether this screen started as a new task (vs. an existing conversation).
    var isNewSession: Bool { newRequest != nil }

    /// The draft's agent/folder are still editable: a new session whose first
    /// send hasn't started yet (after that the conversation is being created).
    var isDraftEditable: Bool { isNewSession && !hasStartedFirstSend }

    /// The agent identity for UI + connection purposes: the loaded summary's
    /// (existing / linked), else the draft's chosen agent.
    var agentTypeForUI: AgentType {
        summary?.agentType ?? selectedAgent ?? .claudeCode
    }

    // MARK: - Load

    /// Guards the one-time draft option load so a re-run of `.task` can't refetch.
    private var didLoadDraftOptions = false

    private var loadedWindow: ConversationDetail?
    private var windowRevision = 0
    private var detailFetchGeneration = 0
    @ObservationIgnored private let folderLookup = SessionFolderLookup()
    private(set) var isLoadingEarlierTurns = false
    private(set) var earlierTurnsError: String?
    /// A compaction reset must also reset the view's local render window.
    private(set) var historyResetTick = 0
    var hasEarlierTurns: Bool { loadedWindow?.hasEarlierTurns == true }

    private var transcriptTotal: Int {
        max(loadedWindow?.totalTurns ?? 0, (loadedWindow?.loadedTurnsOffset ?? 0) + turns.count)
    }

    /// Fetch outside the main actor via CodegClient's async transport/decoder.
    /// A page may prepend while the request is in flight; retry from its new
    /// offset rather than silently discarding that newly loaded history.
    private func fetchWindowedDetail(id: Int, forceTail: Bool = false) async throws -> ConversationDetail {
        detailFetchGeneration &+= 1
        let generation = detailFetchGeneration
        while true {
            try Task.checkCancellation()
            let revision = windowRevision
            let current = loadedWindow
            let selector: ConversationTurnWindow
            if !forceTail, let current, current.isWindowed {
                selector = .fromIndex(current.loadedTurnsOffset)
            } else {
                selector = .tail(60)
            }
            var detail = try await withNetworkRetry { try await client.conversationDetail(id: id, window: selector) }
            guard generation == detailFetchGeneration else { throw CancellationError() }
            if revision != windowRevision { continue }
            if !forceTail, TurnWindowMerger.refreshing(detail, current: current) == nil {
                detail = try await withNetworkRetry { try await client.conversationDetail(id: id, window: .tail(60)) }
                guard generation == detailFetchGeneration else { throw CancellationError() }
                if revision != windowRevision { continue }
            }
            return detail
        }
    }

    private func adoptTranscript(_ detail: ConversationDetail, prepending: Bool = false) {
        if !prepending, TurnWindowMerger.refreshing(detail, current: loadedWindow) == nil {
            historyResetTick &+= 1
        }
        loadedWindow = detail
        windowRevision &+= 1
        turns = detail.turns
        earlierTurnsError = nil
    }

    /// Folder-dependent controls fill in independently of the transcript. Keep
    /// previous folder data on failure and retry on the next foreground sync.
    private func refreshFoldersLazily() {
        let client = client
        folderLookup.task = Task { [weak self] in
            guard let folders = try? await withNetworkRetry({ try await client.listFolders() }),
                  !Task.isCancelled, let self else { return }
            self.allFolders = folders
            self.folder = folders.first { $0.id == self.summary?.folderId }
            self.currentBranch = self.summary?.gitBranch ?? self.folder?.gitBranch
        }
    }

    func loadEarlierTurns(beforePrepend: @MainActor () -> Void = {}) async {
        guard !isLoadingEarlierTurns, let id = conversationID,
              var current = loadedWindow, current.hasEarlierTurns else { return }
        isLoadingEarlierTurns = true
        earlierTurnsError = nil
        defer { isLoadingEarlierTurns = false }
        let revision = windowRevision
        do {
            let page = try await withNetworkRetry {
                try await client.conversationTurns(id: id, beforeIndex: current.loadedTurnsOffset, limit: 60)
            }
            guard !Task.isCancelled, revision == windowRevision else { return }
            // Preserve any locally promoted reply while older history is loading.
            current.turns = turns
            let version = turnsVersion
            let snapshot = current
            let merged = await Task.detached(priority: .userInitiated) {
                TurnWindowMerger.prepending(page, to: snapshot)
            }.value
            guard !Task.isCancelled, revision == windowRevision, version == turnsVersion else { return }
            if let merged {
                // The reader may have moved while HTTP/decode/merge was in flight.
                // Capture only for a validated page, immediately before publishing it.
                beforePrepend()
                adoptTranscript(merged, prepending: true)
            } else {
                let tail = try await fetchWindowedDetail(id: id, forceTail: true)
                historyResetTick &+= 1
                adoptTranscript(tail)
                summary = tail.summary
                sessionStats = tail.sessionStats ?? sessionStats
            }
        } catch {
            if !Task.isCancelled { earlierTurnsError = APIError.userMessage(error) }
        }
    }

    func load() async {
        switch mode {
        case .existing(let id):
            phase = .loading
            await syncExisting(id: id, stickToBottom: true)

        case .new(let request):
            // A blank draft: show the composer immediately, then populate the
            // folder + agent lists so the in-page pickers (the nav-bar agent
            // button) are ready. Nothing is sent until the user writes + taps send.
            phase = .loaded
            guard !didLoadDraftOptions else { return }
            didLoadDraftOptions = true
            await loadDraftOptions(preselectedFolderID: request.preselectedFolderID)
        }
    }

    /// Re-sync an already-loaded, server-linked conversation: re-fetch its detail
    /// and reattach if a turn is live. Shared by the initial `load()` (which shows
    /// the loading spinner first) and `refreshOnForeground()` (which does not, so
    /// resuming the app doesn't flash the transcript away and back).
    private func syncExisting(id: Int, stickToBottom: Bool) async {
        refreshFoldersLazily()
        do {
            let detail = try await fetchWindowedDetail(id: id)

            summary = detail.summary
            adoptTranscript(detail)
            sessionStats = detail.sessionStats
            folder = allFolders.first { $0.id == detail.summary.folderId }
            currentBranch = detail.summary.gitBranch ?? folder?.gitBranch
            insertModel.agentType = detail.summary.agentType
            // Built-in sessions may delegate to custom agents too. Load their
            // display names without delaying the transcript.
            insertModel.loadAgentsIfNeeded()
            phase = .loaded
            if stickToBottom { requestStickToBottom() }
            // If a turn is still running on this session (started here earlier,
            // from codeg web, or before an app relaunch), attach so it streams
            // live and any pending permission/question card surfaces.
            //
            // Two signals say "a turn is in flight", and we trust EITHER:
            //   • `in_flight_user_turn_id` — precise, but the server only stamps
            //     it when the persisted tail is `[…, User]` or `[…, User,
            //     Assistant]` (see `apply_in_flight_message_id`); it goes nil the
            //     moment the agent persists a second trailing assistant turn
            //     mid-stream — which is exactly what plan mode does (a plan/
            //     reasoning turn, then the partial reply). That nil would strand a
            //     genuinely-streaming session on a static transcript.
            //   • row `status == .inProgress` — coarser but RELIABLE: set
            //     unconditionally when the turn starts and cleared only on
            //     `TurnComplete`, so it stays true for the whole turn (including
            //     while blocked on an ExitPlanMode confirmation).
            // Treating either as live makes reattach retry through a transient
            // discovery miss; the snapshot then decides what's actually running.
            let serverSaysLive = detail.inFlightUserTurnId != nil
                || detail.summary.status == .inProgress
            await reattachIfLive(serverSaysLive: serverSaysLive)
        } catch {
            // A foreground refresh failing silently leaves the existing transcript
            // on screen (better than replacing a working view with an error for a
            // transient network blip); the initial `load()` path, which has nothing
            // to fall back to, is the one that needs `phase = .failed`.
            if phase != .loaded, !Task.isCancelled, let message = APIError.userMessage(error) {
                phase = .failed(message)
            }
        }
    }

    /// Re-sync linked sessions (including a draft after its first send) when the
    /// app returns to the foreground. Keep pre-prompt sends intact.
    ///
    /// Two different recoveries, picked by whether a turn was actually live:
    /// a turn that was streaming is reconnected IN PLACE by
    /// `resumeStreamAfterForeground()` (the same `liveTurn`/connection, so
    /// nothing it already streamed is lost or duplicated); an idle session
    /// instead gets a full re-fetch, since nothing here would otherwise notice
    /// e.g. a rename or a message sent from another client while we were away.
    func refreshOnForeground() async {
        guard phase == .loaded else { return }
        // Resolve/create/attach can still be in flight before isTurnActive.
        // Foreground refresh must never cancel or replace that send pipeline.
        guard sendPipelineID == nil || isTurnActive else { return }
        if isTurnActive || isDiscoveringLive {
            resumeStreamAfterForeground()
            return
        }
        guard let id = conversationID else { return }
        discardStaleLiveState()
        await syncExisting(id: id, stickToBottom: false)
    }

    /// Drop local tracking of a live turn WITHOUT telling the server to cancel it
    /// (unlike `cancel()`) — the turn may genuinely still be running; only our
    /// view of it (built from a socket iOS suspended while backgrounded) is
    /// stale. `reattachIfLive`, called right after, re-discovers the true state:
    /// a fresh stream if it's still going, or nothing further if the server-
    /// fetched `turns` already carry its finished reply.
    private func discardStaleLiveState() {
        if let live = liveTurn, !live.isStreaming { promoteUnreconciled(live) }
        isTurnActive = false
        isDiscoveringLive = false
        isReconnecting = false
        recoveryMessage = nil
        closeStream()
        liveTurn = nil
        liveTurnFromReattach = false
        clearInteractivePrompts()
        sendState = .idle
    }

    /// Populate the draft's folder/agent lists and pick sensible defaults
    /// (preselected folder → most-recent folder; its default agent → first
    /// installed). Failures leave the full `AgentType` fallback in place.
    private func loadDraftOptions(preselectedFolderID: Int?) async {
        // The picker lists top-level open folders only (a new session shouldn't
        // target a worktree directly). The full set resolves a preselected folder
        // that the picker omits — e.g. a worktree the branch switcher just opened a
        // draft in.
        async let openReq = client.listOpenFolders()
        async let allReq = client.listFolders()

        // Narrow agents to what the server actually has installed + enabled.
        if let agents = try? await client.listAgents() {
            agentNames = AgentDisplayNames(agents: agents)
            let usable = agents.filter { $0.available && $0.enabled }
                .sorted { $0.sortOrder < $1.sortOrder }
                .map(\.agentType)
            var deduped: [AgentType] = []
            for agent in usable where !deduped.contains(agent) { deduped.append(agent) }
            if !deduped.isEmpty { availableAgents = deduped }
        }

        let open = (try? await openReq) ?? []
        let all = (try? await allReq) ?? []
        allFolders = all
        availableFolders = FolderVisibility.filterTopLevel(open)
            .sorted { $0.lastOpenedAt > $1.lastOpenedAt }
        if folder == nil {
            folder = all.first { $0.id == preselectedFolderID } ?? availableFolders.first
        }
        currentBranch = folder?.gitBranch
        if selectedAgent == nil {
            if let preferred = folder?.defaultAgentType, availableAgents.contains(preferred) {
                selectedAgent = preferred
            } else {
                selectedAgent = availableAgents.first
            }
        }
        if let agent = selectedAgent { insertModel.agentType = agent }
    }

    // MARK: - Draft selection (new session only)

    /// Change the draft's agent before the first send. A different agent needs a
    /// different connection, so any one resolved by the options sheet is dropped.
    func selectAgent(_ agent: AgentType) {
        guard isDraftEditable, agent != selectedAgent else { return }
        selectedAgent = agent
        insertModel.agentType = agent
        resetDraftConnection()
    }

    /// Change the draft's folder before the first send. The folder is the agent's
    /// working dir, so a change likewise invalidates any resolved connection.
    func selectFolder(_ newFolder: FolderDetail) {
        guard isDraftEditable, newFolder.id != folder?.id else { return }
        folder = newFolder
        currentBranch = newFolder.gitBranch
        resetDraftConnection()
    }

    /// Drop a connection the options sheet resolved before any send, so the next
    /// option-apply / first prompt re-resolves against the new agent/folder.
    private func resetDraftConnection() {
        connectionID = nil
        agentOptions.teardown()
    }

    // MARK: - Git branch (selector)

    /// List the folder's branches for the branch selector. Returns nil when there
    /// is no folder path (no git context) or the call fails (surfaced via notice).
    /// Also refreshes the current-branch label opportunistically.
    func loadBranches() async -> GitBranchList? {
        guard let path = folder?.path else { return nil }
        do {
            let list = try await client.gitListAllBranches(path: path)
            if let cur = try? await client.gitCurrentBranch(path: path), !cur.isEmpty {
                currentBranch = cur
            }
            return list
        } catch {
            notice = APIError.userMessage(error)
            return nil
        }
    }

    /// The folder name to show in the branch/workspace surface: the ROOT repo's
    /// name when this conversation lives in a worktree (git ops still target the
    /// worktree's own `path`), else the folder's own name. Mirrors the web's
    /// `resolveFolderDisplayName`.
    var displayFolderName: String? {
        guard let folder else { return nil }
        return FolderVisibility.displayName(of: folder, in: allFolders)
    }

    /// Switch to `branch`, worktree-aware (web parity, `planBranchSwitch`):
    /// - the branch isn't checked out anywhere (or it's a remote pick) → `git
    ///   checkout` in the repo root (in place when we're already in the root);
    /// - it lives in another (registered or unregistered) worktree → open a NEW
    ///   draft session in that folder rather than mutating this conversation.
    ///
    /// Returns the navigation intent for the caller (the view performs the actual
    /// navigation since the view model has no nav handle). Surfaces failures via
    /// `notice`.
    func switchBranch(_ branch: String, isRemote: Bool) async -> BranchSwitchOutcome {
        guard let active = folder else { return .failed }
        if branch == currentBranch { return .noop }

        // Find where the branch is checked out (skip for a remote pick — those
        // always check out fresh in the root).
        let resolution: WorktreeResolution? = isRemote
            ? nil
            : try? await client.resolveWorktreeFolder(repoPath: active.path, branch: branch)
        let plan = FolderVisibility.planBranchSwitch(
            active: active, resolution: resolution, allFolders: allFolders, isRemote: isRemote
        )

        switch plan {
        case .noop:
            return .noop

        case .navigateRegistered(let folderId):
            // Already a registered folder — make sure it's open, then navigate.
            if let target = allFolders.first(where: { $0.id == folderId }) {
                _ = try? await client.openFolder(path: target.path)
            }
            NotificationCenter.default.post(name: .foldersDidChange, object: nil)
            return .openSession(folderId: folderId)

        case .navigateExternal(let path, let rootId):
            // Worktree dir not registered yet — register it (parented to the root),
            // then navigate into it.
            let detail: FolderDetail
            do {
                detail = try await client.openWorktreeFolder(path: path, sourceFolderId: rootId)
            } catch {
                notice = APIError.userMessage(error)
                return .failed
            }
            NotificationCenter.default.post(name: .foldersDidChange, object: nil)
            return .openSession(folderId: detail.id)

        case .checkoutInRoot(let root):
            do {
                try await client.gitCheckout(path: root.path, branchName: branch)
            } catch {
                guard !APIError.isCancellation(error) else { return .failed }
                // A plain `git checkout` is refused by git when the branch is
                // already checked out in another worktree ("fatal: '<b>' is already
                // used by worktree at '<path>'"). We only land here when resolution
                // was skipped (a remote pick) or was unavailable, so the branch was
                // never routed to its worktree. Recover the way the web's resolve
                // step would have — locate that worktree and open a session in it —
                // instead of surfacing a dead-end checkout failure. A genuine
                // failure (e.g. a dirty working tree) yields nil and is surfaced.
                if let outcome = await recoverFromWorktreeCheckout(branch: branch, root: root, error: error) {
                    return outcome
                }
                notice = APIError.userMessage(error)
                return .failed
            }
            if root.id == active.id {
                // In place — reflect the ACTUAL resulting HEAD (a remote ref like
                // `origin/x` lands on local `x`).
                if let actual = try? await client.gitCurrentBranch(path: root.path), !actual.isEmpty {
                    currentBranch = actual
                } else {
                    currentBranch = branch
                }
                return .switchedInPlace
            }
            // We were inside a worktree; the checkout happened in the root → open a
            // session there so the user lands on the branch they picked.
            NotificationCenter.default.post(name: .foldersDidChange, object: nil)
            return .openSession(folderId: root.id)
        }
    }

    /// Recover from a `git checkout` that git refused because `branch` is already
    /// checked out in a worktree. Locates that worktree and returns a navigation
    /// intent into it, mirroring what the web's resolve step does up front. Returns
    /// nil when the failure was something else (e.g. a dirty tree) so the caller
    /// surfaces the real error.
    private func recoverFromWorktreeCheckout(branch: String, root: FolderDetail, error: Error) async -> BranchSwitchOutcome? {
        // Preferred: ask the server where the branch lives. This works no matter how
        // we got here — notably a remote ref whose local branch sits in a worktree,
        // where the up-front resolution was deliberately skipped.
        if let resolution = try? await client.resolveWorktreeFolder(repoPath: root.path, branch: branch),
           let path = resolution.path {
            return await openWorktreeSession(path: path, folderId: resolution.folderId, root: root)
        }
        // Fallback for servers without `resolve_worktree_folder`: git names the
        // occupying worktree in its error ("… already used by worktree at '<path>'").
        let detail = (error as? APIError)?.debugDescription ?? error.localizedDescription
        if let path = Self.worktreePath(fromCheckoutError: detail) {
            return await openWorktreeSession(path: path, folderId: nil, root: root)
        }
        return nil
    }

    /// Open (registering if needed) the folder backing the worktree at `path` and
    /// return the intent to start a session there. `folderId` is the already-known
    /// registered folder, if resolution provided one.
    private func openWorktreeSession(path: String, folderId: Int?, root: FolderDetail) async -> BranchSwitchOutcome? {
        if let folderId, let target = allFolders.first(where: { $0.id == folderId }) {
            _ = try? await client.openFolder(path: target.path)
            NotificationCenter.default.post(name: .foldersDidChange, object: nil)
            return .openSession(folderId: folderId)
        }
        guard let detail = try? await client.openWorktreeFolder(path: path, sourceFolderId: root.id) else {
            return nil
        }
        NotificationCenter.default.post(name: .foldersDidChange, object: nil)
        return .openSession(folderId: detail.id)
    }

    /// Extract the worktree path from git's "already used by worktree at '<path>'"
    /// checkout error, or nil when the message isn't that collision (so a genuine
    /// failure like a dirty tree isn't mistaken for one).
    static func worktreePath(fromCheckoutError message: String) -> String? {
        guard message.contains("already used by worktree") else { return nil }
        guard let start = message.range(of: "at '")?.upperBound,
              let end = message[start...].firstIndex(of: "'") else { return nil }
        let path = String(message[start..<end])
        return path.isEmpty ? nil : path
    }

    /// Create `branch` (off `startPoint`; nil = current HEAD) and check it out.
    func createBranch(_ branch: String, from startPoint: String?) async -> Bool {
        let name = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path = folder?.path, !name.isEmpty else { return false }
        do {
            try await client.gitNewBranch(path: path, branchName: name, startPoint: startPoint)
            currentBranch = name
            return true
        } catch {
            notice = APIError.userMessage(error)
            return false
        }
    }

    // MARK: - Attachments

    /// Append newly-prepared images, enforcing both a count cap and an aggregate
    /// byte budget (so the base64 prompt payload stays under the server's body
    /// limit), and surfacing a notice if any were dropped.
    func addAttachments(_ newAttachments: [Attachment]) {
        guard !newAttachments.isEmpty else { return }
        var currentBytes = attachments.reduce(0) { $0 + $1.byteCount }
        var droppedForCount = false
        var droppedForSize = false
        for attachment in newAttachments {
            if attachments.count >= AttachmentPrep.maxCount {
                droppedForCount = true
                break
            }
            if currentBytes + attachment.byteCount > AttachmentPrep.maxTotalBytes {
                droppedForSize = true
                continue
            }
            attachments.append(attachment)
            currentBytes += attachment.byteCount
        }
        if droppedForCount {
            notice = "You can attach up to \(AttachmentPrep.maxCount) images."
        } else if droppedForSize {
            notice = "Some images were too large to attach."
        }
    }

    func removeAttachment(_ id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    // MARK: - Send

    /// Send the composer's draft — or, with `overrideText`, a prompt the app itself
    /// generated (today: the revision notes from a plan-approval "request changes",
    /// which Grok expects as a follow-up turn). An override never touches the
    /// composer's draft or attachments, so a message the user was typing survives;
    /// a rejected send still restores the text into the composer so it isn't lost.
    func send(overrideText: String? = nil) {
        let text = (overrideText ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        let sending = overrideText == nil ? attachments : []
        guard (!text.isEmpty || !sending.isEmpty), !isInFlight else { return }
        // Identity comes from the loaded summary (existing conversation) or the
        // new-task request; without either the screen isn't ready to send.
        guard summary != nil || newRequest != nil else { return }
        // A draft (no linked summary yet) needs a folder + agent before it can
        // connect; lock the pickers the moment its first send begins.
        if summary == nil {
            guard folder != nil, selectedAgent != nil else {
                notice = "Pick a folder and agent first."
                return
            }
            hasStartedFirstSend = true
        }

        // If the previous reply finished streaming but never reconciled into the
        // transcript (slow server persistence, or refreshAfterTurn still retrying),
        // fold it into `turns` before we reuse the `liveTurn` slot — otherwise this
        // send would drop that reply from view until the next reconcile.
        if let prior = liveTurn, !prior.isStreaming, !prior.isEmpty {
            promoteUnreconciled(prior)
        }
        turnReconciliation = TurnReconciliation(totalTurns: transcriptTotal, turns: turns)
        reconciliationAttempts = 0

        // 1) Optimistic user turn (text first, then images) + clear the composer.
        var blocks: [ContentBlock] = []
        if !text.isEmpty { blocks.append(.text(text)) }
        blocks.append(contentsOf: sending.map { $0.optimisticBlock })
        let userTurn = MessageTurn(
            id: "pending-\(UUID().uuidString)",
            role: .user,
            blocks: blocks,
            timestamp: Date()
        )
        pendingUserTurns.append(userTurn)
        if overrideText == nil {
            draft = ""
            attachments = []
        }

        // 2) Live assistant placeholder.
        let live = LiveTurn()
        liveTurn = live
        // A locally-sent turn: the reply streams into this placeholder and the
        // prompt lives in `pendingUserTurns`, so `turns` carries no persisted
        // in-flight reply to suppress. Clearing here is also the single point that
        // un-sticks a stale reattach flag once the user sends again.
        liveTurnFromReattach = false
        sendState = .connecting
        notice = nil
        isDiscoveringLive = false
        isReconnecting = false
        recoveryMessage = nil
        reconnectSchedule.reset()
        promptRequestStarted = false
        promptRequestInFlight = false
        observedPromptAcceptance = false
        let clientMessageID = UUID().uuidString
        promptClientMessageID = clientMessageID
        sendPipelineID = clientMessageID
        // The user's own send always re-pins, even if they'd scrolled up.
        requestStickToBottom()

        // 3) Run the network + streaming flow.
        sendTask?.cancel()
        let userTurnID = userTurn.id
        sendTask = Task { [weak self] in
            await self?.runSend(text: text, attachments: sending, live: live, userTurnID: userTurnID, clientMessageID: clientMessageID)
        }
    }

    private func runSend(text: String, attachments sending: [Attachment], live: LiveTurn, userTurnID: String, clientMessageID: String) async {
        defer {
            if sendPipelineID == clientMessageID {
                sendPipelineID = nil
                sendTask = nil
                promptRequestInFlight = false
            }
        }
        do {
            // For a brand-new draft, create the conversation row server-side BEFORE
            // prompting so every client (desktop / web) sees it immediately. No-op
            // for an existing or already-created conversation.
            try await ensureConversationCreated(firstPromptText: text)
            try Task.checkCancellation()

            // Resolve a connection (reuse → existing live conn → fresh spawn).
            let conn = try await resolveConnection()
            try Task.checkCancellation()
            guard promptClientMessageID == clientMessageID else { return }
            connectionID = conn

            // Open the event stream and wait until it is ready + attached.
            try await openStream(connectionID: conn, live: live)
            guard !Task.isCancelled else { return }

            isTurnActive = true
            lastFrameAt = .now
            if case .connecting = sendState { sendState = .thinking }

            // Fire the prompt; the reply arrives over the stream. Once this
            // returns, the server has accepted the turn — past this point a
            // failure is a *stream* failure (handled by the consumer loop), not a
            // send failure, so the optimistic turn must stay on screen.
            promptRequestStarted = true
            promptRequestInFlight = true
            try await sendPrompt(conn: conn, text: text, attachments: sending, clientMessageID: clientMessageID)
            guard promptClientMessageID == clientMessageID else { return }
            observedPromptAcceptance = true
            // Prompt accepted — the created conversation is now legitimately in use,
            // so it must not be rolled back by a later stream failure.
            draftCreatedConversationID = nil
        } catch let error as APIError where error.isStaleConnection && !observedPromptAcceptance {
            guard !Task.isCancelled, promptClientMessageID == clientMessageID else { return }
            // Stale connection → drop it and retry once with a fresh spawn.
            connectionID = nil
            await retrySendOnce(text: text, attachments: sending, live: live, clientMessageID: clientMessageID, userTurnID: userTurnID)
        } catch where APIError.isCancellation(error) {
            // Cancelled by the user / view teardown — handled in cancel().
        } catch {
            await recoverPromptFailure(error, text: text, attachments: sending, live: live,
                                       userTurnID: userTurnID, clientMessageID: clientMessageID)
        }
    }

    private func retrySendOnce(text: String, attachments sending: [Attachment], live: LiveTurn, clientMessageID: String, userTurnID: String) async {
        do {
            promptRequestStarted = false
            promptRequestInFlight = false
            isTurnActive = false
            closeStream()
            let prefs = preferredSelectors
            let conn = try await client.connect(
                agentType: agentTypeForUI,
                workingDir: folder?.path,
                sessionId: summary?.externalId,
                preferredModeId: prefs.modeId,
                preferredConfigValues: prefs.configValues
            )
            try Task.checkCancellation()
            guard promptClientMessageID == clientMessageID else { return }
            connectionID = conn
            try await openStream(connectionID: conn, live: live)
            guard !Task.isCancelled else { return }
            isTurnActive = true
            lastFrameAt = .now
            if case .connecting = sendState { sendState = .thinking }
            promptRequestStarted = true
            promptRequestInFlight = true
            try await sendPrompt(conn: conn, text: text, attachments: sending, clientMessageID: clientMessageID)
            guard promptClientMessageID == clientMessageID else { return }
            observedPromptAcceptance = true
            draftCreatedConversationID = nil
        } catch where APIError.isCancellation(error) {
            // no-op
        } catch {
            await recoverPromptFailure(error, text: text, attachments: sending, live: live,
                                       userTurnID: userTurnID, clientMessageID: clientMessageID)
        }
    }

    private func recoverPromptFailure(_ error: Error, text: String, attachments: [Attachment],
                                      live: LiveTurn, userTurnID: String, clientMessageID: String) async {
        guard !Task.isCancelled, promptClientMessageID == clientMessageID else { return }
        promptRequestInFlight = false
        var snapshot: LiveSessionSnapshot?
        if promptRequestStarted, !observedPromptAcceptance, let conn = connectionID {
            snapshot = try? await client.connectionSnapshot(connectionId: conn, as: LiveSessionSnapshot.self)
        }
        guard !Task.isCancelled, promptClientMessageID == clientMessageID else { return }
        switch PromptAcceptance.decide(requestStarted: promptRequestStarted,
                                       observedTurnEvent: observedPromptAcceptance,
                                       clientMessageID: clientMessageID, snapshot: snapshot,
                                       confirmedRejection: PromptAcceptance.isConfirmedRejection(error)) {
        case .rejected:
            discardOptimisticSend(userTurnID: userTurnID, live: liveTurn ?? live,
                                  restoringDraft: text, restoringAttachments: attachments)
            notice = APIError.userMessage(error)
        case .accepted, .unknown:
            // An HTTP response can be lost after admission, even after completion.
            // Never resend or delete the conversation while acceptance is unknown.
            draftCreatedConversationID = nil
            if isTurnActive {
                if let message = APIError.userMessage(error) { recoveryMessage = message }
                reconnectStream(into: liveTurn ?? live, connectionID: connectionID,
                                reason: APIError.userMessage(error), reattach: liveTurnFromReattach)
            }
        }
    }

    /// The user's last-used mode/config for the active agent, sent on every
    /// `connect` so a fresh session starts with their saved selections (mirrors
    /// the web client). Empty/nil values are omitted by the request encoder.
    private var preferredSelectors: SelectorPrefs {
        SelectorPrefsStore.prefs(for: agentTypeForUI)
    }

    private func resolveConnection() async throws -> String {
        if let existing = connectionID { return existing }
        // Only a linked conversation can have a server-side connection to find;
        // a new task always spawns fresh (no sessionId → a brand-new session).
        if let id = conversationID,
           let found = try await client.findConnection(
               conversationId: id,
               sessionId: summary?.externalId,
               agentType: agentTypeForUI
           )?.connectionId {
            return found
        }
        let prefs = preferredSelectors
        return try await client.connect(
            agentType: agentTypeForUI,
            workingDir: folder?.path,
            sessionId: summary?.externalId,
            preferredModeId: prefs.modeId,
            preferredConfigValues: prefs.configValues
        )
    }

    /// Resolve a live chat connection for out-of-band actions — currently applying
    /// agent mode/config from the options sheet. Unlike the send path, this does
    /// NOT trust a cached `connectionID`: it validates liveness via `findConnection`
    /// (which returns the conversation's bound connection or nil) and only spawns a
    /// fresh one when none is live, so a mode/config change can't be sent to a
    /// connection the server has since garbage-collected. The result is cached so
    /// the next send reuses the same connection.
    func resolveConnectionForOptions() async throws -> String {
        if let id = conversationID,
           let found = try await client.findConnection(
               conversationId: id,
               sessionId: summary?.externalId,
               agentType: agentTypeForUI
           )?.connectionId {
            connectionID = found
            return found
        }
        let prefs = preferredSelectors
        let conn = try await client.connect(
            agentType: agentTypeForUI,
            workingDir: folder?.path,
            sessionId: summary?.externalId,
            preferredModeId: prefs.modeId,
            preferredConfigValues: prefs.configValues
        )
        connectionID = conn
        return conn
    }

    private func sendPrompt(conn: String, text: String, attachments sending: [Attachment], clientMessageID: String) async throws {
        // Text first, then images — matches the web client's block order.
        var blocks: [PromptInputBlock] = []
        if !text.isEmpty { blocks.append(.text(text)) }
        blocks.append(contentsOf: sending.map { $0.promptInputBlock })
        // A new task sends a nil conversationId + the target folderId; the
        // server creates the conversation and announces it via
        // `conversation_linked` on the stream.
        try await client.prompt(
            connectionId: conn,
            blocks: blocks,
            folderId: summary?.folderId ?? folder?.id,
            conversationId: conversationID,
            clientMessageId: clientMessageID
        )
    }

    /// Create the server-side conversation row up front for a brand-new draft's
    /// first send (mirrors codeg web). This is what makes the new session visible
    /// to *other* clients immediately: `create_conversation` broadcasts a
    /// `conversation_upsert` to every connected client, whereas prompting with a
    /// nil `conversationId` creates the row implicitly and announces it only on
    /// this client's own stream — so the desktop never learns of it.
    ///
    /// No-op once a conversation exists (existing session, or a retry after the
    /// row was already created). On failure it throws into `runSend`'s `catch`,
    /// which rolls the optimistic send back.
    private func ensureConversationCreated(firstPromptText text: String) async throws {
        guard conversationID == nil, let folderId = folder?.id, let agent = selectedAgent else { return }
        let id = try await client.createConversation(
            folderId: folderId,
            agentType: agent,
            title: Self.draftTitle(from: text)
        )
        conversationID = id
        draftCreatedConversationID = id
        currentBranch = folder?.gitBranch
        // Refresh this app's own session list so the new row shows there too.
        notifyConversationsChanged()
        // Fetch identity (title / status / external id) in the background so the
        // nav-bar title + actions menu light up — without blocking the prompt's
        // first token on an extra round-trip.
        Task { [weak self] in
            guard let self,
                  let detail = try? await self.client.conversationDetail(id: id),
                  self.conversationID == id else { return }
            self.summary = detail.summary
            self.sessionStats = detail.sessionStats ?? self.sessionStats
            self.insertModel.agentType = detail.summary.agentType
        }
    }

    /// A title for a freshly created conversation, derived from the first prompt
    /// (first non-empty line, capped to 80 chars) — mirrors the web client. nil →
    /// the server titles it later from the session.
    private static func draftTitle(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        return String(firstLine.prefix(80))
    }

    // MARK: - Stream lifecycle

    /// Resolved by the consumer loop the moment the socket reports `.ready`, so
    /// `openStream` can return only after the stream is attached. Single-shot.
    private var readyContinuation: CheckedContinuation<Void, Error>?

    /// Opens a fresh `EventStream`, spawns the single consumer loop, and suspends
    /// until snapshot/replay confirms attach. There is exactly one
    /// iterator over `frames` — the consumer loop — so frames are never dropped.
    private func openStream(connectionID conn: String, live: LiveTurn) async throws {
        do {
            try await openStreamAttempt(connectionID: conn, live: live)
        } catch APIError.connectionLost(let reason) where reason == EventStream.CloseReason.endpointChanged {
            // Selection has published the replacement endpoint before closing
            // the old socket. No prompt has been sent; retry attach exactly once.
            try Task.checkCancellation()
            try await openStreamAttempt(connectionID: conn, live: live)
        }
    }

    private func openStreamAttempt(connectionID conn: String, live: LiveTurn) async throws {
        closeStream()
        reconnectSchedule.reset()
        seqTracker.bind(to: conn)
        // A new prompt has no local state to replay into. Establish a fresh baseline.
        seqTracker.adoptSnapshot(nil)
        let generation = streamGeneration
        let newStream = client.makeEventStream()
        stream = newStream
        newStream.start()
        consumerTask = Task { [weak self] in
            await self?.consume(stream: newStream, connectionID: conn, live: live, generation: generation)
        }
        armAttachDeadline(connectionID: conn, generation: generation, initialSend: true, reattach: false)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                readyContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, generation == self.streamGeneration else { return }
                self.closeStream()
            }
        }
        try Task.checkCancellation()
        // Snapshot confirmation and a close can arrive in the same batch before
        // runSend resumes. Never fire a prompt after that subscription vanished.
        guard generation == streamGeneration, stream === newStream else {
            throw APIError.transport("The event stream closed before the prompt was sent.")
        }
    }

    /// Both send and reattach consumers use one reducer, including failures before
    /// the first snapshot. A generation owns the socket, deadline and cursor.
    private func consume(stream: EventStream, connectionID conn: String, live initialLive: LiveTurn?,
                         generation: Int, initialSend: Bool = true, reattach: Bool = false) async {
        var live = initialLive
        for await frame in stream.frames {
            guard !Task.isCancelled, generation == streamGeneration else { return }
            lastFrameAt = .now
            switch frame {
            case .ready:
                stream.attach(subscriptionId: subscriptionID, connectionId: conn,
                              sinceSeq: initialSend ? nil : seqTracker.sinceSeq)
            case .snapshot(let snapshot):
                confirmAttach()
                seqTracker.adoptSnapshot(snapshot.eventSeq)
                // The initial send's snapshot describes the state BEFORE prompting.
                if !initialSend || readyContinuation == nil {
                    live = applySnapshot(snapshot, live: live, reattach: reattach)
                }
                resumeReady(throwing: nil)
            case .replay(let events):
                confirmAttach()
                if let current = live ?? liveTurn {
                    live = current
                    for envelope in seqTracker.orderedReplay(events) {
                        guard generation == streamGeneration else { return }
                        applyEnvelope(envelope, live: current)
                    }
                }
                resumeReady(throwing: nil)
            case .pong:
                break
            case .event(let envelope):
                guard envelope.connectionId == conn, seqTracker.accept(envelope.seq) else { continue }
                if let current = live ?? liveTurn {
                    live = current
                    applyEnvelope(envelope, live: current)
                }
            case .detached(let reason):
                streamFailed(connectionID: conn, reason: reason, initialSend: initialSend, reattach: reattach)
                return
            case .closed(let reason):
                streamFailed(connectionID: conn, reason: reason, initialSend: initialSend, reattach: reattach)
                return
            }
        }
        // An unexpected end without a terminal frame must not leave stream set.
        if !Task.isCancelled, generation == streamGeneration {
            streamFailed(connectionID: conn, reason: nil, initialSend: initialSend, reattach: reattach)
        }
    }

    private func applyEnvelope(_ envelope: EventEnvelope, live: LiveTurn) {
        if promptRequestStarted, PromptAcceptance.isTurnEvidence(envelope.event, clientMessageID: promptClientMessageID) {
            observedPromptAcceptance = true
            draftCreatedConversationID = nil
        }
        handle(event: envelope.event, live: live)
    }

    @discardableResult
    private func applySnapshot(_ snapshot: LiveSessionSnapshot, live: LiveTurn?, reattach: Bool) -> LiveTurn? {
        if promptRequestStarted,
           snapshot.status == .prompting || snapshot.pendingUserMessage?.messageId == promptClientMessageID {
            observedPromptAcceptance = true
            draftCreatedConversationID = nil
        }
        switch SnapshotOutcome.classify(isTurnActive: isTurnActive, snapshot: snapshot) {
        case .adoptLive:
            guard let rebuilt = buildLiveTurn(from: snapshot) else { return live }
            liveTurn = rebuilt
            if reattach { liveTurnFromReattach = true }
            isTurnActive = true
            restorePending(from: snapshot)
            sendState = .thinking
            requestScrollToBottom()
            return rebuilt
        case .restorePendingOnly:
            let current = liveTurn ?? live ?? LiveTurn()
            liveTurn = current
            if reattach { liveTurnFromReattach = true }
            isTurnActive = true
            restorePending(from: snapshot)
            sendState = .thinking
            requestScrollToBottom()
            return current
        case .finalize:
            // Admission can precede the connection loop's first event. Do not
            // interpret its pre-prompt idle state as a completed local send.
            if promptRequestInFlight, !observedPromptAcceptance { return live }
            // Covers a turn that completed while the socket was disconnected.
            // Use the same reconciliation and prompt cleanup as TurnComplete.
            if let current = liveTurn ?? live { finalize(live: current, stopReason: "end_turn") }
            return liveTurn
        case .ignore:
            if !isTurnActive {
                closeStream()
                Task { [weak self] in await self?.reconcileAfterMissedLive() }
            }
            return live
        }
    }

    private func confirmAttach() {
        attachDeadlineTask?.cancel()
        attachDeadlineTask = nil
        reconnectTask = nil
        reconnectSchedule.reset()
        isReconnecting = false
        recoveryMessage = nil
        isDiscoveringLive = false
        if isTurnActive, case .connecting = sendState { sendState = .thinking }
    }

    private func armAttachDeadline(connectionID conn: String, generation: Int, initialSend: Bool, reattach: Bool) {
        attachDeadlineTask?.cancel()
        attachDeadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard let self, generation == self.streamGeneration else { return }
            self.streamFailed(connectionID: conn, reason: "The live connection timed out.",
                              initialSend: initialSend, reattach: reattach)
        }
    }

    private func streamFailed(connectionID conn: String, reason: String?, initialSend: Bool, reattach: Bool) {
        if initialSend, readyContinuation != nil {
            let error: APIError = reason == "connection_gone" ? .streamGone
                : reason == EventStream.CloseReason.endpointChanged ? .connectionLost(EventStream.CloseReason.endpointChanged)
                : .transport(reason ?? "The event stream closed unexpectedly.")
            resumeReady(throwing: error)
            closeStream()
            return
        }
        let recover = isTurnActive || isDiscoveringLive
        closeStream()
        guard recover else { return }
        if reason == "connection_gone" { connectionID = nil }
        reconnectStream(into: liveTurn, connectionID: connectionID,
                        reason: reason, reattach: reattach)
    }

    /// Resolve the pending `openStream` suspension exactly once.
    private func resumeReady(throwing error: Error?) {
        guard let continuation = readyContinuation else { return }
        readyContinuation = nil
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }

    // MARK: - Reattach (open a session whose turn is already in-flight)

    /// After loading an existing conversation, attach to its live connection — if
    /// one exists and a turn is in-flight (or a card is pending) — so the reply
    /// streams and any pending permission/question surfaces, all WITHOUT sending.
    /// This is the cross-client / app-relaunch path: a turn started in codeg web
    /// (or left blocked) becomes interactive on open. Idle connections are dropped.
    ///
    /// Additive: it does not touch the send flow. The moment the user sends,
    /// `openStream` supersedes this stream (a generation bump ends this consumer).
    func reattachIfLive(serverSaysLive: Bool = false) async {
        guard let id = conversationID, summary != nil,
              liveTurn == nil, stream == nil, sendPipelineID == nil, !isDiscoveringLive else { return }
        if !serverSaysLive, summary?.status == .completed || summary?.status == .cancelled { return }
        turnReconciliation = TurnReconciliation(totalTurns: transcriptTotal, turns: turns)
        reconciliationAttempts = 0
        isDiscoveringLive = true
        seqTracker.adoptSnapshot(nil)
        let generation = streamGeneration
        if serverSaysLive {
            // Preserve the recovery chain even when discovery or the first attach
            // fails before any snapshot arrives.
            liveTurn = LiveTurn()
            liveTurnFromReattach = true
            isTurnActive = true
            sendState = .connecting
            lastFrameAt = .now
        }
        do {
            let found = try await client.findConnection(conversationId: id,
                                                       sessionId: summary?.externalId, agentType: agentTypeForUI)
            guard !Task.isCancelled, generation == streamGeneration, sendPipelineID == nil else { return }
            guard let conn = found?.connectionId else {
                if let live = liveTurn, isTurnActive {
                    await reconcileOrFail(live: live, reason: "connection_gone")
                } else {
                    isDiscoveringLive = false
                    closeStream()
                }
                return
            }
            connectionID = conn
            startRecoveryStream(connectionID: conn, live: liveTurn, reattach: true)
        } catch {
            guard !Task.isCancelled, generation == streamGeneration else { return }
            if let message = APIError.userMessage(error) { recoveryMessage = message }
            reconnectStream(into: liveTurn, connectionID: nil, reason: APIError.userMessage(error), reattach: true)
        }
    }

    /// The server reported a live turn at load but we couldn't attach to it (it
    /// finished in the gap, or the connection was momentarily undiscoverable).
    /// Quietly refetch the detail so the transcript shows the final reply rather
    /// than the snapshot we loaded a beat too early. No-op if a turn has since
    /// started locally — that path owns the transcript.
    private func reconcileAfterMissedLive() async {
        guard let id = conversationID, liveTurn == nil, !isInFlight, stream == nil else { return }
        guard let detail = try? await fetchWindowedDetail(id: id) else { return }
        guard liveTurn == nil, !isInFlight, stream == nil else { return }
        summary = detail.summary
        adoptTranscript(detail)
        sessionStats = detail.sessionStats ?? sessionStats
        requestStickToBottom()
    }

    /// Consumer for the reattach stream. Unlike `consume`, it has no `openStream`
    /// continuation to release and it BUILDS the live turn from the attach snapshot
    /// rather than being handed one. If the snapshot shows nothing in flight, it
    /// closes the stream (idle connection — leave it alone).
    private func consumeReattach(stream: EventStream, connectionID conn: String, live: LiveTurn?,
                                generation: Int) async {
        await consume(stream: stream, connectionID: conn, live: live, generation: generation,
                      initialSend: false, reattach: true)
    }

    /// Rebuild an in-flight assistant turn from a reattach snapshot. Returns nil
    /// when the connection is idle (no live message, no plan, no pending card, and
    /// not actively prompting).
    private func buildLiveTurn(from snap: LiveSessionSnapshot) -> LiveTurn? {
        let blocks = snap.liveMessage?.content ?? []
        let hasPending = snap.pendingPermission != nil || snap.pendingQuestion != nil
            || snap.pendingPlanApproval != nil
        guard !blocks.isEmpty || hasPending || snap.pendingUserMessage != nil || snap.status == .prompting else { return nil }

        let live = LiveTurn()
        let toolsById = Dictionary((snap.activeToolCalls ?? []).map { ($0.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
        for block in blocks {
            switch block {
            case .text(let t): live.appendText(t)
            case .thinking(let t): live.appendThinking(t)
            case .toolCallRef(let toolId):
                guard let st = toolsById[toolId] else { break }
                live.upsertToolCall(
                    id: st.id,
                    title: st.label,
                    kind: st.kind,
                    status: Self.normalizedToolStatus(st.status),
                    rawInput: st.inputPreview,
                    rawOutput: st.outputText,
                    content: st.content,
                    meta: st.meta
                )
            case .plan(let entries):
                live.updatePlan(PlanEntry.list(from: entries))
            case .unknown:
                break
            }
        }
        live.flushAllText()
        return live
    }

    private func restorePending(from snap: LiveSessionSnapshot) {
        if let p = snap.pendingPermission {
            pendingPermission = PendingPermission(requestId: p.requestId, toolCall: p.toolCall, options: p.options)
        } else {
            pendingPermission = nil
        }
        if let q = snap.pendingQuestion {
            pendingQuestion = PendingQuestion(questionId: q.questionId, questions: q.questions)
        } else {
            pendingQuestion = nil
        }
        // Set OR clear: the attach snapshot is the connection's authoritative
        // pending state, so an approval that another client resolved while we were
        // reconnecting must not leave a stale, still-actionable card behind
        // (answering it would post a decision for an approval that no longer exists).
        if let p = snap.pendingPlanApproval {
            pendingPlanApproval = PendingPlanApproval(
                approvalId: p.approvalId, toolCallId: p.toolCallId, planMarkdown: p.planMarkdown)
        } else {
            pendingPlanApproval = nil
        }
    }

    /// Normalize a snapshot `ToolCallStatus` (which may be PascalCase) to the
    /// lowercase form the live tool card interprets.
    private static func normalizedToolStatus(_ raw: String) -> String {
        switch raw.lowercased() {
        case "inprogress", "in_progress", "in-progress", "running": return "in_progress"
        case "completed", "done", "success": return "completed"
        case "failed", "error": return "failed"
        case "pending": return "pending"
        default: return raw.lowercased()
        }
    }

    // MARK: - Event → UI mapping

    private func handle(event: AcpEvent, live: LiveTurn) {
        switch event {
        case .contentDelta(let text):
            live.appendText(text)
            if case .running = sendState {} else { sendState = .thinking }
            requestScrollToBottom()

        case .thinking(let text):
            live.appendThinking(text)
            if case .running = sendState {} else { sendState = .thinking }
            requestScrollToBottom()

        case .toolCall(let id, let title, let kind, let status, let content, let rawInput, let rawOutput, let meta):
            live.upsertToolCall(id: id, title: title, kind: kind, status: status, rawInput: rawInput, rawOutput: rawOutput, content: content, meta: meta)
            sendState = .running(tool: title.isEmpty ? "tool" : title)
            requestScrollToBottom()

        case .toolCallUpdate(let id, let title, let status, let content, let rawInput, let rawOutput, let append, let meta):
            live.updateToolCall(id: id, title: title, status: status, rawInput: rawInput, rawOutput: rawOutput, content: content, append: append, meta: meta)
            if let active = live.activeToolTitle {
                sendState = .running(tool: active)
            } else {
                sendState = .thinking
            }
            requestScrollToBottom()

        case .statusChanged(let status):
            switch status {
            case .connecting: if case .idle = sendState { sendState = .connecting }
            case .prompting: if case .running = sendState {} else { sendState = .thinking }
            case .error:
                failLive(live, message: "The agent connection errored.")
            default:
                break
            }

        case .usageUpdate(let used, let size):
            applyUsage(used: used, size: size)

        case .userMessage(let messageID, _):
            if messageID == promptClientMessageID {
                observedPromptAcceptance = true
                draftCreatedConversationID = nil
            }

        case .turnComplete(let stopReason):
            finalize(live: live, stopReason: stopReason)

        case .error(let message, _):
            failLive(live, message: message)

        case .conversationLinked(let linkedID, _):
            adoptLinkedConversation(linkedID)

        case .permissionRequest(let requestId, let toolCall, let options):
            // The agent paused for approval (incl. ExitPlanMode). Surface the card
            // above the compose bar; the turn stays in-flight until it's resolved.
            pendingPermission = PendingPermission(requestId: requestId, toolCall: toolCall, options: options)
            requestScrollToBottom()

        case .permissionResolved(let requestId):
            // Resolved here or by another client — clear the matching card only, so
            // a stale echo can't wipe a freshly-raised one.
            if pendingPermission?.requestId == requestId { pendingPermission = nil }

        case .questionRequest(let questionId, let questions):
            pendingQuestion = PendingQuestion(questionId: questionId, questions: questions)
            requestScrollToBottom()

        case .questionResolved(let questionId):
            if pendingQuestion?.questionId == questionId { pendingQuestion = nil }

        case .planApprovalRequest(let approvalId, let toolCallId, let planMarkdown):
            // Grok finished planning and is blocked until the user decides.
            pendingPlanApproval = PendingPlanApproval(
                approvalId: approvalId, toolCallId: toolCallId, planMarkdown: planMarkdown)
            requestScrollToBottom()

        case .planApprovalResolved(let approvalId):
            if pendingPlanApproval?.approvalId == approvalId { pendingPlanApproval = nil }

        case .planUpdate(let entries):
            live.updatePlan(entries)
            requestScrollToBottom()

        case .conversationStatusChanged(let id, let status):
            guard id == conversationID else { break }
            summary?.status = status
            if status == .pendingReview || status == .completed || status == .cancelled {
                // The status can also be edited manually or emitted before a
                // failed prompt enqueue. Confirm its terminal edge with live state.
                Task { [weak self] in await self?.confirmTurnEnded(live: live) }
            }

        case .sessionStarted, .userPromptSent, .unknown:
            break
        }
    }

    /// A new task's first prompt creates the server-side conversation; adopt
    /// its id (and identity summary) without disturbing the in-flight stream.
    private func adoptLinkedConversation(_ id: Int) {
        guard conversationID == nil else { return }
        conversationID = id
        Task { [weak self] in
            guard let self else { return }
            guard let detail = try? await self.client.conversationDetail(id: id),
                  self.conversationID == id else { return }
            // Mid-stream: adopt identity + stats only — the live turn is still
            // rendering and `refreshAfterTurn()` reconciles the transcript.
            self.summary = detail.summary
            self.sessionStats = detail.sessionStats ?? self.sessionStats
            self.insertModel.agentType = detail.summary.agentType
        }
    }

    private func applyUsage(used: UInt64, size: UInt64) {
        let prev = sessionStats
        sessionStats = SessionStats(
            totalUsage: prev?.totalUsage,
            totalTokens: Int(used),
            totalDurationMs: prev?.totalDurationMs ?? 0,
            contextWindowUsedTokens: Int(used),
            contextWindowMaxTokens: size > 0 ? Int(size) : prev?.contextWindowMaxTokens,
            contextWindowUsagePercent: size > 0 ? (Double(used) / Double(size)) * 100 : prev?.contextWindowUsagePercent
        )
    }

    // MARK: - Finalize / fail

    private func finalize(live: LiveTurn, stopReason: String) {
        guard isTurnActive else { return }
        isTurnActive = false
        isDiscoveringLive = false
        isReconnecting = false
        recoveryMessage = nil
        // Read before clearing: this is the one transition that delivers parked
        // plan-revision notes (every other terminal path drops them).
        let planFollowUp = pendingPlanFollowUp
        clearInteractivePrompts()
        // Publish any pending coalesced text before flipping to the finalized
        // render so the seam is reflow-free (the finalized branch reads the same
        // run text, now complete).
        live.flushAllText()
        live.isStreaming = false
        live.stopReason = stopReason
        sendState = .idle
        completedTurnTick &+= 1
        closeStream()
        requestScrollToBottom()
        // Replace the optimistic + live turns with the authoritative server copy.
        Task { [weak self] in await self?.refreshAfterTurn(reconciling: live) }
        // The keep-planning turn just ended — deliver the revision notes as the
        // follow-up prompt Grok expects (it discards them on the reply itself).
        if let planFollowUp { send(overrideText: planFollowUp) }
    }

    /// Roll back an optimistic send that failed *before the server accepted the
    /// prompt*: tear down the stream, drop the pending user turn and its empty
    /// live placeholder, and restore the user's text so they can retry. The
    /// caller surfaces the reason via `notice`.
    private func discardOptimisticSend(userTurnID: String, live: LiveTurn, restoringDraft text: String, restoringAttachments sent: [Attachment]) {
        isTurnActive = false
        isDiscoveringLive = false
        isReconnecting = false
        recoveryMessage = nil
        clearInteractivePrompts()
        closeStream()
        pendingUserTurns.removeAll { $0.id == userTurnID }
        if liveTurn === live { liveTurn = nil }
        sendState = .idle
        // If THIS send created the conversation up front (a draft's first send) but
        // the prompt was never accepted, roll that creation back too: delete the
        // empty row (so it doesn't linger in every client's sidebar) and clear the
        // adopted identity, returning the screen to a clean, editable draft.
        if let createdID = draftCreatedConversationID {
            draftCreatedConversationID = nil
            conversationID = nil
            summary = nil
            sessionStats = nil
            Task { [weak self] in
                try? await self?.client.deleteConversation(conversationId: createdID)
                self?.notifyConversationsChanged()
            }
        }
        // The send failed before the server accepted it, so no conversation was
        // created — re-open the draft's agent/folder pickers for an edited retry.
        if conversationID == nil { hasStartedFirstSend = false }
        // Don't clobber a fresh draft the user may have started typing.
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = text
        }
        // Restore the staged images too, unless the user has since added new ones.
        if attachments.isEmpty, !sent.isEmpty {
            attachments = sent
        }
        requestScrollToBottom()
    }

    private func failLive(_ live: LiveTurn, message: String?) {
        isTurnActive = false
        isDiscoveringLive = false
        isReconnecting = false
        recoveryMessage = nil
        clearInteractivePrompts()
        live.flushAllText()
        live.isStreaming = false
        if let message { live.errorMessage = message }
        sendState = message.map { .error($0) } ?? .idle
        closeStream()
        // Keep the live turn on screen so the user sees partial output + error;
        // drop the placeholder only if it is completely empty and errorless.
        if live.isEmpty {
            liveTurn = nil
        }
        requestScrollToBottom()
    }

    // MARK: - Stream recovery (transient drops)

    /// Foreground and "Retry now" bypass the remaining backoff. Missing ACP
    /// identity is rediscovered without sending a second prompt.
    func resumeStreamAfterForeground() {
        guard sendPipelineID == nil || isTurnActive else { return }
        guard isTurnActive || isDiscoveringLive else { return }
        reconnectStream(into: liveTurn, connectionID: connectionID, reason: nil,
                        reattach: liveTurnFromReattach || isDiscoveringLive, immediately: true)
    }

    func retryRecoveryNow() {
        guard isReconnecting else { return }
        resumeStreamAfterForeground()
    }

    /// Retry for as long as this screen tracks the turn. A lost ACP connection
    /// triggers discovery; a lost socket keeps the same cursor and live content.
    private func reconnectStream(into live: LiveTurn?, connectionID conn: String?, reason: String?,
                                 reattach: Bool = false, immediately: Bool = false) {
        guard isTurnActive || isDiscoveringLive else { closeStream(); return }
        if let live, liveTurn !== live { return }
        closeStream()
        let delay = reconnectSchedule.next(closeReason: reason)
        let generation = streamGeneration
        isReconnecting = true
        sendState = .connecting
        reconnectTask = Task { [weak self] in
            if !immediately {
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
            guard let self, !Task.isCancelled, generation == self.streamGeneration,
                  self.isTurnActive || self.isDiscoveringLive else { return }
            var resolved = conn
            if resolved == nil, let id = self.conversationID {
                do {
                    resolved = try await self.client.findConnection(conversationId: id,
                        sessionId: self.summary?.externalId, agentType: self.agentTypeForUI)?.connectionId
                } catch {
                    guard !Task.isCancelled, generation == self.streamGeneration else { return }
                    if let message = APIError.userMessage(error) { self.recoveryMessage = message }
                    self.reconnectStream(into: self.liveTurn, connectionID: nil,
                                         reason: APIError.userMessage(error), reattach: reattach)
                    return
                }
            }
            guard !Task.isCancelled, generation == self.streamGeneration else { return }
            guard let resolved else {
                if let current = self.liveTurn, self.isTurnActive {
                    await self.reconcileOrFail(live: current, reason: reason)
                } else {
                    // A cold, idle discovery completed successfully: no live session.
                    self.isDiscoveringLive = false
                    self.isReconnecting = false
                    self.recoveryMessage = nil
                    self.closeStream()
                    await self.reconcileAfterMissedLive()
                }
                return
            }
            self.connectionID = resolved
            self.startRecoveryStream(connectionID: resolved, live: self.liveTurn, reattach: reattach)
        }
    }

    private func startRecoveryStream(connectionID conn: String, live: LiveTurn?, reattach: Bool) {
        closeStream()
        seqTracker.bind(to: conn)
        let generation = streamGeneration
        let newStream = client.makeEventStream()
        stream = newStream
        newStream.start()
        consumerTask = Task { [weak self] in
            if reattach {
                await self?.consumeReattach(stream: newStream, connectionID: conn, live: live, generation: generation)
            } else {
                await self?.consume(stream: newStream, connectionID: conn, live: live, generation: generation,
                                    initialSend: false)
            }
        }
        armAttachDeadline(connectionID: conn, generation: generation, initialSend: false, reattach: reattach)
    }

    /// Screen-scoped tasks use independent loops so a slow snapshot probe cannot
    /// delay the 30-second connection touch (the server reaps after 180 seconds).
    func screenDidAppear() {
        isScreenVisible = true
        if isTurnActive, stream == nil { resumeStreamAfterForeground() }
        if touchTask == nil {
            touchTask = Task { [weak self] in
                while !Task.isCancelled {
                    if let conn = self?.connectionID { _ = try? await self?.client.touchConnection(connectionId: conn) }
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                }
            }
        }
        if watchdogTask == nil {
            watchdogTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    await self?.probeQuietTurn()
                }
            }
        }
    }

    private func probeQuietTurn() async {
        guard isTurnActive, !promptRequestInFlight,
              lastFrameAt.duration(to: .now) >= .seconds(15), let live = liveTurn else { return }
        lastFrameAt = .now
        guard let conn = connectionID else {
            if reconnectTask == nil { resumeStreamAfterForeground() }
            return
        }
        let generation = streamGeneration
        do {
            let snapshot = try await client.connectionSnapshot(connectionId: conn, as: LiveSessionSnapshot.self)
            guard !Task.isCancelled, generation == streamGeneration, isTurnActive, liveTurn === live else { return }
            guard let snapshot else {
                connectionID = nil
                closeStream()
                await reconcileOrFail(live: live, reason: "connection_gone")
                return
            }
            // HTTP may race later WS events. Never finish a newer live state from
            // an older snapshot, and never advance the WS cursor with an HTTP read.
            if let seq = snapshot.eventSeq, let applied = seqTracker.sinceSeq, seq < applied { return }
            switch SnapshotOutcome.classify(isTurnActive: true, snapshot: snapshot) {
            case .finalize:
                finalize(live: live, stopReason: "end_turn")
            case .adoptLive, .restorePendingOnly:
                if stream == nil { resumeStreamAfterForeground() }
            case .ignore:
                break
            }
        } catch {
            // A failed HTTP probe is not evidence the turn stopped. Socket retry
            // continues independently; healthy quiet tools remain on screen.
            if isReconnecting, let message = APIError.userMessage(error) { recoveryMessage = message }
        }
    }

    private func confirmTurnEnded(live: LiveTurn) async {
        guard isTurnActive, !promptRequestInFlight, let conn = connectionID else { return }
        let generation = streamGeneration
        guard let snapshot = try? await client.connectionSnapshot(connectionId: conn, as: LiveSessionSnapshot.self),
              generation == streamGeneration, isTurnActive, liveTurn === live else { return }
        if let seq = snapshot.eventSeq, let applied = seqTracker.sinceSeq, seq < applied { return }
        if SnapshotOutcome.classify(isTurnActive: true, snapshot: snapshot) == .finalize {
            finalize(live: live, stopReason: "end_turn")
        }
    }

    /// Reconcile when the ACP connection disappeared or the screen is leaving.
    /// While visible, inconclusive reads continue discovery with backoff.
    private func reconcileOrFail(live: LiveTurn, reason: String?) async {
        guard liveTurn === live, isTurnActive else { return }
        if let id = conversationID,
           let detail = try? await fetchWindowedDetail(id: id),
           liveTurn === live, isTurnActive {
            summary = detail.summary
            sessionStats = detail.sessionStats ?? sessionStats
            let baseline = turnReconciliation ?? TurnReconciliation(totalTurns: transcriptTotal, turns: turns)
            reconciliationAttempts += 1
            if baseline.canAdopt(detail, preservingReply: !live.isEmpty,
                                 streamedReply: live.snapshotAsMessageTurn().blocks,
                                 retriesExhausted: reconciliationAttempts >= 5) {
                isTurnActive = false
                isDiscoveringLive = false
                isReconnecting = false
                recoveryMessage = nil
                clearInteractivePrompts()
                adoptTranscript(detail)
                pendingUserTurns.removeAll()
                liveTurn = nil
                sendState = .idle
                closeStream()
                requestScrollToBottom()
                return
            }
        }
        if isScreenVisible {
            reconnectStream(into: live, connectionID: nil, reason: reason, reattach: liveTurnFromReattach)
        }
    }

    // MARK: - Interactive prompts (permission / question / plan)

    /// Resolve the pending permission (or ExitPlanMode) by selecting an option.
    /// Optimistically clears the card on success; on failure keeps it and returns
    /// `false` so the card can re-enable and show an inline error. The agent then
    /// continues — or stops, for a `reject*` option — over the same stream.
    func respondPermission(optionId: String) async -> Bool {
        guard let pending = pendingPermission, let conn = connectionID else { return false }
        do {
            try await client.respondPermission(connectionId: conn, requestId: pending.requestId, optionId: optionId)
            // Optimistic clear; the stream also echoes `permission_resolved`
            // (idempotent — matched by request id).
            if pendingPermission?.requestId == pending.requestId { pendingPermission = nil }
            requestScrollToBottom()
            return true
        } catch {
            notice = APIError.userMessage(error)
            return false
        }
    }

    /// Answer the pending `ask_user_question`. Optimistic clear on success.
    func answerQuestion(_ answer: QuestionAnswer) async -> Bool {
        guard let pending = pendingQuestion, let conn = connectionID else { return false }
        do {
            try await client.answerQuestion(connectionId: conn, questionId: pending.questionId, answer: answer)
            if pendingQuestion?.questionId == pending.questionId { pendingQuestion = nil }
            requestScrollToBottom()
            return true
        } catch {
            notice = APIError.userMessage(error)
            return false
        }
    }

    /// Dismiss the pending question — the agent proceeds with its own judgment.
    func declineQuestion() async -> Bool {
        await answerQuestion(.dismissed)
    }

    /// Resolve Grok's blocked `exit_plan_mode`. Optimistic clear on success.
    ///
    /// "Request changes" needs one extra step: Grok DISCARDS the reply's `feedback`
    /// on the keep-planning path (only approve/abandon consume it), and its own TUI
    /// instead delivers the revision notes as a follow-up user turn. Mirror that —
    /// otherwise the notes vanish and Grok re-presents the same plan. The
    /// keep-planning turn is usually still winding down at this point, so the
    /// follow-up is parked and flushed when the turn completes.
    func answerPlanApproval(decision: PlanApprovalDecision, feedback: String?) async -> Bool {
        guard let pending = pendingPlanApproval, let conn = connectionID else { return false }
        let notes = (feedback ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await client.answerPlanApproval(connectionId: conn, approvalId: pending.approvalId,
                                                decision: decision, feedback: notes.isEmpty ? nil : notes)
            if pendingPlanApproval?.approvalId == pending.approvalId { pendingPlanApproval = nil }
            if decision == .requestChanges, !notes.isEmpty {
                // Park the notes for THIS turn's completion — `finalize` picks them
                // up. If the keep-planning turn already ended, send them now.
                if isInFlight { pendingPlanFollowUp = notes } else { send(overrideText: notes) }
            }
            requestScrollToBottom()
            return true
        } catch {
            notice = APIError.userMessage(error)
            return false
        }
    }

    /// A blocked permission/question/plan-approval can't outlive its turn: clear
    /// any pending card when the turn finalizes, fails, or is cancelled.
    ///
    /// Parked plan-revision notes are dropped here too — they are meaningful only
    /// as the immediate follow-up to the keep-planning turn that produced them. A
    /// turn that failed or was cancelled never gets that follow-up, and leaving
    /// the notes parked would let a LATER, unrelated turn's completion send them.
    /// (`finalize` — the one path that legitimately delivers them — reads them
    /// before calling this.)
    private func clearInteractivePrompts() {
        pendingPermission = nil
        pendingQuestion = nil
        pendingPlanApproval = nil
        pendingPlanFollowUp = nil
    }

    /// After a successful turn, re-fetch the persisted transcript and splice it
    /// in, dropping the optimistic user turns and the live placeholder so nothing
    /// renders twice.
    ///
    /// The server emits `turn_complete` a beat *before* the assistant reply is
    /// queryable, so an immediate `conversationDetail` can come back without the
    /// new reply (only the user turn persisted, or the assistant turn present but
    /// still empty). Adopting that blindly would replace the just-streamed reply
    /// with an empty "No content" turn — the bug this guards against. So we only
    /// retire the finalized live turn once the fetched transcript actually carries
    /// the reply; until then the live turn (now pulse-free) stays on screen, and
    /// we retry a few times with a short backoff. If it never reconciles, the live
    /// turn simply remains — the content is preserved and a later full load
    /// reconciles it.
    private func refreshAfterTurn(reconciling live: LiveTurn) async {
        // A new task that never got linked keeps its locally rendered turns.
        guard let id = conversationID else { return }
        // Whether the finished live turn has content worth preserving. If it was
        // empty (e.g. a no-op turn), an empty persisted reply can also reconcile.
        let mustPreserveReply = !live.isEmpty
        let baseline = turnReconciliation ?? TurnReconciliation(totalTurns: transcriptTotal, turns: turns)

        for attempt in 0..<5 {
            // If the user started another turn while we were reconciling, that
            // newer turn now owns turns/pendingUserTurns/liveTurn; bail so we
            // don't wipe its in-flight state (its own finalize reconciles later).
            guard !Task.isCancelled, liveTurn === live else { return }
            do {
                let detail = try await fetchWindowedDetail(id: id)
                // Re-check after the await — a new turn may have begun during it.
                guard !Task.isCancelled, liveTurn === live else { return }
                // Identity/stats are always safe to adopt, even before the reply
                // is queryable, so the header stays fresh while we wait.
                summary = detail.summary
                sessionStats = detail.sessionStats ?? sessionStats

                // An idle updated assistant row is sufficient even if totalTurns
                // is unchanged. Retry unchanged reads before the bounded fallback.
                if baseline.canAdopt(detail, preservingReply: mustPreserveReply,
                                     streamedReply: live.snapshotAsMessageTurn().blocks,
                                     retriesExhausted: attempt == 4) {
                    adoptTranscript(detail)
                    pendingUserTurns.removeAll()
                    liveTurn = nil
                    requestScrollToBottom()
                    return
                }
                // Not reconciled for this turn yet — keep the finalized live turn
                // visible and try again shortly.
            } catch {
                // Re-fetch failed: keep the live turn (now finalized, no pulse) so
                // the user still sees the reply, then retry.
            }
            // Don't sleep after the final attempt.
            if attempt < 4 {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
        }
        // Gave up reconciling (the server hasn't persisted the reply within the
        // retry window). Fold the finalized reply — and its optimistic user turn —
        // into the authoritative `turns` so it survives a subsequent send instead
        // of living only in the single `liveTurn` slot; a later reconcile or full
        // load replaces it with the server's copy.
        promoteUnreconciled(live)
    }

    /// Fold a finalized-but-unreconciled live reply (plus the optimistic user
    /// turn(s) still awaiting persistence) into `turns`, so the reply is never
    /// dropped from view when the `liveTurn` slot is reused by the next send. The
    /// synthesized turns are transient: the next successful `refreshAfterTurn` /
    /// `load` overwrites `turns` wholesale with the server's authoritative copy.
    private func promoteUnreconciled(_ live: LiveTurn) {
        // Only act while this is still the current live turn — if a newer turn has
        // taken over, it already owns (and preserved) the prior state.
        guard liveTurn === live else { return }
        turns.append(contentsOf: pendingUserTurns)
        pendingUserTurns.removeAll()
        // Only fold in an assistant turn that actually has renderable content. A
        // finalized turn can be non-empty *solely* because of an inline error /
        // "Cancelled." message (which `snapshotAsMessageTurn` can't represent as a
        // persisted block, since ContentBlock has no error case) — appending its
        // zero-block snapshot would render as "No content". Such a transient error
        // placeholder is simply dropped on the next send; the user turn is kept.
        let snapshot = live.snapshotAsMessageTurn()
        if !snapshot.blocks.isEmpty {
            turns.append(snapshot)
        }
        liveTurn = nil
        requestScrollToBottom()
    }

    // MARK: - Cancel

    func cancel() {
        guard let live = liveTurn else { return }
        let conn = connectionID
        isTurnActive = false
        isDiscoveringLive = false
        isReconnecting = false
        recoveryMessage = nil
        sendPipelineID = nil
        promptClientMessageID = nil
        promptRequestInFlight = false
        clearInteractivePrompts()
        live.flushAllText()
        live.isStreaming = false
        if live.isEmpty {
            live.errorMessage = "Cancelled."
        }
        sendState = .idle
        sendTask?.cancel()
        consumerTask?.cancel()
        closeStream()
        requestScrollToBottom()
        if let conn {
            Task { [weak self] in
                try? await self?.client.cancel(connectionId: conn)
            }
        }
    }

    private func closeStream() {
        // Supersede the current consumer so its imminent `.closed`/`.detached`
        // frame is ignored (it must not end a turn we are deliberately closing).
        streamGeneration &+= 1
        attachDeadlineTask?.cancel()
        attachDeadlineTask = nil
        consumerTask?.cancel()
        consumerTask = nil
        resumeReady(throwing: CancellationError())
        // Drop any pending silent reconnect — a deliberate close ends recovery.
        reconnectTask?.cancel()
        reconnectTask = nil
        stream?.detach(subscriptionId: subscriptionID)
        stream?.close()
        stream = nil
    }

    /// Tear down all live work — call from `.onDisappear` / deinit paths.
    func teardown() {
        isScreenVisible = false
        watchdogTask?.cancel()
        watchdogTask = nil
        touchTask?.cancel()
        touchTask = nil
        sendPipelineID = nil
        promptRequestInFlight = false
        sendTask?.cancel()
        sendTask = nil
        consumerTask?.cancel()
        consumerTask = nil
        agentOptions.teardown()
        insertModel.teardown()
        closeStream()
        if let live = liveTurn, isTurnActive {
            live.flushAllText()
            Task { [weak self] in await self?.reconcileOrFail(live: live, reason: nil) }
        }
    }

    // MARK: - Scroll

    private func requestScrollToBottom() {
        scrollTick &+= 1
    }

    /// Force the transcript to re-pin to the bottom even if the user had scrolled
    /// up (their own send / initial load).
    private func requestStickToBottom() {
        stickTick &+= 1
    }

    /// The transcript reports its bottom-proximity here as the user scrolls, so the
    /// floating "jump to latest" button can appear/disappear.
    func setPinnedToBottom(_ pinned: Bool) {
        if isPinnedToBottom != pinned { isPinnedToBottom = pinned }
    }

    /// The user tapped the floating "jump to latest" button.
    func userTappedScrollToBottom() {
        isPinnedToBottom = true
        requestStickToBottom()
    }

    // MARK: - Conversation actions (nav-bar "…" menu)

    /// Whether there's a real, server-linked conversation to act on (gates the
    /// actions menu; a brand-new unsent draft has none yet).
    var canManageConversation: Bool { conversationID != nil && summary != nil }

    /// Pinned state for the menu's Pin/Unpin label.
    var isPinned: Bool { summary?.isPinned ?? false }

    /// Current lifecycle status (for the status submenu's checkmark).
    var currentStatus: ConversationStatus? { summary?.status }

    /// Rename the conversation. Optimistically updates the title (so the nav
    /// title and details sheet reflect it immediately), reverting on failure.
    func rename(to newTitle: String) async {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = conversationID, !trimmed.isEmpty, trimmed != summary?.title else { return }
        let previous = summary?.title
        summary?.title = trimmed
        do {
            try await client.renameConversation(conversationId: id, title: trimmed)
            notifyConversationsChanged()
        } catch {
            summary?.title = previous
            notice = APIError.userMessage(error)
        }
    }

    /// Pin or unpin. Optimistically flips `pinnedAt`, reverting on failure.
    func togglePin() async {
        guard let id = conversationID else { return }
        userToggleTick &+= 1
        let next = !isPinned
        let previous = summary?.pinnedAt
        summary?.pinnedAt = next ? (previous ?? Date()) : nil
        do {
            try await client.setPinned(conversationId: id, pinned: next)
            notifyConversationsChanged()
        } catch {
            summary?.pinnedAt = previous
            notice = APIError.userMessage(error)
        }
    }

    /// Change lifecycle status. Optimistically updates, reverting on failure.
    func setStatus(_ status: ConversationStatus) async {
        guard let id = conversationID, summary?.status != status else { return }
        userToggleTick &+= 1
        let previous = summary?.status
        summary?.status = status
        do {
            try await client.updateStatus(conversationId: id, status: status)
            notifyConversationsChanged()
        } catch {
            summary?.status = previous ?? status
            notice = APIError.userMessage(error)
        }
    }

    /// Permanently delete the conversation. Returns `true` on success so the
    /// view can pop back to the list; on failure surfaces a notice and stays.
    func deleteConversation() async -> Bool {
        guard let id = conversationID else { return false }
        do {
            try await client.deleteConversation(conversationId: id)
            notifyConversationsChanged()
            return true
        } catch {
            notice = APIError.userMessage(error)
            return false
        }
    }

    /// Tell the (separate) session-list view model to refetch after a mutation,
    /// so it doesn't show a stale title/status or a still-tappable deleted row.
    private func notifyConversationsChanged() {
        NotificationCenter.default.post(name: .conversationsDidChange, object: nil)
    }

}

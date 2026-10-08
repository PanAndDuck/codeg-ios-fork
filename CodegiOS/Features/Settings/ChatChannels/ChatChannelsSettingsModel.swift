import SwiftUI
import Observation

/// Loads + manages chat channels: the channel list joined with live connection
/// status, plus create/update (incl. keyring token) and optimistic delete.
@MainActor
@Observable
final class ChatChannelsSettingsModel {
    enum Phase: Equatable { case loading, loaded, failed(String) }

    private(set) var phase: Phase = .loading
    private(set) var channels: [ChatChannelInfo] = []
    /// channelId → live status (from `get_chat_channel_status`).
    private(set) var statuses: [Int: ChannelConnectionStatus] = [:]
    var refreshError: String?
    var toast: String?
    /// Channels whose instant enable/disable write is in flight (disables that
    /// row's toggle so a double-tap can't race two writes).
    private(set) var togglingEnabled: Set<Int> = []

    private let client: CodegClient?

    /// Tail of a serial chain that the list refresh + the row enable toggles append
    /// to, so they run in call order: a refresh can't land a stale snapshot over a
    /// just-confirmed toggle, and the toggle's optimistic write + reconcile happen
    /// atomically relative to any `load()`. (Mirrors the Agents page.)
    private var opTail: Task<Void, Never> = Task {}

    init(client: CodegClient?) { self.client = client }

    func load() async {
        let prior = opTail
        let task = Task { @MainActor in
            await prior.value
            await self.loadBody()
        }
        opTail = task
        await task.value
    }

    private func loadBody() async {
        guard let client else { phase = .failed("No server selected."); return }
        if channels.isEmpty { phase = .loading }
        do {
            channels = try await client.listChatChannels()
            phase = .loaded
            refreshError = nil
            await loadStatuses()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            if channels.isEmpty { phase = .failed(error.localizedDescription) }
            else { refreshError = APIError.userMessage(error) }
        }
    }

    /// Cheap status-only refresh (used on re-appear without a full reload).
    func loadStatuses() async {
        guard let client, let list = try? await client.chatChannelStatus() else { return }
        statuses = Dictionary(list.map { ($0.channelId, $0.status) }, uniquingKeysWith: { _, new in new })
    }

    func status(for channel: ChatChannelInfo) -> ChannelConnectionStatus {
        statuses[channel.id] ?? .disconnected
    }

    /// Instant enable/disable from the list row. Flips only `enabled` (optimistic),
    /// preserving the rest of the channel. Disabling a *connected* channel first
    /// disconnects it (mirrors the web's `handleToggleEnabled`) so we never show
    /// "disabled" while the backend is still connected. Runs inside the serial
    /// chain, reads the live element at its slot, and reconciles by id (never a
    /// captured index) — so a concurrent `load()` can't clobber it.
    func setEnabled(_ channel: ChatChannelInfo, _ on: Bool) async {
        guard client != nil else { return }
        // Reentrancy guard (the toggle is also disabled in-flight in the UI).
        guard !togglingEnabled.contains(channel.id),
              channels.contains(where: { $0.id == channel.id }) else { return }
        togglingEnabled.insert(channel.id)
        let prior = opTail
        let task = Task { @MainActor in
            await prior.value
            guard let client = self.client,
                  let index = self.channels.firstIndex(where: { $0.id == channel.id }) else { return }
            let previous = self.channels[index].enabled
            guard previous != on else { return }   // already in the desired state
            self.channels[index] = self.channels[index].with(enabled: on)   // optimistic, at this slot
            do {
                if !on {
                    // Disabling: refresh the live status at this slot first — the
                    // cached value can be stale or missing (`loadStatuses` keeps the
                    // last value on a failed read). If the channel is connected,
                    // disconnect it BEFORE persisting enabled=false (web parity) so a
                    // "disabled" channel never leaves a live backend connection. A
                    // disconnect failure aborts the disable (caught below → reverted).
                    await self.loadStatuses()
                    if self.statuses[channel.id] == .connected {
                        try await client.disconnectChatChannel(id: channel.id)
                        // Reconcile the status now so the pill can't stay "Connected"
                        // if a later refresh fails — don't depend on loadStatuses().
                        self.statuses[channel.id] = .disconnected
                    }
                }
                var body = UpdateChatChannelBody(id: channel.id)
                body.enabled = on
                let updated = try await client.updateChatChannel(body)
                if let now = self.channels.firstIndex(where: { $0.id == channel.id }) {
                    self.channels[now] = updated
                }
            } catch {
                if let now = self.channels.firstIndex(where: { $0.id == channel.id }) {
                    self.channels[now] = self.channels[now].with(enabled: previous)
                }
                self.refreshError = APIError.userMessage(error)
            }
        }
        opTail = Task { @MainActor in _ = await task.value }
        await task.value
        togglingEnabled.remove(channel.id)
    }

    func create(name: String, type: ChannelType, configJson: String, enabled: Bool, dailyReportEnabled: Bool, dailyReportTime: String?, token: String?) async throws {
        guard let client else { return }
        let created = try await client.createChatChannel(
            name: name, channelType: type, configJson: configJson,
            enabled: enabled, dailyReportEnabled: dailyReportEnabled, dailyReportTime: dailyReportTime
        )
        if let token, !token.isEmpty {
            do {
                try await client.saveChatChannelToken(channelId: created.id, token: token)
            } catch {
                // Keep create atomic: roll back the just-created channel so a retry
                // can't leave a duplicate (best-effort delete), then surface the error.
                try? await client.deleteChatChannel(id: created.id)
                await load()
                throw error
            }
        }
        await load()
    }

    func update(_ body: UpdateChatChannelBody, token: String?) async throws {
        guard let client else { return }
        _ = try await client.updateChatChannel(body)
        if let token, !token.isEmpty {
            try await client.saveChatChannelToken(channelId: body.id, token: token)
        }
        await load()
    }

    func delete(_ channel: ChatChannelInfo) async {
        guard let client else { return }
        let previous = channels
        channels.removeAll { $0.id == channel.id }
        do {
            try await client.deleteChatChannel(id: channel.id)
            toast = "Deleted “\(channel.name)”."
        } catch {
            channels = previous
            if let message = APIError.userMessage(error) { toast = "Couldn’t delete: \(message)" }
        }
    }
}

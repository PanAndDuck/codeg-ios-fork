import Foundation
import Observation

/// Live connection state for a single server, derived from a `health()` probe.
enum ServerStatus: Equatable, Sendable {
    case checking
    case online(version: String)
    case offline(reason: String)

    var isChecking: Bool {
        if case .checking = self { return true }
        return false
    }
}

/// Tracks per-server reachability by probing `health()` on each `CodegClient`.
///
/// Probes run concurrently (one child task per server inside a `TaskGroup`) and
/// never block the UI: callers fire `refreshAll()` / `refresh(_:)` and read the
/// published `statuses` map. Each server carries its own monotonic generation
/// token, so a result is only written if it belongs to the latest probe *of
/// that server*. This means overlapping refreshes of different servers never
/// strand one in `.checking`, while a newer probe of the same server still
/// supersedes a slower older one.
@MainActor
@Observable
final class ServerStatusModel {
    /// Current status keyed by `ServerProfile.id`. Absent ⇒ never probed.
    private(set) var statuses: [UUID: ServerStatus] = [:]

    private let store: ServerStore
    /// Latest probe token issued per server; a result is applied only if it
    /// still matches, otherwise a fresher probe has superseded it.
    private var generations: [UUID: Int] = [:]
    private var nextToken = 0

    init(store: ServerStore) {
        self.store = store
    }

    /// Status for a server, defaulting to `.checking` until the first probe
    /// resolves so rows show a spinner rather than flicker empty.
    func status(for id: UUID) -> ServerStatus {
        statuses[id] ?? .checking
    }

    /// Probe every saved server concurrently. Safe to call repeatedly; for each
    /// server, only the most recent probe's result is applied.
    func refreshAll() async {
        let servers = store.servers

        // Drop statuses/tokens for servers that no longer exist, then mark all
        // live ones as checking for immediate visual feedback.
        let liveIDs = Set(servers.map(\.id))
        statuses = statuses.filter { liveIDs.contains($0.key) }
        generations = generations.filter { liveIDs.contains($0.key) }

        var tokens: [UUID: Int] = [:]
        for server in servers {
            let token = issueToken(for: server.id)
            tokens[server.id] = token
            statuses[server.id] = .checking
        }

        await probe(servers, tokens: tokens)
    }

    /// Re-probe a single server (used after add/edit so its dot updates without
    /// resweeping the whole list).
    func refresh(_ server: ServerProfile) async {
        let token = issueToken(for: server.id)
        statuses[server.id] = .checking
        await probe([server], tokens: [server.id: token])
    }

    /// Forget a server's status (call after delete).
    func remove(_ id: UUID) {
        statuses.removeValue(forKey: id)
        generations.removeValue(forKey: id)
    }

    // MARK: - Probing

    /// Allocate a fresh per-server token and record it as the current one.
    private func issueToken(for id: UUID) -> Int {
        nextToken += 1
        generations[id] = nextToken
        return nextToken
    }

    private func probe(_ servers: [ServerProfile], tokens: [UUID: Int]) async {
        guard !servers.isEmpty else { return }

        await withTaskGroup(of: (UUID, ServerStatus?).self) { group in
            for server in servers {
                group.addTask { [store] in
                    await store.prepareEndpoint(for: server)
                    let client = await store.client(for: server)
                    return await (server.id, Self.probeOne(client))
                }
            }
            // Apply each result the moment its own probe resolves, rather than
            // waiting for the whole group. A reachable server's status appears
            // right away even when a peer is down and won't time out for many
            // seconds — one unreachable host no longer strands every other row
            // in `.checking`. Apply only if it's still the latest probe for that
            // server (a newer refresh supersedes a slower older one).
            for await (id, status) in group where tokens[id] == generations[id] {
                guard let status else { continue }
                statuses[id] = status
            }
        }
    }

    /// Probe one client off the main actor. A missing client means the profile
    /// has no URL/token, which we report as offline.
    private nonisolated static func probeOne(_ client: CodegClient?) async -> ServerStatus? {
        guard let client else {
            return .offline(reason: "Missing URL or token")
        }
        do {
            let health = try await client.health()
            return .online(version: health.version)
        } catch {
            return APIError.userMessage(error).map { .offline(reason: $0) }
        }
    }
}

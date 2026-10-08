import SwiftUI
import Observation

/// Loads + mutates locally-installed MCP servers (`mcp_scan_local`). Add/edit go
/// through `mcp_upsert_local_server` (spec + apps together); delete is optimistic
/// with rollback. Marketplace install is deferred to a later pass.
@MainActor
@Observable
final class McpSettingsModel {
    enum Phase: Equatable { case loading, loaded, failed(String) }

    private(set) var phase: Phase = .loading
    private(set) var servers: [LocalMcpServer] = []
    var refreshError: String?

    private let client: CodegClient?

    init(client: CodegClient?) { self.client = client }

    func load() async {
        guard let client else { phase = .failed("No server selected."); return }
        if servers.isEmpty { phase = .loading }
        do {
            servers = try await client.mcpScanLocal().sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
            phase = .loaded
            refreshError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            if servers.isEmpty { phase = .failed(error.localizedDescription) }
            else { refreshError = APIError.userMessage(error) }
        }
    }

    func upsert(serverId: String, spec: JSONValue, apps: [McpAppType]) async throws {
        guard let client else { return }
        _ = try await client.mcpUpsertLocalServer(serverId: serverId, spec: spec, apps: apps)
        await load()
    }

    func remove(_ server: LocalMcpServer) async {
        guard let client else { return }
        let previous = servers
        servers.removeAll { $0.id == server.id }
        do {
            try await client.mcpRemoveServer(serverId: server.id)
        } catch {
            servers = previous
            refreshError = APIError.userMessage(error)
        }
    }
}

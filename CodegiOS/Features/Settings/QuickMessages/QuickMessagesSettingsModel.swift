import SwiftUI
import Observation

/// Loads and mutates the server's quick-message templates. Mirrors the
/// list+editor model pattern (`ServerStatusModel`): a `phase` for first load,
/// stale-data `refreshError` banner, optimistic delete/reorder with rollback.
@MainActor
@Observable
final class QuickMessagesSettingsModel {
    enum Phase: Equatable { case loading, loaded, failed(String) }

    private(set) var phase: Phase = .loading
    private(set) var items: [QuickMessage] = []
    /// Non-fatal error after data already loaded (a refresh/mutation failed).
    var refreshError: String?

    private let client: CodegClient?

    init(client: CodegClient?) { self.client = client }

    func load() async {
        guard let client else { phase = .failed("No server selected."); return }
        if items.isEmpty { phase = .loading }
        do {
            items = try await client.quickMessagesList().sorted { $0.sortOrder < $1.sortOrder }
            phase = .loaded
            refreshError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            if items.isEmpty { phase = .failed(error.localizedDescription) }
            else { refreshError = APIError.userMessage(error) }
        }
    }

    func create(title: String, content: String) async throws {
        guard let client else { return }
        _ = try await client.quickMessageCreate(title: title, content: content)
        await load()
    }

    func update(id: Int, title: String, content: String) async throws {
        guard let client else { return }
        _ = try await client.quickMessageUpdate(id: id, title: title, content: content)
        await load()
    }

    func delete(at offsets: IndexSet) async {
        guard let client else { return }
        let targets = offsets.map { items[$0] }
        let previous = items
        items.remove(atOffsets: offsets)
        do {
            for target in targets { try await client.quickMessageDelete(id: target.id) }
        } catch {
            items = previous
            refreshError = APIError.userMessage(error)
        }
    }

    private var reorderInFlight = false
    private var pendingOrder: [Int]?

    /// Reorder locally for immediacy, then persist via a coalescing serial sender.
    func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
        pendingOrder = items.map(\.id)
        Task { await drainReorder() }
    }

    /// Persist reorders serially: only one request is ever in flight, and it
    /// always sends the LATEST desired order — so rapid consecutive drags can't
    /// land on the server out of sequence (which would leave a stale order). On
    /// failure, reload to resync with the server's truth.
    private func drainReorder() async {
        guard !reorderInFlight, let client else { return }
        reorderInFlight = true
        defer { reorderInFlight = false }
        while let ids = pendingOrder {
            pendingOrder = nil
            do {
                try await client.quickMessagesReorder(ids: ids)
            } catch {
                refreshError = APIError.userMessage(error)
                await load()
                return
            }
        }
    }
}

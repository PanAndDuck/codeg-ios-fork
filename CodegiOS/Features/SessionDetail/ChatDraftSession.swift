import Foundation
import Observation

/// A chat draft owns one scratch directory and at most one conversation.
/// Tasks are shared across reentrant callers; an uncertain create is reconciled
/// by that directory before another POST. The server also enforces unique paths.
@MainActor @Observable
final class ChatDraftSession {
    private let client: CodegClient
    private(set) var directory: String?
    private(set) var conversation: CreateChatConversationResult?
    private var directoryTask: Task<String, Error>?
    private var creationTask: Task<CreateChatConversationResult, Error>?
    private var needsReconciliation = false

    var isAvailable: Bool { client.transport.chatAvailability.isAvailable }
    var hasUnresolvedCreation: Bool { needsReconciliation && conversation == nil && isAvailable }

    init(client: CodegClient) { self.client = client }

    func prepareDirectory() async throws -> String {
        if let directory { return directory }
        if let directoryTask { return try await directoryTask.value }
        guard isAvailable else { throw APIError.server(status: 501, code: nil, message: "") }
        let task = Task { try await client.createChatDirectory() }
        directoryTask = task
        defer { directoryTask = nil }
        let path = try await task.value
        directory = path
        return path
    }

    func createConversation(agent: AgentType, title: String?) async throws -> CreateChatConversationResult {
        if let conversation { return conversation }
        if let creationTask { return try await creationTask.value }
        guard isAvailable else { throw APIError.server(status: 501, code: nil, message: "") }
        let task = Task { () throws -> CreateChatConversationResult in
            let path = try await prepareDirectory()
            if needsReconciliation, let recovered = try await findCreatedConversation(path: path) {
                return recovered
            }
            // Retain this flag through cancellation, transport and decode errors.
            // A successful response can be lost after the server commits the row.
            needsReconciliation = true
            return try await client.createChatConversation(agentType: agent, title: title, existingDir: path)
        }
        creationTask = task
        defer { creationTask = nil }
        let result = try await task.value
        conversation = result
        needsReconciliation = false
        return result
    }

    private func findCreatedConversation(path: String) async throws -> CreateChatConversationResult? {
        let folders = try await client.listFolders()
        guard let folder = folders.first(where: { $0.kind == .chat && $0.path == path }) else { return nil }
        let rows = try await client.listConversations(folderIds: [folder.id])
        guard let row = rows.first(where: { $0.folderId == folder.id }) else {
            // A previous request can still be between the two server inserts.
            throw APIError.transport(String(localized: "Chat is still being created. Please try again."))
        }
        return CreateChatConversationResult(conversationId: row.id, folderId: folder.id, folder: folder)
    }
}

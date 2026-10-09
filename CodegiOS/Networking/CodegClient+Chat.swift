import Foundation
import Observation

/// Shared by clients for the same server transport, including LAN/relay switches.
@MainActor @Observable
final class ChatEndpointAvailability {
    var isAvailable = true
    nonisolated init() {}

    func record(_ error: Error) {
        if case APIError.server(let status, _, _) = error, status == 404 || status == 501 {
            isAvailable = false
        }
    }
}

struct CreateChatDirectoryResult: Decodable, Sendable {
    let path: String
}

struct CreateChatConversationResult: Decodable, Sendable {
    let conversationId: Int
    let folderId: Int
    let folder: FolderDetail
}

extension CodegClient {
    @MainActor
    func createChatDirectory() async throws -> String {
        do {
            let result: CreateChatDirectoryResult = try await postJSON("create_chat_dir", EmptyBody())
            return result.path
        } catch {
            transport.chatAvailability.record(error)
            throw error
        }
    }

    @MainActor
    func createChatConversation(agentType: AgentType, title: String?, existingDir: String?) async throws -> CreateChatConversationResult {
        do {
            return try await postJSON("create_chat_conversation", CreateChatConversationBody(
                agentType: agentType, title: title, existingDir: existingDir
            ))
        } catch {
            transport.chatAvailability.record(error)
            throw error
        }
    }
}

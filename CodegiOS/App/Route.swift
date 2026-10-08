import Foundation

/// The five top-level tabs of the compact (iPhone) shell: four content tabs
/// plus the system search tab (rendered by iOS 26 as the separated glass
/// magnifier next to the tab bar). Regular width (iPad) maps the same
/// destinations onto the split view's sidebar instead.
enum AppTab: String, Hashable, CaseIterable {
    case chats
    case projects
    case activity
    case settings
    case search
}

/// iPad sidebar selection — the split view's "source list". Settings is
/// presented as a sheet on iPad (gear in the sidebar toolbar), and search rides
/// the content column, so neither needs a sidebar row.
enum SidebarSection: String, Hashable {
    case chats
    case projects
    case activity
}

/// A pushable destination. Every entry point (list rows, search results,
/// activity, the running bar, deep links, future push notifications) converges
/// on this enum so navigation behaves identically regardless of origin.
enum Route: Hashable {
    case conversation(Int)
    case project(Int)
    /// The "start a new task" screen: a blank session detail. The agent, folder,
    /// and config are chosen in-page (from the nav-bar agent button), and the
    /// first send connects + prompts before a server conversation id exists
    /// (it adopts one on `conversation_linked`).
    case newSession(NewSessionRequest)
}

/// A draft new-task token. Carries only an optional preselected folder (e.g.
/// when launched from a project); the agent/folder/first message are all chosen
/// on the session screen itself, so this is just a stable identity for the
/// pushed/pending draft.
struct NewSessionRequest: Hashable, Identifiable {
    let id: UUID
    var preselectedFolderID: Int?

    init(id: UUID = UUID(), preselectedFolderID: Int? = nil) {
        self.id = id
        self.preselectedFolderID = preselectedFolderID
    }
}

extension Route {
    /// Accept this build's OS scheme plus the existing `codeg://` content links.
    static func accepts(url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "codeg" { return true }
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        return types.contains { type in
            (type["CFBundleURLSchemes"] as? [String] ?? []).contains { $0.lowercased() == scheme }
        }
    }

    /// Parse a deep link using the registered OS scheme or `codeg://`:
    /// `…://conversation/<id>` and `…://project/<id>`. (`…://tab/<name>` switches tabs rather than
    /// pushing, so `AppModel.handle(url:)` deals with it before calling this.)
    static func from(url: URL) -> Route? {
        guard accepts(url: url) else { return nil }
        let id = url.pathComponents.count > 1 ? Int(url.pathComponents[1]) : nil
        switch url.host?.lowercased() {
        case "conversation": return id.map { .conversation($0) }
        case "project": return id.map { .project($0) }
        default: return nil
        }
    }
}

import SwiftUI

/// Names belong to a server catalog, never to global agent identity. Keeping
/// this value in the owning feature avoids leaking names between servers.
struct AgentDisplayNames {
    private var names: [AgentType: String]

    init(agents: [AcpAgentInfo] = []) {
        names = Dictionary(agents.map { ($0.agentType, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    func name(for agent: AgentType, abbreviated: Bool = false) -> String {
        if !agent.isBuiltIn, let name = names[agent], !name.isEmpty { return name }
        return abbreviated ? agent.shortName : agent.displayName
    }
}

private struct AgentDisplayNamesKey: EnvironmentKey {
    static let defaultValue = AgentDisplayNames()
}

extension EnvironmentValues {
    var agentDisplayNames: AgentDisplayNames {
        get { self[AgentDisplayNamesKey.self] }
        set { self[AgentDisplayNamesKey.self] = newValue }
    }
}

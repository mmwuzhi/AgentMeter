import AgentStatusCore
import Foundation

struct ActiveAgentNode: Identifiable, Sendable, Equatable {
    let agent: ActiveAgent
    var children: [ActiveAgent] = []
    var id: String { agent.id }

    var topStatus: AgentStatusState? {
        ([agent] + children).compactMap(\.displayStatus).max { $0.priority < $1.priority }
    }

    var statusRank: Int { topStatus?.priority ?? -1 }
}

struct ActiveAgentGroup: Identifiable, Sendable, Equatable {
    let provider: Provider
    let projectName: String
    let projectPath: String?
    var nodes: [ActiveAgentNode]

    var id: String { "\(provider.rawValue):\(projectPath ?? "pid:\(nodes.first?.agent.pid ?? 0)")" }
    var agentCount: Int { nodes.reduce(0) { $0 + 1 + $1.children.count } }
    var isFlat: Bool { nodes.count == 1 && nodes[0].children.isEmpty }
    var topStatus: AgentStatusState? {
        nodes.compactMap(\.topStatus).max { $0.priority < $1.priority }
    }
    var statusRank: Int { topStatus?.priority ?? -1 }
}

enum ActiveAgentGrouping {
    static func group(_ agents: [ActiveAgent]) -> [ActiveAgentGroup] {
        let byPID = Dictionary(agents.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })

        func topAncestor(of agent: ActiveAgent) -> ActiveAgent {
            var current = agent
            var visited = Set([agent.pid])
            while let parentPID = current.parentAgentPID,
                  let parent = byPID[parentPID],
                  parent.provider == agent.provider,
                  visited.count <= 64 {
                guard visited.insert(parent.pid).inserted else { return agent }
                current = parent
            }
            return current
        }

        var childrenByTop: [String: [ActiveAgent]] = [:]
        var topLevel: [ActiveAgent] = []
        for agent in agents {
            let top = topAncestor(of: agent)
            if top.id == agent.id {
                topLevel.append(agent)
            } else {
                childrenByTop[top.id, default: []].append(agent)
            }
        }

        func projectPath(_ agent: ActiveAgent) -> String? { agent.session?.projectPath ?? agent.cwd }
        func projectName(_ agent: ActiveAgent) -> String {
            if let name = agent.session?.projectName, !name.isEmpty { return name }
            if let path = projectPath(agent), !path.isEmpty {
                return URL(fileURLWithPath: path).lastPathComponent
            }
            return agent.provider.displayName
        }

        var groupsByKey: [String: ActiveAgentGroup] = [:]
        for agent in topLevel {
            let path = projectPath(agent)
            let key = "\(agent.provider.rawValue):" + (path ?? "pid:\(agent.pid)")
            let node = ActiveAgentNode(
                agent: agent,
                children: (childrenByTop[agent.id] ?? []).sorted(by: agentOrdersBefore)
            )
            if var group = groupsByKey[key] {
                group.nodes.append(node)
                groupsByKey[key] = group
            } else {
                groupsByKey[key] = ActiveAgentGroup(
                    provider: agent.provider,
                    projectName: projectName(agent),
                    projectPath: path,
                    nodes: [node]
                )
            }
        }

        return groupsByKey.values
            .map { group in
                var group = group
                group.nodes.sort { lhs, rhs in
                    if lhs.statusRank != rhs.statusRank { return lhs.statusRank > rhs.statusRank }
                    return agentOrdersBefore(lhs.agent, rhs.agent)
                }
                return group
            }
            .sorted { lhs, rhs in
                if lhs.statusRank != rhs.statusRank { return lhs.statusRank > rhs.statusRank }
                if lhs.provider.rawValue != rhs.provider.rawValue {
                    return lhs.provider.rawValue < rhs.provider.rawValue
                }
                let lhsElapsed = lhs.nodes.first?.agent.elapsedSeconds ?? 0
                let rhsElapsed = rhs.nodes.first?.agent.elapsedSeconds ?? 0
                if lhsElapsed != rhsElapsed { return lhsElapsed > rhsElapsed }
                return lhs.id < rhs.id
            }
    }

    private static func agentOrdersBefore(_ lhs: ActiveAgent, _ rhs: ActiveAgent) -> Bool {
        let lhsRank = lhs.displayStatus?.priority ?? -1
        let rhsRank = rhs.displayStatus?.priority ?? -1
        if lhsRank != rhsRank { return lhsRank > rhsRank }
        if lhs.elapsedSeconds != rhs.elapsedSeconds { return lhs.elapsedSeconds > rhs.elapsedSeconds }
        return lhs.pid < rhs.pid
    }
}

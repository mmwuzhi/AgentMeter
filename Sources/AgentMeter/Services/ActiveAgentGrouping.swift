import AgentStatusCore
import Foundation

/// The rows the popover lists for one provider, and how many it leaves out
/// (`ActiveAgent.isListed`). A row stays when something under it is listed: a
/// child process that is running keeps its parent's row to hang from. Pure
/// over the rows, so an app restart or a refresh reaches the same answer.
struct ActiveAgentListing: Equatable, Sendable {
    let agents: [ActiveAgent]
    let hiddenCount: Int

    init(_ all: [ActiveAgent]) {
        let byPID = Dictionary(all.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var kept = Set(all.filter(\.isListed).map(\.pid))
        for pid in kept {
            var current = byPID[pid]
            while let parentPID = current?.parentAgentPID,
                  let parent = byPID[parentPID],
                  parent.provider == current?.provider,
                  kept.insert(parentPID).inserted {
                current = parent
            }
        }
        agents = all.filter { kept.contains($0.pid) }
        hiddenCount = all.count - agents.count
    }

    var hiddenNote: String? {
        guard hiddenCount > 0 else { return nil }
        return "\(hiddenCount) idle \(hiddenCount == 1 ? "session" : "sessions") hidden"
    }

    static let hiddenHelp = "Sessions with nothing running and no activity for over 24 hours are not listed. "
        + "They are still open, and show up again as soon as they do something."
}

struct ActiveAgentNode: Identifiable, Sendable, Equatable {
    let agent: ActiveAgent
    /// Child *processes*: agents whose nearest agent ancestor is this one.
    var children: [ActiveAgent] = []
    /// The session's transcript-derived subagents that are still listed
    /// (`ActiveSubagent.isListed`). They have no process and no hook state, so
    /// they do not count toward `agentCount` and do not move `topStatus`; the
    /// hook already keeps the parent `working` while they run.
    var subagents: [ActiveSubagent] = []
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

    var allAgents: [ActiveAgent] { nodes.flatMap { [$0.agent] + $0.children } }

    /// Groups whose sessions want the user (waiting/error) start expanded;
    /// merely working or idle ones stay collapsed behind their summary.
    var needsAttention: Bool {
        (topStatus?.priority ?? -1) >= AgentStatusState.waiting.priority
    }

    /// Header line shown while the group is collapsed: total count, the most
    /// urgent status with how many sessions are in it, aggregated usage.
    var collapsedSummary: String {
        var parts = ["\(agentCount)"]
        if let status = topStatus, status != .idle {
            let count = allAgents.filter { $0.displayStatus == status }.count
            parts.append("\(count) \(status.rawValue)")
        }
        if let usage = aggregatedUsageText {
            parts.append(usage)
        }
        return parts.joined(separator: " · ")
    }

    /// Combined usage across every attributed session in the group, in the
    /// same format as a single row's usage text. nil when nothing is known.
    var aggregatedUsageText: String? {
        let sessions = allAgents.compactMap(\.session)
        let tokens = sessions.compactMap(\.tokenCount).reduce(0, +)
        guard tokens > 0 else { return nil }
        let cost = sessions.compactMap(\.estimatedCostUSD).reduce(0, +)
        guard cost >= 0.005 else { return TokenFormat.short(tokens) }
        return "\(TokenFormat.short(tokens)) · $\(String(format: "%.2f", cost))"
    }
}

extension ActiveAgentNode {
    /// Subagents stay hidden behind their parent row unless one of them is
    /// waiting for input or erroring.
    var childrenNeedAttention: Bool {
        children.contains { ($0.displayStatus?.priority ?? -1) >= AgentStatusState.waiting.priority }
    }

    /// Key under which the user's subagent-disclosure choice is remembered in
    /// `AppViewModel.sessionDisclosure`, distinct from group IDs.
    var disclosureKey: String { "subagents:\(agent.id)" }

    /// Rows behind the node's disclosure: child processes and listed subagents.
    var childRowCount: Int { children.count + subagents.count }
    var hasChildRows: Bool { childRowCount > 0 }

    /// Text on the disclosure that hides the child rows: how many there are
    /// and, while any is still running, how many of those. The count alone
    /// read the same for a session whose agents finished minutes ago and one
    /// with a workflow fanned out underneath it, which is what the line is
    /// there to tell apart.
    var childRowLabel: String {
        var label = childRowCount == 1 ? "1 subagent" : "\(childRowCount) subagents"
        let working = children.filter { $0.displayStatus == .working }.count
            + subagents.filter(\.isWorking).count
        if working > 0 { label += " · \(working) working" }
        return label
    }
}

enum ActiveAgentGrouping {
    /// Every disclosure key the current group list can legitimately remember a
    /// choice for; `AppViewModel.sessionDisclosure` is pruned against this.
    static func disclosureKeys(for groups: [ActiveAgentGroup]) -> Set<String> {
        var keys = Set(groups.map(\.id))
        for group in groups {
            for node in group.nodes where node.hasChildRows {
                keys.insert(node.disclosureKey)
            }
        }
        return keys
    }

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
                children: (childrenByTop[agent.id] ?? []).sorted(by: agentOrdersBefore),
                subagents: (agent.session?.subagents ?? []).filter(\.isListed)
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

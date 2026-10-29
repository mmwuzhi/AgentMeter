import AgentStatusCore
import Foundation
@testable import AgentMeter
import XCTest

/// How the Sessions list is ordered and counted: needs-the-user first, then
/// running, then idle sessions newest activity first, at the level of
/// processes, nodes and groups.
final class ActiveAgentOrderingTests: XCTestCase {
    private let observedAt = Date(timeIntervalSince1970: 2_000_000_000)
    private let hour: TimeInterval = 3_600
    private let day: TimeInterval = 86_400

    /// `age`: how long before `observedAt` the session last did something
    /// (state change and transcript alike); nil leaves it undated.
    private func agent(
        _ pid: Int,
        project: String = "alpha",
        status: AgentStatusState? = .idle,
        source: ActiveAgentStatusSource = .registry,
        age: TimeInterval? = 60,
        processAge: TimeInterval = 86_400,
        parent: Int? = nil,
        observed: Date? = nil
    ) -> ActiveAgent {
        let seen = observed ?? observedAt
        let stamp = age.map { seen.addingTimeInterval(-$0) }
        return ActiveAgent(
            provider: .claude, pid: pid, parentPID: 1, command: "claude", elapsedSeconds: processAge,
            observedAt: seen, cwd: "/work/\(project)",
            session: stamp.map {
                ActiveAgentSession(id: "s\(pid)", projectPath: "/work/\(project)", projectName: project,
                                   branch: nil, lastUpdatedAt: $0, source: "test")
            },
            parentAgentPID: parent, status: status,
            statusUpdatedAt: stamp, statusSource: status == nil ? nil : source
        )
    }

    private func order(_ agents: [ActiveAgent]) -> [Int] {
        ActiveAgentGrouping.group(agents).flatMap { $0.nodes.map(\.agent.pid) }
    }

    private func groupOrder(_ agents: [ActiveAgent]) -> [String] {
        ActiveAgentGrouping.group(agents).map(\.projectName)
    }

    // MARK: Idle sessions

    func testIdleSessionsAreNewestActivityFirstNotOldestProcessFirst() {
        // What the list did: the oldest process first, so a session opened days
        // ago and idle for a day sat above one that finished a minute ago.
        let rows = [
            agent(1, age: 20 * hour, processAge: 4 * day),
            agent(2, age: 10 * hour, processAge: 3 * day),
            agent(3, age: 30 * hour, processAge: 2 * day),
            agent(4, age: 1 * hour, processAge: 1 * day),
        ]

        XCTAssertEqual(order(rows), [4, 2, 1, 3])
    }

    func testTheLastActivityIsTheOneTheListingAndTheRowUse() {
        // State stamped long ago, transcript written a minute ago (and the
        // reverse): the newer of the two places the session.
        let rows = [
            agent(1, age: 5 * hour),
            ActiveAgentOrderingTests.mixed(pid: 2, stateAge: 4 * day, transcriptAge: 60, observedAt: observedAt),
            ActiveAgentOrderingTests.mixed(pid: 3, stateAge: 60 * 30, transcriptAge: 4 * day, observedAt: observedAt),
        ]

        XCTAssertEqual(order(rows), [2, 3, 1])
    }

    func testAnUndatedSessionIsLastAmongTheIdleOnes() {
        let rows = [agent(1, age: nil), agent(2, age: 20 * hour), agent(3, age: 2 * hour)]

        XCTAssertEqual(order(rows), [3, 2, 1])
    }

    func testARowWithNeitherStateNorDateIsLastOfAll() {
        // No registry, no hook, no transcript time: nothing to rank it by.
        let rows = [agent(1, status: nil, age: nil), agent(2, age: 5 * day), agent(3, age: 20 * hour)]

        XCTAssertEqual(order(rows), [3, 2, 1])
    }

    func testARowWithoutHookOrRegistryIsOrderedByItsTranscriptLikeAnyIdleOne() {
        // What a Codex process is: no state at all, only the rollout's time.
        let rows = [
            agent(1, status: nil, age: 20 * hour),
            agent(2, status: nil, age: 2 * hour),
            agent(3, age: 5 * hour),
        ]

        XCTAssertEqual(order(rows), [2, 3, 1])
    }

    func testEqualTimesFallBackToProcessAgeThenPid() {
        let rows = [
            agent(30, age: hour, processAge: 1 * day),
            agent(20, age: hour, processAge: 2 * day),
            agent(10, age: hour, processAge: 2 * day),
        ]

        XCTAssertEqual(order(rows), [10, 20, 30])
    }

    // MARK: Active sessions

    func testNeedsTheUserFirstThenRunningThenIdle() {
        let rows = [
            agent(1, status: .idle, age: 10),
            agent(2, status: .working, age: 5 * day),
            agent(3, status: .waiting, age: 5 * day),
            agent(4, status: .error, source: .hook, age: 600),
        ]

        XCTAssertEqual(order(rows), [4, 3, 2, 1])
    }

    func testRunningSessionsKeepTheirPlacesWhileTheirTranscriptsMove() {
        // A working session's transcript is written to all the time; ordering
        // by it would make two running sessions swap on every refresh.
        func rows(newer: Int) -> [ActiveAgent] {
            [agent(1, status: .working, age: newer == 1 ? 2 : 90, processAge: 2 * day),
             agent(2, status: .working, age: newer == 2 ? 2 : 90, processAge: 1 * day)]
        }

        XCTAssertEqual(order(rows(newer: 1)), [1, 2])
        XCTAssertEqual(order(rows(newer: 2)), [1, 2])
    }

    func testAnIdleSessionThatStartsWorkingMovesAboveTheIdleOnes() {
        let before = [agent(1, age: 2 * hour), agent(2, age: 20 * hour)]
        XCTAssertEqual(order(before), [1, 2])

        let after = [agent(1, age: 2 * hour), agent(2, status: .working, age: 1)]
        XCTAssertEqual(order(after), [2, 1])
    }

    // MARK: Stability

    func testTheOrderDoesNotDependOnTheOrderTheRowsArriveIn() {
        let rows = [
            agent(1, age: 20 * hour, processAge: 4 * day),
            agent(2, status: .working, age: 3, processAge: 3 * day),
            agent(3, age: hour, processAge: 2 * day),
            agent(4, age: hour, processAge: 2 * day),
            agent(5, status: .waiting, age: day, processAge: 1 * day),
            agent(6, age: nil),
        ]
        let expected = order(rows)

        var permutation = Array(rows.indices)
        for shuffle in 0..<60 {
            permutation.swapAt(shuffle % rows.count, (shuffle * 7 + 3) % rows.count)
            XCTAssertEqual(order(permutation.map { rows[$0] }), expected, "shuffle \(shuffle)")
        }
        XCTAssertEqual(expected, [5, 2, 3, 4, 1, 6])
    }

    func testRandomRowsOrderTheSameWhateverTheArrivalOrder() {
        // A comparator that is not a strict weak order (a rank mixed with a
        // time that only some ranks use, nil times, equal times) gives a
        // different answer for a different input order; this is what would show.
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Int(state % UInt64(bound))
        }
        let statuses: [AgentStatusState?] = [.error, .waiting, .working, .idle, .idle, .idle, nil]
        let ages: [TimeInterval?] = [nil, 30, 600, 600, 3 * hour, 3 * hour, day, 5 * day]
        for trial in 0..<60 {
            let rows = (1...9).map { pid in
                agent(pid, project: ["a", "b", "c"][next(3)], status: statuses[next(statuses.count)],
                      age: ages[next(ages.count)], processAge: [day, 2 * day, 2 * day][next(3)],
                      parent: next(5) == 0 && pid > 1 ? next(pid - 1) + 1 : nil)
            }
            let expected = order(rows)
            let expectedGroups = groupOrder(rows)
            for _ in 0..<12 {
                var shuffled = rows
                for index in shuffled.indices.reversed() { shuffled.swapAt(index, next(index + 1)) }
                XCTAssertEqual(order(shuffled), expected, "trial \(trial)")
                XCTAssertEqual(groupOrder(shuffled), expectedGroups, "trial \(trial)")
            }
        }
    }

    func testTheNextRefreshOfAnUnchangedWorldReordersNothing() {
        // Five seconds later every process is five seconds older and the
        // observation moved with it; nothing else happened.
        func rows(shift: TimeInterval) -> [ActiveAgent] {
            let seen = observedAt.addingTimeInterval(shift)
            return [
                agent(1, age: 20 * hour + shift, processAge: 4 * day + shift, observed: seen),
                agent(2, status: .working, age: 30 + shift, processAge: 3 * day + shift, observed: seen),
                agent(3, age: hour + shift, processAge: 2 * day + shift, observed: seen),
                agent(4, project: "beta", age: 5 * hour + shift, processAge: 1 * day + shift, observed: seen),
            ]
        }

        XCTAssertEqual(order(rows(shift: 0)), order(rows(shift: 5)))
        XCTAssertEqual(groupOrder(rows(shift: 0)), groupOrder(rows(shift: 5)))
        XCTAssertEqual(ActiveAgentGrouping.group(rows(shift: 0)).map(\.id),
                       ActiveAgentGrouping.group(rows(shift: 5)).map(\.id))
    }

    // MARK: Groups

    func testAProjectWithARunningSessionComesFirstThenTheNewestIdleProject() {
        let rows = [
            agent(1, project: "old", age: 20 * hour),
            agent(2, project: "busy", status: .working, age: 3 * day),
            agent(3, project: "fresh", age: hour),
            agent(4, project: "middle", age: 5 * hour),
        ]

        XCTAssertEqual(groupOrder(rows), ["busy", "fresh", "middle", "old"])
    }

    func testAProjectIsAsRecentAsItsNewestSession() {
        let rows = [
            agent(1, project: "a", age: 20 * hour), agent(2, project: "a", age: 2 * hour),
            agent(3, project: "b", age: 3 * hour), agent(4, project: "b", age: 4 * hour),
        ]

        XCTAssertEqual(groupOrder(rows), ["a", "b"])
        XCTAssertEqual(ActiveAgentGrouping.group(rows)[0].nodes.map(\.agent.pid), [2, 1])
    }

    func testAProjectWithWaitingOutranksOneThatOnlyWorks() {
        let rows = [
            agent(1, project: "works", status: .working, age: 1),
            agent(2, project: "waits", status: .waiting, age: 4 * day),
        ]

        XCTAssertEqual(groupOrder(rows), ["waits", "works"])
    }

    // MARK: Process trees

    func testAChildKeepsItsParentAndTheTreeIsOrderedAsOne() {
        // Parent 1 is idle for 5 h but its child ran 10 minutes ago: the tree
        // is as recent as its newest process.
        let rows = [
            agent(1, age: 5 * hour),
            agent(2, age: 10 * 60, parent: 1),
            agent(3, age: 3 * hour),
        ]

        let group = ActiveAgentGrouping.group(rows)[0]

        XCTAssertEqual(group.nodes.map(\.agent.pid), [1, 3])
        XCTAssertEqual(group.nodes[0].children.map(\.pid), [2])
    }

    func testAnIdleParentWithARunningChildRanksAsRunning() {
        let rows = [
            agent(1, age: 10 * 60),
            agent(2, age: 3 * day),
            agent(3, status: .working, age: 5, parent: 2),
        ]

        XCTAssertEqual(order(rows), [2, 1])
    }

    func testChildrenOfOneNodeFollowTheSameRule() {
        let rows = [
            agent(1, age: 30),
            agent(2, age: 5 * hour, processAge: 4 * day, parent: 1),
            agent(3, age: 1 * hour, processAge: 1 * day, parent: 1),
            agent(4, status: .working, age: 5, processAge: 2 * day, parent: 1),
        ]

        XCTAssertEqual(ActiveAgentGrouping.group(rows)[0].nodes[0].children.map(\.pid), [4, 3, 2])
    }

    // MARK: Counts

    func testTheHeaderCountsTheListedSessionsAndAgreesWithTheGroups() {
        let old = 5 * day
        let all = [
            agent(1, project: "alpha", age: 60),
            agent(2, project: "alpha", age: 120),
            agent(3, project: "beta", age: 300),
            agent(4, project: "beta", age: 400, parent: 3),
            agent(5, project: "gamma", status: .working, age: 5),
            agent(6, project: "alpha", age: old),
            agent(7, project: "delta", age: old),
            agent(8, project: "beta", age: old, parent: 3),
        ]

        let listing = ActiveAgentListing(all)
        let groups = ActiveAgentGrouping.group(listing.agents)

        XCTAssertEqual(listing.agents.map(\.pid), [1, 2, 3, 4, 5])
        XCTAssertEqual(listing.hiddenCount, 3)
        XCTAssertEqual(ActiveAgentGrouping.sessionCount(groups), 5)
        XCTAssertEqual(groups.reduce(0) { $0 + $1.agentCount }, listing.agents.count)
        // What is shown plus what is hidden is every live session, once.
        XCTAssertEqual(ActiveAgentGrouping.sessionCount(groups) + listing.hiddenCount, all.count)
    }

    func testEachGroupCountsItsListedSessionsParentsAndChildrenAlike() {
        let rows = [
            agent(1, project: "alpha", age: 60),
            agent(2, project: "alpha", age: 120),
            agent(3, project: "beta", age: 300),
            agent(4, project: "beta", age: 400, parent: 3),
            agent(5, project: "gamma", age: 500),
        ]

        let groups = Dictionary(uniqueKeysWithValues: ActiveAgentGrouping.group(rows).map { ($0.projectName, $0) })

        XCTAssertEqual(groups["alpha"]?.agentCount, 2)
        XCTAssertEqual(groups["beta"]?.agentCount, 2, "a parent and its child process")
        XCTAssertEqual(groups["gamma"]?.agentCount, 1)
        XCTAssertEqual(groups["alpha"]?.allAgents.count, groups["alpha"]?.agentCount)
        XCTAssertEqual(groups["beta"]?.allAgents.count, groups["beta"]?.agentCount)
    }

    func testAHiddenSessionIsInNeitherTheGroupNorItsSummary() {
        let rows = [
            agent(1, project: "alpha", status: .working, age: 5),
            agent(2, project: "alpha", age: 5 * day),
            agent(3, project: "alpha", age: 6 * day),
        ]

        let listing = ActiveAgentListing(rows)
        let group = ActiveAgentGrouping.group(listing.agents)[0]

        XCTAssertEqual(group.agentCount, 1)
        XCTAssertTrue(group.isFlat)
        XCTAssertEqual(listing.hiddenCount, 2)
    }

    func testNothingListedCountsZero() {
        let rows = [agent(1, age: 5 * day), agent(2, project: "beta", age: 6 * day)]

        let listing = ActiveAgentListing(rows)

        XCTAssertEqual(ActiveAgentGrouping.sessionCount(ActiveAgentGrouping.group(listing.agents)), 0)
        XCTAssertEqual(listing.hiddenCount, 2)
    }

    // MARK: Fixtures

    private static func mixed(pid: Int, stateAge: TimeInterval, transcriptAge: TimeInterval,
                              observedAt: Date) -> ActiveAgent {
        ActiveAgent(
            provider: .claude, pid: pid, parentPID: 1, command: "claude", elapsedSeconds: 86_400,
            observedAt: observedAt, cwd: "/work/alpha",
            session: ActiveAgentSession(
                id: "s\(pid)", projectPath: "/work/alpha", projectName: "alpha", branch: nil,
                lastUpdatedAt: observedAt.addingTimeInterval(-transcriptAge), source: "test"),
            status: .idle, statusUpdatedAt: observedAt.addingTimeInterval(-stateAge), statusSource: .registry
        )
    }
}

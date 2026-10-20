import Foundation
@testable import AgentMeter
import XCTest

/// What `RefreshCoordinator` hands the history store: the raw quota reading of
/// each provider whose fetch brought one back, at the landing; Claude's reset
/// grants when a cycle read them; and the restored observations once. Nothing here opens a database (the closures are
/// recorders) or a network connection (every provider is a stand-in).
///
/// Same stand-in style as `RefreshCoordinatorDecouplingTests`; its helpers are
/// file-private there, so the few needed are repeated here.
@MainActor
final class RefreshCoordinatorQuotaHistoryTests: XCTestCase {
    // MARK: - Stand-ins

    private actor Latch {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            let resumed = waiters
            waiters = []
            resumed.forEach { $0.resume() }
        }
    }

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date

        init(_ date: Date) { self.date = date }

        var now: Date { lock.lock(); defer { lock.unlock() }; return date }

        func advance(by seconds: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            date = date.addingTimeInterval(seconds)
        }
    }

    private final class Recorder: @unchecked Sendable {
        struct Recorded: Equatable { let snapshot: QuotaSnapshot; let at: Date }
        struct GrantCall: Equatable { let grants: [ResetGrantObservation]; let at: Date }

        private let lock = NSLock()
        private var _recorded: [Recorded] = []
        private var _legacy: [[QuotaObservation]] = []
        private var _produced: [Provider: [QuotaSnapshot]] = [:]
        private var _codexReads = 0
        private var _resetReads = 0
        private var _grants: [GrantCall] = []

        func record(_ snapshot: QuotaSnapshot, _ at: Date) { lock.lock(); _recorded.append(Recorded(snapshot: snapshot, at: at)); lock.unlock() }
        func importLegacy(_ observations: [QuotaObservation]) { lock.lock(); _legacy.append(observations); lock.unlock() }
        func produced(_ snapshot: QuotaSnapshot) { lock.lock(); _produced[snapshot.provider, default: []].append(snapshot); lock.unlock() }
        func codexRead() { lock.lock(); _codexReads += 1; lock.unlock() }
        /// Counts a reset read and returns its 1-based index.
        func resetRead() -> Int { lock.lock(); defer { lock.unlock() }; _resetReads += 1; return _resetReads }
        func recordGrants(_ grants: [ResetGrantObservation], _ at: Date) {
            lock.lock(); _grants.append(GrantCall(grants: grants, at: at)); lock.unlock()
        }

        var recorded: [Recorded] { lock.lock(); defer { lock.unlock() }; return _recorded }
        var legacy: [[QuotaObservation]] { lock.lock(); defer { lock.unlock() }; return _legacy }
        var codexReads: Int { lock.lock(); defer { lock.unlock() }; return _codexReads }
        var resetReads: Int { lock.lock(); defer { lock.unlock() }; return _resetReads }
        var grantCalls: [GrantCall] { lock.lock(); defer { lock.unlock() }; return _grants }
        func produced(by provider: Provider) -> [QuotaSnapshot] { lock.lock(); defer { lock.unlock() }; return _produced[provider] ?? [] }
        func recorded(for provider: Provider) -> [Recorded] { recorded.filter { $0.snapshot.provider == provider } }
    }

    private struct Harness {
        let clock: TestClock
        let recorder: Recorder
        let model: AppViewModel
        let coordinator: RefreshCoordinator
    }

    /// A stand-in's answer: the snapshot a provider returns this cycle.
    private typealias Answer = @Sendable (TestClock, QuotaSnapshot) -> QuotaSnapshot

    /// Every provider answers at once with a fresh `.oauth` reading unless the
    /// test hands in another answer. Claude's may be async (a latch).
    private func makeHarness(
        claude: (@Sendable (TestClock, ProviderState) async -> ProviderState)? = nil,
        codex: Answer? = nil,
        copilot: Answer? = nil,
        resets: (@Sendable (_ readIndex: Int) -> (state: ClaudeResetState?, attempted: Bool))? = nil,
        observations: [QuotaObservation] = []
    ) -> Harness {
        let clock = TestClock(HistoryFixture.epoch)
        let recorder = Recorder()
        let minuteAgo = clock.now.addingTimeInterval(-60)
        let model = AppViewModel(
            snapshot: StateCache.Snapshot(
                codex: ProviderState(provider: .codex, quota: HistoryFixture.fresh(.codex, used: 10, at: minuteAgo), usage: .empty(.codex)),
                claude: ProviderState(provider: .claude, quota: HistoryFixture.fresh(.claude, used: 20, at: minuteAgo), usage: .empty(.claude)),
                copilot: ProviderState(provider: .copilot, quota: .unavailable(.copilot, note: "no gh"), usage: .empty(.copilot)),
                quotaObservations: observations),
            storedLifetimeSpend: [])
        let environment = RefreshEnvironment(
            now: { clock.now },
            fetchCodex: { _, _, previous in
                recorder.codexRead()
                var next = previous
                let at = clock.now
                next.quota = codex?(clock, previous.quota) ?? HistoryFixture.fresh(.codex, used: 40, at: at)
                recorder.produced(next.quota)
                return next
            },
            fetchClaudeQuota: { previous in
                if let claude {
                    let next = await claude(clock, previous)
                    recorder.produced(next.quota)
                    return next
                }
                var next = previous
                next.quota = HistoryFixture.fresh(.claude, used: 30, at: clock.now)
                recorder.produced(next.quota)
                return next
            },
            fetchClaudeResets: {
                let index = recorder.resetRead()
                if let resets { return resets(index) }
                return (ClaudeResetState(eligible: true, grants: []), true)
            },
            fetchClaudeUsage: { _ in .empty(.claude) },
            fetchCopilot: { previous in
                var next = previous
                next.quota = copilot?(clock, previous.quota) ?? HistoryFixture.fresh(.copilot, used: 50, at: clock.now)
                recorder.produced(next.quota)
                return next
            },
            fetchActiveAgents: { [] },
            fetchCodexResetCredits: { nil },
            fetchProviderStatus: { [:] },
            visibleSlots: { _ in [.claude] },
            foregroundRefreshKinds: { _ in [:] },
            saveState: { _ in },
            saveLedger: { _ in },
            evaluateNotifications: { _, _ in },
            recordQuotaReading: { snapshot, at in recorder.record(snapshot, at) },
            importLegacyQuota: { recorder.importLegacy($0) },
            recordResetGrants: { grants, at in recorder.recordGrants(grants, at) }
        )
        let coordinator = RefreshCoordinator(viewModel: model, environment: environment)
        return Harness(clock: clock, recorder: recorder, model: model, coordinator: coordinator)
    }

    private func waitUntil(
        _ what: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting until \(what)", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func waitForRefreshToLand(_ h: Harness, file: StaticString = #filePath, line: UInt = #line) async {
        await waitUntil("the refresh lands", file: file, line: line) { !h.model.isRefreshing }
    }

    // MARK: - What is recorded

    /// Once per provider, in plan order, the raw snapshot the provider
    /// returned, at the landing time (which is later than the fetch: Claude's
    /// answer took two seconds).
    func testEachProviderLandingRecordsItsRawSnapshotOnceWithTheLandingTime() async {
        let h = makeHarness(claude: { clock, previous in
            var next = previous
            next.quota = HistoryFixture.fresh(.claude, used: 30, at: clock.now)
            clock.advance(by: 2)
            return next
        })

        h.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(h)

        let recorded = h.recorder.recorded
        XCTAssertEqual(recorded.map(\.snapshot.provider), [.codex, .claude, .copilot])
        for entry in recorded {
            XCTAssertEqual(h.recorder.produced(by: entry.snapshot.provider), [entry.snapshot],
                           "\(entry.snapshot.provider): exactly what the provider returned")
            XCTAssertEqual(entry.at, HistoryFixture.epoch.addingTimeInterval(2), "the landing time, read after the fetches")
        }
        let claude = recorded[1].snapshot
        XCTAssertEqual(claude.fetchedAt, HistoryFixture.epoch, "stamped at the fetch, not at the landing")
        XCTAssertNotEqual(claude.fetchedAt, recorded[1].at)
        XCTAssertEqual(claude.windows.first?.usedPercent, 30)
        XCTAssertEqual(claude.source, .oauth)
    }

    /// The closure is handed the provider's raw answer even where the screen
    /// keeps something else: a lower-authority Codex reading in the same epoch
    /// is shown as the previous one, but it was measured.
    func testTheRawSnapshotIsRecordedWhereTheScreenKeepsAnotherOne() async {
        let previousReset = HistoryFixture.epoch.addingTimeInterval(-60 + 3600)
        let h = makeHarness(codex: { clock, _ in
            HistoryFixture.fresh(.codex, used: 55, at: clock.now, source: .appServer,
                                      resetsAt: previousReset.addingTimeInterval(30))
        })

        h.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(h)

        XCTAssertEqual(h.model.codex.quota.windows.first?.usedPercent, 10, "the screen keeps the higher-authority reading")
        let codex = h.recorder.recorded(for: .codex)
        XCTAssertEqual(codex.count, 1)
        XCTAssertEqual(codex.first?.snapshot.windows.first?.usedPercent, 55)
        XCTAssertEqual(codex.first?.snapshot.source, .appServer)
    }

    func testTheClosureHasRunByTheTimeTheRefreshIsMarkedLanded() async {
        let h = makeHarness()

        h.coordinator.refresh(forceAll: true)
        await waitUntil("the refresh lands") { !h.model.isRefreshing }

        // The landing block is one synchronous section: when the flag drops,
        // every call has been made and none is pending.
        XCTAssertEqual(h.recorder.recorded.count, 3)
        XCTAssertNotNil(h.model.lastRefresh)
    }

    // MARK: - What is not recorded

    func testAnUnavailableResultIsNotRecorded() async {
        let offline: Answer = { _, _ in QuotaSnapshot.unavailable(.copilot, note: "offline") }
        let h = makeHarness(
            claude: { _, previous in
                var next = previous
                next.quota = .unavailable(.claude, note: "offline")
                return next
            },
            codex: { _, _ in .unavailable(.codex, note: "offline") },
            copilot: offline)

        h.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(h)

        XCTAssertEqual(h.recorder.recorded.count, 0)
        // The older live readings stay on screen after a failed cycle; they are not re-recorded.
        XCTAssertEqual(h.model.claude.quota.source, .oauth)
        XCTAssertEqual(h.model.claude.quota.windows.first?.usedPercent, 20)
        XCTAssertEqual(h.model.codex.quota.windows.first?.usedPercent, 10)
    }

    /// A refresh that plans only Claude's quota leaves Codex and Copilot
    /// unread: their `previous` comes straight back, and for Codex that is a
    /// live `.oauth` snapshot a minute old that must not look like a new reading.
    func testAProviderThePlanSkippedIsNotRecorded() async {
        let h = makeHarness()
        h.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(h)
        XCTAssertEqual(h.recorder.recorded.map(\.snapshot.provider), [.codex, .claude, .copilot])
        XCTAssertEqual(h.recorder.codexReads, 1)

        h.clock.advance(by: 30)
        h.coordinator.refresh(forceVisibleQuota: true)
        await waitForRefreshToLand(h)

        XCTAssertEqual(h.recorder.codexReads, 1, "the plan did not read Codex")
        XCTAssertEqual(h.model.codex.quota.source, .oauth, "a live-looking snapshot is on screen for it")
        XCTAssertEqual(h.recorder.recorded.map(\.snapshot.provider), [.codex, .claude, .copilot, .claude],
                       "only Claude's quota was fetched the second time")
        XCTAssertEqual(h.recorder.recorded.last?.at, HistoryFixture.epoch.addingTimeInterval(30))
    }

    func testAStaleCacheEchoIsNotRecordedAndALaterLiveReadingIs() async {
        let echoing = LockedFlag()
        echoing.value = true
        let h = makeHarness(claude: { clock, previous in
            var next = previous
            next.quota = echoing.value
                ? HistoryFixture.staleEcho(at: clock.now)
                : HistoryFixture.fresh(.claude, used: 35, at: clock.now)
            return next
        })

        h.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(h)
        XCTAssertEqual(h.recorder.recorded(for: .claude).count, 0, "the echo is no reading")
        XCTAssertEqual(h.recorder.recorded.map(\.snapshot.provider), [.codex, .copilot])

        echoing.value = false
        h.clock.advance(by: 60)
        h.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(h)
        XCTAssertEqual(h.recorder.recorded(for: .claude).count, 1)
        XCTAssertEqual(h.recorder.recorded(for: .claude).first?.snapshot.windows.first?.usedPercent, 35)
    }

    /// A scrape of a cache at most five minutes old is a current reading, and
    /// is recorded; its snapshot carries the cache time the mapping keys it by.
    func testAFreshCacheScrapeIsRecorded() async {
        let h = makeHarness(claude: { clock, previous in
            var next = previous
            next.quota = QuotaSnapshot(
                provider: .claude, windows: [QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 31, resetsAt: nil)],
                source: .cli, planType: "max", fetchedAt: clock.now, note: nil, cachedAt: clock.now.addingTimeInterval(-120))
            return next
        })

        h.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(h)

        let claude = h.recorder.recorded(for: .claude)
        XCTAssertEqual(claude.count, 1)
        XCTAssertEqual(claude.first?.snapshot.source, .cli)
        XCTAssertEqual(claude.first?.snapshot.cachedAt, HistoryFixture.epoch.addingTimeInterval(-120))
    }

    /// The 30 s escape: a refresh that lands after a newer one started is
    /// discarded whole, so it records nothing.
    func testASupersededRefreshRecordsNothing() async {
        let network = Latch()
        let waiting = LockedFlag()
        let h = makeHarness(claude: { clock, previous in
            // Only the first read hangs; the escape's read answers at once.
            if clock.now == HistoryFixture.epoch {
                waiting.value = true
                await network.wait()
            }
            var next = previous
            next.quota = HistoryFixture.fresh(.claude, used: clock.now == HistoryFixture.epoch ? 30 : 35, at: clock.now)
            return next
        })

        h.coordinator.refresh(forceAll: true)
        await waitUntil("the first read is waiting") { waiting.value }

        h.clock.advance(by: 31)
        h.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(h)
        let landed = h.recorder.recorded
        XCTAssertEqual(landed.map(\.snapshot.provider), [.codex, .claude, .copilot], "the escape's refresh recorded its three")
        XCTAssertEqual(Set(landed.map(\.at)), [HistoryFixture.epoch.addingTimeInterval(31)])
        XCTAssertEqual(landed[1].snapshot.windows.first?.usedPercent, 35)

        // The stalled refresh answers now and finds itself superseded.
        await network.open()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(h.recorder.recorded, landed, "nothing more was recorded")
        XCTAssertFalse(h.recorder.recorded.contains { $0.snapshot.fetchedAt == HistoryFixture.epoch },
                       "nothing the stalled refresh read")
        XCTAssertEqual(h.model.claude.quota.windows.first?.usedPercent, 35)
    }

    /// A snapshot restored from `last-state.json` is the previous reading, not
    /// a new one: nothing is recorded until a refresh fetches.
    func testARestoredSnapshotAtLaunchRecordsNothing() async {
        let h = makeHarness()

        XCTAssertEqual(h.model.claude.quota.source, .oauth, "a live-looking reading is restored")
        XCTAssertEqual(h.model.codex.quota.source, .oauth)
        XCTAssertTrue(h.recorder.recorded.isEmpty)

        h.coordinator.stop()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(h.recorder.recorded.isEmpty)
        XCTAssertTrue(h.recorder.legacy.isEmpty, "the legacy import is start()'s, not the initializer's")
    }

    // MARK: - Reset grants

    private func grant(_ id: String, left: Int = 1, endsInDays days: Double = 3, clears: [String] = ["five_hour"]) -> ClaudeResetGrant {
        ClaudeResetGrant(id: id, resetsLeft: left, endsAt: HistoryFixture.epoch.addingTimeInterval(days * 86_400), clears: clears)
    }

    /// One call per cycle that read the grants, with the mapped set and the
    /// landing time.
    func testResetGrantsAreRecordedAtLandingWithTheMappedSet() async {
        let state = ClaudeResetState(eligible: true, grants: [
            grant("g2", left: 2, endsInDays: 5, clears: ["seven_day", "five_hour"]),
            grant("g1", left: 1, endsInDays: 3),
        ])
        let h = makeHarness(resets: { _ in (state, true) })

        h.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(h)

        let calls = h.recorder.grantCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.at, HistoryFixture.epoch)
        XCTAssertEqual(calls.first?.grants, ResetGrantObservation.observations(from: state))
        XCTAssertEqual(calls.first?.grants.map(\.id), ["g1", "g2"])
        XCTAssertEqual(calls.first?.grants.last?.clears, "five_hour,seven_day", "sorted, comma-joined")
        XCTAssertEqual(h.model.claudeResetState, state, "the state on screen is the one recorded")
    }

    /// An empty state is a real answer ("no resets"), not an absence.
    func testAnEmptyGrantStateIsPassed() async {
        let h = makeHarness()   // the default read answers an eligible state with no grants

        h.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(h)

        XCTAssertEqual(h.recorder.grantCalls.count, 1)
        XCTAssertEqual(h.recorder.grantCalls.first?.grants, [])

        let ineligible = makeHarness(resets: { _ in (ClaudeResetState(eligible: false, ineligibleReason: "seat"), true) })
        ineligible.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(ineligible)
        XCTAssertEqual(ineligible.recorder.grantCalls.map(\.grants), [[]])
    }

    /// nil means the grants were not read this cycle, or the read failed.
    func testNothingIsRecordedWhenTheGrantsWereNotRead() async {
        // A read that fails: the stand-in answers nil.
        let failing = makeHarness(resets: { _ in (nil, true) })
        failing.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(failing)
        XCTAssertEqual(failing.recorder.resetReads, 1, "the read was attempted")
        XCTAssertTrue(failing.recorder.grantCalls.isEmpty)

        // A cycle that sent no reset request: the 20-minute clock has not run out.
        let h = makeHarness()
        h.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(h)
        XCTAssertEqual(h.recorder.grantCalls.count, 1)
        h.clock.advance(by: 30)
        h.coordinator.refresh(forceVisibleQuota: true)
        await waitForRefreshToLand(h)
        XCTAssertEqual(h.recorder.resetReads, 1, "not planned again within 20 minutes")
        XCTAssertEqual(h.recorder.grantCalls.count, 1, "no read, no call")

        // A failed quota read sends no reset request either.
        let offline = makeHarness(claude: { _, previous in
            var next = previous
            next.quota = .unavailable(.claude, note: "offline")
            return next
        })
        offline.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(offline)
        XCTAssertEqual(offline.recorder.resetReads, 0)
        XCTAssertTrue(offline.recorder.grantCalls.isEmpty)
    }

    func testASupersededRefreshRecordsNoGrants() async {
        let network = Latch()
        let waiting = LockedFlag()
        let h = makeHarness(
            claude: { clock, previous in
                if clock.now == HistoryFixture.epoch {
                    waiting.value = true
                    await network.wait()
                }
                var next = previous
                next.quota = HistoryFixture.fresh(.claude, used: 30, at: clock.now)
                return next
            },
            // The first read to be asked is the escape's (the stalled refresh reads grants only after its quota answers).
            resets: { index in
                (ClaudeResetState(eligible: true, grants: [ClaudeResetGrant(
                    id: "read\(index)", resetsLeft: 1, endsAt: nil, clears: ["five_hour"])]), true)
            })

        h.coordinator.refresh(forceAll: true)
        await waitUntil("the first read is waiting") { waiting.value }
        h.clock.advance(by: 31)
        h.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(h)
        XCTAssertEqual(h.recorder.grantCalls.map { $0.grants.map(\.id) }, [["read1"]])

        await network.open()
        await waitUntil("the stalled refresh reads its grants") { h.recorder.resetReads == 2 }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(h.recorder.grantCalls.map { $0.grants.map(\.id) }, [["read1"]], "the superseded refresh recorded none")
        XCTAssertEqual(h.model.claudeResetState.grants.map(\.id), ["read1"])
    }

    // MARK: - Legacy import

    func testTheRestoredObservationsAreHandedToTheLegacyImportOnce() async {
        let observations = [
            QuotaObservation(provider: .claude, windowID: "five_hour", remainingPercent: 60,
                             observedAt: HistoryFixture.epoch.addingTimeInterval(-300), resetsAt: nil),
            QuotaObservation(provider: .claude, windowID: "seven_day", remainingPercent: 33,
                             observedAt: HistoryFixture.epoch.addingTimeInterval(-300), resetsAt: nil, source: .oauth),
        ]
        let h = makeHarness(observations: observations)
        XCTAssertEqual(h.model.quotaObservations, observations, "restored by the view model")

        // `start()` calls this and also launches the pricing refresh (network)
        // and the timers, which a unit test must not; this is the part of it
        // under test.
        h.coordinator.submitLegacyQuotaOnce()
        h.coordinator.submitLegacyQuotaOnce()

        XCTAssertEqual(h.recorder.legacy.count, 1, "once per process")
        XCTAssertEqual(h.recorder.legacy.first, observations)
        XCTAssertTrue(h.recorder.recorded.isEmpty)
    }

    func testTheLegacyImportSeesTheObservationsAsRestoredNotAsRefreshed() async {
        let restored = [QuotaObservation(provider: .claude, windowID: "five_hour", remainingPercent: 60,
                                         observedAt: HistoryFixture.epoch.addingTimeInterval(-300), resetsAt: nil)]
        let h = makeHarness(observations: restored)

        h.coordinator.submitLegacyQuotaOnce()
        h.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(h)
        h.coordinator.submitLegacyQuotaOnce()

        XCTAssertEqual(h.recorder.legacy, [restored], "the live observations a refresh adds are not legacy")
        XCTAssertGreaterThan(h.model.quotaObservations.count, restored.count)
    }
}

/// Fixtures callable from the stand-ins, which run off the main actor.
private enum HistoryFixture {
    static let epoch = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        .addingTimeInterval(12 * 3600)

    static func fresh(
        _ provider: Provider, used: Double, at date: Date, source: QuotaSnapshot.SourceKind = .oauth,
        resetsAt: Date? = nil
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            provider: provider,
            windows: [QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: used,
                                  resetsAt: resetsAt ?? date.addingTimeInterval(3600))],
            source: source, planType: "team", fetchedAt: date, note: nil)
    }

    static func staleEcho(at now: Date) -> QuotaSnapshot {
        QuotaSnapshot(
            provider: .claude,
            windows: [QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 0, resetsAt: nil)],
            source: .cli, planType: "max", fetchedAt: now, note: "Scraped from `claude /usage`",
            cachedAt: now.addingTimeInterval(-2 * 86_400))
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false

    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

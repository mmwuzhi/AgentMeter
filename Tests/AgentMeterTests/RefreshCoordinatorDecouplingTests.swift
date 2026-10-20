import Foundation
@testable import AgentMeter
import XCTest

/// Fixtures usable from any isolation: the stand-in providers run off the
/// main actor.
private enum Fixture {
    static let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
    static let epoch = day.addingTimeInterval(12 * 3600)

    static func liveQuota(
        _ provider: Provider,
        used: Double,
        at date: Date,
        source: QuotaSnapshot.SourceKind = .oauth
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            provider: provider,
            windows: [QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: used,
                                  resetsAt: date.addingTimeInterval(3600))],
            source: source,
            planType: "team",
            fetchedAt: date,
            note: nil
        )
    }

    static func report(_ provider: Provider, inputTokens: Int, complete: Bool = false) -> UsageReport {
        var counts = TokenCounts()
        counts.input = inputTokens
        let entry = DayModelUsage(day: day, model: "claude-opus-5-5", counts: counts)
        return UsageRollup.report(provider: provider, entries: [entry], table: PriceTable(),
                                  now: epoch, isCompleteHistory: complete)
    }

    /// What `claude /usage` printed at 08:45 on 2026-10-19 while OAuth was
    /// failing: Claude Code's cache from two days earlier, no reset times.
    static func cacheEcho(at now: Date) -> QuotaSnapshot {
        QuotaSnapshot(
            provider: .claude,
            windows: [QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 0, resetsAt: nil),
                      QuotaWindow(id: "seven_day", label: "Weekly", usedPercent: 67, resetsAt: nil)],
            source: .cli, planType: "max", fetchedAt: now, note: "Scraped from `claude /usage`",
            cachedAt: now.addingTimeInterval(-2 * 86_400))
    }

    static func state(_ provider: Provider, quota: QuotaSnapshot, usage: UsageReport? = nil) -> ProviderState {
        ProviderState(provider: provider, quota: quota, usage: usage ?? .empty(provider))
    }
}

/// A flag the stand-in providers read from off the main actor.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false

    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

/// The Claude usage scan runs apart from the refresh that asks for it. These
/// drive `RefreshCoordinator.refresh` against stand-in providers whose answers
/// the test releases in the order it wants, so a 40-second scan beside a
/// 1-second quota read is two latches, not a clock.
@MainActor
final class RefreshCoordinatorDecouplingTests: XCTestCase {
    // MARK: - Stand-ins

    /// Suspends callers until opened; a provider that has not answered yet.
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

        var now: Date {
            lock.lock(); defer { lock.unlock() }
            return date
        }

        func advance(by seconds: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            date = date.addingTimeInterval(seconds)
        }
    }

    /// What the stand-ins were asked and what the coordinator wrote out.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _usageScans: [Bool] = []
        private var _claudeQuotaReads = 0
        private var _codexReads = 0
        private var _resetReads = 0
        private var _savedStates: [StateCache.Snapshot] = []
        private var _savedLedgers: [[LifetimeDayRecord]] = []
        private var _notifications: [Provider] = []
        private var _notifiedWindows: [(Provider, [QuotaWindow])] = []

        func usageScan(completeHistory: Bool) { lock.lock(); _usageScans.append(completeHistory); lock.unlock() }
        func claudeQuotaRead() { lock.lock(); _claudeQuotaReads += 1; lock.unlock() }
        func codexRead() { lock.lock(); _codexReads += 1; lock.unlock() }
        func resetRead() { lock.lock(); _resetReads += 1; lock.unlock() }
        func saved(_ state: StateCache.Snapshot) { lock.lock(); _savedStates.append(state); lock.unlock() }
        func saved(_ ledger: [LifetimeDayRecord]) { lock.lock(); _savedLedgers.append(ledger); lock.unlock() }
        func notified(_ provider: Provider, _ windows: [QuotaWindow]) {
            lock.lock(); _notifications.append(provider); _notifiedWindows.append((provider, windows)); lock.unlock()
        }

        /// The `completeHistory` argument of every scan started, in order.
        var usageScans: [Bool] { lock.lock(); defer { lock.unlock() }; return _usageScans }
        var claudeQuotaReads: Int { lock.lock(); defer { lock.unlock() }; return _claudeQuotaReads }
        var codexReads: Int { lock.lock(); defer { lock.unlock() }; return _codexReads }
        var resetReads: Int { lock.lock(); defer { lock.unlock() }; return _resetReads }
        var savedStates: [StateCache.Snapshot] { lock.lock(); defer { lock.unlock() }; return _savedStates }
        var savedLedgers: [[LifetimeDayRecord]] { lock.lock(); defer { lock.unlock() }; return _savedLedgers }
        var notifications: [Provider] { lock.lock(); defer { lock.unlock() }; return _notifications }
        /// The windows the last evaluation for `provider` was handed.
        func lastNotifiedWindows(_ provider: Provider) -> [QuotaWindow]? {
            lock.lock(); defer { lock.unlock() }
            return _notifiedWindows.last { $0.0 == provider }?.1
        }
    }

    // MARK: - Fixtures

    /// A model restored from a cache: a live Claude reading a minute old and no
    /// usage yet, so the first refresh reads Claude and plans its scan. No
    /// usage on purpose: `AppViewModel.init` bootstraps the spend ledger from
    /// restored reports and writes it to the real ledger file, so a restored
    /// report with a day in it would reach disk from here.
    private func makeModel(clock: TestClock) -> AppViewModel {
        let minuteAgo = clock.now.addingTimeInterval(-60)
        return AppViewModel(
            snapshot: StateCache.Snapshot(
                codex: Fixture.state(.codex, quota: Fixture.liveQuota(.codex, used: 10, at: minuteAgo, source: .oauth)),
                claude: Fixture.state(.claude, quota: Fixture.liveQuota(.claude, used: 20, at: minuteAgo)),
                copilot: Fixture.state(.copilot, quota: .unavailable(.copilot, note: "no gh"))
            ),
            storedLifetimeSpend: []
        )
    }

    private struct Harness {
        let clock: TestClock
        let recorder: Recorder
        let model: AppViewModel
        let coordinator: RefreshCoordinator
    }

    /// Every provider answers at once with a fresh reading unless the test
    /// hands in a slower or different stand-in.
    private func makeHarness(
        quota: (@Sendable (TestClock, ProviderState) async -> ProviderState)? = nil,
        usage: (@Sendable (Bool) async -> UsageReport)? = nil,
        resets: (@Sendable () async -> (state: ClaudeResetState?, attempted: Bool))? = nil
    ) -> Harness {
        let clock = TestClock(Fixture.epoch)
        let recorder = Recorder()
        let model = makeModel(clock: clock)
        let freshQuota: @Sendable (TestClock, ProviderState) async -> ProviderState = { clock, previous in
            var next = previous
            next.quota = Fixture.liveQuota(.claude, used: 30, at: clock.now)
            return next
        }
        let defaultUsage: @Sendable (Bool) async -> UsageReport = { complete in
            Fixture.report(.claude, inputTokens: 1_000, complete: complete)
        }
        let environment = RefreshEnvironment(
            now: { clock.now },
            fetchCodex: { _, _, previous in
                recorder.codexRead()
                var next = previous
                next.quota = Fixture.liveQuota(.codex, used: 40, at: clock.now, source: .oauth)
                return next
            },
            fetchClaudeQuota: { previous in
                recorder.claudeQuotaRead()
                return await (quota ?? freshQuota)(clock, previous)
            },
            fetchClaudeResets: {
                recorder.resetRead()
                if let resets { return await resets() }
                return (ClaudeResetState(eligible: true, grants: []), true)
            },
            fetchClaudeUsage: { complete in
                recorder.usageScan(completeHistory: complete)
                return await (usage ?? defaultUsage)(complete)
            },
            fetchCopilot: { previous in
                var next = previous
                next.quota = Fixture.liveQuota(.copilot, used: 50, at: clock.now, source: .oauth)
                return next
            },
            fetchActiveAgents: { [] },
            fetchCodexResetCredits: { nil },
            fetchProviderStatus: { [:] },
            visibleSlots: { _ in [.claude] },
            foregroundRefreshKinds: { _ in [:] },
            saveState: { recorder.saved($0) },
            saveLedger: { recorder.saved($0) },
            evaluateNotifications: { provider, windows in recorder.notified(provider, windows) }
        )
        let coordinator = RefreshCoordinator(viewModel: model, environment: environment)
        return Harness(clock: clock, recorder: recorder, model: model, coordinator: coordinator)
    }

    private func waitUntil(
        _ what: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
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

    // MARK: - Quota, resets and the other providers do not wait for the scan

    func testQuotaLandsWhileTheHistoryScanIsStillRunning() async {
        let scan = Latch()
        let scanned = Fixture.report(.claude, inputTokens: 1_000, complete: true)
        let h = makeHarness(usage: { _ in
            await scan.wait()
            return scanned
        })

        h.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(h)

        XCTAssertEqual(h.model.claude.quota.windows.first?.usedPercent, 30, "the live reading is on screen")
        XCTAssertEqual(h.model.claude.usage, .empty(.claude), "the restored usage stays until the scan lands")
        XCTAssertEqual(h.recorder.usageScans, [true], "the first scan after launch reads every file")
        XCTAssertNotNil(h.model.lastRefresh)

        await scan.open()
        await waitUntil("the scan lands") { h.model.claude.usage == scanned }
        XCTAssertEqual(h.model.claude.quota.windows.first?.usedPercent, 30, "landing usage leaves the quota alone")
        XCTAssertEqual(h.recorder.savedStates.last?.claude.usage, scanned, "the landed usage reaches the cache")
    }

    func testResetGrantsAreReadBehindTheQuotaNotBehindTheScan() async {
        let scan = Latch()
        let grants = ClaudeResetState(
            eligible: true,
            grants: [ClaudeResetGrant(id: "g1", resetsLeft: 1, endsAt: Fixture.epoch.addingTimeInterval(86_400), clears: ["five_hour"])]
        )
        let h = makeHarness(
            usage: { complete in
                await scan.wait()
                return Fixture.report(.claude, inputTokens: 1, complete: complete)
            },
            resets: { (grants, true) }
        )

        h.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(h)

        XCTAssertEqual(h.recorder.resetReads, 1)
        XCTAssertEqual(h.model.claudeResetState, grants, "the grants landed with the quota, scan still running")
        await scan.open()
        await waitUntil("the scan lands") { h.model.claude.usage.totalTokens == 1 }
    }

    func testCodexAndCopilotLandWhileTheClaudeScanRuns() async {
        let scan = Latch()
        let h = makeHarness(usage: { complete in
            await scan.wait()
            return Fixture.report(.claude, inputTokens: 1, complete: complete)
        })

        h.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(h)

        XCTAssertEqual(h.model.codex.quota.windows.first?.usedPercent, 40)
        XCTAssertEqual(h.model.copilot.quota.windows.first?.usedPercent, 50)
        XCTAssertEqual(h.recorder.notifications, [.codex, .claude, .copilot], "alerts were evaluated on the live readings")
        await scan.open()
        await waitUntil("the scan lands") { h.model.claude.usage.totalTokens == 1 }
    }

    func testTheScanIsNotStartedWhenUsageIsNotPlanned() async {
        let h = makeHarness()

        h.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(h)
        await waitUntil("the scan lands") { h.model.claude.usage.totalTokens == 1_000 }

        // A popover-open refresh half a minute later wants quota; usage is
        // not due for another quarter hour.
        h.clock.advance(by: 30)
        h.coordinator.refresh(forceVisibleQuota: true)
        await waitForRefreshToLand(h)

        XCTAssertEqual(h.recorder.usageScans, [true])
        XCTAssertEqual(h.recorder.claudeQuotaReads, 2)
    }

    // MARK: - Neither path overwrites the other's newer result

    func testAScanResultDoesNotUndoAQuotaThatLandedMeanwhile() async {
        let scan = Latch()
        let scanned = Fixture.report(.claude, inputTokens: 1_000, complete: true)
        let h = makeHarness(usage: { _ in
            await scan.wait()
            return scanned
        })

        h.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(h)
        XCTAssertEqual(h.model.claude.quota.windows.first?.usedPercent, 30)

        // A second "Refresh now", past the forced-refresh spacing, reads
        // Claude again while the first scan is still running.
        h.clock.advance(by: 30)
        h.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(h)
        XCTAssertEqual(h.recorder.claudeQuotaReads, 2)
        XCTAssertEqual(h.recorder.usageScans, [true], "the running scan is joined, not repeated")
        let landedQuota = h.model.claude.quota

        await scan.open()
        await waitUntil("the scan lands") { h.model.claude.usage == scanned }
        XCTAssertEqual(h.model.claude.quota, landedQuota, "the scan's result keeps the newer quota")
    }

    func testAQuotaRefreshKeepsTheUsageThatLandedWhileItWaited() async {
        let network = Latch()
        let scanned = Fixture.report(.claude, inputTokens: 1_000, complete: true)
        let h = makeHarness(
            quota: { clock, previous in
                await network.wait()
                var next = previous
                next.quota = Fixture.liveQuota(.claude, used: 30, at: clock.now)
                return next
            },
            usage: { _ in scanned }
        )

        h.coordinator.refresh(forceAll: true)
        // The scan is quick this time and lands while the quota read hangs.
        await waitUntil("the scan lands first") { h.model.claude.usage == scanned }
        XCTAssertTrue(h.model.isRefreshing)
        XCTAssertEqual(h.model.claude.quota.windows.first?.usedPercent, 20, "the old reading is still on screen")

        await network.open()
        await waitForRefreshToLand(h)
        XCTAssertEqual(h.model.claude.quota.windows.first?.usedPercent, 30)
        XCTAssertEqual(h.model.claude.usage, scanned, "the refresh did not put back the usage it started with")
        XCTAssertEqual(h.recorder.savedStates.last?.claude.usage, scanned)
    }

    // MARK: - Overlapping refreshes share the scan and send no extra reads

    func testARefreshQueuedBehindAnotherJoinsTheRunningScan() async {
        let network = Latch()
        let scan = Latch()
        let h = makeHarness(
            quota: { clock, previous in
                await network.wait()
                var next = previous
                next.quota = Fixture.liveQuota(.claude, used: 30, at: clock.now)
                return next
            },
            usage: { complete in
                await scan.wait()
                return Fixture.report(.claude, inputTokens: 1, complete: complete)
            }
        )

        h.coordinator.refresh(forceAll: true)
        await waitUntil("the first read is sent") { h.recorder.claudeQuotaReads == 1 }
        // Queued: the first refresh is seconds old, so this one waits and
        // replays when it lands.
        h.clock.advance(by: 5)
        h.coordinator.refresh(forceAll: true)
        XCTAssertEqual(h.recorder.claudeQuotaReads, 1)

        await network.open()
        await waitForRefreshToLand(h)
        // The replay ran: Codex was read again, Claude was read seconds ago
        // and is not, and the usage it wanted is the scan already running.
        await waitUntil("the replay reads Codex") { h.recorder.codexReads == 2 }
        await waitForRefreshToLand(h)
        XCTAssertEqual(h.recorder.claudeQuotaReads, 1, "a live reading seconds old is not re-read")
        XCTAssertEqual(h.recorder.usageScans, [true], "one scan for both refreshes")

        await scan.open()
        await waitUntil("the scan lands") { h.model.claude.usage.totalTokens == 1 }
    }

    // MARK: - The complete scan's result survives, and the clock follows the landing

    func testACompleteReportLandsAfterItsRefreshWasSupersededByTheEscape() async {
        let network = Latch()
        let scan = Latch()
        let scanned = Fixture.report(.claude, inputTokens: 1_000, complete: true)
        let h = makeHarness(
            quota: { clock, previous in
                // Only the first read hangs; the escape's read answers at once.
                if clock.now == Fixture.epoch { await network.wait() }
                var next = previous
                next.quota = Fixture.liveQuota(.claude, used: clock.now == Fixture.epoch ? 30 : 35, at: clock.now)
                return next
            },
            usage: { _ in
                await scan.wait()
                return scanned
            }
        )

        h.coordinator.refresh(forceAll: true)
        await waitUntil("the complete scan is started") { h.recorder.usageScans == [true] }

        // 31 s in, the escape lets a second refresh start beside the stalled one.
        h.clock.advance(by: 31)
        h.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(h)
        XCTAssertEqual(h.model.claude.quota.windows.first?.usedPercent, 35, "the escape's reading landed")
        XCTAssertEqual(h.recorder.usageScans, [true], "the escape joined the scan instead of starting a second")

        // The stalled read answers now: its refresh is superseded and lands nothing.
        await network.open()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(h.model.claude.quota.windows.first?.usedPercent, 35)

        // The scan it started still lands, complete history included.
        await scan.open()
        await waitUntil("the complete report lands") { h.model.claude.usage == scanned }

        // ...and only now does the clock count a complete read as done: an
        // hour later the next scan is a windowed one.
        h.clock.advance(by: 3600)
        h.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(h)
        await waitUntil("the windowed scan is started") { h.recorder.usageScans.count == 2 }
        XCTAssertEqual(h.recorder.usageScans, [true, false])
    }

    func testTheNextCompleteScanWaitsSixHoursFromTheLastOneThatLanded() async {
        let h = makeHarness()

        h.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(h)
        await waitUntil("the first scan lands") { h.model.claude.usage.totalTokens == 1_000 }

        h.clock.advance(by: 3600)
        h.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(h)
        await waitUntil("the second scan is started") { h.recorder.usageScans.count == 2 }

        h.clock.advance(by: 5 * 3600)
        h.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(h)
        await waitUntil("the third scan is started") { h.recorder.usageScans.count == 3 }

        XCTAssertEqual(h.recorder.usageScans, [true, false, true])
    }

    func testACompleteScanThatNeverLandedIsNotCountedAsDone() async {
        let scan = Latch()
        let h = makeHarness(usage: { complete in
            await scan.wait()
            return Fixture.report(.claude, inputTokens: 1_000, complete: complete)
        })

        h.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(h)
        XCTAssertEqual(h.recorder.usageScans, [true])

        // The process is winding down: the scan is retired before it answers.
        h.coordinator.stop()
        await scan.open()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(h.model.claude.usage, .empty(.claude), "a retired scan lands nothing")

        // Nothing landed, so the next scan reads everything again.
        h.clock.advance(by: 30)
        h.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(h)
        await waitUntil("a new scan is started") { h.recorder.usageScans.count == 2 }
        XCTAssertEqual(h.recorder.usageScans, [true, true])
    }

    // MARK: - Failures on either side

    func testAFailedQuotaReadKeepsTheLastLiveReadingAndTheScanStillLands() async {
        let scanned = Fixture.report(.claude, inputTokens: 1_000, complete: true)
        let h = makeHarness(
            quota: { _, previous in
                var next = previous
                next.quota = ClaudeService.lastLiveQuota(failedAt: previous.quota.fetchedAt)
                return next
            },
            usage: { _ in scanned }
        )

        h.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(h)
        await waitUntil("the scan lands") { h.model.claude.usage == scanned }

        XCTAssertEqual(h.model.claude.quota.source, .oauth, "the minute-old live reading is kept")
        XCTAssertEqual(h.model.claude.quota.windows.first?.usedPercent, 20)
        XCTAssertEqual(h.recorder.resetReads, 0, "no reset read behind a failed quota read")
        XCTAssertFalse(h.model.staleQuotaProviders.contains(.claude), "one failure is not yet stale")
    }

    func testAnEmptyScanLandsWithoutTouchingTheQuotaOrTheLedger() async {
        let h = makeHarness(usage: { _ in .empty(.claude) })

        h.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(h)
        await waitUntil("the empty report lands") { h.recorder.usageScans.count == 1 && h.recorder.savedStates.count >= 2 }

        XCTAssertEqual(h.model.claude.quota.windows.first?.usedPercent, 30)
        XCTAssertEqual(h.model.claude.usage, .empty(.claude))
        XCTAssertTrue(h.model.lifetimeSpend.isEmpty)
    }

    func testNotificationsAreEvaluatedOncePerRefreshAndNotWhenTheScanLands() async {
        let scan = Latch()
        let h = makeHarness(usage: { complete in
            await scan.wait()
            return Fixture.report(.claude, inputTokens: 1, complete: complete)
        })

        h.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(h)
        XCTAssertEqual(h.recorder.notifications.count, 3)

        await scan.open()
        await waitUntil("the scan lands") { h.model.claude.usage.totalTokens == 1 }
        XCTAssertEqual(h.recorder.notifications.count, 3, "landing usage changes no window, so nothing is re-evaluated")
    }

    // MARK: - The statistics are what one combined refresh produced before

    func testTheLedgerIsWhatMergingTheReportsTogetherGives() async {
        let scanned = Fixture.report(.claude, inputTokens: 1_000, complete: true)
        let h = makeHarness(usage: { _ in scanned })

        h.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(h)
        await waitUntil("the scan lands") { h.model.claude.usage == scanned }

        let expected = LifetimeSpendTracker.merge(
            existing: [],
            reports: [h.model.codex.usage, scanned],
            table: h.model.priceTable
        )
        XCTAssertEqual(h.model.lifetimeSpend, expected)
        XCTAssertEqual(h.recorder.savedLedgers.last, expected)
        XCTAssertEqual(h.recorder.savedStates.last?.lifetimeSpend, expected)
    }

    func testACompleteScanStillCorrectsAnInflatedDayDownward() async {
        // First scan: windowed, and over-counted; second: complete, and right.
        let h = makeHarness(usage: { complete in
            Fixture.report(.claude, inputTokens: complete ? 700 : 1_000, complete: complete)
        })

        // Pretend a complete read already landed, so the first scan is windowed.
        h.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(h)
        await waitUntil("the first scan lands") { h.recorder.usageScans.count == 1 }
        XCTAssertEqual(h.recorder.usageScans, [true])
        // The first scan after launch is complete by design; a later windowed
        // scan that reads a higher count can only grow the day...
        h.clock.advance(by: 60)
        h.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(h)
        await waitUntil("the windowed scan lands") { h.model.claude.usage.totalTokens == 1_000 }
        XCTAssertEqual(h.model.lifetimeSpend.first?.tokens, 1_000)

        // ...and the next complete one brings it back down.
        h.clock.advance(by: 6 * 3600)
        h.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(h)
        await waitUntil("the complete scan lands") { h.model.claude.usage.totalTokens == 700 }
        XCTAssertEqual(h.recorder.usageScans, [true, false, true])
        XCTAssertEqual(h.model.lifetimeSpend.first?.tokens, 700)
    }

    // MARK: - Where a quota reading came from, and when

    /// The echo is older than the live reading on screen (restored a minute
    /// ago), so that reading stays; the echo is no observation, alerts see
    /// only the kept reading, and the stale banner shows from the first
    /// cycle, dated by the kept reading.
    func testScrapeEchoingAnOldCacheDoesNotDisplaceANewerReading() async {
        let h = makeHarness(quota: { clock, previous in
            var next = previous
            next.quota = Fixture.cacheEcho(at: clock.now)
            return next
        })
        let restored = h.model.claude.quota

        h.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(h)

        XCTAssertEqual(h.model.claude.quota, restored, "the newer reading stays on screen")
        XCTAssertFalse(h.model.quotaObservations.contains { $0.provider == .claude && $0.windowID == "seven_day" },
                       "the echo is not an observation")
        XCTAssertTrue(h.model.quotaObservations.contains { $0.provider == .codex }, "live readings still are")
        XCTAssertEqual(h.recorder.lastNotifiedWindows(.claude)?.map(\.usedPercent), [20],
                       "alerts see the kept reading, as after any failed cycle")
        XCTAssertTrue(h.model.staleQuotaProviders.contains(.claude), "stale from the first cycle")
        XCTAssertEqual(h.model.claude.quota.readingTime, Fixture.epoch.addingTimeInterval(-60),
                       "the banner dates the data by the kept reading")
    }

    /// With nothing usable on screen the echo is shown — as the CLI
    /// fallback, dated by its cache — but still never observed and never
    /// handed to alerts.
    func testEchoWithNothingToKeepIsShownButNeitherObservedNorAlerted() async {
        let h = makeHarness(quota: { clock, previous in
            var next = previous
            next.quota = Fixture.cacheEcho(at: clock.now)
            return next
        })
        h.model.claude.quota = .unavailable(.claude, note: "nothing yet")

        h.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(h)

        XCTAssertEqual(h.model.claude.quota.source, .cli)
        XCTAssertEqual(h.model.claude.quota.windows.map(\.usedPercent), [0, 67], "the fallback is shown")
        XCTAssertFalse(h.model.quotaObservations.contains { $0.provider == .claude })
        XCTAssertEqual(h.recorder.lastNotifiedWindows(.claude), [])
        XCTAssertTrue(h.model.staleQuotaProviders.contains(.claude))
        XCTAssertEqual(h.model.claude.quota.readingTime, h.clock.now.addingTimeInterval(-2 * 86_400))
    }

    /// The screen keeps the older reading, but the forced-refresh spacing
    /// counts from the scrape that just happened: a forced refresh right
    /// behind it (wake fires three notifications) reads nothing, and one past
    /// the spacing reads as usual — the same reads as when the echo itself
    /// was shown.
    func testKeepingTheOlderReadingSendsNoExtraQuotaRead() async {
        let h = makeHarness(quota: { clock, previous in
            var next = previous
            next.quota = Fixture.cacheEcho(at: clock.now)
            return next
        })
        h.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(h)
        XCTAssertEqual(h.recorder.claudeQuotaReads, 1)
        XCTAssertEqual(h.model.claude.quota.source, .oauth, "the older live reading is on screen")

        h.clock.advance(by: 5)
        h.coordinator.refresh(forceVisibleQuota: true)
        await waitForRefreshToLand(h)
        XCTAssertEqual(h.recorder.claudeQuotaReads, 1, "held back by the scrape 5 s ago, not released by the older reading")

        h.clock.advance(by: 5)
        h.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(h)
        XCTAssertEqual(h.recorder.claudeQuotaReads, 1, "\"Refresh now\" is held back for Claude the same way")

        h.clock.advance(by: 20)
        h.coordinator.refresh(forceVisibleQuota: true)
        await waitForRefreshToLand(h)
        XCTAssertEqual(h.recorder.claudeQuotaReads, 2, "past the spacing it reads as usual")
    }

    /// Once OAuth answers again its reading replaces the kept one and is
    /// recorded; the stale mark clears.
    func testLiveReadingAfterAnEchoTakesTheScreenBack() async {
        let echoing = LockedFlag()
        echoing.value = true
        let h = makeHarness(quota: { clock, previous in
            var next = previous
            next.quota = echoing.value
                ? Fixture.cacheEcho(at: clock.now)
                : Fixture.liveQuota(.claude, used: 35, at: clock.now)
            return next
        })
        h.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(h)
        XCTAssertTrue(h.model.staleQuotaProviders.contains(.claude))

        echoing.value = false
        h.clock.advance(by: 60)
        h.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(h)

        XCTAssertEqual(h.model.claude.quota.windows.map(\.usedPercent), [35])
        XCTAssertFalse(h.model.staleQuotaProviders.contains(.claude))
        XCTAssertEqual(h.model.quotaObservations.filter { $0.provider == .claude }.last?.observedAt, h.clock.now)
        XCTAssertEqual(h.recorder.lastNotifiedWindows(.claude)?.map(\.usedPercent), [35])
    }

    /// A live reading is recorded once, at the time it was fetched and as
    /// OAuth's; when OAuth then fails, the reading kept on screen adds
    /// nothing, and the second failure shows the stale banner.
    func testLiveReadingIsObservedOnceAndAFailedCycleAddsNothing() async {
        let failing = LockedFlag()
        let h = makeHarness(quota: { clock, previous in
            var next = previous
            if failing.value {
                next.quota = .unavailable(.claude, note: "offline")
            } else {
                next.quota = Fixture.liveQuota(.claude, used: 30, at: clock.now)
                clock.advance(by: 2)   // the answer lands two seconds after it was read
            }
            return next
        })

        h.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(h)
        let fetchedAt = h.model.claude.quota.fetchedAt
        let observed = h.model.quotaObservations.filter { $0.provider == .claude }
        XCTAssertEqual(observed.map(\.observedAt).max(), fetchedAt, "stamped when read, not when it landed")
        XCTAssertEqual(observed.last?.source, .oauth)

        failing.value = true
        for _ in 0..<2 {
            h.clock.advance(by: 60)
            h.coordinator.refresh(forceAll: true)
            await waitForRefreshToLand(h)
        }
        XCTAssertEqual(h.model.claude.quota.windows.first?.usedPercent, 30, "the last live reading stays on screen")
        XCTAssertEqual(h.model.quotaObservations.filter { $0.provider == .claude }, observed,
                       "the kept reading is not recorded again")
        XCTAssertTrue(h.model.staleQuotaProviders.contains(.claude))
        XCTAssertEqual(h.recorder.lastNotifiedWindows(.claude)?.map(\.usedPercent), [30],
                       "alerts still see the last live reading")
    }

    // MARK: - A slow scan, in wall-clock terms

    func testQuotaIsOnScreenLongBeforeASlowScanFinishes() async {
        let h = makeHarness(usage: { complete in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return Fixture.report(.claude, inputTokens: 1, complete: complete)
        })

        let started = Date()
        h.coordinator.refresh(forceAll: true)
        await waitForRefreshToLand(h)
        let quotaLatency = Date().timeIntervalSince(started)

        XCTAssertEqual(h.model.claude.quota.windows.first?.usedPercent, 30)
        XCTAssertLessThan(quotaLatency, 1.0, "the quota did not wait for the two-second scan")
        await waitUntil("the scan lands") { h.model.claude.usage.totalTokens == 1 }
    }

    // MARK: - The clock rule itself

    func testCompleteHistoryIsDueAtLaunchAndEverySixHoursAfterALanding() {
        let now = Fixture.epoch
        XCTAssertTrue(RefreshCoordinator.claudeCompleteHistoryDue(lastLanded: nil, now: now, interval: 6 * 3600))
        XCTAssertFalse(RefreshCoordinator.claudeCompleteHistoryDue(
            lastLanded: now.addingTimeInterval(-6 * 3600 + 1), now: now, interval: 6 * 3600))
        XCTAssertTrue(RefreshCoordinator.claudeCompleteHistoryDue(
            lastLanded: now.addingTimeInterval(-6 * 3600), now: now, interval: 6 * 3600))
    }
}

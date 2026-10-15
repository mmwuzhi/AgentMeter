import Foundation
@testable import AgentMeter
import XCTest

final class ClaudeUsageGateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_000_000)

    private func at(_ offset: TimeInterval) -> Date { now.addingTimeInterval(offset) }

    private func response(_ status: Int, retryAfter: String? = nil) -> HTTPURLResponse {
        HTTPURLResponse(
            url: ClaudeOAuthFetcher.usageURL, statusCode: status, httpVersion: "HTTP/2",
            headerFields: retryAfter.map { ["Retry-After": $0] })!
    }

    /// A refused request sent just before its answer arrived at `offset`.
    private func limited(
        _ backoff: inout ClaudeUsageBackoff, at offset: TimeInterval,
        retryAfter: TimeInterval? = nil, sentAt: TimeInterval? = nil
    ) {
        backoff.recordRateLimited(retryAfter: retryAfter, sentAt: at(sentAt ?? offset - 0.1), at: at(offset))
    }

    private func wait(_ backoff: ClaudeUsageBackoff, from offset: TimeInterval) -> TimeInterval? {
        backoff.blockedUntil(at: at(offset)).map { $0.timeIntervalSince(at(offset)) }
    }

    // MARK: Backoff schedule

    func testWithoutRetryAfterEachRefusedRetryWaitsLongerUpToFiveMinutes() {
        var backoff = ClaudeUsageBackoff()
        var waits: [TimeInterval] = []
        // Each retry is sent after the previous wait ended, so each is a new refusal.
        for round in 0..<6 {
            let t = TimeInterval(round) * 1000
            limited(&backoff, at: t)
            waits.append(wait(backoff, from: t)!)
        }

        XCTAssertEqual(waits, [60, 120, 240, 300, 300, 300])
    }

    func testBlockEndsOnItsOwnAndASuccessStartsTheScheduleOver() {
        var backoff = ClaudeUsageBackoff()
        limited(&backoff, at: 0)
        limited(&backoff, at: 100)

        XCTAssertNotNil(backoff.blockedUntil(at: at(219)))
        XCTAssertNil(backoff.blockedUntil(at: at(220)), "free again once the wait has passed")

        backoff.recordSuccess(sentAt: at(300))
        XCTAssertNil(backoff.blockedUntil(at: at(300)))
        limited(&backoff, at: 400)
        XCTAssertEqual(wait(backoff, from: 400), 60)
    }

    // MARK: Ordering of answers

    /// Request A goes out, request B goes out after it, B is refused and A's
    /// 200 arrives afterwards: A was answered before the limit existed.
    func testAnEarlierRequestsSuccessDoesNotLiftALaterRefusal() {
        var backoff = ClaudeUsageBackoff()
        let sentA = at(0)
        limited(&backoff, at: 1.1, sentAt: 1)

        backoff.recordSuccess(sentAt: sentA)

        XCTAssertEqual(wait(backoff, from: 1.5)!, 60 - 0.4, accuracy: 0.001)
        // A request sent after the refusal, once the wait is over, does lift it.
        backoff.recordSuccess(sentAt: at(70))
        XCTAssertNil(backoff.blockedUntil(at: at(70)))
    }

    func testRefusalsFromOneBurstCountOnceAndTheNextRetryEscalates() {
        var backoff = ClaudeUsageBackoff()
        // Two requests sent together, both refused: one event.
        limited(&backoff, at: 1.0, sentAt: 0)
        limited(&backoff, at: 1.2, sentAt: 0.0005)
        XCTAssertEqual(wait(backoff, from: 1.2)!, 60 - 0.2, accuracy: 0.001, "the second answer did not double the wait")

        // A retry sent after the wait is refused too: now it escalates.
        limited(&backoff, at: 70, sentAt: 62)
        XCTAssertEqual(wait(backoff, from: 70), 120)
    }

    func testALateRefusalFromTheSameBurstOnlyExtendsWithALongerRetryAfter() {
        var backoff = ClaudeUsageBackoff()
        limited(&backoff, at: 1.0, sentAt: 0)

        limited(&backoff, at: 1.1, retryAfter: 20, sentAt: 0.5)
        XCTAssertEqual(wait(backoff, from: 1.1)!, 60 - 0.1, accuracy: 0.001, "a shorter Retry-After never shortens the wait")

        limited(&backoff, at: 1.2, retryAfter: 400, sentAt: 0.6)
        XCTAssertEqual(wait(backoff, from: 1.2), 400, "a longer one extends it")
    }

    // MARK: Retry-After

    func testAValidRetryAfterIsHonouredInFullAndRoundedUpOnlyFromTinyValues() {
        func waitFor(_ retryAfter: TimeInterval) -> TimeInterval {
            var backoff = ClaudeUsageBackoff()
            limited(&backoff, at: 0, retryAfter: retryAfter)
            return wait(backoff, from: 0)!
        }

        XCTAssertEqual(waitFor(300), 300)
        XCTAssertEqual(waitFor(90), 90, "shorter than the default is honoured too")
        XCTAssertEqual(waitFor(3600), 3600, "a long wait is not cut short to retry early")
        XCTAssertEqual(waitFor(24 * 3600), 24 * 3600)
        XCTAssertEqual(waitFor(0), 15, "a zero wait does not mean hammer")
    }

    func testRetryAfterHeaderParsesSecondsAndHTTPDates() {
        XCTAssertEqual(ClaudeUsageBackoff.retryAfter(header: "120", at: now), 120)
        XCTAssertEqual(ClaudeUsageBackoff.retryAfter(header: " 30 ", at: now), 30)
        XCTAssertEqual(ClaudeUsageBackoff.retryAfter(header: "1.5", at: now), 1.5)
        XCTAssertEqual(ClaudeUsageBackoff.retryAfter(header: "3600", at: now), 3600)

        // 1_792_000_000 is 2026-10-14 17:46:40 GMT.
        XCTAssertEqual(
            ClaudeUsageBackoff.retryAfter(header: "Wed, 14 Oct 2026 17:51:40 GMT", at: now), 300)
        XCTAssertEqual(
            ClaudeUsageBackoff.retryAfter(header: "Wed, 14 Oct 2026 17:30:00 GMT", at: now), 0,
            "a date already past reads as zero")
    }

    func testMissingInvalidOrAbsurdRetryAfterFallsBackToTheSchedule() {
        XCTAssertNil(ClaudeUsageBackoff.retryAfter(header: nil, at: now))
        XCTAssertNil(ClaudeUsageBackoff.retryAfter(header: "", at: now))
        XCTAssertNil(ClaudeUsageBackoff.retryAfter(header: "soon", at: now))
        XCTAssertNil(ClaudeUsageBackoff.retryAfter(header: "-5", at: now))
        XCTAssertNil(ClaudeUsageBackoff.retryAfter(header: "inf", at: now))
        XCTAssertNil(ClaudeUsageBackoff.retryAfter(header: "nan", at: now))
        XCTAssertNil(ClaudeUsageBackoff.retryAfter(header: "86401", at: now), "more than a day is a malformed header")
        XCTAssertNil(ClaudeUsageBackoff.retryAfter(header: "Thu, 14 Oct 2027 17:46:40 GMT", at: now),
                     "a date a year out is too")
    }

    // MARK: Gate

    func testA429BlocksUntilItsRetryAfterAndALaterRequestsSuccessLiftsIt() async {
        let gate = ClaudeUsageGate()
        let open = await gate.blockedUntil(at: now)
        XCTAssertNil(open)

        await gate.record(response(429, retryAfter: "300"), sentAt: at(-0.2), at: now)
        let blocked = await gate.blockedUntil(at: at(299))
        XCTAssertEqual(blocked, at(300))

        // Sent before the refusal: says nothing about the limit now.
        await gate.record(response(200), sentAt: at(-0.5), at: at(0.3))
        let stillBlocked = await gate.blockedUntil(at: at(10))
        XCTAssertEqual(stillBlocked, at(300), "an earlier request's 200 must not lift the wait")

        await gate.record(response(200), sentAt: at(301), at: at(301.2))
        let lifted = await gate.blockedUntil(at: at(301.2))
        XCTAssertNil(lifted)
    }

    func testOtherStatusesLeaveTheGateAlone() async {
        let gate = ClaudeUsageGate()
        await gate.record(response(429), sentAt: at(-0.2), at: now)

        await gate.record(response(401), sentAt: at(1), at: at(1.1))
        await gate.record(response(500), sentAt: at(2), at: at(2.1))

        let still = await gate.blockedUntil(at: at(3))
        XCTAssertEqual(still, at(60), "a 401 or 5xx neither lifts nor extends the wait")
    }

    // MARK: Nothing is sent during the wait

    /// The shared gate is process-wide, so the test that blocks it lifts it again.
    private func blockSharedGate(for seconds: TimeInterval = 120) async {
        await ClaudeUsageGate.shared.record(
            response(429, retryAfter: "\(Int(seconds))"), sentAt: Date().addingTimeInterval(-0.01))
    }

    private func liftSharedGate() async {
        await ClaudeUsageGate.shared.record(response(200), sentAt: Date().addingTimeInterval(60))
    }

    func testFetchersRefuseToSendWhileTheWaitRuns() async throws {
        await blockSharedGate()
        // Unwrapped, not asserted: if the gate were open the calls below would
        // send a real request.
        let blocked = await ClaudeUsageGate.shared.blockedUntil()
        _ = try XCTUnwrap(blocked, "the shared gate should be blocked")
        let token = ClaudeCredentials.Token(accessToken: "never-sent", refreshToken: nil, expiresAt: nil)

        do {
            _ = try await ClaudeOAuthFetcher.fetch(token: token)
            XCTFail("the quota read should not have been sent")
        } catch is ClaudeUsageGate.Blocked {
        } catch {
            XCTFail("expected Blocked, got \(error)")
        }
        do {
            _ = try await ClaudeResetGrantFetcher.fetch(token: token)
            XCTFail("the reset read should not have been sent")
        } catch ClaudeResetGrantFetcher.FetchError.blocked {
        } catch {
            XCTFail("expected blocked, got \(error)")
        }
        await liftSharedGate()
    }

    func testAQuotaCycleDuringTheWaitReadsNoCredentialAndSendsNothing() async throws {
        await blockSharedGate()
        // Unwrapped, not asserted: an open gate would read the Keychain here.
        let blocked = await ClaudeUsageGate.shared.blockedUntil()
        _ = try XCTUnwrap(blocked, "the shared gate should be blocked")

        let state = await ClaudeService().fetch(refreshQuota: true, refreshUsage: false, previous: nil)

        await liftSharedGate()
        XCTAssertEqual(state.quota.source, .unavailable)
        XCTAssertNotNil(
            state.quota.note?.range(of: "^Claude is rate-limiting quota reads — retrying after ", options: .regularExpression),
            "unexpected note: \(state.quota.note ?? "nil")")
    }

    func testRateLimitedQuotaCarriesNoReadingAndSaysWhenItRetries() {
        let snapshot = ClaudeService.rateLimitedQuota(until: now)

        XCTAssertEqual(snapshot.source, .unavailable)
        XCTAssertTrue(snapshot.windows.isEmpty)
        XCTAssertNotNil(
            snapshot.note?.range(
                of: "^Claude is rate-limiting quota reads — retrying after [0-9]{2}:[0-9]{2}$",
                options: .regularExpression),
            "unexpected note: \(snapshot.note ?? "nil")")
        let previous = QuotaSnapshot(
            provider: .claude,
            windows: [QuotaWindow(id: "five_hour", label: "5-hour", usedPercent: 12,
                                  resetsAt: now.addingTimeInterval(3600))],
            source: .oauth, planType: "pro", fetchedAt: now.addingTimeInterval(-30), note: nil)
        let state = ProviderState(provider: .claude, quota: snapshot, usage: .empty(.claude))
        XCTAssertEqual(state.preservingLiveQuota(from: previous, at: now).quota, previous,
                       "the live reading stays on screen while the endpoint is refused")
    }

    // MARK: Reset-read single flight

    private actor Counter {
        private(set) var calls = 0
        func next() -> Int { calls += 1; return calls }
    }

    func testConcurrentResetReadsShareOneRequest() async {
        let gate = ClaudeUsageGate()
        let counter = Counter()
        let state = ClaudeResetState(eligible: true)

        // Two refreshes reaching the read together: the second
        // arrives while the first is still waiting on the network.
        async let first = gate.readResets {
            _ = await counter.next()
            try? await Task.sleep(nanoseconds: 300_000_000)
            return state
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        async let second = gate.readResets {
            _ = await counter.next()
            return ClaudeResetState(eligible: false)
        }
        let (a, b) = await (first, second)

        let calls = await counter.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(a, state)
        XCTAssertEqual(b, state, "the joiner takes the read already in flight")
    }

    func testAResetReadAfterTheFirstFinishedSendsItsOwnRequest() async {
        let gate = ClaudeUsageGate()
        let counter = Counter()

        _ = await gate.readResets { _ = await counter.next(); return nil }
        let second = await gate.readResets { _ = await counter.next(); return ClaudeResetState(eligible: true) }

        let calls = await counter.calls
        XCTAssertEqual(calls, 2, "a read that failed is not reused: the next caller tries again")
        XCTAssertEqual(second, ClaudeResetState(eligible: true))
    }

    /// Two refreshes reached the reset read nearly together; a
    /// second refresh arriving a few seconds later, after the first read had
    /// finished, would have sent its own, because its plan could not see a
    /// read the stalled refresh had not landed.
    func testAResetReadSoonAfterASuccessfulOneReusesItsState() async {
        let gate = ClaudeUsageGate()
        let counter = Counter()
        let first = ClaudeResetState(eligible: true)
        let start = now

        let a = await gate.readResets(at: start) { _ = await counter.next(); return first }
        let b = await gate.readResets(at: start.addingTimeInterval(3)) {
            _ = await counter.next()
            return ClaudeResetState(eligible: false)
        }
        let c = await gate.readResets(at: start.addingTimeInterval(ClaudeUsageGate.resetReuseWindow - 1)) {
            _ = await counter.next()
            return ClaudeResetState(eligible: false)
        }
        let afterWindow = ClaudeResetState(eligible: true, ineligibleReason: nil, grants: [])
        let d = await gate.readResets(at: start.addingTimeInterval(ClaudeUsageGate.resetReuseWindow)) {
            _ = await counter.next()
            return afterWindow
        }

        let calls = await counter.calls
        XCTAssertEqual(calls, 2)
        XCTAssertEqual([a, b, c], [first, first, first])
        XCTAssertEqual(d, afterWindow, "a minute later it reads again")
    }

    func testConcurrentQuotaReadsShareOneRequestAndItsError() async {
        struct Refused: Error {}
        let gate = ClaudeUsageGate()
        let counter = Counter()
        let snapshot = QuotaSnapshot(
            provider: .claude, windows: [], source: .oauth, planType: "pro", fetchedAt: now, note: nil)

        // Refreshes stacked behind one Keychain prompt reach the read together.
        async let first = gate.readQuota {
            _ = await counter.next()
            try? await Task.sleep(nanoseconds: 300_000_000)
            return snapshot
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        async let second = gate.readQuota {
            _ = await counter.next()
            throw Refused()
        }
        let (a, b) = try! await (first, second)

        let calls = await counter.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(a, snapshot)
        XCTAssertEqual(b, snapshot)

        // The error of a shared read reaches every waiter, and a later read
        // starts afresh.
        async let refusedFirst: QuotaSnapshot = gate.readQuota {
            _ = await counter.next()
            try await Task.sleep(nanoseconds: 300_000_000)
            throw Refused()
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        async let refusedSecond: QuotaSnapshot = gate.readQuota { snapshot }
        var refused = 0
        do { _ = try await refusedFirst } catch is Refused { refused += 1 } catch {}
        do { _ = try await refusedSecond } catch is Refused { refused += 1 } catch {}
        XCTAssertEqual(refused, 2, "the joiner gets the shared read's error, not a result of its own")

        let later = try? await gate.readQuota { _ = await counter.next(); return snapshot }
        let finalCalls = await counter.calls
        XCTAssertEqual(later, snapshot)
        XCTAssertEqual(finalCalls, 3)
    }

    /// A read that never answers must not capture every later refresh: once it
    /// is older than the join window the next caller sends its own, and the
    /// hung one finishing afterwards does not clear that newer read.
    func testAHungResetReadIsNotJoinedForever() async {
        let gate = ClaudeUsageGate()
        let counter = Counter()
        let release = AsyncStream<Void>.makeStream()
        let start = now
        let afterWindow = now.addingTimeInterval(ClaudeUsageGate.resetJoinWindow + 1)
        let muchLater = now.addingTimeInterval(100)

        async let hung: ClaudeResetState? = gate.readResets(at: start) {
            _ = await counter.next()
            for await _ in release.stream { break }
            return nil
        }
        try? await Task.sleep(nanoseconds: 50_000_000)

        let fresh = await gate.readResets(at: afterWindow) {
            _ = await counter.next()
            return ClaudeResetState(eligible: true)
        }
        let callsWhileHung = await counter.calls
        XCTAssertEqual(callsWhileHung, 2, "the stale read was not joined")
        XCTAssertEqual(fresh, ClaudeResetState(eligible: true))

        // Now let the hung read end; a reader arriving in the window of a
        // newer in-flight read must still join that one.
        async let newer: ClaudeResetState? = gate.readResets(at: muchLater) {
            _ = await counter.next()
            try? await Task.sleep(nanoseconds: 200_000_000)
            return ClaudeResetState(eligible: false)
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        release.continuation.yield()
        release.continuation.finish()
        _ = await hung
        let joiner = await gate.readResets(at: muchLater.addingTimeInterval(1)) {
            _ = await counter.next()
            return ClaudeResetState(eligible: true)
        }
        let newerResult = await newer

        let calls = await counter.calls
        XCTAssertEqual(calls, 3, "the hung read finishing did not clear the newer in-flight read")
        XCTAssertEqual(joiner, newerResult)
    }
}

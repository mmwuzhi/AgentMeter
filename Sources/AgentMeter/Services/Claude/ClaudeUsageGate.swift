import Foundation

/// What a 429 from `/api/oauth/usage` obliges the app to do, as pure state:
/// stay off the endpoint until `blockedUntil`, then try again, waiting longer
/// each time the retry is refused too. `Retry-After` wins when the response
/// carries a usable one. The default backoff tops out at five minutes.
///
/// Responses arrive in completion order, not send order, so each one carries
/// the time its request went out and is judged against the last 429 the app
/// learned of: an answer to a request that predates it describes the server
/// before the limit and must neither lift it nor count as a second refusal.
struct ClaudeUsageBackoff: Equatable, Sendable {
    static let initialDelay: TimeInterval = 60
    static let maxDelay: TimeInterval = 5 * 60
    /// Shortest wait a server-stated `Retry-After` is rounded up to, so a
    /// zero does not mean hammering.
    static let minRetryAfter: TimeInterval = 15
    /// A longer `Retry-After` is not a wait but a malformed header, and falls
    /// back to the default schedule instead of stranding the quota for days.
    static let maxRetryAfter: TimeInterval = 24 * 3600

    private(set) var consecutiveRateLimits = 0
    private(set) var until: Date?
    /// When the app last learned of a 429 that started or escalated the wait.
    private var lastRateLimitedAt: Date?

    /// The time before which no request may go out, or nil once it has passed.
    func blockedUntil(at now: Date) -> Date? {
        guard let until, until > now else { return nil }
        return until
    }

    /// `sentAt` is when the refused request was sent, `now` when its answer
    /// arrived. A 429 whose request predates the wait already in place belongs
    /// to the same burst: it does not escalate the schedule, and only extends
    /// the wait when it states a longer `Retry-After`.
    mutating func recordRateLimited(retryAfter: TimeInterval?, sentAt: Date, at now: Date) {
        if let lastRateLimitedAt, sentAt <= lastRateLimitedAt {
            if let retryAfter {
                until = max(until ?? now, now.addingTimeInterval(Self.delay(retryAfter: retryAfter)))
            }
            return
        }
        consecutiveRateLimits += 1
        lastRateLimitedAt = now
        let delay: TimeInterval
        if let retryAfter {
            delay = Self.delay(retryAfter: retryAfter)
        } else {
            let doublings = Double(min(consecutiveRateLimits - 1, 8))
            delay = min(Self.initialDelay * pow(2, doublings), Self.maxDelay)
        }
        until = now.addingTimeInterval(delay)
    }

    /// A 200 lifts the wait, unless its request was sent before the 429 that
    /// set it.
    mutating func recordSuccess(sentAt: Date) {
        if let lastRateLimitedAt, sentAt <= lastRateLimitedAt { return }
        consecutiveRateLimits = 0
        until = nil
    }

    private static func delay(retryAfter: TimeInterval) -> TimeInterval {
        max(retryAfter, minRetryAfter)
    }

    /// `Retry-After` is either delta-seconds or an HTTP date. Nil when absent,
    /// unreadable or beyond `maxRetryAfter`; a date already past reads as zero.
    static func retryAfter(header: String?, at now: Date) -> TimeInterval? {
        guard let text = header?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let seconds: TimeInterval
        if let value = Double(text) {
            seconds = value
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            guard let date = formatter.date(from: text) else { return nil }
            seconds = max(0, date.timeIntervalSince(now))
        }
        return seconds.isFinite && seconds >= 0 && seconds <= maxRetryAfter ? seconds : nil
    }
}

/// Every request to `/api/oauth/usage` (the quota read, the reset-grants read,
/// and the `claude /usage` scrape that asks the same endpoint with the same
/// token) shares one rate limit, so what one of them learns binds the others,
/// whichever refresh they come from.
///
/// The gate also keeps overlapping refreshes from each sending the same read.
/// `ProviderRefreshPlan` only sees what earlier refreshes have landed, and the
/// 30-second escape in `RefreshCoordinator.refresh` lets a second refresh start
/// beside a stalled one that has landed nothing: both then reached the reset
/// read together after a slow launch scan,
/// and refreshes stacked behind a Keychain prompt would reach the quota read
/// together when it is answered.
actor ClaudeUsageGate {
    static let shared = ClaudeUsageGate()

    /// Thrown by a fetcher that found the wait still running when it was about
    /// to send, which can happen when a 429 lands while it waits on the
    /// credential read.
    struct Blocked: Error, Sendable { let until: Date }

    /// A read in flight longer than its window is not joined: each request's
    /// own timeout (15 s quota, 8 s reset) is shorter, so one still running
    /// has hung, and a refresh that joined it would hang with it.
    static let quotaJoinWindow: TimeInterval = 20
    static let resetJoinWindow: TimeInterval = 10
    /// A reset read that succeeded is reused, not repeated, for this long:
    /// the same spacing the planner gives "Refresh now".
    static let resetReuseWindow = ProviderRefreshPlan.minimumForcedClaudeResetsSpacing

    private var backoff = ClaudeUsageBackoff()
    private var quotaFlight = Flight<Result<QuotaSnapshot, any Error>>()
    private var resetFlight = Flight<ClaudeResetState?>()
    private var lastResets: (startedAt: Date, state: ClaudeResetState)?

    func blockedUntil(at now: Date = Date()) -> Date? {
        backoff.blockedUntil(at: now)
    }

    /// What a response from the endpoint teaches: a 429 starts or extends the
    /// wait (honouring `Retry-After`), a 200 ends it. Other statuses (401,
    /// 5xx) say nothing about the limit and leave it alone.
    func record(_ response: HTTPURLResponse, sentAt: Date, at now: Date = Date()) {
        switch response.statusCode {
        case 200:
            backoff.recordSuccess(sentAt: sentAt)
        case 429:
            backoff.recordRateLimited(
                retryAfter: ClaudeUsageBackoff.retryAfter(
                    header: response.value(forHTTPHeaderField: "Retry-After"), at: now),
                sentAt: sentAt,
                at: now)
        default:
            break
        }
    }

    /// One quota read at a time: a caller that arrives while one is in flight
    /// takes its answer, or its error, instead of sending its own.
    func readQuota(
        at now: Date = Date(),
        using read: @escaping @Sendable () async throws -> QuotaSnapshot
    ) async throws -> QuotaSnapshot {
        if let task = quotaFlight.joinable(at: now, window: Self.quotaJoinWindow) {
            return try await task.value.get()
        }
        let task = Task<Result<QuotaSnapshot, any Error>, Never> {
            do { return .success(try await read()) } catch { return .failure(error) }
        }
        let id = quotaFlight.begin(at: now, task)
        let result = await task.value
        quotaFlight.end(id)
        return try result.get()
    }

    /// One reset-grants read at a time, and none within `resetReuseWindow` of
    /// one that succeeded: such a caller takes that read's state. A read that
    /// failed is not reused, so the next caller tries again.
    func readResets(
        at now: Date = Date(),
        using read: @escaping @Sendable () async -> ClaudeResetState?
    ) async -> ClaudeResetState? {
        if let task = resetFlight.joinable(at: now, window: Self.resetJoinWindow) {
            return await task.value
        }
        if let last = lastResets, now.timeIntervalSince(last.startedAt) < Self.resetReuseWindow {
            return last.state
        }
        let task = Task { await read() }
        let id = resetFlight.begin(at: now, task)
        let state = await task.value
        resetFlight.end(id)
        if let state { lastResets = (now, state) }
        return state
    }

    /// The read currently in flight, if any.
    private struct Flight<Value: Sendable> {
        private var current: (id: UUID, startedAt: Date, task: Task<Value, Never>)?

        func joinable(at now: Date, window: TimeInterval) -> Task<Value, Never>? {
            guard let current, now.timeIntervalSince(current.startedAt) < window else { return nil }
            return current.task
        }

        mutating func begin(at now: Date, _ task: Task<Value, Never>) -> UUID {
            let id = UUID()
            current = (id, now, task)
            return id
        }

        /// A hung read that was replaced must not clear its replacement.
        mutating func end(_ id: UUID) {
            if current?.id == id { current = nil }
        }
    }
}

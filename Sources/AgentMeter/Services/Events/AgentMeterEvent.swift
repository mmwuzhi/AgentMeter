import Foundation

// The events AgentMeter tells the user about through the shared notification
// path (`NotificationManager+Events.swift`) and keeps in `events.jsonl`
// (`AgentMeterEventStore`): session task outcomes now, rule alerts later. The
// built-in quota critical/recovery notifications keep their own path and are
// not events.
//
// Times are whole milliseconds (`HistoryTime`), in memory and on disk alike,
// so an event read back from the log equals the one that was recorded.

/// What an event says happened. A string, not a closed enum, so a kind written
/// by a newer build decodes in an older one and survives its compaction.
struct AgentMeterEventKind: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }

    // Session task outcomes (design 5.9). Phase 1b produces them.
    static let taskCompleted = Self("task_completed")
    static let taskFailed = Self("task_failed")
    static let taskWaiting = Self("task_waiting")
    static let taskInterrupted = Self("task_interrupted")
    static let taskUnknown = Self("task_unknown")

    /// Decides the notification category. Rule alerts (`rule_*`) arrive with
    /// the usage alerts.
    enum Family: Sendable, Equatable {
        case task, rule, other
    }

    var family: Family {
        if rawValue.hasPrefix("task_") { return .task }
        if rawValue.hasPrefix("rule_") { return .rule }
        return .other
    }

    var description: String { rawValue }

    init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Who or what an event concerns, so a later reader (the popover row, the
/// Dashboard, a click on the notification) can find the session, task or rule
/// again. Every field is optional; a producer fills in what it knows.
struct AgentMeterEventSubject: Hashable, Sendable, Codable {
    /// `Provider.rawValue`, kept as a string so an unknown provider still decodes.
    var provider: String?
    var sessionID: String?
    /// The task within the session (1b: the user prompt's `prompt_id`, or
    /// `<sessionId>|<startedAt>` without one).
    var taskKey: String?
    var projectPath: String?
    var ruleID: String?
    var scopeKey: String?
    /// The session's title when the event was recorded (format 2), as the
    /// session list showed it; nil when it had none or before format 2. The
    /// menu names a session that has ended with it. Untrusted text, shown
    /// only through `SessionLabel`.
    var sessionTitle: String?
    /// How the session's process was started (`TaskSessionLaunch` raw
    /// value, format 2); nil when unknown.
    var sessionKind: String?

    init(provider: String? = nil, sessionID: String? = nil, taskKey: String? = nil,
         projectPath: String? = nil, ruleID: String? = nil, scopeKey: String? = nil,
         sessionTitle: String? = nil, sessionKind: String? = nil) {
        self.provider = provider
        self.sessionID = sessionID
        self.taskKey = taskKey
        self.projectPath = projectPath
        self.ruleID = ruleID
        self.scopeKey = scopeKey
        self.sessionTitle = sessionTitle
        self.sessionKind = sessionKind
    }
}

/// What the notification shows. The producer writes the text; it must never
/// carry a prompt, an assistant message or error details (design 5.9 F).
struct AgentMeterEventContent: Hashable, Sendable, Codable {
    var title: String
    var body: String
    /// A later event posted with the same identifier replaces the delivered
    /// banner instead of stacking (`agentmeter.task.<sid>.<taskKey>` for
    /// tasks). Nil: `agentmeter.event.<id>`, one banner per event.
    var notificationIdentifier: String?
    /// Groups banners in Notification Center (tasks: per project).
    var threadIdentifier: String?

    init(title: String, body: String, notificationIdentifier: String? = nil, threadIdentifier: String? = nil) {
        self.title = title
        self.body = body
        self.notificationIdentifier = notificationIdentifier
        self.threadIdentifier = threadIdentifier
    }
}

/// What became of an event's notification. It only moves forward: pending,
/// then interrupted or a final state, and a final state never changes. Only
/// the process that recorded an event ever posts it, once (at most one
/// banner per event); nothing is retried.
struct AgentMeterEventDelivery: Hashable, Sendable {
    enum State: String, Sendable, Codable {
        /// Recorded, not decided yet. Only ever seen in the run that recorded
        /// the event: a later run finds it `interrupted`.
        case pending
        /// The run that recorded it ended before its outcome was written: a
        /// crash, a kill, or a quit while a permission prompt was open. The
        /// banner may or may not have gone out. Set by the next run, at its
        /// first read of the log; never retried. The recording run's own
        /// outcome, if it was still alive and writes one later, replaces it.
        case interrupted
        /// The notification center accepted the request.
        case posted
        /// The center refused it; `reason` holds the error's domain and code.
        case failed
        /// Deliberately not posted; `reason` says why (`Suppression`, or a
        /// producer's own reason such as `beforeLaunch`).
        case suppressed

        /// Order of the forward-only moves: a delivery is replaced only by
        /// one of a higher rank, so replaying the log gives the same answer
        /// whatever order two processes' lines landed in.
        var rank: Int {
            switch self {
            case .pending: 0
            case .interrupted: 1
            case .posted, .failed, .suppressed: 2
            }
        }
    }

    /// Why AgentMeter itself held a notification back.
    enum Suppression {
        /// The user turned this kind off (`AgentMeterNotificationPreferences`).
        static let disabledByUser = "disabledByUser"
        /// The process has no app bundle (a bare `make debug` binary), where
        /// the notification center would trap.
        static let noAppBundle = "noAppBundle"
        /// Notifications are denied in System Settings.
        static let permissionDenied = "permissionDenied"
        /// No answer to the permission prompt, or no prompt possible.
        static let notAuthorized = "notAuthorized"
        /// It happened too long before it could be posted (found after a
        /// restart, or held up behind an open permission prompt).
        static let stale = "stale"
    }

    var state: State
    var reason: String?
    /// When the state was decided; nil while pending.
    var decidedAt: Date?

    static let pending = AgentMeterEventDelivery(state: .pending, reason: nil, decidedAt: nil)

    static func posted(at date: Date) -> Self {
        Self(state: .posted, reason: nil, decidedAt: date)
    }

    static func failed(_ reason: String, at date: Date) -> Self {
        Self(state: .failed, reason: reason, decidedAt: date)
    }

    static func suppressed(_ reason: String, at date: Date) -> Self {
        Self(state: .suppressed, reason: reason, decidedAt: date)
    }

    /// `decidedAt` is when a later run found it pending.
    static func interrupted(at date: Date) -> Self {
        Self(state: .interrupted, reason: nil, decidedAt: date)
    }

    /// Whether `next` may replace this delivery.
    func isSuperseded(by next: Self) -> Bool {
        next.state.rank > state.rank
    }

    init(state: State, reason: String?, decidedAt: Date?) {
        self.state = state
        self.reason = reason.map { String($0.prefix(AgentMeterEvent.maximumReasonLength)) }
        self.decidedAt = decidedAt.map(AgentMeterEvent.wholeMilliseconds)
    }
}

/// One thing that happened and that AgentMeter may tell the user about.
struct AgentMeterEvent: Hashable, Sendable, Identifiable {
    /// The producer's name for this occurrence, and the dedup key: the store
    /// keeps at most one event per id, across restarts, for as long as it
    /// keeps the event (`AgentMeterEventStore.Limits.retention`). A producer
    /// that rediscovers the same occurrence (a restart, a rescan) builds the
    /// same id, e.g. `task_completed|<sessionId>|<taskKey>`.
    let id: String
    let kind: AgentMeterEventKind
    /// When it happened, as the producer saw it (1b: the Stop hook's time).
    let occurredAt: Date
    /// When AgentMeter first noticed it: right after `occurredAt` for a live
    /// event, much later for one found after a restart.
    let discoveredAt: Date
    var subject: AgentMeterEventSubject
    var content: AgentMeterEventContent
    /// The detector or evaluator that decided it (`detectorVersion`,
    /// `evaluatorVersion` in the design), so a later version can tell its
    /// own events from older ones.
    var producerVersion: String?
    var delivery: AgentMeterEventDelivery
    /// Nil while unread. Only an explicit read sets it (a click on the
    /// notification, `markRead`); time passing never does.
    var readAt: Date?

    var isUnread: Bool { readAt == nil }

    static let maximumIDLength = 512
    static let maximumTitleLength = 256
    static let maximumBodyLength = 1_024
    static let maximumReasonLength = 128
    static let maximumFieldLength = 4_096

    /// Lengths are capped and times rounded to whole milliseconds here, so
    /// what the store writes and what it reads back are the same value.
    init(id: String, kind: AgentMeterEventKind, occurredAt: Date, discoveredAt: Date,
         subject: AgentMeterEventSubject = AgentMeterEventSubject(), content: AgentMeterEventContent,
         producerVersion: String? = nil, delivery: AgentMeterEventDelivery = .pending, readAt: Date? = nil) {
        self.id = String(id.prefix(Self.maximumIDLength))
        self.kind = AgentMeterEventKind(String(kind.rawValue.prefix(Self.maximumReasonLength)))
        self.occurredAt = Self.wholeMilliseconds(occurredAt)
        self.discoveredAt = Self.wholeMilliseconds(discoveredAt)
        self.subject = Self.capped(subject)
        self.content = AgentMeterEventContent(
            title: String(content.title.prefix(Self.maximumTitleLength)),
            body: String(content.body.prefix(Self.maximumBodyLength)),
            notificationIdentifier: content.notificationIdentifier.map { String($0.prefix(Self.maximumIDLength)) },
            threadIdentifier: content.threadIdentifier.map { String($0.prefix(Self.maximumIDLength)) })
        self.producerVersion = producerVersion.map { String($0.prefix(Self.maximumReasonLength)) }
        self.delivery = delivery
        self.readAt = readAt.map(Self.wholeMilliseconds)
    }

    static func wholeMilliseconds(_ date: Date) -> Date {
        let ms = min(max(HistoryTime.ms(date), -HistoryTime.maxMagnitudeMs + 1), HistoryTime.maxMagnitudeMs - 1)
        return HistoryTime.date(ms: ms)
    }

    private static func capped(_ subject: AgentMeterEventSubject) -> AgentMeterEventSubject {
        func cap(_ value: String?) -> String? { value.map { String($0.prefix(maximumFieldLength)) } }
        return AgentMeterEventSubject(
            provider: cap(subject.provider), sessionID: cap(subject.sessionID), taskKey: cap(subject.taskKey),
            projectPath: cap(subject.projectPath), ruleID: cap(subject.ruleID), scopeKey: cap(subject.scopeKey),
            sessionTitle: subject.sessionTitle.map { String($0.prefix(maximumTitleLength)) },
            sessionKind: subject.sessionKind.map { String($0.prefix(maximumReasonLength)) })
    }
}

// MARK: - Coding (times as integer milliseconds)

extension AgentMeterEventDelivery: Codable {
    private enum CodingKeys: String, CodingKey {
        case state, reason, decidedAt
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(state: try c.decode(State.self, forKey: .state),
                  reason: try c.decodeIfPresent(String.self, forKey: .reason),
                  decidedAt: try c.decodeIfPresent(Int64.self, forKey: .decidedAt).map(HistoryTime.date(ms:)))
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(reason, forKey: .reason)
        try c.encodeIfPresent(decidedAt.map(HistoryTime.ms), forKey: .decidedAt)
    }
}

extension AgentMeterEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, kind, occurredAt, discoveredAt, subject, content, producerVersion, delivery, readAt
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            kind: try c.decode(AgentMeterEventKind.self, forKey: .kind),
            occurredAt: HistoryTime.date(ms: try c.decode(Int64.self, forKey: .occurredAt)),
            discoveredAt: HistoryTime.date(ms: try c.decode(Int64.self, forKey: .discoveredAt)),
            subject: try c.decodeIfPresent(AgentMeterEventSubject.self, forKey: .subject) ?? AgentMeterEventSubject(),
            content: try c.decode(AgentMeterEventContent.self, forKey: .content),
            producerVersion: try c.decodeIfPresent(String.self, forKey: .producerVersion),
            delivery: try c.decodeIfPresent(AgentMeterEventDelivery.self, forKey: .delivery) ?? .pending,
            readAt: try c.decodeIfPresent(Int64.self, forKey: .readAt).map(HistoryTime.date(ms:)))
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(HistoryTime.ms(occurredAt), forKey: .occurredAt)
        try c.encode(HistoryTime.ms(discoveredAt), forKey: .discoveredAt)
        try c.encode(subject, forKey: .subject)
        try c.encode(content, forKey: .content)
        try c.encodeIfPresent(producerVersion, forKey: .producerVersion)
        try c.encode(delivery, forKey: .delivery)
        try c.encodeIfPresent(readAt.map(HistoryTime.ms), forKey: .readAt)
    }
}

/// Which events a query or a bulk read covers. Empty fields match everything.
struct AgentMeterEventFilter: Sendable, Equatable {
    var kinds: Set<AgentMeterEventKind>?
    var sessionID: String?
    var unreadOnly: Bool

    init(kinds: Set<AgentMeterEventKind>? = nil, sessionID: String? = nil, unreadOnly: Bool = false) {
        self.kinds = kinds
        self.sessionID = sessionID
        self.unreadOnly = unreadOnly
    }

    static let all = AgentMeterEventFilter()

    func matches(_ event: AgentMeterEvent) -> Bool {
        if let kinds, !kinds.contains(event.kind) { return false }
        if let sessionID, event.subject.sessionID != sessionID { return false }
        if unreadOnly, !event.isUnread { return false }
        return true
    }
}

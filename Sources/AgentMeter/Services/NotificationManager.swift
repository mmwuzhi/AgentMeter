import Foundation
import UserNotifications

@MainActor
protocol NotificationAuthorizationCenter: AnyObject {
    var delegate: (any UNUserNotificationCenterDelegate)? { get set }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    /// Delivery goes through the same seam as the permission request, so a
    /// test can see what would have been posted without touching the real
    /// center.
    func post(_ request: UNNotificationRequest)
    /// Event delivery: like `post`, but says whether the center took it.
    func deliver(_ request: UNNotificationRequest) async throws
    /// The permission as it stands now. The user can change it in System
    /// Settings at any time, so event delivery asks before every post.
    func authorizationStatus() async -> UNAuthorizationStatus
    /// Everything System Settings says about these notifications, for the
    /// Settings window (style, lock screen, previews).
    func currentSettings() async -> AgentMeterNotificationSettings
    func setCategories(_ categories: Set<UNNotificationCategory>)
}

extension UNUserNotificationCenter: NotificationAuthorizationCenter {
    func post(_ request: UNNotificationRequest) {
        add(request, withCompletionHandler: nil)
    }

    func deliver(_ request: UNNotificationRequest) async throws {
        try await add(request)
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await notificationSettings().authorizationStatus
    }

    func currentSettings() async -> AgentMeterNotificationSettings {
        AgentMeterNotificationSettings(await notificationSettings())
    }

    func setCategories(_ categories: Set<UNNotificationCategory>) {
        setNotificationCategories(categories)
    }
}

/// The quota alerts that went out, by `provider:window`: what keeps one
/// depletion from alerting twice. Kept across launches
/// (`QuotaNotificationStateStore`): it used to live in memory only, and every
/// relaunch alerted again for a window still low in the same epoch.
struct QuotaNotificationState: Equatable, Codable {
    struct Alert: Equatable, Codable {
        /// The `resetsAt` of the epoch it went out for; nil while no reading
        /// of that epoch has carried one.
        var resetsAt: Date?
        var alertedAt: Date
    }

    /// The latest alert per window: a recovery is judged against it.
    var alerts: [String: Alert] = [:]
    /// The reset of every epoch alerted per window, while it is still ahead:
    /// a reading of one of them alerts no more. Readings carry no account,
    /// and two epochs of one window can read side by side: another login's,
    /// or a stale fallback reading (Codex's rollout log after a reset credit
    /// was spent) of the epoch before.
    var alertedResets: [String: [Date]] = [:]

    /// What a launch keeps: what still describes an epoch that runs by its
    /// stated reset. An alert whose reset passed more than
    /// `sameEpochTolerance` ago ended while AgentMeter was not watching, so
    /// its window re-arms as on any new epoch, with no recovery banner for an
    /// end nobody saw; one without a reset cannot show it is still running
    /// and is dropped too (at worst one alert again, never one missed).
    func kept(at now: Date) -> QuotaNotificationState {
        var kept = self
        kept.alerts = alerts.filter { _, alert in alert.resetsAt.map { Self.runs($0, at: now) } ?? false }
        kept.dropEndedResets(at: now)
        return kept
    }

    /// Forgets alerted resets that have passed: no reading of their epoch is
    /// taken any more (`QuotaNotificationPolicy` skips a reading past its
    /// reset), so they can match nothing.
    mutating func dropEndedResets(at now: Date) {
        alertedResets = alertedResets.compactMapValues { resets in
            let running = resets.filter { Self.runs($0, at: now) }
            return running.isEmpty ? nil : running
        }
    }

    func hasAlerted(_ key: String, epochEndingAt reset: Date) -> Bool {
        alertedResets[key]?.contains { QuotaNotificationPolicy.isSameEpoch(reset, $0) } ?? false
    }

    mutating func remember(_ key: String, epochEndingAt reset: Date?) {
        guard let reset, !hasAlerted(key, epochEndingAt: reset) else { return }
        alertedResets[key, default: []].append(reset)
    }

    private static func runs(_ reset: Date, at now: Date) -> Bool {
        reset.addingTimeInterval(QuotaWindow.sameEpochTolerance) > now
    }
}

/// Where the quota alerts' state is kept: one `UserDefaults` key beside the
/// alert settings, the only copy. Read at each evaluation, so a second
/// instance on the same defaults (a development build beside the installed
/// app) builds on the first one's alerts instead of overwriting them, though
/// not atomically (two processes refreshing at the same moment can still both
/// post); written whenever it changes. A value that does not decode reads as
/// empty, as before the key existed.
struct QuotaNotificationStateStore {
    var load: () -> QuotaNotificationState
    var save: (QuotaNotificationState) -> Void

    static let defaultsKey = "quotaAlertState"

    static func defaults(_ defaults: UserDefaults) -> Self {
        Self(
            load: {
                guard let data = defaults.data(forKey: defaultsKey) else { return QuotaNotificationState() }
                return (try? JSONDecoder().decode(QuotaNotificationState.self, from: data)) ?? QuotaNotificationState()
            },
            save: { state in
                guard let data = try? JSONEncoder().encode(state) else { return }
                defaults.set(data, forKey: defaultsKey)
            })
    }

    /// Tests: kept for this store's lifetime only.
    static var memory: Self {
        final class Box { var state = QuotaNotificationState() }
        let box = Box()
        return Self(load: { box.state }, save: { box.state = $0 })
    }
}

enum QuotaNotificationEvent: Equatable {
    case critical(provider: Provider, window: QuotaWindow)
    case recovered(provider: Provider, window: QuotaWindow)
}

enum QuotaNotificationPolicy {
    static func evaluate(
        provider: Provider,
        windows: [QuotaWindow],
        now: Date = Date(),
        threshold: Double,
        alertsEnabled: Bool,
        recoveryEnabled: Bool,
        canDeliver: Bool,
        state: inout QuotaNotificationState
    ) -> [QuotaNotificationEvent] {
        guard alertsEnabled else {
            state = QuotaNotificationState()
            return []
        }
        guard canDeliver else { return [] }

        var events: [QuotaNotificationEvent] = []
        for window in windows {
            // A reading whose own reset has passed describes an epoch that is
            // over: last-state.json at launch, or a sibling carried along when
            // a failed refresh keeps the last live snapshot whole.
            if let reset = window.resetsAt, reset <= now { continue }
            let key = Self.key(provider: provider, windowID: window.id)
            let alert = state.alerts[key]
            if window.remainingPercent <= threshold {
                if let alert {
                    if let alertedReset = alert.resetsAt {
                        // Without a reset time the reading may be the `claude
                        // /usage` scrape echoing a cached level, so only a
                        // stated reset re-alerts.
                        guard let reset = window.resetsAt, !isSameEpoch(reset, alertedReset) else { continue }
                    } else if !epoch(of: window, beganAfter: alert.alertedAt) {
                        // An alert from a reading without a reset takes the
                        // first one stated, unless that epoch began after the
                        // alert went out (the Mac slept across the reset).
                        state.alerts[key]?.resetsAt = window.resetsAt
                        state.remember(key, epochEndingAt: window.resetsAt)
                        continue
                    }
                }
                // An epoch alerted before, earlier or later than the latest.
                if let reset = window.resetsAt, state.hasAlerted(key, epochEndingAt: reset) { continue }
                state.alerts[key] = QuotaNotificationState.Alert(resetsAt: window.resetsAt, alertedAt: now)
                state.remember(key, epochEndingAt: window.resetsAt)
                events.append(.critical(provider: provider, window: window))
            } else if let alert {
                // With no reset time on record there is no epoch to wait out,
                // and waiting would leave the window disarmed until relaunch.
                if let alertedReset = alert.resetsAt, !isLaterEpoch(window, than: alertedReset, now: now) { continue }
                if recoveryEnabled {
                    events.append(.recovered(provider: provider, window: window))
                }
                state.alerts.removeValue(forKey: key)
            }
        }
        state.dropEndedResets(at: now)
        return events
    }

    private static func key(provider: Provider, windowID: String) -> String {
        "\(provider.rawValue):\(windowID)"
    }

    /// Whether two resets name one epoch: within drift of each other
    /// (`sameEpochTolerance`; Codex's shifted by minutes in 17fb060).
    static func isSameEpoch(_ reset: Date, _ other: Date) -> Bool {
        abs(reset.timeIntervalSince(other)) <= QuotaWindow.sameEpochTolerance
    }

    /// Whether `window` reads a later epoch than the one ending at
    /// `alertedReset`, which a recovery needs. A reading that states its
    /// reset is later when that reset falls beyond `alertedReset` by more
    /// than drift: a reset spent mid-epoch (a Claude limit reset, a Codex
    /// reset credit) starts a full cycle from when it is spent, while drift
    /// within `sameEpochTolerance` stays one epoch even after `alertedReset`
    /// has passed. An earlier one is never a recovery: a stale fallback
    /// reading or another login's window would otherwise post one each time
    /// it alternated with the alerted one. A reading without one is later
    /// only once `alertedReset` has passed: Claude drops `resets_at`
    /// mid-epoch and later brings the same one back.
    private static func isLaterEpoch(_ window: QuotaWindow, than alertedReset: Date, now: Date) -> Bool {
        guard let reset = window.resetsAt else { return alertedReset <= now }
        return reset.timeIntervalSince(alertedReset) > QuotaWindow.sameEpochTolerance
    }

    /// Whether the epoch `window` reads began after `alertedAt`: its stated
    /// reset less one stated cycle (a reset spent mid-epoch starts a full
    /// cycle too). Within drift of that start it counts as begun, so an
    /// unclear case alerts once more rather than never. Without a reset or a
    /// cycle (Copilot states none) there is nothing to tell by: no.
    private static func epoch(of window: QuotaWindow, beganAfter alertedAt: Date) -> Bool {
        guard let reset = window.resetsAt, let cycle = window.cycle else { return false }
        return alertedAt <= reset.addingTimeInterval(QuotaWindow.sameEpochTolerance - cycle)
    }
}

/// Posts a system notification when a provider's quota drops to/below the user's
/// critical threshold. Dedups per window and reset epoch, across launches
/// (`QuotaNotificationState`): each depletion notifies once, and a
/// window re-arms once another epoch has begun (its reset passed, a limit
/// reset spent early moved it, or another login's window reads).
///
/// Also the one deliverer of events (`NotificationManager+Events.swift`):
/// session task outcomes now, rule alerts later. They share the permission
/// request and the delegate with the quota path and nothing else; the quota
/// path neither records events nor reads their settings.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    let authorizationCenter: any NotificationAuthorizationCenter
    private let bundleIdentifier: () -> String?
    private(set) var authorized = false
    private(set) var requested = false
    /// The quota alerts' dedup state, read at each evaluation. At init what
    /// no longer runs is dropped and written back
    /// (`QuotaNotificationState.kept(at:)`).
    private let quotaStateStore: QuotaNotificationStateStore
    /// The permission prompt while it is open, so an event that needs the
    /// answer waits for the same prompt instead of asking again.
    private(set) var authorizationRequest: Task<Void, Never>?

    /// The event record: dedup, delivery outcome, read state.
    let eventStore: AgentMeterEventStore
    /// Read on every event delivery.
    let preferences: @MainActor () -> AgentMeterNotificationPreferences
    let now: () -> Date
    /// An event that happened longer ago than this when it could be posted is
    /// recorded but not announced: found after a restart, or held up behind
    /// a permission prompt the user left open.
    let maximumDeliveryDelay: TimeInterval

    /// Invoked on the main actor when the user taps a quota notification.
    var onOpenProvider: ((Provider) -> Void)?
    /// Invoked on the main actor when the user taps an event's notification
    /// (or one of its actions). Returns whether the tap reads the event;
    /// only then is it marked read. Without a handler a tap reads it.
    var onEventResponse: (@MainActor (AgentMeterEvent, String) async -> Bool)?
    /// Invoked on the main actor after events were recorded, settled or read
    /// through this manager, so a view can re-query the store.
    var onEventsChanged: (() -> Void)?

    nonisolated static let defaultMaximumDeliveryDelay: TimeInterval = 15 * 60

    private override init() {
        authorizationCenter = UNUserNotificationCenter.current()
        bundleIdentifier = { Bundle.main.bundleIdentifier }
        eventStore = .shared
        preferences = { AgentMeterNotificationPreferences(defaults: .standard) }
        now = { Date() }
        maximumDeliveryDelay = Self.defaultMaximumDeliveryDelay
        quotaStateStore = .defaults(.standard)
        super.init()
        dropEndedQuotaAlerts()
    }

    init(
        authorizationCenter: any NotificationAuthorizationCenter,
        bundleIdentifier: @escaping () -> String?,
        eventStore: AgentMeterEventStore = .inMemory(),
        preferences: @escaping @MainActor () -> AgentMeterNotificationPreferences = { AgentMeterNotificationPreferences() },
        now: @escaping () -> Date = { Date() },
        maximumDeliveryDelay: TimeInterval = NotificationManager.defaultMaximumDeliveryDelay,
        quotaStateStore: QuotaNotificationStateStore = .memory
    ) {
        self.authorizationCenter = authorizationCenter
        self.bundleIdentifier = bundleIdentifier
        self.eventStore = eventStore
        self.preferences = preferences
        self.now = now
        self.maximumDeliveryDelay = maximumDeliveryDelay
        self.quotaStateStore = quotaStateStore
        super.init()
        dropEndedQuotaAlerts()
    }

    /// At launch: what ended while AgentMeter was not running goes, and stays
    /// gone (written back), so the key holds only running epochs.
    private func dropEndedQuotaAlerts() {
        let stored = quotaStateStore.load()
        let kept = stored.kept(at: now())
        if kept != stored { quotaStateStore.save(kept) }
    }

    private var enabled: Bool {
        UserDefaults.standard.object(forKey: "alertsEnabled") as? Bool ?? true
    }

    private var recoveryEnabled: Bool {
        UserDefaults.standard.object(forKey: "quotaRecoveryNotificationsEnabled") as? Bool ?? true
    }

    /// Clamped to a sane 1…99 so a bad default can't silence or spam alerts.
    private var threshold: Double {
        let v = UserDefaults.standard.object(forKey: "alertThresholdPercent") as? Double ?? 10
        return max(1, min(99, v))
    }

    /// UNUserNotificationCenter traps when there is no app bundle (bare `make debug`
    /// binary), so every entry point guards on a bundle identifier.
    var hasBundle: Bool { bundleIdentifier() != nil }

    /// Become the notification-center delegate without asking for permission,
    /// so taps on already-delivered notifications route back even before (or
    /// without) an authorization request.
    ///
    /// Also registers the event categories and reads the event record on its
    /// own queue, so the first event does not wait for the file.
    func activate() {
        guard hasBundle else { return }
        authorizationCenter.delegate = self
        authorizationCenter.setCategories(Self.eventCategories)
        let store = eventStore
        Task.detached(priority: .utility) { await store.prepare() }
    }

    /// What System Settings says now; nil without an app bundle, where the
    /// center would trap.
    func notificationSettings() async -> AgentMeterNotificationSettings? {
        guard hasBundle else { return nil }
        return await authorizationCenter.currentSettings()
    }

    func requestAuthorizationIfNeeded() async {
        guard !requested, hasBundle else { return }
        requested = true
        authorizationCenter.delegate = self   // so banners show even while the app is active
        let center = authorizationCenter
        let request = Task { @MainActor in
            self.authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
        authorizationRequest = request
        await request.value
    }

    /// The windows each provider last handed to `evaluate`. The permission
    /// prompt below can stay open for hours, and the reading captured before
    /// it may have reset or recovered by the time it resolves; the deferred
    /// pass evaluates these instead, so it never notifies on a stale window
    /// or stores its old `resetsAt` (which would post a false recovery next).
    private var latestWindows: [Provider: [QuotaWindow]] = [:]

    /// Evaluate one provider's windows and notify on downward threshold crossings.
    func evaluate(provider: Provider, windows: [QuotaWindow]) {
        latestWindows[provider] = windows
        // Ask for permission at the moment the first alert would actually fire,
        // instead of ambushing the user at launch. Denial sets `requested`, so
        // this runs at most once.
        if !requested, hasBundle, wouldNotify(provider: provider, windows: windows) {
            Task { @MainActor in
                await requestAuthorizationIfNeeded()
                self.evaluate(provider: provider, windows: self.latestWindows[provider] ?? windows)
            }
            return
        }
        let before = quotaStateStore.load()
        var state = before
        let events = QuotaNotificationPolicy.evaluate(
            provider: provider,
            windows: windows,
            now: now(),
            threshold: threshold,
            alertsEnabled: enabled,
            recoveryEnabled: recoveryEnabled,
            canDeliver: authorized && hasBundle,
            state: &state
        )
        for event in events {
            switch event {
            case let .critical(provider, window):
                postCritical(provider: provider, window: window)
            case let .recovered(provider, window):
                postRecovered(provider: provider, window: window)
            }
        }
        // In the same main-actor turn as the posts, so only a crash can come
        // between; posted first, it costs at worst one alert again, never one.
        if state != before { quotaStateStore.save(state) }
    }

    /// Dry-runs the policy on a copy of the dedup state: would this evaluation
    /// deliver anything if permission were already granted?
    private func wouldNotify(provider: Provider, windows: [QuotaWindow]) -> Bool {
        var stateCopy = quotaStateStore.load()
        return !QuotaNotificationPolicy.evaluate(
            provider: provider,
            windows: windows,
            now: now(),
            threshold: threshold,
            alertsEnabled: enabled,
            recoveryEnabled: recoveryEnabled,
            canDeliver: true,
            state: &stateCopy
        ).isEmpty
    }

    @discardableResult
    private func postCritical(provider: Provider, window: QuotaWindow) -> Bool {
        guard authorized, hasBundle else { return false }
        let content = UNMutableNotificationContent()
        content.title = "\(provider.displayName) quota low"
        content.body = Self.criticalBody(for: window)
        content.sound = .default
        content.userInfo = ["provider": provider.rawValue]
        let request = UNNotificationRequest(
            identifier: "agentmeter.\(provider.rawValue).\(window.id).\(Int(Date().timeIntervalSince1970))",
            content: content, trigger: nil)
        authorizationCenter.post(request)
        return true
    }

    @discardableResult
    private func postRecovered(provider: Provider, window: QuotaWindow) -> Bool {
        guard authorized, hasBundle else { return false }
        let content = UNMutableNotificationContent()
        content.title = "\(provider.displayName) quota recovered"
        content.body = Self.recoveredBody(for: window)
        content.sound = .default
        content.userInfo = ["provider": provider.rawValue]
        let request = UNNotificationRequest(
            identifier: "agentmeter.\(provider.rawValue).\(window.id).recovered.\(Int(Date().timeIntervalSince1970))",
            content: content, trigger: nil)
        authorizationCenter.post(request)
        return true
    }

    nonisolated static func criticalBody(for window: QuotaWindow) -> String {
        let pct = Int(window.remainingPercent.rounded())
        guard let reset = window.resetsAt else {
            return "\(window.label): \(pct)% left"
        }
        let verb = window.isOneTimeCredit == true ? "expires" : "resets"
        return "\(window.label): \(pct)% left · \(verb) \(QuotaRow.relative(reset))"
    }

    nonisolated static func recoveredBody(for window: QuotaWindow) -> String {
        let pct = Int(window.remainingPercent.rounded())
        guard let reset = window.resetsAt else {
            return "\(window.label): \(pct)% left"
        }
        let prefix = window.isOneTimeCredit == true ? "expires" : "next reset"
        return "\(window.label): \(pct)% left · \(prefix) \(QuotaRow.relative(reset))"
    }

    // Show the banner + play sound even when AgentMeter is the active app
    // (popover or Settings open), instead of silently swallowing it.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // Tapping a quota notification opens that provider's popover instead of
    // doing nothing.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let eventID = response.notification.request.content.userInfo[Self.eventIDUserInfoKey] as? String {
            let action = response.actionIdentifier
            completionHandler()
            Task { @MainActor in await self.handleEventResponse(eventID: eventID, actionIdentifier: action) }
            return
        }
        let raw = response.actionIdentifier == UNNotificationDefaultActionIdentifier
            ? response.notification.request.content.userInfo["provider"] as? String
            : nil
        completionHandler()
        guard let raw else { return }
        Task { @MainActor in
            if let provider = Provider(rawValue: raw) {
                self.onOpenProvider?(provider)
            }
        }
    }
}

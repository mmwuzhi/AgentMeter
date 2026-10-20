import Foundation
import UserNotifications

/// What the producer of an event wants done with it.
enum AgentMeterDeliveryIntent: Sendable, Equatable {
    /// Post it, if the user's settings and the system allow.
    case notify
    /// Record it without posting; `reason` lands in its delivery (a
    /// producer's own rule: `beforeLaunch`, `belowMinimumDuration`, `muted`).
    case recordOnly(reason: String)
}

// The shared event path. A producer builds an `AgentMeterEvent` with an id
// that names the occurrence and calls `submit`:
//
//  1. record: the store refuses an id it already has (this run or an earlier
//     one) and writes the new event, pending, before anything is posted;
//  2. decide: the producer's intent, the user's per-kind setting, an app
//     bundle, freshness, then the permission as the system states it now
//     (asking once, lazily, with the same flag and prompt as the quota path);
//  3. post through the center and record what came of it.
//
// A process that dies between 1 and 3 leaves the event pending, and pending
// events are never retried: at most one banner per event. Nothing here runs
// on the refresh or the scan path; producers call `submit` from their own
// task and need not wait for it.
extension NotificationManager {
    static let taskCategoryIdentifier = "AGENTMETER_TASK"
    static let ruleCategoryIdentifier = "AGENTMETER_RULE"
    nonisolated static let eventIDUserInfoKey = "agentmeterEventID"
    static let eventKindUserInfoKey = "agentmeterEventKind"

    /// Registered at `activate()`. No action buttons yet: a button needs a
    /// handler behind it (Open Session, Mute arrive with the task
    /// notifications, Snooze with the rule alerts). `didReceive` already
    /// routes any action identifier to `onEventResponse`.
    static var eventCategories: Set<UNNotificationCategory> {
        [
            UNNotificationCategory(identifier: taskCategoryIdentifier, actions: [], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: ruleCategoryIdentifier, actions: [], intentIdentifiers: [], options: []),
        ]
    }

    /// Records `event` and, when allowed, posts it. Returns the event as
    /// recorded with its delivery decided, or why nothing happened.
    @discardableResult
    func submit(_ event: AgentMeterEvent, intent: AgentMeterDeliveryIntent = .notify) async -> AgentMeterEventSubmission {
        let recorded = await eventStore.record(event)
        guard case let .recorded(stored) = recorded else { return recorded }
        onEventsChanged?()
        let delivery = await decideAndPost(stored, intent: intent)
        let settled = await eventStore.setDelivery(delivery, forEventID: stored.id)
        onEventsChanged?()
        return .recorded(settled ?? stored)
    }

    /// Marks events read and tells `onEventsChanged`. Returns how many were unread.
    @discardableResult
    func markEventsRead(ids: [String]) async -> Int {
        let changed = await eventStore.markRead(ids: ids, at: now())
        if !changed.isEmpty { onEventsChanged?() }
        return changed.count
    }

    @discardableResult
    func markEventsRead(matching filter: AgentMeterEventFilter) async -> Int {
        let changed = await eventStore.markRead(matching: filter, at: now())
        if !changed.isEmpty { onEventsChanged?() }
        return changed.count
    }

    /// A tap on an event's notification, or one of its actions: marks it read
    /// and hands it on. Apart from the delegate callback, whose response
    /// object a test cannot build.
    func handleEventResponse(eventID: String, actionIdentifier: String) async {
        // Only with `.customDismissAction`, which no category sets: closing a
        // banner is not reading it.
        guard actionIdentifier != UNNotificationDismissActionIdentifier else { return }
        await markEventsRead(ids: [eventID])
        guard let event = await eventStore.event(id: eventID) else { return }
        onEventResponse?(event, actionIdentifier)
    }

    private func decideAndPost(_ event: AgentMeterEvent, intent: AgentMeterDeliveryIntent) async -> AgentMeterEventDelivery {
        typealias Suppression = AgentMeterEventDelivery.Suppression
        if case let .recordOnly(reason) = intent { return .suppressed(reason, at: now()) }
        guard preferences().notifies(event.kind) else { return .suppressed(Suppression.disabledByUser, at: now()) }
        guard hasBundle else { return .suppressed(Suppression.noAppBundle, at: now()) }
        guard isFresh(event) else { return .suppressed(Suppression.stale, at: now()) }

        var status = await authorizationCenter.authorizationStatus()
        if status == .notDetermined {
            await awaitPermissionPrompt()
            status = await authorizationCenter.authorizationStatus()
            // The prompt can stay open for hours.
            guard isFresh(event) else { return .suppressed(Suppression.stale, at: now()) }
        }
        switch status {
        case .authorized, .provisional:
            break
        case .denied:
            return .suppressed(Suppression.permissionDenied, at: now())
        default:
            return .suppressed(Suppression.notAuthorized, at: now())
        }

        do {
            try await authorizationCenter.deliver(Self.notificationRequest(for: event))
            return .posted(at: now())
        } catch {
            return .failed(Self.failureReason(error), at: now())
        }
    }

    /// Asks for permission the first time an event needs it, or waits for the
    /// prompt the quota path already opened.
    private func awaitPermissionPrompt() async {
        if !requested {
            await requestAuthorizationIfNeeded()
        } else if let authorizationRequest {
            await authorizationRequest.value
        }
    }

    private func isFresh(_ event: AgentMeterEvent) -> Bool {
        now().timeIntervalSince(event.occurredAt) <= maximumDeliveryDelay
    }

    static func notificationRequest(for event: AgentMeterEvent) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = event.content.title
        content.body = event.content.body
        content.sound = .default
        switch event.kind.family {
        case .task: content.categoryIdentifier = taskCategoryIdentifier
        case .rule: content.categoryIdentifier = ruleCategoryIdentifier
        case .other: break
        }
        if let thread = event.content.threadIdentifier { content.threadIdentifier = thread }
        // The id is enough: a tap looks the event up in the store.
        content.userInfo = [eventIDUserInfoKey: event.id, eventKindUserInfoKey: event.kind.rawValue]
        let identifier = event.content.notificationIdentifier ?? "agentmeter.event.\(event.id)"
        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    }

    /// The error's domain and code: never its message, which can name things.
    static func failureReason(_ error: any Error) -> String {
        let error = error as NSError
        return "\(error.domain):\(error.code)"
    }
}

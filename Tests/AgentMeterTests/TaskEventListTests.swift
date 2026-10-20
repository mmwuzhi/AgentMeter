@testable import AgentMeter
import Foundation
import XCTest

/// A task event as the producer records it, with the delivery and read
/// state a test needs.
func listEvent(
    _ id: String, _ kind: AgentMeterEventKind = .taskCompleted, session: String = "ffafe0d9-aaaa", task: String = "p1",
    at offset: TimeInterval = 0, delivery: AgentMeterEventDelivery = .posted(at: Date(timeIntervalSince1970: 1_792_480_000)),
    readAt: Date? = nil, title: String = "agentmeter finished", body: String = "Session ffafe0d9\n12m run"
) -> AgentMeterEvent {
    let at = Date(timeIntervalSince1970: 1_792_480_000 + offset)
    return AgentMeterEvent(
        id: id, kind: kind, occurredAt: at, discoveredAt: at.addingTimeInterval(0.5),
        subject: AgentMeterEventSubject(provider: "claude", sessionID: session, taskKey: task,
                                        projectPath: "/Users/u/work/agentmeter"),
        content: AgentMeterEventContent(title: title, body: body,
                                        notificationIdentifier: "agentmeter.task.\(session).\(task)"),
        producerVersion: "task-outcome/1", delivery: delivery, readAt: readAt)
}

final class TaskEventListTests: XCTestCase {
    private let decided = Date(timeIntervalSince1970: 1_792_480_000)
    typealias Reason = TaskOutcomeAnnouncement.Reason
    typealias Suppression = AgentMeterEventDelivery.Suppression

    // MARK: - Which events are for the user

    func testWhatTheMenuListsAndWhatIsHistoryOnly() {
        func attention(_ kind: AgentMeterEventKind, _ delivery: AgentMeterEventDelivery) -> Bool {
            TaskEventAttention.needsAttention(listEvent("x", kind, delivery: delivery))
        }
        // Posted, refused, or possibly posted: the user is meant to see it.
        for kind in [AgentMeterEventKind.taskCompleted, .taskFailed, .taskWaiting] {
            XCTAssertTrue(attention(kind, .posted(at: decided)), kind.rawValue)
            XCTAssertTrue(attention(kind, .failed("UNErrorDomain:1", at: decided)), kind.rawValue)
            XCTAssertTrue(attention(kind, .interrupted(at: decided)), kind.rawValue)
        }
        // The switches are about the banner; the menu still lists the task.
        for reason in [Suppression.disabledByUser, Suppression.permissionDenied, Suppression.notAuthorized,
                       Suppression.stale, Suppression.noAppBundle] {
            XCTAssertTrue(attention(.taskCompleted, .suppressed(reason, at: decided)), reason)
        }
        // An unconfirmed task is never posted, and is listed.
        XCTAssertTrue(attention(.taskUnknown, .suppressed(Reason.backgroundShellRunning, at: decided)))
        // The producer's history-only reasons are not.
        for reason in [Reason.beforeLaunch, Reason.reportOrigin, Reason.cronsArmed, Reason.belowMinimumDuration,
                       Reason.notAnnounced] {
            XCTAssertFalse(attention(.taskCompleted, .suppressed(reason, at: decided)), reason)
        }
        XCTAssertFalse(attention(.taskInterrupted, .suppressed(Reason.notAnnounced, at: decided)))
        XCTAssertFalse(attention(.taskInterrupted, .posted(at: decided)), "interruptions are never listed")
        XCTAssertFalse(attention(AgentMeterEventKind("task_paused"), .posted(at: decided)), "a newer build's kind")
        XCTAssertFalse(attention(AgentMeterEventKind("rule_fired"), .posted(at: decided)))
        XCTAssertFalse(attention(.taskCompleted, .pending), "settles within the submit; counting it would flicker")
    }

    func testHistoryOnlyIsReadOffTheSuppressionReasonAlone() {
        let reasons = TaskOutcomeAnnouncement.historyOnlyReasons
        func historyOnly(_ event: AgentMeterEvent) -> Bool { AgentMeterEventLogState.isHistoryOnly(event, reasons: reasons) }
        XCTAssertTrue(historyOnly(listEvent("a", delivery: .suppressed(Reason.belowMinimumDuration, at: decided))))
        XCTAssertTrue(historyOnly(listEvent("b", .taskInterrupted, delivery: .suppressed(Reason.notAnnounced, at: decided))))
        XCTAssertFalse(historyOnly(listEvent("c", delivery: .suppressed(Suppression.disabledByUser, at: decided))),
                       "a banner switched off: still for the user")
        XCTAssertFalse(historyOnly(listEvent("d", .taskUnknown, delivery: .suppressed(Reason.backgroundShellRunning, at: decided))))
        XCTAssertFalse(historyOnly(listEvent("e", delivery: .pending)))
        XCTAssertFalse(historyOnly(listEvent("f")))
        XCTAssertEqual(AgentMeterEventStore.Limits.standard.historyOnlyReasons, reasons, "the log and the menu agree")
    }

    func testTheHistoryOnlyReasonsAreTheProducersRecordOnlyReasonsButUnconfirmed() {
        XCTAssertEqual(TaskOutcomeAnnouncement.historyOnlyReasons,
                       [Reason.beforeLaunch, Reason.reportOrigin, Reason.cronsArmed, Reason.belowMinimumDuration,
                        Reason.notAnnounced])
    }

    // MARK: - One item per task

    func testAWaitAndTheEndOfOneTaskAreOneItemShowingTheEnd() throws {
        let waiting = listEvent("w", .taskWaiting, at: 0, body: "Session ffafe0d9\nWaiting for permission · 1m")
        let completed = listEvent("c", .taskCompleted, at: 600)
        let other = listEvent("o", .taskFailed, session: "bbbb", task: "p9", at: 300,
                              body: "Session bbbb\nRate limit · after 2m")
        let items = TaskEventItem.items(from: [waiting, other, completed, completed])
        XCTAssertEqual(items.map(\.id), ["ffafe0d9-aaaa|p1", "bbbb|p9"], "newest first, duplicates once")
        let task = try XCTUnwrap(items.first)
        XCTAssertEqual(task.status, .completed)
        XCTAssertEqual(task.eventIDs, ["c", "w"])
        XCTAssertEqual(task.unreadEventIDs, ["c", "w"])
        XCTAssertEqual(task.detail, "12m run")
        XCTAssertEqual(task.projectName, "agentmeter")
        XCTAssertEqual(task.shortSessionID, "Session ffafe0d9")
        XCTAssertEqual(items[1].detail, "Rate limit · after 2m")
    }

    func testATaskIsUnreadWhileAnyOfItsEventsIs() throws {
        let readWait = listEvent("w", .taskWaiting, at: 0, readAt: decided)
        let unreadEnd = listEvent("c", .taskCompleted, at: 600)
        let item = try XCTUnwrap(TaskEventItem.items(from: [readWait, unreadEnd]).first)
        XCTAssertTrue(item.isUnread)
        XCTAssertEqual(item.unreadEventIDs, ["c"])
        let handled = try XCTUnwrap(TaskEventItem.items(from: [readWait, listEvent("c", at: 600, readAt: decided)]).first)
        XCTAssertFalse(handled.isUnread)
    }

    func testAFollowUpAfterAnUnconfirmedEndShowsItsRealEnd() throws {
        let unconfirmed = listEvent("u", .taskUnknown, at: 0, delivery: .suppressed(Reason.backgroundShellRunning, at: decided))
        let later = listEvent("c", .taskCompleted, at: 900)
        XCTAssertEqual(try XCTUnwrap(TaskEventItem.items(from: [unconfirmed, later]).first).status, .completed)
        XCTAssertEqual(try XCTUnwrap(TaskEventItem.items(from: [unconfirmed]).first).status, .unconfirmed,
                       "on its own it stays unconfirmed")
    }

    func testHistoryOnlyEventsNeverBecomeItems() {
        let short = listEvent("s", delivery: .suppressed(Reason.belowMinimumDuration, at: decided))
        let interrupted = listEvent("i", .taskInterrupted, task: "p2", delivery: .suppressed(Reason.notAnnounced, at: decided))
        XCTAssertTrue(TaskEventItem.items(from: [short, interrupted]).isEmpty)
    }

    // MARK: - Unconfirmed wording

    func testAnUnconfirmedTaskNeverSaysItsShellStillRuns() throws {
        // As 1b recorded it, before the wording changed.
        let old = listEvent("u", .taskUnknown, delivery: .suppressed(Reason.backgroundShellRunning, at: decided),
                            title: "agentmeter stopped, background work running",
                            body: "Session ffafe0d9\n2 background shells still running · after 2m")
        let item = try XCTUnwrap(TaskEventItem.items(from: [old]).first)
        XCTAssertEqual(item.status, .unconfirmed)
        XCTAssertNil(item.detail, "the stored line is not shown")
        let line = TaskEventRow.statusLine(for: item)
        let tooltip = TaskEventRow.tooltip(for: item, sessionTitle: nil)
        XCTAssertEqual(line, "Task status unconfirmed")
        // Past tense and dated ("were still running at the last check"),
        // never a claim about now: the shell may have ended since.
        for text in [line, tooltip] {
            for claim in ["shell still running", "shells still running", "tasks still running", "background work running"] {
                XCTAssertFalse(text.contains(claim), text)
            }
        }
        XCTAssertTrue(TaskEventStatus.unconfirmedExplanation.contains("were still running at the last check"))
        XCTAssertFalse(line.lowercased().contains("finish"), line)
        XCTAssertTrue(tooltip.contains("will not be marked finished on its own"))
        XCTAssertTrue(tooltip.contains(TaskEventStatus.unconfirmedExplanation))
        XCTAssertTrue(tooltip.contains("never sent as a notification"))
    }

    func testSeenNeverReadsAsResolved() throws {
        // "Seen" is the read state: the user looked. A wait may still be
        // waiting, an unconfirmed task stays unconfirmed.
        let waiting = try XCTUnwrap(TaskEventItem.items(from: [listEvent("w", .taskWaiting, readAt: decided,
                                                                         body: "Session ffafe0d9\nWaiting for permission · 1m")]).first)
        let unconfirmed = try XCTUnwrap(TaskEventItem.items(from: [listEvent(
            "u", .taskUnknown, delivery: .suppressed(Reason.backgroundShellRunning, at: decided), readAt: decided)]).first)
        XCTAssertEqual(TaskEventRow.markSeenHelp(for: waiting), "Mark seen. It doesn't mean the wait is over.")
        XCTAssertEqual(TaskEventRow.markSeenHelp(for: unconfirmed), "Mark seen. The task stays unconfirmed.")
        XCTAssertEqual(TaskEventRow.statusLine(for: unconfirmed), "Task status unconfirmed", "seen keeps the status")
        XCTAssertEqual(TaskEventRow.statusLine(for: waiting), "Waiting for permission · 1m")
        XCTAssertTrue(TaskEventRow.tooltip(for: waiting, sessionTitle: nil).contains("the session may have moved on since"))
        XCTAssertTrue(TaskEventRow.tooltip(for: unconfirmed, sessionTitle: nil).contains("Marking it seen keeps it unconfirmed"))
        // No "handled", "resolved" or "done" anywhere the user reads.
        let sources = ["Sources/AgentMeter/Views/Menu/TaskEventsSection.swift",
                       "Sources/AgentMeter/Views/TaskNotificationSettings.swift"]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for path in sources {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            for literal in text.components(separatedBy: "\"").enumerated().filter({ $0.offset % 2 == 1 }).map(\.element) {
                for word in ["handled", "Handled", "resolved", "Resolved"] {
                    XCTAssertFalse(literal.contains(word), "\(path): \"\(literal)\"")
                }
            }
        }
    }

    func testStatusesForEveryShownKind() {
        XCTAssertEqual(TaskEventStatus.kinds, [.taskCompleted, .taskFailed, .taskWaiting, .taskUnknown])
        XCTAssertNil(TaskEventStatus(kind: .taskInterrupted))
        XCTAssertEqual(TaskEventStatus.allCases.map(\.label),
                       ["Finished", "Failed", "Needs input", "Task status unconfirmed"])
        for status in TaskEventStatus.allCases { XCTAssertEqual(TaskEventStatus(kind: status.kind), status) }
    }

    func testTheTooltipSaysWhatBecameOfTheBanner() throws {
        func text(_ delivery: AgentMeterEventDelivery) throws -> String {
            try XCTUnwrap(TaskEventItem.items(from: [listEvent("x", delivery: delivery)]).first).deliveryText
        }
        XCTAssertEqual(try text(.posted(at: decided)), "Notification shown")
        XCTAssertEqual(try text(.suppressed(Suppression.disabledByUser, at: decided)),
                       "No macOS notification (turned off in Settings); still listed here")
        XCTAssertEqual(try text(.suppressed(Suppression.permissionDenied, at: decided)),
                       "No notification: not allowed in System Settings")
        XCTAssertTrue(try text(.interrupted(at: decided)).contains("may not have been shown"))
    }

    // MARK: - Snapshot and states

    func testTheSnapshotSplitsUnreadFromHandledAndCountsTasks() {
        var events: [AgentMeterEvent] = []
        for index in 0..<14 {
            events.append(listEvent("h\(index)", task: "h\(index)", at: Double(index), readAt: decided))
        }
        events.append(listEvent("u1w", .taskWaiting, task: "u1", at: 100))
        events.append(listEvent("u1c", task: "u1", at: 200))
        events.append(listEvent("u2", .taskFailed, task: "u2", at: 150))
        let snapshot = TaskEventsSnapshot.make(unreadEvents: events.filter(\.isUnread), recentEvents: events, overflow: nil)
        XCTAssertEqual(snapshot.unreadCount, 2, "tasks, not events")
        XCTAssertEqual(snapshot.unread.map(\.id), ["ffafe0d9-aaaa|u1", "ffafe0d9-aaaa|u2"])
        XCTAssertEqual(snapshot.handled.count, TaskEventsSnapshot.handledLimit)
        XCTAssertEqual(snapshot.handled.first?.id, "ffafe0d9-aaaa|h13")
        XCTAssertEqual(TaskEventsState.loaded(snapshot).unreadCount, 2)
        XCTAssertEqual(TaskEventsState.loading.unreadCount, 0)
        XCTAssertNil(TaskEventsState.loading.snapshot)
    }

    @MainActor
    func testTheHeaderTellsLoadingNothingAllHandledAndUnreadApart() {
        func text(_ state: TaskEventsState, hooks: Bool = true) -> String {
            TaskEventsSection(state: state, hooksEnabled: hooks).stateText
        }
        XCTAssertEqual(text(.loading), "Loading…")
        XCTAssertEqual(text(.loaded(.empty)), "None yet")
        XCTAssertEqual(text(.loaded(.empty), hooks: false), "Off")
        let handled = TaskEventsSnapshot.make(unreadEvents: [], recentEvents: [listEvent("a", readAt: decided)], overflow: nil)
        XCTAssertEqual(text(.loaded(handled)), "All seen")
        let unread = TaskEventsSnapshot.make(unreadEvents: [listEvent("a")], recentEvents: [], overflow: nil)
        XCTAssertEqual(text(.loaded(unread)), "1 unread")
    }

    // MARK: - Dropped unread events

    func testOverflowShowsUntilThatExactTotalIsAcknowledged() throws {
        let first = AgentMeterUnreadOverflow(count: 3, throughDiscoveredAt: decided, lastDroppedAt: decided.addingTimeInterval(60))
        let none = TaskEventOverflowAcknowledgement()
        XCTAssertNil(none.notice(for: nil))
        XCTAssertEqual(try XCTUnwrap(none.notice(for: first)).dropped, 3)

        let seen = TaskEventOverflowAcknowledgement(first)
        XCTAssertNil(seen.notice(for: first))
        let more = AgentMeterUnreadOverflow(count: 5, throughDiscoveredAt: decided.addingTimeInterval(30),
                                            lastDroppedAt: decided.addingTimeInterval(120))
        let notice = try XCTUnwrap(seen.notice(for: more))
        XCTAssertEqual(notice.dropped, 2, "only what was dropped since")
        XCTAssertEqual(notice.total, 5)
        XCTAssertEqual(notice.throughDiscoveredAt, decided.addingTimeInterval(30))
        // The log started over (deleted, replaced): its total is all new.
        let restarted = AgentMeterUnreadOverflow(count: 2, throughDiscoveredAt: decided, lastDroppedAt: decided.addingTimeInterval(500))
        XCTAssertEqual(try XCTUnwrap(seen.notice(for: restarted)).dropped, 2)
    }

    func testTheAcknowledgementPersistsInDefaults() throws {
        let suite = "agentmeter.tests.overflow.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(TaskEventOverflowAcknowledgement(defaults: defaults), TaskEventOverflowAcknowledgement())
        let overflow = AgentMeterUnreadOverflow(count: 4, throughDiscoveredAt: decided, lastDroppedAt: decided.addingTimeInterval(0.5))
        TaskEventOverflowAcknowledgement(overflow).save(to: defaults)
        let read = TaskEventOverflowAcknowledgement(defaults: defaults)
        XCTAssertNil(read.notice(for: overflow))
        XCTAssertEqual(TaskEventOverflowAcknowledgement.countKey, "taskEventsOverflowAcknowledgedCount")
        XCTAssertEqual(TaskEventOverflowAcknowledgement.droppedAtKey, "taskEventsOverflowAcknowledgedDroppedAt")
    }
}

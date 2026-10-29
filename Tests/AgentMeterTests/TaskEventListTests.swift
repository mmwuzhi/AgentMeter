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

    func testReadNeverReadsAsResolved() throws {
        // "Read" is the read state: the user looked. A wait may still be
        // waiting, an unconfirmed task stays unconfirmed.
        let waiting = try XCTUnwrap(TaskEventItem.items(from: [listEvent("w", .taskWaiting, readAt: decided,
                                                                         body: "Session ffafe0d9\nWaiting for permission · 1m")]).first)
        let unconfirmed = try XCTUnwrap(TaskEventItem.items(from: [listEvent(
            "u", .taskUnknown, delivery: .suppressed(Reason.backgroundShellRunning, at: decided), readAt: decided)]).first)
        XCTAssertEqual(TaskEventRow.markReadHelp(for: waiting), "Mark as read. It doesn't mean the wait is over.")
        XCTAssertEqual(TaskEventRow.markReadHelp(for: unconfirmed), "Mark as read. The task stays unconfirmed.")
        XCTAssertEqual(TaskEventRow.statusLine(for: unconfirmed), "Task status unconfirmed", "read keeps the status")
        XCTAssertEqual(TaskEventRow.statusLine(for: waiting), "Waiting for permission · 1m")
        XCTAssertTrue(TaskEventRow.tooltip(for: waiting, sessionTitle: nil).contains("the session may have moved on since"))
        XCTAssertTrue(TaskEventRow.tooltip(for: unconfirmed, sessionTitle: nil).contains("Marking it read keeps it unconfirmed"))
    }

    /// One read vocabulary: read and unread. No "handled" or "resolved"
    /// (read never means the task is dealt with), and none of the old
    /// "seen" or the notice's "Dismiss", anywhere the user reads.
    func testTheViewsSayReadAndUnreadOnly() throws {
        let sources = ["Sources/AgentMeter/Views/Menu/TaskEventsSection.swift",
                       "Sources/AgentMeter/Views/TaskNotificationSettings.swift"]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for path in sources {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            for literal in text.components(separatedBy: "\"").enumerated().filter({ $0.offset % 2 == 1 }).map(\.element) {
                for word in ["handled", "Handled", "resolved", "Resolved", "seen", "Seen", "dismiss", "Dismiss"] {
                    XCTAssertFalse(literal.contains(word), "\(path): \"\(literal)\"")
                }
            }
        }
    }

    // MARK: - Rows

    func testARowSaysWhatHappenedWhenAndWhere() throws {
        let item = try XCTUnwrap(TaskEventItem.items(from: [listEvent("c")]).first)
        XCTAssertEqual(TaskEventRow.statusLine(for: item), "Finished · 12m run", "the run time when the event has it")
        XCTAssertEqual(TaskEventRow.identityLine(for: item, sessionTitle: nil), "agentmeter · Session ffafe0d9")
        XCTAssertEqual(TaskEventRow.identityLine(for: item, sessionTitle: "Fix the quota pacing tooltip"),
                       "agentmeter · Fix the quota pacing tooltip")
        let failed = try XCTUnwrap(TaskEventItem.items(from: [listEvent("f", .taskFailed, body: "Session ffafe0d9\nRate limit · after 2m")]).first)
        XCTAssertEqual(TaskEventRow.statusLine(for: failed), "Failed · Rate limit · after 2m")
    }

    func testARowNamesItsSessionByTheLiveTitleThenTheRecordedOne() throws {
        func titled(_ id: String, _ title: String?, kind: String? = nil, at offset: TimeInterval = 0) -> AgentMeterEvent {
            var event = listEvent(id, at: offset)
            event.subject.sessionTitle = title
            event.subject.sessionKind = kind
            return event
        }
        // The wait recorded a title, the end did not (the row was gone).
        let wait = titled("w", "Fix the\nquota tooltip", at: 0)
        let end = titled("c", nil, at: 600)
        let item = try XCTUnwrap(TaskEventItem.items(from: [wait, end]).first)
        XCTAssertEqual(item.storedSessionTitle, "Fix the quota tooltip", "sanitized, from any of the task's events")
        XCTAssertEqual(TaskEventsSection.sessionTitle(for: item, liveTitles: [:]), "Fix the quota tooltip",
                       "after the session ended")
        XCTAssertEqual(TaskEventsSection.sessionTitle(for: item, liveTitles: ["ffafe0d9-aaaa": "Renamed since"]),
                       "Renamed since", "the live row first, as the session list shows it now")
        XCTAssertEqual(TaskEventsSection.sessionTitle(for: item, liveTitles: ["other-session": "Someone else's"]),
                       "Fix the quota tooltip", "another session's row never names it")

        // Before format 2: no title, so the short id.
        let old = try XCTUnwrap(TaskEventItem.items(from: [listEvent("o")]).first)
        XCTAssertNil(old.storedSessionTitle)
        XCTAssertEqual(TaskEventRow.identityLine(for: old, sessionTitle: TaskEventsSection.sessionTitle(for: old, liveTitles: [:])),
                       "agentmeter · Session ffafe0d9")
        // A script's run says so.
        let headless = try XCTUnwrap(TaskEventItem.items(from: [titled("h", nil, kind: "headless")]).first)
        XCTAssertEqual(TaskEventRow.identityLine(for: headless, sessionTitle: nil), "agentmeter · Session ffafe0d9 · Headless run")
        XCTAssertEqual(headless.markedRead.isHeadless, true)
        XCTAssertEqual(item.markedRead.storedSessionTitle, item.storedSessionTitle)
    }

    func testTheTooltipSaysWhatAClickDoesForEachKindOfHost() throws {
        let terminal = TaskSessionProcess(pid: 77, tty: "ttys002", host: itermHost)
        let editor = TaskSessionProcess(pid: 2114, host: TaskSessionHost(pid: 6986, bundleID: "com.microsoft.VSCode", name: "Code"))
        XCTAssertEqual(TaskEventRow.clickHelp(route: .terminalTab(terminal), isUnread: false),
                       "Click switches to its iTerm2 tab.")
        XCTAssertEqual(TaskEventRow.clickHelp(route: .appOnly(editor), isUnread: false),
                       "Click brings Code forward — AgentMeter can't pick the session's window there.")
        XCTAssertEqual(TaskEventRow.clickHelp(route: .ended, isUnread: false), "Click opens nothing: the session has ended.")
        XCTAssertTrue(TaskEventRow.clickHelp(route: .unhosted, isUnread: false).hasPrefix("Click opens nothing"))
        XCTAssertTrue(TaskEventRow.clickHelp(route: .ambiguous(2), isUnread: false).hasPrefix("Click opens nothing"))
        XCTAssertEqual(TaskEventRow.clickHelp(route: nil, isUnread: false),
                       "Click switches to the session's terminal tab, or brings its app forward.",
                       "before the pointer has looked it up")
        // Every click reads: the unread row says so, whatever it opens.
        for route in [TaskSessionRoute.terminalTab(terminal), .appOnly(editor), .ended, .unhosted, .ambiguous(2)] {
            XCTAssertTrue(TaskEventRow.clickHelp(route: route, isUnread: true).hasSuffix("It also marks the task read."))
        }
        let item = try XCTUnwrap(TaskEventItem.items(from: [listEvent("c")]).first)
        let tooltip = TaskEventRow.tooltip(for: item, sessionTitle: nil, route: .appOnly(editor))
        XCTAssertTrue(tooltip.hasSuffix("Click brings Code forward — AgentMeter can't pick the session's window there. It also marks the task read."))
        XCTAssertFalse(tooltip.contains("open the session"), "no promise of a jump into the session")
    }

    func testTheClickedTaskKeepsItsPlaceWhileItsLineShows() throws {
        let events = [listEvent("a", task: "a", at: 300), listEvent("b", task: "b", at: 200), listEvent("c", task: "c", at: 100)]
        let before = TaskEventsSnapshot.make(unreadEvents: events, recentEvents: [], overflow: nil)
        let clicked = before.unread[1]
        let notice = TaskEventNotice(item: clicked.markedRead, reason: .ended)
        // Before the reload the task is still unread: nothing moves.
        XCTAssertEqual(TaskEventsSection.rows(before, notice: notice).top.map(\.id), before.unread.map(\.id))

        // Read since: kept between its neighbours, out of the read list.
        let read = events.map { event -> AgentMeterEvent in
            var event = event
            if event.id == "b" { event.readAt = decided }
            return event
        }
        let after = TaskEventsSnapshot.make(unreadEvents: read.filter(\.isUnread), recentEvents: read, overflow: nil)
        XCTAssertEqual(after.handled.map(\.id), [clicked.id])
        let rows = TaskEventsSection.rows(after, notice: notice)
        XCTAssertEqual(rows.top.map(\.id), before.unread.map(\.id))
        XCTAssertFalse(rows.top[1].isUnread)
        XCTAssertTrue(rows.read.isEmpty)
        // Out of the latest read ones too: the clicked task as it was.
        let gone = TaskEventsSnapshot(unread: after.unread, handled: [], overflow: nil)
        XCTAssertEqual(TaskEventsSection.rows(gone, notice: notice).top.map(\.id), before.unread.map(\.id))
        // Without a line, the read task goes to the read list.
        XCTAssertEqual(TaskEventsSection.rows(after, notice: nil).top.map(\.id), ["ffafe0d9-aaaa|a", "ffafe0d9-aaaa|c"])
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
    func testTheHeaderTellsLoadingNothingAllReadAndUnreadApart() {
        func text(_ state: TaskEventsState, hooks: Bool = true) -> String {
            TaskEventsSection(state: state, hooksEnabled: hooks).stateText
        }
        XCTAssertEqual(text(.loading), "Loading…")
        XCTAssertEqual(text(.loaded(.empty)), "None yet")
        XCTAssertEqual(text(.loaded(.empty), hooks: false), "Off")
        let handled = TaskEventsSnapshot.make(unreadEvents: [], recentEvents: [listEvent("a", readAt: decided)], overflow: nil)
        XCTAssertEqual(text(.loaded(handled)), "All read")
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

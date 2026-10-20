import SwiftUI

/// What the task list can ask for. The feed (`TaskEventFeed`) does the work;
/// the view stays a function of its inputs, so it renders the same in a test.
struct TaskEventActions {
    var open: (TaskEventItem) -> Void = { _ in }
    var markSeen: (TaskEventItem) -> Void = { _ in }
    var markAllSeen: ([TaskEventItem]) -> Void = { _ in }
    var acknowledgeOverflow: () -> Void = {}
    var bringForward: (TaskEventNotice) -> Void = { _ in }
    var markNoticeSeen: (TaskEventNotice) -> Void = { _ in }
    var dismissNotice: () -> Void = {}
}

extension TaskEventActions {
    @MainActor
    init(feed: TaskEventFeed) {
        self.init(
            open: { item in Task { await feed.open(item) } },
            markSeen: { item in Task { await feed.markSeen(item) } },
            markAllSeen: { items in Task { await feed.markAllSeen(items) } },
            acknowledgeOverflow: { Task { await feed.acknowledgeOverflow() } },
            bringForward: { feed.bringForward($0) },
            markNoticeSeen: { notice in Task { await feed.markSeen(notice) } },
            dismissNotice: { feed.dismissNotice() })
    }
}

/// The popover's list of Claude Code task notifications: one compact header
/// that always says which of "not read yet", "nothing so far", "all seen" or
/// "N unread" holds, the unread tasks under it, and the seen ones behind a
/// disclosure. Opening the popover marks nothing read. "Seen" says the user
/// looked, never that a wait is over or an unconfirmed task finished.
struct TaskEventsSection: View {
    let state: TaskEventsState
    var notice: TaskEventNotice?
    /// Without the hooks no task outcome can be recorded at all.
    var hooksEnabled: Bool
    /// Live sessions' titles by id. The popover already shows them on the
    /// session rows; the switch that keeps titles out of notifications is
    /// about banners and the lock screen.
    var sessionTitles: [String: String] = [:]
    var now = Date()
    var actions = TaskEventActions()
    @State private var showsAllUnread = false
    @State private var showsSeen = false

    static let collapsedUnreadLimit = 5
    static let expandedUnreadLimit = 50

    private var snapshot: TaskEventsSnapshot? { state.snapshot }
    private var unread: [TaskEventItem] { snapshot?.unread ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let overflow = snapshot?.overflow {
                overflowRow(overflow)
            }
            if let notice {
                noticeRow(notice)
            }
            if !unread.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(visibleUnread) { item in
                        TaskEventRow(item: item, sessionTitle: title(for: item), now: now,
                                     highlighted: notice?.itemID == item.id,
                                     open: { actions.open(item) }, markSeen: { actions.markSeen(item) })
                    }
                }
                moreUnreadControl
            }
            if let seen = snapshot?.handled, !seen.isEmpty {
                seenList(seen)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: unread.isEmpty ? "bell" : "bell.badge")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Task notifications").font(.caption.weight(.semibold))
            Spacer(minLength: 8)
            Text(stateText)
                .font(.caption2.weight(.medium))
                .foregroundStyle(unread.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.blue))
                .help(stateHelp)
            if !unread.isEmpty {
                Button("Mark all seen") { actions.markAllSeen(unread) }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .help("Marks the \(unread.count) unread \(unread.count == 1 ? "task" : "tasks") seen. Their status stays as recorded: a wait may still be waiting, an unconfirmed task stays unconfirmed.")
            }
        }
    }

    /// Distinguishes every state, so an empty list is never mistaken for one
    /// that has not been read yet.
    var stateText: String {
        guard let snapshot else { return "Loading…" }
        if snapshot.unreadCount > 0 { return "\(snapshot.unreadCount) unread" }
        if !snapshot.handled.isEmpty { return "All seen" }
        return hooksEnabled ? "None yet" : "Off"
    }

    private var stateHelp: String {
        guard let snapshot else { return "Reading the notification history." }
        if snapshot.isEmpty, !hooksEnabled {
            return "Needs live session status: turn it on in Settings › General."
        }
        return "Finished, failed and waiting Claude Code tasks stay unread here until you reach them from here or a notification, or mark them seen."
    }

    private var visibleUnread: [TaskEventItem] {
        Array(unread.prefix(showsAllUnread ? Self.expandedUnreadLimit : Self.collapsedUnreadLimit))
    }

    @ViewBuilder
    private var moreUnreadControl: some View {
        let hidden = unread.count - visibleUnread.count
        if !showsAllUnread, hidden > 0 {
            Button("Show \(hidden) more") { showsAllUnread = true }
                .buttonStyle(.borderless)
                .font(.caption2)
        } else if hidden > 0 {
            Text("\(hidden) more not listed. Mark all seen covers them too.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func seenList(_ seen: [TaskEventItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                showsSeen.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(showsSeen ? 90 : 0))
                    Text("Seen · latest \(seen.count)")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showsSeen {
                ForEach(seen) { item in
                    TaskEventRow(item: item, sessionTitle: title(for: item), now: now,
                                 highlighted: notice?.itemID == item.id,
                                 open: { actions.open(item) }, markSeen: nil)
                }
            }
        }
    }

    private func overflowRow(_ overflow: TaskEventOverflowNotice) -> some View {
        let limit = AgentMeterEventStore.Limits.standard.maximumEvents.formatted()
        let through = overflow.throughDiscoveredAt.formatted(date: .abbreviated, time: .shortened)
        return VStack(alignment: .leading, spacing: 4) {
            Label("\(overflow.dropped) older unread \(overflow.dropped == 1 ? "notification was" : "notifications were") dropped to keep the history under \(limit) events. They were found on or before \(through).",
                  systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Button("OK") { actions.acknowledgeOverflow() }
                .buttonStyle(.borderless)
                .font(.caption2)
                .help("Hides this until more are dropped.")
        }
    }

    /// The task it is about has usually just been read, so it may no longer
    /// be in the unread list: the notice names it.
    private func noticeRow(_ notice: TaskEventNotice) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(notice.projectName + (notice.sessionLabel.map { " · \($0)" } ?? ""))
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(notice.message + (notice.eventIDs.isEmpty ? "" : " " + TaskEventNotice.staysUnread))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "info.circle")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                if let host = notice.host {
                    Button("Bring \(host.name) forward") { actions.bringForward(notice) }
                        .help("Activates the app only. It never opens a window or a session, and the task stays unread.")
                }
                if !notice.eventIDs.isEmpty {
                    Button("Mark seen") { actions.markNoticeSeen(notice) }
                        .help("Its status stays as recorded.")
                }
                Button("Dismiss") { actions.dismissNotice() }
            }
            .buttonStyle(.borderless)
            .font(.caption2)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
    }

    private func title(for item: TaskEventItem) -> String? {
        item.sessionID.flatMap { sessionTitles[$0] }
    }
}

/// One task: its status, where it ran, how long ago. Clicking it opens the
/// session (and reads it when the session comes forward); the check mark
/// marks it seen without leaving.
struct TaskEventRow: View {
    let item: TaskEventItem
    var sessionTitle: String?
    var now: Date
    var highlighted = false
    var open: () -> Void
    /// Nil on a seen row.
    var markSeen: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button(action: open) {
                content.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Self.tooltip(for: item, sessionTitle: sessionTitle))
            if let markSeen {
                Button(action: markSeen) {
                    Image(systemName: "checkmark.circle")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(Self.markSeenHelp(for: item))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(highlighted ? Color.orange.opacity(0.12) : Color.primary.opacity(hovering ? 0.07 : 0))
        )
        .padding(.horizontal, -6)
        .padding(.vertical, -3)
        .onHover { hovering = $0 }
    }

    private var content: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle()
                .fill(item.isUnread ? Color.blue : Color.clear)
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
            Image(systemName: item.status.symbolName)
                .font(.caption)
                .foregroundStyle(statusColor.opacity(item.isUnread ? 1 : 0.6))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.projectName)
                        .font(.caption.weight(item.isUnread ? .semibold : .regular))
                    if let session = sessionTitle ?? item.shortSessionID {
                        Text(session)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .lineLimit(1)
                .truncationMode(.middle)
                Text(Self.statusLine(for: item))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if item.status == .unconfirmed {
                    // In full: the sentence is the status.
                    Text(TaskEventStatus.unconfirmedExplanation)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            Text(ActiveAgent.relativeAge(from: item.occurredAt, to: now))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        switch item.status {
        case .completed: .green
        case .failed: .red
        case .waiting: .orange
        case .unconfirmed: .secondary
        }
    }

    /// A wait's detail already says what it waits for ("Waiting for
    /// permission · 1m"); the others lead with the status.
    static func statusLine(for item: TaskEventItem) -> String {
        if item.status == .waiting, let detail = item.detail { return detail }
        return [item.status.label, item.detail].compactMap { $0 }.joined(separator: " · ")
    }

    /// Seen is not resolved: a wait may still be waiting, an unconfirmed task
    /// stays unconfirmed.
    static func markSeenHelp(for item: TaskEventItem) -> String {
        switch item.status {
        case .waiting: "Mark seen. It doesn't mean the wait is over."
        case .unconfirmed: "Mark seen. The task stays unconfirmed."
        case .completed, .failed: "Mark seen."
        }
    }

    static func tooltip(for item: TaskEventItem, sessionTitle: String?) -> String {
        var lines = [item.status.label]
        switch item.status {
        case .unconfirmed:
            lines.append(TaskEventStatus.unconfirmedExplanation)
            lines.append("It will not be marked finished on its own. Marking it seen keeps it unconfirmed.")
        case .waiting:
            lines.append("As recorded when the wait began; the session may have moved on since.")
        case .completed, .failed:
            break
        }
        var identity = [item.projectName]
        if let sessionTitle { identity.append(sessionTitle) }
        if let short = item.shortSessionID { identity.append(short) }
        lines.append(identity.joined(separator: " · "))
        lines.append(item.occurredAt.formatted(date: .abbreviated, time: .shortened))
        lines.append(item.deliveryText)
        lines.append(item.isUnread ? "Click to open the session; the check mark marks it seen."
                                   : "Seen. Click to open the session.")
        return lines.joined(separator: "\n")
    }
}

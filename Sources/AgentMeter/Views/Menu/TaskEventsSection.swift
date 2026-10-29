import SwiftUI

/// What the task list can ask for. The feed (`TaskEventFeed`) does the work;
/// the view stays a function of its inputs, so it renders the same in a test.
struct TaskEventActions {
    var open: (TaskEventItem) -> Void = { _ in }
    var markRead: (TaskEventItem) -> Void = { _ in }
    var markAllRead: ([TaskEventItem]) -> Void = { _ in }
    var acknowledgeOverflow: () -> Void = {}
    /// The pointer reached a row: find where its click would go.
    var preview: (TaskEventItem) -> Void = { _ in }
}

extension TaskEventActions {
    @MainActor
    init(feed: TaskEventFeed) {
        self.init(
            open: { item in Task { await feed.open(item) } },
            markRead: { item in Task { await feed.markRead(item) } },
            markAllRead: { items in Task { await feed.markAllRead(items) } },
            acknowledgeOverflow: { Task { await feed.acknowledgeOverflow() } },
            preview: { item in Task { await feed.preview(item) } })
    }
}

/// The popover's list of Claude Code task notifications: one compact header
/// that always says which of "not read yet", "nothing so far", "all read" or
/// "N unread" holds, the unread tasks under it, and the read ones behind a
/// disclosure. Opening the popover marks nothing read. "Read" says the user
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
    /// Where a click on a session's task would go, once looked up.
    var routes: [String: TaskSessionRoute] = [:]
    var now = Date()
    var actions = TaskEventActions()
    @State private var showsAllUnread = false
    @State private var showsRead = false

    static let collapsedUnreadLimit = 5
    static let expandedUnreadLimit = 50

    private var snapshot: TaskEventsSnapshot? { state.snapshot }
    private var unread: [TaskEventItem] { snapshot?.unread ?? [] }
    private var rows: (top: [TaskEventItem], read: [TaskEventItem]) { Self.rows(snapshot, notice: notice) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let overflow = snapshot?.overflow {
                overflowRow(overflow)
            }
            if !rows.top.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(visibleUnread) { item in
                        row(item, markRead: item.isUnread ? { actions.markRead(item) } : nil)
                    }
                }
                moreUnreadControl
            }
            if !rows.read.isEmpty {
                readList(rows.read)
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
                Button("Mark all read") { actions.markAllRead(unread) }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .help("Marks the \(unread.count) unread \(unread.count == 1 ? "task" : "tasks") read. Their status stays as recorded: a wait may still be waiting, an unconfirmed task stays unconfirmed.")
            }
        }
    }

    /// Distinguishes every state, so an empty list is never mistaken for one
    /// that has not been read yet.
    var stateText: String {
        guard let snapshot else { return "Loading…" }
        if snapshot.unreadCount > 0 { return "\(snapshot.unreadCount) unread" }
        if !snapshot.handled.isEmpty { return "All read" }
        return hooksEnabled ? "None yet" : "Off"
    }

    var stateHelp: String {
        guard let snapshot else { return "Reading the notification history." }
        if snapshot.isEmpty, !hooksEnabled {
            return "Needs live session status: turn it on in Settings › General."
        }
        return "Claude Code tasks that finished, failed or need input. Each stays unread until you click it here or in its notification, or mark it read."
    }

    /// The unread tasks, with the last clicked one kept where it was while
    /// its line shows (reading it would move it, line and all, into the
    /// collapsed read list), and the read ones without it.
    nonisolated static func rows(_ snapshot: TaskEventsSnapshot?,
                     notice: TaskEventNotice?) -> (top: [TaskEventItem], read: [TaskEventItem]) {
        let unread = snapshot?.unread ?? []
        var read = snapshot?.handled ?? []
        guard let notice, !unread.contains(where: { $0.id == notice.itemID }) else { return (unread, read) }
        let kept = read.first { $0.id == notice.itemID } ?? notice.item
        read.removeAll { $0.id == notice.itemID }
        return ((unread + [kept]).sorted { TaskEventItem.newestFirst($0.latest, $1.latest) }, read)
    }

    private func row(_ item: TaskEventItem, markRead: (() -> Void)?) -> some View {
        TaskEventRow(item: item, sessionTitle: title(for: item), now: now,
                     route: item.sessionID.flatMap { routes[$0] },
                     note: notice?.itemID == item.id ? notice?.message : nil,
                     open: { actions.open(item) }, markRead: markRead, preview: { actions.preview(item) })
    }

    private var visibleUnread: [TaskEventItem] {
        Array(rows.top.prefix(showsAllUnread ? Self.expandedUnreadLimit : Self.collapsedUnreadLimit))
    }

    @ViewBuilder
    private var moreUnreadControl: some View {
        let hidden = rows.top.count - visibleUnread.count
        if !showsAllUnread, hidden > 0 {
            Button("Show \(hidden) more") { showsAllUnread = true }
                .buttonStyle(.borderless)
                .font(.caption2)
        } else if hidden > 0 {
            Text("\(hidden) more not listed. Mark all read covers them too.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func readList(_ read: [TaskEventItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                showsRead.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(showsRead ? 90 : 0))
                    Text("Read · latest \(read.count)")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showsRead {
                ForEach(read) { item in
                    row(item, markRead: nil)
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

    private func title(for item: TaskEventItem) -> String? {
        item.sessionID.flatMap { sessionTitles[$0] }
    }
}

/// One task: its status and how long ago, where it ran, and the line saying
/// what its last click could not do. Clicking it brings forward what runs the
/// session and reads it; the check mark reads it without leaving.
struct TaskEventRow: View {
    let item: TaskEventItem
    var sessionTitle: String?
    var now: Date
    /// Where a click goes, once looked up; nil before.
    var route: TaskSessionRoute?
    /// What the last click on this task could not do.
    var note: String?
    var open: () -> Void
    /// Nil on a read row.
    var markRead: (() -> Void)?
    var preview: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button(action: open) {
                content.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Self.tooltip(for: item, sessionTitle: sessionTitle, route: route))
            if let markRead {
                Button(action: markRead) {
                    Image(systemName: "checkmark.circle")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(Self.markReadHelp(for: item))
                .accessibilityLabel("Mark as read")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(hovering ? 0.07 : 0))
        )
        .padding(.horizontal, -6)
        .padding(.vertical, -3)
        .onHover { inside in
            hovering = inside
            if inside { preview() }
        }
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
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Self.statusLine(for: item))
                        .font(.caption.weight(item.isUnread ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    Text(ActiveAgent.relativeAge(from: item.occurredAt, to: now))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
                Text(Self.identityLine(for: item, sessionTitle: sessionTitle))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.status == .unconfirmed {
                    // In full: the sentence is the status.
                    Text(TaskEventStatus.unconfirmedExplanation)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note {
                    Label(note, systemImage: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
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
    /// permission · 1m"); the others lead with the status, then the run time
    /// or the error the producer recorded ("Finished · 12m run").
    nonisolated static func statusLine(for item: TaskEventItem) -> String {
        if item.status == .waiting, let detail = item.detail { return detail }
        return [item.status.label, item.detail].compactMap { $0 }.joined(separator: " · ")
    }

    /// "agentmeter · Fix the quota pacing tooltip", or the short id without a
    /// title.
    nonisolated static func identityLine(for item: TaskEventItem, sessionTitle: String?) -> String {
        [item.projectName, sessionTitle ?? item.shortSessionID].compactMap { $0 }.joined(separator: " · ")
    }

    /// Read is not resolved: a wait may still be waiting, an unconfirmed
    /// task stays unconfirmed.
    nonisolated static func markReadHelp(for item: TaskEventItem) -> String {
        switch item.status {
        case .waiting: "Mark as read. It doesn't mean the wait is over."
        case .unconfirmed: "Mark as read. The task stays unconfirmed."
        case .completed, .failed: "Mark as read."
        }
    }

    /// What a click does, as far as is known before it: `route` is what the
    /// pointer reaching the row found (`TaskEventFeed.preview`). AgentMeter
    /// selects a terminal tab, or brings the app forward and no more: it
    /// never picks an editor window or opens a session.
    nonisolated static func clickHelp(route: TaskSessionRoute?, isUnread: Bool) -> String {
        let action = switch route {
        case let .terminalTab(process)?:
            "Click switches to its \(process.host?.name ?? "terminal") tab."
        case let .appOnly(process)?:
            "Click brings \(process.host?.name ?? "its app") forward — AgentMeter can't pick the session's window there."
        case .unhosted?:
            "Click opens nothing: the session runs outside an app AgentMeter can bring forward."
        case .ended?:
            "Click opens nothing: the session has ended."
        case .ambiguous?:
            "Click opens nothing: more than one process has this session."
        case nil:
            "Click switches to the session's terminal tab, or brings its app forward."
        }
        return isUnread ? action + " It also marks the task read." : action
    }

    nonisolated static func tooltip(for item: TaskEventItem, sessionTitle: String?, route: TaskSessionRoute? = nil) -> String {
        var lines = [item.status.label]
        switch item.status {
        case .unconfirmed:
            lines.append(TaskEventStatus.unconfirmedExplanation)
            lines.append("It will not be marked finished on its own. Marking it read keeps it unconfirmed.")
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
        lines.append(clickHelp(route: route, isUnread: item.isUnread))
        return lines.joined(separator: "\n")
    }
}

import AgentStatusCore
import AppKit
import SwiftUI

/// Root content of the menubar popover.
enum MenuViewScope: Equatable {
    case provider(Provider)

    init(slot: MenuBarSlot) {
        self = .provider(slot.provider)
    }
}

struct MenuView: View {
    @Bindable var model: AppViewModel
    var scope: MenuViewScope
    var onRefresh: () -> Void
    /// Closes the popover and shows Settings (`SettingsOpener`). Not a
    /// `SettingsLink`: that neither activates the app nor brings an open
    /// Settings window forward, so a click behind other windows did nothing.
    var onSettings: () -> Void
    var onQuit: () -> Void
    @State private var sectionsHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView(.vertical) {
                sections
                    .background(GeometryReader { proxy in
                        Color.clear.preference(
                            key: SectionsHeightKey.self, value: proxy.size.height)
                    })
            }
            .scrollBounceBehavior(.basedOnSize)
            .onPreferenceChange(SectionsHeightKey.self) { sectionsHeight = $0 }
            .frame(height: sectionsHeight > 0 ? min(sectionsHeight, maxSectionsHeight) : nil)
            Divider()
            footer
        }
        .frame(width: 340)
        .environment(model)
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(visibleProviders, id: \.self) { p in
                let providerState = PopoverOrder.state(p, model)
                ProviderSection(
                    state: providerState,
                    historyPoints: LifetimeSpendTracker.dayPoints(
                        ledger: model.lifetimeSpend, report: providerState.usage,
                        table: model.priceTable),
                    priceTable: model.priceTable,
                    activeAgents: model.activeAgents.filter { $0.provider == p },
                    tint: PopoverOrder.tint(p),
                    resetCredits: resetCreditItems(for: p),
                    providerStatus: model.providerStatus[p],
                    isQuotaStale: model.staleQuotaProviders.contains(p),
                    showsKeychainPrimer: p == .claude && model.claudeKeychainPrimerNeeded,
                    runway: { provider, window in
                        model.runway(for: provider, window: window)
                    }
                )
            }
        }
        .padding(12)
    }

    private func resetCreditItems(for provider: Provider) -> [ResetCreditItem] {
        switch provider {
        case .codex: ResetCreditItem.items(codex: model.codexResetCreditState.credits)
        case .claude: ResetCreditItem.items(claude: model.claudeResetState)
        case .copilot: []
        }
    }

    /// Sizes to content, but never past the hosting screen: long session lists
    /// or an expanded heatmap scroll inside the popover instead of running off
    /// it. The controller records the popover's own screen on each open, so a
    /// smaller secondary display gets the smaller cap; `NSScreen.main` is only
    /// the pre-first-open fallback.
    private var maxSectionsHeight: CGFloat {
        Self.sectionsCap(screenVisibleHeight:
            model.popoverScreenVisibleHeight ?? NSScreen.main?.visibleFrame.height)
    }

    /// Roughly header + footer + popover chrome + a little breathing room.
    nonisolated static func sectionsCap(screenVisibleHeight: CGFloat?) -> CGFloat {
        max(200, (screenVisibleHeight ?? 800) - 140)
    }

    private var visibleProviders: [Provider] {
        switch scope {
        case .provider(let provider):
            return [provider]
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: headerIconName)
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Spacer()
            if let last = model.lastRefresh {
                Text(last, format: .dateTime.hour().minute())
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Button(action: onRefresh) {
                RefreshGlyph(spinning: model.isRefreshing)
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Text(spendSummary)
                .font(.caption).foregroundStyle(.secondary)
                .help("Accrued across refreshes since AgentMeter started tracking. Local logs only reach back about 30 days, so earlier spend is not included.")
            Spacer()
            Button("Settings", action: onSettings).buttonStyle(.borderless).font(.caption)
            Button("Quit", action: onQuit).buttonStyle(.borderless).font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var title: String {
        switch scope {
        case .provider(let provider): return provider.displayName
        }
    }

    private var headerIconName: String {
        switch scope {
        case .provider(.codex): return "terminal"
        case .provider(.claude): return "text.bubble"
        case .provider(.copilot): return "sparkles"
        }
    }

    private var spendSummary: String {
        switch scope {
        case .provider(let provider):
            return "All-time spend  \(Self.dollars(model.lifetimeSpendUSD(for: provider)))"
        }
    }

    private static func dollars(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return "$" + (f.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value))
    }
}

/// The header's refresh arrow: a spinning copy while a refresh runs, a still
/// one otherwise. The spin must never come from a SwiftUI animation. A
/// `repeatForever` animation lives on the transaction it starts in, and the
/// transaction that brings the spinner in is never just the spinner's own:
/// `showPopover()` starts a refresh right before it shows the popover, so the
/// update that inserts the arrow is the one that lays the whole popover out.
/// Attached with `.animation(_, value:)` the repeat captured the arrow's own
/// move between rows and slid it bottom-to-top forever; started with
/// `withAnimation` in `onAppear` it captured every frame in the popover and
/// the whole interface drifted. Both kept running with the popover closed,
/// because the hosting controller lives for the app's lifetime. `SpinningArrow`
/// therefore reads the clock instead, and no `repeatForever` exists in the app
/// (`MenuViewTests.testNoRepeatingAnimationInSources` keeps it that way).
private struct RefreshGlyph: View {
    let spinning: Bool

    var body: some View {
        if #available(macOS 15, *) {
            // The symbol's own rotate effect turns about the anchor SF Symbols
            // defines for `arrow.clockwise`. A `rotationEffect` pivots on the
            // frame centre, which the arrowhead pushes off the arc, so the arc
            // wobbled around it by about a point. The effect's own pace is one
            // turn per 2 s (measured); speed 2 keeps the one turn per second
            // the clock-driven fallback below has always had.
            Image(systemName: "arrow.clockwise")
                .symbolEffect(.rotate, options: .repeat(.continuous).speed(2), isActive: spinning)
        } else if spinning {
            SpinningArrow()
        } else {
            Image(systemName: "arrow.clockwise")
        }
    }
}

/// macOS 14 fallback, where symbol effects cannot rotate.
///
/// One full turn a second, computed from the frame's timestamp. Nothing here
/// is animated: each tick sets the angle outright, so there is no transaction
/// that could carry the rotation into anyone else's layout. `start` is state
/// so the turn begins upright and stays continuous across body updates; the
/// view exists only while refreshing, and the schedule stops with it.
private struct SpinningArrow: View {
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            Image(systemName: "arrow.clockwise")
                .rotationEffect(.degrees(context.date.timeIntervalSince(start) * 360))
        }
    }
}

struct ActiveAgentsSection: View {
    let agents: [ActiveAgent]
    var title = "Sessions"

    private var groups: [ActiveAgentGroup] { ActiveAgentGrouping.group(agents) }
    private var totalCount: Int { ActiveAgentGrouping.sessionCount(groups) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(title).font(.caption.weight(.semibold))
                Spacer()
                Text("\(totalCount)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
            }

            // Stated, not defaulted: a flat group's `ActiveAgentNodeRows` emits its
            // session row, disclosure button and children as siblings straight into
            // this stack, and the `.center` default floated the narrow "1 subagent"
            // button to the middle while the grouped path's leading stack kept its
            // twin at the left.
            VStack(alignment: .leading, spacing: 8) {
                ForEach(groups) { group in
                    if group.isFlat {
                        // Still the node view: a lone session's subagents live
                        // behind the same disclosure as one under a group header.
                        ActiveAgentNodeRows(node: group.nodes[0], showsProjectTitle: true)
                    } else {
                        ActiveAgentGroupRow(group: group)
                    }
                }
            }

        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }
}

private struct ActiveAgentGroupRow: View {
    let group: ActiveAgentGroup
    @Environment(AppViewModel.self) private var model

    /// Automatic until the user toggles: open exactly while the group needs
    /// the user, so a session that starts waiting mid-run surfaces itself.
    /// An explicit choice is remembered on the model for this app run.
    private var expanded: Bool {
        model.sessionDisclosure[group.id] ?? group.needsAttention
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    model.sessionDisclosure[group.id] = !expanded
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 8)
                    SessionStateGlyph(status: group.topStatus, provider: group.provider,
                                      marker: group.turnMarker(in: model.sessionTurnResults))
                    Text(group.projectName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(expanded ? "\(group.agentCount)" : group.collapsedSummary(turnResults: model.sessionTurnResults))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(group.nodes) { node in
                        ActiveAgentNodeRows(node: node)
                    }
                }
                .padding(.leading, 8)
            }
        }
    }
}

/// A top-level session row plus its subagents — child processes and the
/// transcript-derived `ActiveSubagent`s — which stay collapsed behind a small
/// disclosure unless one of the processes needs the user. Used both under an
/// expanded group header and for a flat group, so a project with one session
/// shows that session's subagents the same way.
private struct ActiveAgentNodeRows: View {
    let node: ActiveAgentNode
    /// True for a flat group, whose row is the only place the project is named.
    var showsProjectTitle = false
    @Environment(AppViewModel.self) private var model

    /// Same automatic-until-toggled behavior as the group disclosure.
    private var showsChildren: Bool {
        model.sessionDisclosure[node.disclosureKey] ?? node.childrenNeedAttention
    }

    var body: some View {
        ActiveAgentRow(agent: node.agent, showsProjectTitle: showsProjectTitle, results: model.sessionTurnResults)
        if node.hasChildRows {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    model.sessionDisclosure[node.disclosureKey] = !showsChildren
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(showsChildren ? 90 : 0))
                    Text(node.childRowLabel)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 14)
            if showsChildren {
                ForEach(node.children) { child in
                    ActiveAgentRow(agent: child, showsProjectTitle: false, results: model.sessionTurnResults)
                        .padding(.leading, 14)
                }
                ForEach(node.subagents) { subagent in
                    ActiveSubagentRow(subagent: subagent)
                        .padding(.leading, 14)
                }
            }
        }
    }
}

/// Why a row's click brought nothing forward, under the row, with the app
/// itself one more click away when there is one.
private struct SessionRowNoticeView: View {
    let notice: SessionRowNotice

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(notice.text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let pid = notice.appPID, let value = pid_t(exactly: pid), let name = notice.appName {
                Button("Bring \(name) forward") {
                    _ = NSRunningApplication(processIdentifier: value)?.activate()
                }
                .buttonStyle(.link)
                .font(.caption2)
            }
        }
        // Under the title, past the state glyph (9 pt) and the row's spacing.
        .padding(.leading, 15)
    }
}

/// One transcript-derived subagent under its session. Same shape as
/// `ActiveAgentRow`, but not a button: there is no process of its own to
/// focus, and the parent row directly above already jumps to the terminal
/// the subagent reports into.
private struct ActiveSubagentRow: View {
    let subagent: ActiveSubagent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(subagent.isWorking ? Color.green : Color.gray)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(subagent.displayTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subagent.subtitleText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(subagent.usageText)
                .font(.caption2.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .help(ActiveAgentTooltip.text(for: subagent))
    }
}

private struct ActiveAgentRow: View {
    let agent: ActiveAgent
    /// False for rows under a group header, which already names the project.
    var showsProjectTitle = true
    /// The sessions' latest turn results (`AppViewModel.sessionTurnResults`).
    var results: [String: SessionTurnResult] = [:]
    @State private var hovering = false
    @Environment(AppViewModel.self) private var model

    private var marker: SessionTurnMarker? { agent.turnMarker(in: results) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            row
            if let notice = model.sessionRowNotice, notice.pid == agent.pid {
                SessionRowNoticeView(notice: notice)
            }
        }
    }

    private var row: some View {
        Button {
            model.sessionRowNotice = nil
            model.sessionRowClicks += 1
            let click = model.sessionRowClicks
            let agent = agent
            Task { @MainActor in
                let notice = await AgentAppActivator.focus(agent)
                if model.sessionRowClicks == click { model.sessionRowNotice = notice }
            }
        } label: {
            rowContent
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(hovering ? 0.07 : 0))
                )
                .padding(.horizontal, -6)
                .padding(.vertical, -3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(ActiveAgentTooltip.text(for: agent, marker: marker,
                                      detail: agent.session.flatMap { results[$0.id] }.flatMap { ActiveAgentTooltip.detail(of: $0, for: marker) }))
    }

    private var rowContent: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            // The subtitle says the state in words; the glyph would say it twice.
            SessionStateGlyph(status: agent.displayStatus, provider: agent.provider, marker: marker)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(showsProjectTitle ? agent.displayTitle : agent.inGroupTitle)
                        .font(.caption.weight(.semibold))
                    if showsProjectTitle, let detail = agent.titleDetail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .lineLimit(1)
                .truncationMode(.middle)
                // The state keeps its words; the model and effort before it
                // truncate first.
                HStack(spacing: 0) {
                    if let details = agent.subtitleDetails {
                        Text(details)
                    }
                    Text((agent.subtitleDetails == nil ? "" : " · ") + agent.activityText(marker: marker))
                        .layoutPriority(1)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                // One line for VoiceOver, not two parts joined by a comma.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel([agent.subtitleDetails, agent.activityText(marker: marker)]
                    .compactMap { $0 }.joined(separator: " · "))
            }
            Spacer(minLength: 8)
            if let usage = agent.usageDisplayText {
                Text(usage)
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}

enum ActiveAgentTooltip {
    /// Hover text of a session row, in three blocks separated by a blank line:
    /// what it is and what it is doing, its details, and the technical
    /// identity with the click's effect. What the row truncates is here — the
    /// name (to a larger cap) and the last activity (`ActiveAgent.lastActivityAt`,
    /// the same moment the listing and the order use; left out when unknown).
    static func text(
        for agent: ActiveAgent,
        marker: SessionTurnMarker? = nil,
        detail: String? = nil,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        let session = agent.session
        let title = SessionLabel.fullTitle(session?.title)

        var head = [title ?? agent.displayTitle]
        head.append(stateLine(for: agent, locale: locale, timeZone: timeZone))
        if let marker {
            head.append(turnLine(marker, detail: detail, observedAt: agent.observedAt, locale: locale, timeZone: timeZone))
        }
        // The gray row's "idle · 2 subagents" is the count the last `Stop`
        // reported; the tooltip says what the count is a count of.
        if agent.displayStatus == .idle, let pending = agent.backgroundTaskText {
            head.append("The last turn ended with \(pending) still in flight")
        }

        var details: [String] = []
        // The row names the project and shows the title (or the branch) beside
        // it; with a title above, the project and the branch are still here.
        var place: [String] = []
        if title != nil, let session { place.append("Project \(session.displayProject)") }
        // The row shows the title in the branch's place when it has one
        // (`ActiveAgent.titleDetail`), so the branch has to stay reachable here.
        if let branch = session?.displayBranch { place.append("Branch \(branch)") }
        if !place.isEmpty { details.append(place.joined(separator: " · ")) }
        // The row's own name for the model (`ModelLabel.short`), with the id it
        // was made from when they differ: a snapshot date is checked there.
        var how: [String] = []
        if let full = ModelLabel.full(session?.model) {
            if let name = ModelLabel.short(session?.model), name != full {
                how.append("Model \(name) (\(full))")
            } else {
                how.append("Model \(full)")
            }
        }
        if let effort = SessionLabel.effort(session?.effort) { how.append("Effort \(effort)") }
        if !how.isEmpty { details.append(how.joined(separator: " · ")) }
        // The row's total already includes the subagents; this says how much of
        // it they are, over every subagent the session ever ran.
        if let subagents = session?.subagentUsageText { details.append(subagents) }

        var identity = ["PID #\(agent.pid)"]
        // Whole, for `--resume`; provider text, so only an id fit to be a file name.
        if let session, ActiveAgentService.isSafeSessionFilename(session.id) { identity.append("Session \(session.id)") }
        // What `AgentAppActivator.focus` really does: a terminal's own tab, an
        // editor session's window (never its conversation tab), else the app.
        let tail = [identity.joined(separator: " · "), ActiveAgentTooltip.clickHint]

        return [head, details, tail]
            .filter { !$0.isEmpty }
            .map { $0.joined(separator: "\n") }
            .joined(separator: "\n\n")
    }

    static let clickHint = "Click to bring forward its tab in iTerm2, Terminal or Ghostty, its window in VS Code or Cursor, else its app"

    /// "Last turn finished at 10:42 AM · 12m run": the row's mark, with the
    /// moment and what the outcome's event said (run time, error kind). A
    /// turn, never the session: the session stays open for the next one.
    static func turnLine(_ marker: SessionTurnMarker, detail: String?, observedAt: Date,
                         locale: Locale, timeZone: TimeZone) -> String {
        let (words, at): (String, Date?) = switch marker {
        case let .finished(at): ("Last turn finished", at)
        case let .failed(at): ("Last turn failed", at)
        }
        var line = words
        if let at { line += " at \(exactTime(at, relativeTo: observedAt, locale: locale, timeZone: timeZone))" }
        if let detail { line += " · \(detail)" }
        return line
    }

    /// The result's detail when it is the turn the mark is about: the same
    /// outcome, ended at the same moment (a hook-reported failure is marked
    /// with the hook's time, which the event may not share).
    static func detail(of result: SessionTurnResult, for marker: SessionTurnMarker?) -> String? {
        switch marker {
        case let .finished(at) where result.outcome == .finished && result.endedAt == at: result.detail
        case .failed where result.outcome == .failed: result.detail
        default: nil
        }
    }

    /// "Idle · Last activity: 8d ago (Oct 21, 2:05 PM)". The exact moment joins
    /// once the relative age is an hour or more, where "8d" stops saying when.
    static func stateLine(for agent: ActiveAgent, locale: Locale, timeZone: TimeZone) -> String {
        let state = switch agent.displayStatus {
        case .waiting: agent.waitingReason?.tooltipLead ?? (agent.statusSource == .registry ? "Waiting" : "Waiting for your input")
        case .error: "Failed"
        case .working: "Working"
        case .idle: "Idle"
        case nil: "Open"
        }
        guard let last = agent.lastActivityAt else { return state }
        var text = "\(state) · Last activity: \(ActiveAgent.relativeAge(from: last, to: agent.observedAt))"
        if agent.observedAt.timeIntervalSince(last) >= 3_600 {
            text += " (\(exactTime(last, relativeTo: agent.observedAt, locale: locale, timeZone: timeZone)))"
        }
        return text
    }

    /// Time of day for today, plus the date for earlier days, plus the year
    /// across a year boundary; in the user's own order and clock style.
    static func exactTime(_ date: Date, relativeTo now: Date, locale: Locale, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let template: String
        if calendar.isDate(date, inSameDayAs: now) {
            template = "jm"
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            template = "MMMd jm"
        } else {
            template = "yMMMd jm"
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    /// Hover text of a subagent row: the whole description (the row truncates
    /// it), then agent type, id, full model id and effort.
    static func text(for subagent: ActiveSubagent) -> String {
        var lines = [subagent.isWorking ? "Subagent running" : "Subagent finished"]
        if let description = SessionLabel.title(subagent.description) { lines.append(description) }
        var identity: [String] = []
        if let agentType = subagent.displayAgentType { identity.append(agentType) }
        identity.append("Agent \(subagent.id.prefix(8))")
        if let model = subagent.model, ModelLabel.short(model) != nil { identity.append(model) }
        if let effort = SessionLabel.effort(subagent.effort) { identity.append(effort) }
        lines.append(identity.joined(separator: " · "))
        return lines.joined(separator: "\n")
    }
}

/// A row's or a group's state mark: the state's dot, or in its place the
/// latest turn's check (finished) or cross (failed). One fixed width, so the
/// text after it lines up whichever it is.
private struct SessionStateGlyph: View {
    let status: AgentStatusState?
    let provider: Provider
    var marker: SessionTurnMarker?

    var body: some View {
        Group {
            switch marker {
            case .finished:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case nil:
                Circle().fill(statusColor(status, provider: provider)).frame(width: 7, height: 7)
            }
        }
        .font(.system(size: 9, weight: .semibold))
        .frame(width: 9, height: 9)
        // The dot's bottom on the text's baseline, as before the marks.
        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
        .accessibilityLabel(Self.accessibilityLabel(status: status, marker: marker))
    }

    static func accessibilityLabel(status: AgentStatusState?, marker: SessionTurnMarker?) -> String {
        switch marker {
        case .finished: "Last turn finished"
        case .failed: "Last turn failed"
        case nil:
            switch status {
            case .working: "Working"
            case .waiting: "Waiting"
            case .idle: "Idle"
            case .error: "Failed"
            case nil: "Open"
            }
        }
    }
}

@MainActor
private func statusColor(_ status: AgentStatusState?, provider: Provider) -> Color {
    switch status {
    case .error: return .red
    case .waiting: return .yellow
    case .working: return .green
    case .idle: return .gray
    case nil: return PopoverOrder.tint(provider)
    }
}

private struct SectionsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Provider helpers for popover rendering.
@MainActor
enum PopoverOrder {
    static func state(_ p: Provider, _ model: AppViewModel) -> ProviderState {
        switch p {
        case .codex: return model.codex
        case .claude: return model.claude
        case .copilot: return model.copilot
        }
    }

    static func tint(_ p: Provider) -> Color {
        switch p {
        case .codex: return .green
        case .claude: return .blue
        case .copilot: return .purple
        }
    }
}

/// One provider's grouped panel: title, quota windows, spend, collapsible activity.
struct ProviderSection: View {
    let state: ProviderState
    /// Daily activity for the sparkline and heatmap. Merged from the persisted
    /// lifetime ledger and this refresh's report, so the heatmap keeps days whose
    /// log files have aged out of the scanner's window.
    let historyPoints: [UsageDayPoint]
    /// Prices the dollars at display time, so every figure on screen shares one table.
    let priceTable: PriceTable
    let activeAgents: [ActiveAgent]
    var tint: Color
    /// Codex reset credits (real, or locally inferred when the live fetch is
    /// unavailable) or Claude limit-reset grants; empty for Copilot.
    var resetCredits: [ResetCreditItem] = []
    /// This provider's public status-page reading, when the last poll succeeded.
    var providerStatus: ProviderStatusResult? = nil
    /// True when the shown quota was kept from an older fetch because the last
    /// refresh for this provider failed.
    var isQuotaStale: Bool = false
    /// Claude-only, until the first successful OAuth read: warns that macOS is
    /// about to ask for Keychain access and what to answer.
    var showsKeychainPrimer: Bool = false
    var runway: (Provider, QuotaWindow) -> QuotaRunway
    @State private var showHeatmap = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(state.provider.displayName).font(.subheadline.weight(.semibold))
                if let badge = state.quota.planBadge {
                    planBadgeView(badge)
                }
                Spacer()
                Text(sourceLabel).font(.caption2).foregroundStyle(.tertiary)
            }

            if showsKeychainPrimer {
                Label("Uses Claude Code's login from your Keychain, read with macOS's security tool.",
                      systemImage: "key")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if state.quota.windows.isEmpty {
                let isDegraded = state.quota.source == .unavailable
                Label(unavailableNote, systemImage: isDegraded ? "exclamationmark.triangle" : "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(state.quota.windows) { w in
                        QuotaRow(window: w, runway: runway(state.provider, w))
                    }
                }
                if isQuotaStale {
                    Label("Data from \(QuotaRow.age(state.quota.readingTime)) — refresh failing",
                          systemImage: "clock.arrow.circlepath")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                resetCreditsSection
                if let statusBanner {
                    Label(statusBanner, systemImage: "bolt.horizontal.circle")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }

            if let extra = state.quota.extraUsageSpentUSD {
                HStack(alignment: .firstTextBaseline) {
                    Text("Extra usage").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(Self.dollars(extra))
                        .font(.caption.weight(.semibold).monospacedDigit())
                }
            }

            // Copilot is flat-rate (no token spend), so skip the spend block for
            // providers with no usage history. Gate on the merged history, not
            // this refresh's buckets: a provider idle longer than the scanner's
            // file window has empty buckets but real ledger days, and gating on
            // buckets made the section appear after the launch scan and vanish
            // again on the next windowed refresh.
            if !historyPoints.isEmpty {
                SpendSummary(usage: state.usage)
                activitySection
            }
            // No box at all when every live session is hidden: without the
            // old "N hidden" note, an empty "Sessions 0" would look broken.
            let listed = ActiveAgentListing(activeAgents).agents
            if !listed.isEmpty {
                ActiveAgentsSection(agents: listed)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showHeatmap.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showHeatmap ? 90 : 0))
                    Text("Activity").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if !showHeatmap {
                        // Fill the rest of the row: the old fixed width made
                        // 21 days of activity hard to read.
                        MiniSparkline(points: historyPoints, tint: tint)
                            .frame(height: 20)
                            .frame(maxWidth: .infinity)
                            .transition(.opacity)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showHeatmap {
                VStack(alignment: .leading, spacing: 10) {
                    SpendBreakdownGrid(usage: state.usage, table: priceTable)
                    ModelBreakdown(usage: state.usage, table: priceTable)
                    UsageHeatmap(points: historyPoints, tint: tint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// The plan capsule beside the provider name. Text and tooltip are both
    /// decided by `QuotaSnapshot.planBadge`; this only draws them, and attaches
    /// the tooltip only when there is one, so no badge carries an empty `.help`.
    @ViewBuilder
    private func planBadgeView(_ badge: PlanBadge) -> some View {
        let capsule = Text(badge.text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
        if let help = badge.help {
            capsule.help(help)
        } else {
            capsule
        }
    }

    private var sourceLabel: String {
        switch state.quota.source {
        case .appServer: return "live"
        case .rolloutFile: return "local log"
        case .oauth: return "oauth"
        case .cli: return "cli"
        case .unavailable: return "usage only"
        }
    }

    private static func dollars(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return "$" + (formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value))
    }

    /// "4 resets available" followed by one countdown per credit or grant, e.g.
    /// "5d 10h · 11d 9h · 20d 9h · 25d 5h" — mirrors the individual countdowns
    /// ChatGPT's own usage panel shows, instead of only the nearest one.
    @ViewBuilder
    private var resetCreditsSection: some View {
        if let headline = ResetCreditItem.headline(resetCredits) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let countdowns = ResetCreditItem.countdowns(resetCredits, labeled: state.provider == .claude) {
                    Text(countdowns)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// Shown alongside working quota data as a heads-up — e.g. quota looks fine
    /// right now, but the provider itself has a known incident. Separate from
    /// `unavailableNote` so the two never say the same thing twice. Uses the
    /// component-filtered reading, not the page-wide one: an incident touching
    /// only unrelated components (FedRAMP, Sora, …) shouldn't put a permanent
    /// warning under a perfectly healthy quota panel.
    private var statusBanner: String? {
        guard let providerStatus, providerStatus.componentLevel != .operational else { return nil }
        return providerStatus.componentDescription ?? "\(state.provider.displayName) is reporting issues"
    }

    /// When quota is genuinely unavailable and the provider's own status page
    /// confirms an active incident, swap the generic "Live quota unavailable"
    /// text for the real reason instead of leaving the user to guess whether
    /// it's their own setup or an outage.
    private var unavailableNote: String {
        guard state.quota.source == .unavailable,
              let providerStatus, providerStatus.level != .operational,
              let description = providerStatus.description else {
            return state.quota.note ?? "Live quota unavailable"
        }
        return "\(state.provider.displayName): \(description)"
    }
}

/// One row's worth of reset credits for `ProviderSection`: a Codex credit, or a
/// Claude grant that may hold several resets under one deadline.
struct ResetCreditItem: Equatable {
    var expiresAt: Date?
    var count: Int
    /// The windows a reset refills, when the provider says (Claude only).
    var refills: String?

    static func items(codex credits: [CodexResetCreditExpiry]) -> [ResetCreditItem] {
        credits.sorted { $0.expiresAt < $1.expiresAt }
            .map { ResetCreditItem(expiresAt: $0.expiresAt, count: 1, refills: nil) }
    }

    /// Grants past their deadline drop out here as well as at parse time, since
    /// the state can sit unrefreshed for 20 minutes or across a relaunch.
    static func items(claude state: ClaudeResetState, at now: Date = Date()) -> [ResetCreditItem] {
        guard state.eligible == true else { return [] }
        return state.grants
            .filter { grant in grant.resetsLeft > 0 && grant.endsAt.map { $0 > now } ?? true }
            .sorted { ($0.endsAt ?? .distantFuture) < ($1.endsAt ?? .distantFuture) }
            .map { ResetCreditItem(expiresAt: $0.endsAt, count: $0.resetsLeft,
                                   refills: ClaudeResetGrantFetcher.refillLabel(for: $0.clears)) }
    }

    /// "2 resets available", plus " · refills Weekly" when every item refills
    /// the same windows. Nil when there is nothing to show.
    static func headline(_ items: [ResetCreditItem]) -> String? {
        let total = items.reduce(0) { $0 + $1.count }
        guard total > 0 else { return nil }
        let count = total == 1 ? "1 reset available" : "\(total) resets available"
        guard let refills = sharedRefills(items) else { return count }
        return "\(count) · refills \(refills)"
    }

    /// One entry per item, "6d 23h", "6d 23h ×2", or "Weekly 6d 23h" when
    /// items refill different windows; nil when no item has anything to say.
    /// With `labeled`, the deadline reads as a deadline: "Expires in 6d 23h ·
    /// 9d 2h" when the items share their refills, "Weekly expires in 6d 23h ·
    /// 5-hour expires in 9d 2h" when they do not.
    static func countdowns(_ items: [ResetCreditItem], labeled: Bool = false) -> String? {
        let shared = sharedRefills(items)
        let entries = items.compactMap { item -> String? in
            var parts: [String] = []
            if shared == nil, let refills = item.refills { parts.append(refills) }
            if let expiresAt = item.expiresAt {
                let remaining = QuotaRow.relative(expiresAt, prefixed: false)
                if labeled && shared == nil { parts.append("expires in") }
                parts.append(remaining)
            }
            guard !parts.isEmpty else { return nil }
            if item.count > 1 { parts.append("×\(item.count)") }
            return parts.joined(separator: " ")
        }
        guard !entries.isEmpty else { return nil }
        let line = entries.joined(separator: " · ")
        return labeled && shared != nil ? "Expires in " + line : line
    }

    private static func sharedRefills(_ items: [ResetCreditItem]) -> String? {
        guard let first = items.first?.refills,
              items.allSatisfy({ $0.refills == first }) else { return nil }
        return first
    }
}

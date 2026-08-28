import AgentStatusCore
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
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                ForEach(visibleProviders, id: \.self) { p in
                    ProviderSection(
                        state: PopoverOrder.state(p, model),
                        activeAgents: model.activeAgents.filter { $0.provider == p },
                        tint: PopoverOrder.tint(p),
                        codexResetCredits: p == .codex ? model.codexResetCreditState.credits : [],
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
            Divider()
            footer
        }
        .frame(width: 340)
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
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(model.isRefreshing ? 360 : 0))
                    .animation(model.isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                               value: model.isRefreshing)
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
            SettingsLink { Text("Settings").font(.caption) }.buttonStyle(.borderless)
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

struct ActiveAgentsSection: View {
    let agents: [ActiveAgent]
    var title = "Sessions"

    private var groups: [ActiveAgentGroup] { ActiveAgentGrouping.group(agents) }
    private var totalCount: Int { groups.reduce(0) { $0 + $1.agentCount } }

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

            VStack(spacing: 8) {
                ForEach(groups) { group in
                    if group.isFlat {
                        ActiveAgentRow(agent: group.nodes[0].agent)
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
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 8)
                    Circle().fill(statusColor(group.topStatus, provider: group.provider))
                        .frame(width: 7, height: 7)
                    Text(group.projectName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text("\(group.agentCount)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(spacing: 6) {
                    ForEach(group.nodes) { node in
                        ActiveAgentRow(agent: node.agent, showsProjectTitle: false)
                        ForEach(node.children) { child in
                            ActiveAgentRow(agent: child, showsProjectTitle: false)
                                .padding(.leading, 14)
                        }
                    }
                }
                .padding(.leading, 8)
            }
        }
    }
}

private struct ActiveAgentRow: View {
    let agent: ActiveAgent
    /// False for rows under a group header, which already names the project.
    var showsProjectTitle = true
    @State private var hovering = false

    var body: some View {
        Button {
            AgentAppActivator.focus(agent)
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
        .help(ActiveAgentTooltip.text(for: agent))
    }

    private var rowContent: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(statusColor(agent.displayStatus, provider: agent.provider))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(showsProjectTitle ? agent.displayTitle : agent.inGroupTitle)
                        .font(.caption.weight(.semibold))
                    if showsProjectTitle, let branch = agent.session?.branch, branch != "HEAD" {
                        Text(branch)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .lineLimit(1)
                .truncationMode(.middle)
                Text(agent.subtitleText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
    static func text(for agent: ActiveAgent) -> String {
        let action = switch agent.displayStatus {
        case .waiting: "Waiting for your input, click to jump to this session"
        case .error: "This session needs attention, click to jump to it"
        case .working: "Active, click to jump to this session"
        case .idle: "Idle, click to jump to this session"
        case nil: "Open, click to jump to this session"
        }
        var identity = ["PID #\(agent.pid)"]
        if let session = agent.session {
            identity.append("Session \(session.shortID)")
        }
        return [action, identity.joined(separator: " · ")].joined(separator: "\n")
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
    let activeAgents: [ActiveAgent]
    var tint: Color
    /// Codex-only real (or locally inferred, when the live fetch is unavailable)
    /// reset-credit expiry dates; empty for other providers.
    var codexResetCredits: [CodexResetCreditExpiry] = []
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
                if let plan = state.quota.planType {
                    Text(plan.uppercased())
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                Spacer()
                Text(sourceLabel).font(.caption2).foregroundStyle(.tertiary)
            }

            if showsKeychainPrimer {
                Label("Reads Claude Code's credential from the Keychain — choose Always Allow when macOS asks.",
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
                    Label("Data from \(QuotaRow.age(state.quota.fetchedAt)) — refresh failing",
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
            // providers with no usage history.
            if !state.usage.buckets.isEmpty {
                SpendSummary(usage: state.usage)
                activitySection
            }
            if !activeAgents.isEmpty {
                ActiveAgentsSection(agents: activeAgents)
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
                        MiniSparkline(buckets: state.usage.buckets, tint: tint)
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
                    SpendBreakdownGrid(usage: state.usage)
                    ModelBreakdown(usage: state.usage)
                    UsageHeatmap(buckets: state.usage.buckets, tint: tint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
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

    /// One line per available reset credit, e.g. "4 resets available" followed by
    /// "in 5d 10h · in 11d 9h · in 20d 9h · in 25d 5h" — mirrors the individual
    /// countdowns ChatGPT's own usage panel shows, instead of only the nearest one.
    @ViewBuilder
    private var resetCreditsSection: some View {
        let credits = codexResetCredits.sorted { $0.expiresAt < $1.expiresAt }
        if !credits.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(credits.count == 1 ? "1 reset available" : "\(credits.count) resets available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(credits.map { QuotaRow.relative($0.expiresAt, prefixed: false) }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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

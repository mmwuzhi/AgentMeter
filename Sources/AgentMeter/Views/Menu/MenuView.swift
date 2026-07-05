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
            let state = PopoverOrder.state(provider, model)
            return String(format: "30-day spend  $%.2f", state.usage.totalCostUSD)
        }
    }
}

struct ActiveAgentsSection: View {
    let agents: [ActiveAgent]
    var title = "Active Sessions"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(title).font(.caption.weight(.semibold))
                Spacer()
                Text("\(agents.count)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
            }

            if agents.isEmpty {
                Label("No local Codex or Claude sessions running", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(agents) { agent in
                        ActiveAgentRow(agent: agent)
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }
}

private struct ActiveAgentRow: View {
    let agent: ActiveAgent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(PopoverOrder.tint(agent.provider))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent.provider.displayName)
                        .font(.caption.weight(.semibold))
                    Text(agent.elapsedText)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    if let session = agent.session {
                        Text(session.shortID)
                            .font(.caption2.monospacedDigit().weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                if let session = agent.session {
                    HStack(spacing: 4) {
                        Text(session.displayProject)
                        if let branch = session.branch, branch != "HEAD" {
                            Text(branch)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                } else {
                    Text(agent.displayCommand)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if let usageText = agent.session?.usageText {
                    Text(usageText)
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text("#\(agent.pid)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
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

            if state.quota.windows.isEmpty {
                let isDegraded = state.quota.source == .unavailable
                Label(state.quota.note ?? "Live quota unavailable",
                      systemImage: isDegraded ? "exclamationmark.triangle" : "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(state.quota.windows) { w in
                        QuotaRow(window: w, runway: runway(state.provider, w))
                    }
                }
                if let resetCreditsSummary {
                    Text(resetCreditsSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                        MiniSparkline(buckets: state.usage.buckets, tint: tint)
                            .frame(width: 120, height: 14)
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

    private var resetCreditsSummary: String? {
        guard let text = state.quota.resetCreditsCountText else { return nil }
        guard let expiresAt = state.quota.resetCreditsExpiresAt else { return text }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "\(text) · nearest expiry \(formatter.string(from: expiresAt))"
    }
}

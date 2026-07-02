import SwiftUI

/// Root content of the menubar popover.
struct MenuView: View {
    @Bindable var model: AppViewModel
    var onRefresh: () -> Void
    var onQuit: () -> Void

    @AppStorage("popoverOrder") private var popoverOrderRaw = ""
    @AppStorage("popoverHiddenProviders") private var popoverHiddenRaw = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(visibleProviders, id: \.self) { p in
                        ProviderSection(
                            state: PopoverOrder.state(p, model),
                            tint: PopoverOrder.tint(p),
                            runway: { provider, window in
                                model.runway(for: provider, window: window)
                            }
                        )
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 480)
            Divider()
            footer
        }
        .frame(width: 340)
    }

    private var visibleProviders: [Provider] {
        PopoverOrder.resolved(from: popoverOrderRaw, hiddenRaw: popoverHiddenRaw).filter { provider in
            let state = PopoverOrder.state(provider, model)
            return state.hasPopoverContent || state.isLoadingPlaceholder || PopoverOrder.hasManualVisibilityConfiguration
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .foregroundStyle(.secondary)
            Text("AgentMeter").font(.headline)
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
            Text(String(format: "Total spend  $%.2f", model.totalSpendUSD))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            SettingsLink { Text("Settings").font(.caption) }.buttonStyle(.borderless)
            Button("Quit", action: onQuit).buttonStyle(.borderless).font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// The order (and tint) of provider panels in the popover. Visible providers are
/// persisted as a comma-joined list under `popoverOrder`; hidden providers live
/// under `popoverHiddenProviders`. It seeds itself from the legacy `codexFirst`
/// toggle, starts Copilot hidden by default, and backfills newly-added providers
/// unless the user hid them.
@MainActor
enum PopoverOrder {
    static let key = "popoverOrder"
    static let hiddenKey = "popoverHiddenProviders"
    static let all: [Provider] = [.codex, .claude, .copilot]
    private static let defaultVisible: [Provider] = [.codex, .claude]
    private static let defaultHidden: [Provider] = [.copilot]

    static var hasManualVisibilityConfiguration: Bool {
        UserDefaults.standard.object(forKey: hiddenKey) != nil
    }

    static func resolved(from raw: String, hiddenRaw: String? = nil) -> [Provider] {
        visible(from: raw, hidden: hidden(from: hiddenRaw, visibleRaw: raw))
    }

    static func visible() -> [Provider] {
        let raw = UserDefaults.standard.string(forKey: key) ?? ""
        return visible(from: raw, hidden: hidden(from: UserDefaults.standard.string(forKey: hiddenKey), visibleRaw: raw))
    }

    static func hidden() -> [Provider] {
        hidden(from: UserDefaults.standard.string(forKey: hiddenKey),
               visibleRaw: UserDefaults.standard.string(forKey: key) ?? "")
    }

    private static func hidden(from raw: String?, visibleRaw: String) -> [Provider] {
        if hasManualVisibilityConfiguration { return unique(raw ?? "") }
        guard UserDefaults.standard.object(forKey: key) != nil else { return defaultHidden }
        let savedVisible = Set(unique(visibleRaw))
        return defaultHidden.filter { !savedVisible.contains($0) }
    }

    private static func visible(from raw: String, hidden: [Provider]) -> [Provider] {
        let hiddenSet = Set(hidden)
        var order = unique(raw)
        if order.isEmpty {
            let codexFirst = UserDefaults.standard.object(forKey: "codexFirst") as? Bool ?? true
            order = codexFirst ? defaultVisible : Array(defaultVisible.reversed())
        }
        for p in all where !order.contains(p) && !hiddenSet.contains(p) { order.append(p) }
        return order.filter { all.contains($0) && !hiddenSet.contains($0) }
    }

    private static func unique(_ raw: String) -> [Provider] {
        var seen = Set<Provider>()
        return raw.split(separator: ",")
            .compactMap { Provider(rawValue: String($0)) }
            .filter { seen.insert($0).inserted && all.contains($0) }
    }

    static func save(_ order: [Provider]) {
        UserDefaults.standard.set(order.map(\.rawValue).joined(separator: ","), forKey: key)
    }

    static func save(visible: [Provider], hidden: [Provider]) {
        let visible = visible.filter(all.contains)
        let visibleSet = Set(visible)
        let hidden = hidden.filter { all.contains($0) && !visibleSet.contains($0) }
        UserDefaults.standard.set(visible.map(\.rawValue).joined(separator: ","), forKey: key)
        UserDefaults.standard.set(hidden.map(\.rawValue).joined(separator: ","), forKey: hiddenKey)
    }

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

private extension ProviderState {
    var hasPopoverContent: Bool {
        !quota.windows.isEmpty || !usage.buckets.isEmpty
    }

    var isLoadingPlaceholder: Bool {
        quota.source == .unavailable && quota.note == "Loading…" && usage.buckets.isEmpty
    }
}

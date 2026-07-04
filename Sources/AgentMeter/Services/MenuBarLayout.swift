import Foundation

/// One independent menu-bar item. A slot owns its own status item, popover, and
/// visible columns, so a Claude-heavy setup can be wide without crowding Codex.
enum MenuBarSlot: String, Codable, Sendable, CaseIterable, Identifiable {
    case overview
    case codex
    case claude
    case copilot
    case activeAgents

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .overview: return "Overview"
        case .codex: return Provider.codex.displayName
        case .claude: return Provider.claude.displayName
        case .copilot: return Provider.copilot.displayName
        case .activeAgents: return "Agents"
        }
    }

    var provider: Provider? {
        switch self {
        case .overview: return nil
        case .codex: return .codex
        case .claude: return .claude
        case .copilot: return .copilot
        case .activeAgents: return nil
        }
    }

    var menuBarLimit: Int {
        switch self {
        case .overview: return 6
        case .codex, .claude: return 8
        case .copilot: return 5
        case .activeAgents: return 4
        }
    }
}

/// One configurable menu-bar slot: a stable key plus whether it's shown. Order in
/// the stored array is the left→right order in the menu bar.
struct MenuBarSlotItem: Codable, Identifiable, Equatable, Sendable {
    let key: String
    var enabled: Bool
    var id: String { key }
}

/// One configurable item inside a slot: a stable key plus whether it's shown.
/// Order in the stored array is the left→right order inside that status item.
struct MenuBarItem: Codable, Identifiable, Equatable, Sendable {
    let key: String     // "q:codex:primary", "u:claude:7d", "s:codex", …
    var enabled: Bool
    var id: String { key }
}

enum MenuBarAlertLevel: Equatable {
    case none
    case warn
    case critical
}

enum MenuBarIcon: Equatable {
    case gauge
    case provider(Provider)
    case agents
}

/// A resolved item ready to draw.
struct MenuBarSegment: Equatable {
    let label: String       // caption (short)
    let value: String       // value line
    let remaining: Double?  // 0…100 for quota items; nil for usage/spend
    let alertLevel: MenuBarAlertLevel
}

/// One thing the menu bar draws, in config order: an icon or a value column.
enum MenuBarElement: Equatable {
    case icon(MenuBarIcon)
    case segment(MenuBarSegment)
}

/// Source of truth for which independent status items are visible.
@MainActor
enum MenuBarSlots {
    static let configKey = "menuBarSlotsConfig"

    static func storedConfig() -> [MenuBarSlotItem] {
        guard let data = UserDefaults.standard.data(forKey: configKey),
              let items = try? JSONDecoder().decode([MenuBarSlotItem].self, from: data) else { return [] }
        return items
    }

    static func save(_ items: [MenuBarSlotItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: configKey)
    }

    static func merged() -> [(item: MenuBarSlotItem, name: String)] {
        let names = Dictionary(MenuBarSlot.allCases.map { ($0.rawValue, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        let base = storedConfig().isEmpty ? defaultConfig() : storedConfig()
        var result: [(MenuBarSlotItem, String)] = []
        var seen = Set<String>()
        for item in base {
            guard let name = names[item.key] else { continue }
            result.append((item, name))
            seen.insert(item.key)
        }
        for slot in MenuBarSlot.allCases where !seen.contains(slot.rawValue) {
            result.append((MenuBarSlotItem(key: slot.rawValue, enabled: false), slot.displayName))
        }
        return result
    }

    static func visibleSlots() -> [MenuBarSlot] {
        let slots = merged()
            .filter { $0.item.enabled }
            .compactMap { MenuBarSlot(rawValue: $0.item.key) }
        return slots.isEmpty ? [.overview] : slots
    }

    private static func defaultConfig() -> [MenuBarSlotItem] {
        MenuBarSlot.allCases.map { slot in
            MenuBarSlotItem(key: slot.rawValue, enabled: slot == .overview)
        }
    }
}

/// Source of truth for which fields each status item shows, in what order.
/// Bridges the persisted config (UserDefaults) and the live `AppViewModel`.
@MainActor
enum MenuBarLayout {
    static let configKey = "menuBarItemsConfig"

    static func icon(for slot: MenuBarSlot) -> MenuBarIcon {
        if slot == .activeAgents { return .agents }
        if let provider = slot.provider { return .provider(provider) }
        return .gauge
    }

    private static func configKey(for slot: MenuBarSlot) -> String {
        slot == .overview ? configKey : "\(configKey).\(slot.rawValue)"
    }

    private static func provider(_ code: String) -> Provider? {
        switch code {
        case "codex": return .codex
        case "claude": return .claude
        case "copilot": return .copilot
        default: return nil
        }
    }

    private static func state(_ p: Provider, _ model: AppViewModel) -> ProviderState {
        switch p {
        case .codex: return model.codex
        case .claude: return model.claude
        case .copilot: return model.copilot
        }
    }

    /// Short provider tag used to disambiguate captions when the overview mixes
    /// providers (e.g. "cx 5h", "cl wk", "cp prem").
    private static func tag(_ p: Provider) -> String {
        switch p {
        case .codex: return "cx"
        case .claude: return "cl"
        case .copilot: return "cp"
        }
    }

    /// Critical (red) threshold, also NotificationManager's notify level.
    private static var criticalThreshold: Double {
        let v = UserDefaults.standard.object(forKey: "alertThresholdPercent") as? Double ?? 10
        return max(1, min(99, v))
    }

    /// Warning (yellow) threshold. Defaults above critical; clamped so it's never lower.
    private static var warnThreshold: Double {
        let v = UserDefaults.standard.object(forKey: "warnThresholdPercent") as? Double ?? 25
        return max(criticalThreshold, min(99, v))
    }

    private static func alertLevel(forRemaining remaining: Double) -> MenuBarAlertLevel {
        if remaining <= criticalThreshold { return .critical }
        if remaining <= warnThreshold { return .warn }
        return .none
    }

    // MARK: - Persistence

    static func storedConfig(for slot: MenuBarSlot = .overview) -> [MenuBarItem] {
        guard let data = UserDefaults.standard.data(forKey: configKey(for: slot)),
              let items = try? JSONDecoder().decode([MenuBarItem].self, from: data) else { return [] }
        return items
    }

    static func save(_ items: [MenuBarItem], for slot: MenuBarSlot = .overview) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: configKey(for: slot))
    }

    // MARK: - Discovery

    /// Every item a slot can currently render, in canonical order, with display names.
    static func available(_ model: AppViewModel, for slot: MenuBarSlot = .overview) -> [(key: String, name: String)] {
        var out: [(String, String)] = [("icon", "\(slot.displayName) icon")]
        if slot == .activeAgents {
            out.append(("a:count", "Agents · active count"))
            out.append(("a:session", "Agents · current session"))
            out.append(("a:project", "Agents · current project"))
            out.append(("a:primary", "Agents · primary agent"))
            return out
        }
        for p in providers(for: slot) {
            let s = state(p, model)
            for w in s.quota.windows {
                out.append(("q:\(p.rawValue):\(w.id)", "\(p.displayName) · \(w.label)"))
            }
            if p != .copilot {
                out.append(("u:\(p.rawValue):localDay", "\(p.displayName) · local day"))
                out.append(("u:\(p.rawValue):7d", "\(p.displayName) · 7-day tokens"))
                out.append(("u:\(p.rawValue):30d", "\(p.displayName) · 30-day tokens"))
                out.append(("s:\(p.rawValue)", "\(p.displayName) · spend (today)"))
            }
        }
        return out
    }

    private static func providers(for slot: MenuBarSlot) -> [Provider] {
        if let provider = slot.provider { return [provider] }
        return [.codex, .claude, .copilot]
    }

    /// Default selection used when nothing is configured yet.
    private static func autoDefault(_ model: AppViewModel, for slot: MenuBarSlot) -> [MenuBarItem] {
        guard slot == .overview else {
            if slot == .activeAgents {
                return [
                    MenuBarItem(key: "icon", enabled: true),
                    MenuBarItem(key: "a:count", enabled: true),
                    MenuBarItem(key: "a:session", enabled: true),
                    MenuBarItem(key: "a:project", enabled: false),
                    MenuBarItem(key: "a:primary", enabled: false),
                ]
            }
            return providerDefault(model, for: slot)
        }

        let d = UserDefaults.standard
        let both = d.object(forKey: "menuBarBothProviders") as? Bool ?? false
        let showSpend = d.object(forKey: "showSpendInMenuBar") as? Bool ?? false
        let showPercent = d.object(forKey: "showPercentInMenuBar") as? Bool ?? true
        let primary = d.string(forKey: "menuBarProvider") ?? "codex"
        let codes = both ? ["codex", "claude"] : [primary]
        let showIcon = d.object(forKey: "menuBarShowIcon") as? Bool ?? true

        var items: [MenuBarItem] = [MenuBarItem(key: "icon", enabled: showIcon)]
        for code in codes {
            guard let p = provider(code) else { continue }
            if showPercent {
                for w in state(p, model).quota.windows {
                    items.append(MenuBarItem(key: "q:\(code):\(w.id)", enabled: true))
                }
            }
            if showSpend { items.append(MenuBarItem(key: "s:\(code)", enabled: true)) }
        }
        return items
    }

    private static func providerDefault(_ model: AppViewModel, for slot: MenuBarSlot) -> [MenuBarItem] {
        guard let provider = slot.provider else { return [] }
        let state = state(provider, model)
        var items = [MenuBarItem(key: "icon", enabled: true)]
        for window in state.quota.windows {
            items.append(MenuBarItem(key: "q:\(provider.rawValue):\(window.id)", enabled: true))
        }
        if provider != .copilot {
            items.append(MenuBarItem(key: "u:\(provider.rawValue):localDay", enabled: true))
            items.append(MenuBarItem(key: "u:\(provider.rawValue):7d", enabled: true))
            items.append(MenuBarItem(key: "u:\(provider.rawValue):30d", enabled: true))
            items.append(MenuBarItem(key: "s:\(provider.rawValue)", enabled: false))
        }
        return items
    }

    /// The effective config to render/customize from: saved config (or default),
    /// normalized so an "icon" entry always exists.
    private static func baseConfig(_ model: AppViewModel, for slot: MenuBarSlot) -> [MenuBarItem] {
        var base = storedConfig(for: slot).isEmpty ? autoDefault(model, for: slot) : storedConfig(for: slot)
        if !base.contains(where: { $0.key == "icon" }) {
            let showIcon = slot == .overview
                ? (UserDefaults.standard.object(forKey: "menuBarShowIcon") as? Bool ?? true)
                : true
            base.insert(MenuBarItem(key: "icon", enabled: showIcon), at: 0)
        }
        return base
    }

    /// Config merged with what's currently available: stored items kept in order
    /// (dropping ones no longer present), then newly-seen items appended (off).
    static func merged(_ model: AppViewModel, for slot: MenuBarSlot = .overview) -> [(item: MenuBarItem, name: String)] {
        let names = Dictionary(available(model, for: slot).map { ($0.key, $0.name) }, uniquingKeysWith: { a, _ in a })
        let base = baseConfig(model, for: slot)

        var result: [(MenuBarItem, String)] = []
        var seen = Set<String>()
        for item in base {
            guard let name = names[item.key] else { continue }
            result.append((item, name))
            seen.insert(item.key)
        }
        for (key, name) in available(model, for: slot) where !seen.contains(key) {
            result.append((MenuBarItem(key: key, enabled: false), name))
        }
        return result
    }

    // MARK: - Resolution / rendering

    private static func resolve(_ key: String, _ model: AppViewModel)
        -> (segment: MenuBarSegment, provider: Provider)? {
        if let segment = resolveAgent(key, model) {
            return (segment, .codex)
        }
        let parts = key.split(separator: ":").map(String.init)
        guard parts.count >= 2, let p = provider(parts[1]) else { return nil }
        let s = state(p, model)
        switch parts.first {
        case "q":
            guard parts.count == 3, let w = s.quota.windows.first(where: { $0.id == parts[2] }) else { return nil }
            return (MenuBarSegment(label: w.shortLabel,
                                   value: "\(Int(w.remainingPercent.rounded()))%",
                                   remaining: w.remainingPercent,
                                   alertLevel: alertLevel(forRemaining: w.remainingPercent)), p)
        case "u":
            guard parts.count == 3, let window = UsageWindow(rawValue: parts[2]) else { return nil }
            return (MenuBarSegment(label: window.label,
                                   value: TokenFormat.short(tokens(in: window, usage: s.usage)),
                                   remaining: nil,
                                   alertLevel: .none), p)
        case "s":
            return (MenuBarSegment(label: "usd",
                                   value: String(format: "%.2f", model.todaySpendUSD(for: s)),
                                   remaining: nil,
                                   alertLevel: .none), p)
        default:
            return nil
        }
    }

    private static func resolveAgent(_ key: String, _ model: AppViewModel) -> MenuBarSegment? {
        switch key {
        case "a:count":
            return MenuBarSegment(
                label: "agt",
                value: "\(model.activeAgents.count)",
                remaining: nil,
                alertLevel: .none
            )
        case "a:primary":
            let value = model.activeAgents.first.map { tag($0.provider) } ?? "none"
            return MenuBarSegment(label: "run", value: value, remaining: nil, alertLevel: .none)
        case "a:session":
            let value = model.activeAgents.first?.displaySession ?? "none"
            return MenuBarSegment(label: "ses", value: value, remaining: nil, alertLevel: .none)
        case "a:project":
            let value = model.activeAgents.first?.session?.displayProject
                ?? model.activeAgents.first?.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? "none"
            return MenuBarSegment(label: "proj", value: value, remaining: nil, alertLevel: .none)
        default:
            return nil
        }
    }

    /// A single item's current caption + value for the settings preview chips.
    static func preview(_ key: String, _ model: AppViewModel, slot: MenuBarSlot = .overview) -> MenuBarSegment? {
        if let segment = resolveAgent(key, model) {
            return segment
        }
        guard let (seg, p) = resolve(key, model) else { return nil }
        if slot.provider != nil {
            return seg
        }
        return MenuBarSegment(
            label: "\(tag(p)) \(seg.label)",
            value: seg.value,
            remaining: seg.remaining,
            alertLevel: seg.alertLevel
        )
    }

    /// Enabled elements in order, resolved against the model.
    static func activeElements(_ model: AppViewModel, slot: MenuBarSlot = .overview, limit: Int? = nil) -> [MenuBarElement] {
        let enabled = baseConfig(model, for: slot).filter(\.enabled)
        let resolved = enabled.filter { $0.key != "icon" }.compactMap { resolve($0.key, model) }
        let mixed = slot == .overview && Set(resolved.map(\.provider)).count > 1
        let maxItems = limit ?? slot.menuBarLimit

        var out: [MenuBarElement] = []
        for item in enabled {
            if item.key == "icon" {
                out.append(.icon(icon(for: slot)))
                continue
            }
            guard let r = resolve(item.key, model) else { continue }
            if mixed {
                out.append(.segment(MenuBarSegment(label: "\(tag(r.provider)) \(r.segment.label)",
                                                   value: r.segment.value,
                                                   remaining: r.segment.remaining,
                                                   alertLevel: r.segment.alertLevel)))
            } else {
                out.append(.segment(r.segment))
            }
        }
        return Array(out.prefix(maxItems))
    }

    /// The value columns only, for the alert level and accessibility text.
    static func activeSegments(_ model: AppViewModel, slot: MenuBarSlot = .overview, limit: Int? = nil) -> [MenuBarSegment] {
        activeElements(model, slot: slot, limit: limit).compactMap {
            if case .segment(let s) = $0 { return s }
            return nil
        }
    }

    private enum UsageWindow: String {
        case localDay
        case sevenDays = "7d"
        case thirtyDays = "30d"

        var label: String {
            switch self {
            case .localDay: return "day"
            case .sevenDays: return "7d"
            case .thirtyDays: return "30d"
            }
        }

        var days: Int {
            switch self {
            case .localDay: return 1
            case .sevenDays: return 7
            case .thirtyDays: return 30
            }
        }
    }

    private static func tokens(in window: UsageWindow, usage: UsageReport, now: Date = Date()) -> Int {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        guard let start = cal.date(byAdding: .day, value: -(window.days - 1), to: today) else { return 0 }
        return usage.buckets
            .filter { $0.day >= start && $0.day <= today }
            .reduce(0) { $0 + $1.totalTokens }
    }
}

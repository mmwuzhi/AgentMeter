import Foundation

/// One independent menu-bar item. A slot owns its own status item, popover, and
/// visible columns, so a Claude-heavy setup can be wide without crowding Codex.
enum MenuBarSlot: String, Codable, Sendable, CaseIterable, Identifiable {
    case codex
    case claude
    case copilot

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: return Provider.codex.displayName
        case .claude: return Provider.claude.displayName
        case .copilot: return Provider.copilot.displayName
        }
    }

    var provider: Provider {
        switch self {
        case .codex: return .codex
        case .claude: return .claude
        case .copilot: return .copilot
        }
    }

    var menuBarLimit: Int {
        switch self {
        case .codex, .claude: return 8
        case .copilot: return 5
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
    case provider(Provider)
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
        return slots.isEmpty ? [.codex, .claude] : slots
    }

    private static func defaultConfig() -> [MenuBarSlotItem] {
        MenuBarSlot.allCases.map { slot in
            MenuBarSlotItem(key: slot.rawValue, enabled: slot.defaultVisible)
        }
    }
}

private extension MenuBarSlot {
    var defaultVisible: Bool {
        switch self {
        case .copilot:
            return false
        case .codex, .claude:
            return true
        }
    }
}

/// Source of truth for which fields each status item shows, in what order.
/// Bridges the persisted config (UserDefaults) and the live `AppViewModel`.
@MainActor
enum MenuBarLayout {
    static let configKey = "menuBarItemsConfig"

    static func icon(for slot: MenuBarSlot) -> MenuBarIcon {
        .provider(slot.provider)
    }

    private static func configKey(for slot: MenuBarSlot) -> String {
        "\(configKey).\(slot.rawValue)"
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

    static func storedConfig(for slot: MenuBarSlot) -> [MenuBarItem] {
        guard let data = UserDefaults.standard.data(forKey: configKey(for: slot)),
              let items = try? JSONDecoder().decode([MenuBarItem].self, from: data) else { return [] }
        return items
    }

    static func save(_ items: [MenuBarItem], for slot: MenuBarSlot) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: configKey(for: slot))
    }

    // MARK: - Discovery

    /// Every item a slot can currently render, in canonical order, with display names.
    static func available(_ model: AppViewModel, for slot: MenuBarSlot) -> [(key: String, name: String)] {
        var out: [(String, String)] = [("icon", "\(slot.displayName) icon")]
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
        [slot.provider]
    }

    /// Default selection used when nothing is configured yet.
    private static func autoDefault(_ model: AppViewModel, for slot: MenuBarSlot) -> [MenuBarItem] {
        providerDefault(model, for: slot)
    }

    private static func providerDefault(_ model: AppViewModel, for slot: MenuBarSlot) -> [MenuBarItem] {
        let provider = slot.provider
        let state = state(provider, model)
        let visibleByDefault = defaultVisible(for: slot)
        var items = [MenuBarItem(key: "icon", enabled: visibleByDefault)]
        let primaryQuotaID = defaultQuotaWindowID(in: state.quota.windows)
        for window in state.quota.windows {
            items.append(MenuBarItem(
                key: "q:\(provider.rawValue):\(window.id)",
                enabled: visibleByDefault && window.id == primaryQuotaID
            ))
        }
        if provider != .copilot {
            items.append(MenuBarItem(key: "u:\(provider.rawValue):localDay", enabled: false))
            items.append(MenuBarItem(key: "u:\(provider.rawValue):7d", enabled: false))
            items.append(MenuBarItem(key: "u:\(provider.rawValue):30d", enabled: false))
            items.append(MenuBarItem(key: "s:\(provider.rawValue)", enabled: false))
        }
        return items
    }

    private static func defaultVisible(for slot: MenuBarSlot) -> Bool {
        if let legacy = MenuBarSlots.storedConfig().first(where: { $0.key == slot.rawValue }) {
            return legacy.enabled
        }
        return slot.defaultVisible
    }

    private static func defaultQuotaWindowID(in windows: [QuotaWindow]) -> String? {
        if let fiveHour = windows.first(where: { $0.id == "five_hour" || $0.label == "5-hour" }) {
            return fiveHour.id
        }
        return windows.min { lhs, rhs in
            windowRank(lhs) < windowRank(rhs)
        }?.id
    }

    private static func windowRank(_ window: QuotaWindow) -> Int {
        let label = window.label.lowercased()
        if label.contains("hour") || label.hasSuffix("h") { return 0 }
        if label.contains("day") || label.hasSuffix("d") { return 1 }
        return 2
    }

    /// The effective config to render/customize from: saved config (or default),
    /// normalized so an "icon" entry always exists.
    private static func baseConfig(_ model: AppViewModel, for slot: MenuBarSlot) -> [MenuBarItem] {
        var base = storedConfig(for: slot).isEmpty ? autoDefault(model, for: slot) : storedConfig(for: slot)
        if !base.contains(where: { $0.key == "icon" }) {
            base.insert(MenuBarItem(key: "icon", enabled: true), at: 0)
        }
        return base
    }

    /// Config merged with what's currently available: stored items kept in order
    /// (dropping ones no longer present), then newly-seen items appended (off).
    static func merged(_ model: AppViewModel, for slot: MenuBarSlot) -> [(item: MenuBarItem, name: String)] {
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

    /// A single item's current caption + value for the settings preview chips.
    static func preview(_ key: String, _ model: AppViewModel, slot: MenuBarSlot) -> MenuBarSegment? {
        resolve(key, model)?.segment
    }

    /// Enabled elements in order, resolved against the model.
    static func activeElements(_ model: AppViewModel, slot: MenuBarSlot, limit: Int? = nil) -> [MenuBarElement] {
        let enabled = baseConfig(model, for: slot).filter(\.enabled)
        let maxItems = limit ?? slot.menuBarLimit

        var out: [MenuBarElement] = []
        for item in enabled {
            if item.key == "icon" {
                out.append(.icon(icon(for: slot)))
                continue
            }
            guard let r = resolve(item.key, model) else { continue }
            out.append(.segment(r.segment))
        }
        return Array(out.prefix(maxItems))
    }

    static func visibleSlots(_ model: AppViewModel) -> [MenuBarSlot] {
        MenuBarSlot.allCases.filter { !activeElements(model, slot: $0).isEmpty }
    }

    static func canHideSlot(_ model: AppViewModel, slot: MenuBarSlot) -> Bool {
        MenuBarSlot.allCases.contains { candidate in
            candidate != slot && !activeElements(model, slot: candidate).isEmpty
        }
    }

    /// The value columns only, for the alert level and accessibility text.
    static func activeSegments(_ model: AppViewModel, slot: MenuBarSlot, limit: Int? = nil) -> [MenuBarSegment] {
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

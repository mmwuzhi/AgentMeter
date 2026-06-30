import Foundation

/// One configurable menu-bar item: a stable key plus whether it's shown. Order in
/// the stored array is the left→right order in the menu bar.
struct MenuBarItem: Codable, Identifiable, Equatable, Sendable {
    let key: String     // "q:codex:primary", "q:claude:five_hour", "s:codex", …
    var enabled: Bool
    var id: String { key }
}

/// A resolved item ready to draw.
struct MenuBarSegment: Equatable {
    let label: String       // caption (short)
    let value: String       // value line
    let remaining: Double?  // 0…100 for quota items; nil for spend (drives the alert dot)
}

/// One thing the menu bar draws, in config order: the gauge glyph or a value column.
/// The icon is just another orderable/hideable item (key "icon").
enum MenuBarElement: Equatable {
    case icon
    case segment(MenuBarSegment)
}

/// Source of truth for which items the menu bar shows, in what order. Bridges the
/// persisted config (UserDefaults) and the live `AppViewModel`. iStat-style: the
/// user picks items and orders them; everything resolves dynamically.
@MainActor
enum MenuBarLayout {
    static let configKey = "menuBarItemsConfig"

    private static func provider(_ code: String) -> Provider? {
        code == "codex" ? .codex : (code == "claude" ? .claude : nil)
    }

    private static func state(_ p: Provider, _ model: AppViewModel) -> ProviderState {
        p == .codex ? model.codex : model.claude
    }

    // MARK: - Persistence

    static func storedConfig() -> [MenuBarItem] {
        guard let data = UserDefaults.standard.data(forKey: configKey),
              let items = try? JSONDecoder().decode([MenuBarItem].self, from: data) else { return [] }
        return items
    }

    static func save(_ items: [MenuBarItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: configKey)
    }

    // MARK: - Discovery

    /// Every item the live model can currently render, in canonical order
    /// (per provider: quota windows, then today's spend), with display names.
    static func available(_ model: AppViewModel) -> [(key: String, name: String)] {
        var out: [(String, String)] = [("icon", "Gauge icon")]
        for (p, name, code) in [(Provider.codex, "Codex", "codex"), (Provider.claude, "Claude", "claude")] {
            let s = state(p, model)
            for w in s.quota.windows {
                out.append(("q:\(code):\(w.id)", "\(name) · \(w.label)"))
            }
            out.append(("s:\(code)", "\(name) · spend (today)"))
        }
        return out
    }

    /// Default selection used when nothing is configured yet — preserves the older
    /// coarse toggles (menu-bar provider, show spend, both providers) so existing
    /// menu bars don't change until the user customizes.
    private static func autoDefault(_ model: AppViewModel) -> [MenuBarItem] {
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

    /// The effective config to render/customize from: the saved config (or the
    /// legacy-toggle default), normalized so an "icon" entry always exists. Older
    /// configs predate the icon item; insert it at the front enabled per the legacy
    /// `menuBarShowIcon` toggle so existing menu bars keep their leading gauge.
    private static func baseConfig(_ model: AppViewModel) -> [MenuBarItem] {
        var base = storedConfig().isEmpty ? autoDefault(model) : storedConfig()
        if !base.contains(where: { $0.key == "icon" }) {
            let showIcon = UserDefaults.standard.object(forKey: "menuBarShowIcon") as? Bool ?? true
            base.insert(MenuBarItem(key: "icon", enabled: showIcon), at: 0)
        }
        return base
    }

    /// Config merged with what's currently available: stored items kept in order
    /// (dropping ones no longer present), then newly-seen items appended (off).
    /// Falls back to `autoDefault` when there's no saved config.
    static func merged(_ model: AppViewModel) -> [(item: MenuBarItem, name: String)] {
        let names = Dictionary(available(model).map { ($0.key, $0.name) }, uniquingKeysWith: { a, _ in a })
        let base = baseConfig(model)

        var result: [(MenuBarItem, String)] = []
        var seen = Set<String>()
        for item in base {
            guard let name = names[item.key] else { continue }
            result.append((item, name)); seen.insert(item.key)
        }
        for (key, name) in available(model) where !seen.contains(key) {
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
                                   remaining: w.remainingPercent), p)
        case "s":
            return (MenuBarSegment(label: "$",
                                   value: String(format: "%.2f", model.todaySpendUSD(for: s)),
                                   remaining: nil), p)
        default:
            return nil
        }
    }

    /// A single item's current caption + value for the settings preview chips,
    /// always provider-prefixed so each chip is unambiguous (`cx 5h`, `cl wk`, `cx $`).
    static func preview(_ key: String, _ model: AppViewModel) -> MenuBarSegment? {
        guard let (seg, p) = resolve(key, model) else { return nil }
        let code = p == .codex ? "cx" : "cl"
        return MenuBarSegment(label: "\(code) \(seg.label)", value: seg.value, remaining: seg.remaining)
    }

    /// Enabled elements in order (icon + value columns), resolved against the model.
    /// When the active columns span both providers, captions are prefixed (`cx`/`cl`).
    static func activeElements(_ model: AppViewModel, limit: Int = 6) -> [MenuBarElement] {
        let enabled = baseConfig(model).filter(\.enabled)
        let resolved = enabled.filter { $0.key != "icon" }.compactMap { resolve($0.key, model) }
        let mixed = Set(resolved.map(\.provider)).count > 1

        var out: [MenuBarElement] = []
        for item in enabled {
            if item.key == "icon" { out.append(.icon); continue }
            guard let r = resolve(item.key, model) else { continue }
            if mixed {
                let code = r.provider == .codex ? "cx" : "cl"
                out.append(.segment(MenuBarSegment(label: "\(code) \(r.segment.label)",
                                                   value: r.segment.value, remaining: r.segment.remaining)))
            } else {
                out.append(.segment(r.segment))
            }
        }
        return Array(out.prefix(limit))
    }

    /// The value columns only (no icon) — for the alert level and accessibility text.
    static func activeSegments(_ model: AppViewModel, limit: Int = 6) -> [MenuBarSegment] {
        activeElements(model, limit: limit).compactMap {
            if case .segment(let s) = $0 { return s }
            return nil
        }
    }
}

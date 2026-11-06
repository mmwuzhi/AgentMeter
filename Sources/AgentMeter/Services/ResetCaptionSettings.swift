import Foundation

/// The raw values are stored; Settings calls `window` "Period".
enum ResetCaptionMode: String, CaseIterable, Identifiable {
    case window
    case countdown
    case both

    static let defaultsKey = "menuBarResetCaptionMode"

    var id: String { rawValue }

    /// The stored preference; anything unrecognised reads as the default.
    static var current: ResetCaptionMode {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(ResetCaptionMode.init(rawValue:)) ?? .window
    }

    var title: String {
        switch self {
        case .window: return "Period"
        case .countdown: return "Countdown"
        case .both: return "Both"
        }
    }

    /// The caption of a window coded `code` (`5h`) with `countdown` left.
    func caption(code: String, countdown: String) -> String {
        switch self {
        case .window: return code
        case .countdown: return countdown
        case .both: return "\(code) \(countdown)"
        }
    }

    /// What this mode shows for a 5-hour window with 1 h 21 min left, built
    /// by the formatter and `caption` the menu bar uses, so Settings cannot
    /// describe a format the menu bar no longer draws.
    var example: String {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        let countdown = ResetCountdown.text(until: now.addingTimeInterval(81 * 60), now: now) ?? ""
        return caption(code: "5h", countdown: countdown)
    }
}

/// An sRGB colour for a countdown, kept free of AppKit so the segment stays a
/// plain value.
struct ResetTint: Equatable {
    let red: Double
    let green: Double
    let blue: Double
}

/// The colour chosen for each quota window's countdown. It is bound to the
/// window's identity (`claude:seven_day_fable`), never to a position in the
/// layout, so dragging fields around cannot move a colour from one quota to
/// another, and two weeklies are two entries. A window with no entry keeps the
/// system text colour. Stored as one JSON object of `"RRGGBB"` strings under a
/// key of its own: the layout array is rebuilt from bare keys on every drop.
enum ResetCaptionColors {
    static let defaultsKey = "menuBarResetColors"

    static func key(provider: Provider, windowID: String) -> String {
        "\(provider.rawValue):\(windowID)"
    }

    /// The stored JSON as it sits in defaults, "" when nothing was chosen.
    static var storedJSON: String {
        UserDefaults.standard.string(forKey: defaultsKey) ?? ""
    }

    /// Entries that are not a six-digit hex colour are dropped rather than
    /// guessed at.
    static func decode(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return raw.filter { tint(hex: $0.value) != nil }
    }

    static func encode(_ colors: [String: String]) -> String {
        guard let data = try? JSONEncoder().encode(colors),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return json
    }

    static func tint(forKey key: String, in json: String = storedJSON) -> ResetTint? {
        decode(json)[key].flatMap(tint(hex:))
    }

    /// `json` with `key` set to `hex`, or without it when `hex` is nil (back to
    /// the system text colour); "" once no window has a colour.
    static func setting(_ hex: String?, forKey key: String, in json: String) -> String {
        var colors = decode(json)
        colors[key] = hex
        return colors.isEmpty ? "" : encode(colors)
    }

    static func store(_ hex: String?, forKey key: String, in defaults: UserDefaults = .standard) {
        let json = setting(hex, forKey: key, in: defaults.string(forKey: defaultsKey) ?? "")
        defaults.set(json, forKey: defaultsKey)
    }

    static func tint(hex: String) -> ResetTint? {
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit), let value = UInt32(hex, radix: 16) else { return nil }
        return ResetTint(red: Double((value >> 16) & 0xFF) / 255,
                         green: Double((value >> 8) & 0xFF) / 255,
                         blue: Double(value & 0xFF) / 255)
    }

    static func hex(red: Double, green: Double, blue: Double) -> String {
        func byte(_ component: Double) -> UInt32 { UInt32((min(1, max(0, component)) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}

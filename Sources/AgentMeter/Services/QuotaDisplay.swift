import Foundation

/// Whether quota figures read as the share left or the share spent.
///
/// One switch covers the popover rows and the menu bar together. A meter that
/// fills toward the limit and a headline that counts down from it are both
/// defensible; the same window shown from opposite ends on two surfaces at once
/// is the reading nobody gets right, so the preference is deliberately not
/// per-surface.
///
/// Only the rendering turns over. `QuotaWindow.remainingPercent`,
/// `QuotaColor.forRemaining`, `MenuBarLayout.alertLevel(forRemaining:)` and the
/// notification copy all keep speaking in remainder, so "how low is low" has one
/// definition whichever way the rows are drawn.
enum QuotaDisplay {
    static let defaultsKey = "quotaShowsUsed"

    /// Defaults to the remainder, which is what the app has always shown.
    static var showsUsed: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? false
    }

    /// The figure to render for a window. `remaining` is expected clamped —
    /// `QuotaWindow.remainingPercent` is, `usedPercent` is not.
    static func percent(remaining: Double, showsUsed: Bool) -> Double {
        let bounded = max(0, min(100, remaining))
        return showsUsed ? 100 - bounded : bounded
    }

    /// The word that names which end the figure counts from. Spoken form: the
    /// menu bar's accessibility summary reads "5h 85% used", where the bare
    /// number would otherwise be read as the remainder.
    static func word(showsUsed: Bool) -> String {
        showsUsed ? "used" : "left"
    }

    /// The caption that follows the figure in the popover, built from `word` so
    /// the two can never disagree about which end they are counting from.
    static func caption(showsUsed: Bool) -> String {
        "% " + word(showsUsed: showsUsed)
    }
}

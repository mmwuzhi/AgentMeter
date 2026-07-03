# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

AgentMeter is a menu-bar-only (no Dock icon) macOS app showing Codex, Claude Code, and GitHub Copilot usage: quota bars, quota runway risk, a usage heatmap, and estimated spend where available. It is local-first — it reuses the existing CLI logins, so there are no API keys. Requires the Xcode toolchain (Xcode 16+ / Swift 6); SwiftPM executable target, `.macOS(.v14)`, Swift 6 language mode.

## Commands

```bash
make run      # build release, assemble dist/AgentMeter.app, launch it
make debug    # swift build (debug) + run ./.build/debug/AgentMeter from the terminal
make app      # just assemble dist/AgentMeter.app (runs Scripts/bundle.sh)
make dmg      # package dist/AgentMeter-<version>.dmg
make appcast  # regenerate dist/appcast.xml for the latest DMG
make clean    # rm -rf .build dist
```

GitHub Actions release automation lives in `.github/workflows/release.yml`.
Pushing a `vX.Y.Z` tag or manually running the **Release** workflow builds the
DMG, verifies bundle contents/version/signature, uploads workflow artifacts, and
creates or updates the GitHub Release. Sparkle appcast generation remains manual
because it needs the private Sparkle signing key.

There is a small XCTest suite (`swift test`) and no linter configured. For UI or menu-bar visual changes, also run the app and look at it.

- **Flaky build error** "input file ... was modified during the build": a running AgentMeter instance touches files SwiftPM is reading. Just re-run `make run` — it succeeds on the second try. `make run` does not kill the old instance, so relaunching leaves the previous process; `pkill -f "AgentMeter.app"` before rebuilding when iterating.
- **You cannot screenshot the menu bar** from this environment (the CLI lacks Screen Recording permission; `screencapture` fails with "could not create image from display"). For any menu-bar visual change, state that you cannot verify the render and hand the exact check to the user.
- **The menu-bar item is easily lost behind the notch.** macOS reassigns status-item position on every relaunch; on a crowded menu bar it lands in the hidden region. "I can't find it" almost always means hidden, not crashed — confirm the process with `pgrep -lf "AgentMeter.app"`.

## Architecture

**Launch → refresh → render** pipeline:

- `App/AppDelegate` sets `NSApp.setActivationPolicy(.accessory)` (menu-bar only) and wires the three long-lived objects: `RefreshCoordinator`, `UpdaterController`, `StatusItemController`, all sharing one `AppViewModel`.
- `Services/RefreshCoordinator` owns a configurable `Timer` (`refreshIntervalSeconds`, clamped 15…3600) plus manual `refresh()` (with a 30s watchdog so a wedged fetch can't suppress popover-open refreshes). Each refresh fetches Codex, Claude, and Copilot **in parallel** (`async let`), writes `AppViewModel.codex` / `.claude` / `.copilot`, records quota observations through `QuotaTrendTracker`, persists provider state plus observations via `StateCache` (so the next launch shows last values instantly — `AppViewModel.init` loads them), and runs `NotificationManager.evaluate` for low-quota and recovery alerts. Pricing is refreshed once at `start()`.
- `ViewModels/AppViewModel` is `@MainActor @Observable`. It is the single source of UI truth. `MenuBarLayout.activeElements(_:)` resolves the configured menu-bar items from the model, while `AppViewModel.runway(for:window:)` exposes per-window runway predictions to the popover.
- `Controllers/StatusItemController` owns the `NSStatusItem` + the transient popover hosting `MenuView`. It uses `withObservationTracking` to re-render the menu-bar title when the model changes, and listens to `UserDefaults.didChangeNotification` so Settings changes update the menu bar immediately.
- `Views/Menu/MenuView` is the popover root (SwiftUI). `SettingsView` is a separate `Settings` scene (`AgentMeterApp`).

**Per-provider data flow** — `CodexService`, `ClaudeService`, and `CopilotService` each return a `ProviderState(quota:usage:)` (`Models/Models.swift`). Providers use fallback chains where possible, and the source actually used is reported back via `QuotaSnapshot.source` (shown in the UI as "live" / "local log" / "oauth" / "cli" / "usage only"):

- **Codex quota**: `AppServerSession` (`codex app-server` JSON-RPC) → falls back to `CodexRolloutReader` parsing the newest `~/.codex/sessions/**/rollout-*.jsonl` `rate_limits`. Usage/spend = per-day `last_token_usage` summed from rollout logs. **`CodexRolloutReader.rolloutFiles()` must enumerate BOTH `~/.codex/sessions/` (date-nested) and `~/.codex/archived_sessions/` (flat).** Codex CLI ≥0.142 moves older/inactive sessions into `archived_sessions/`; reading only `sessions/` makes today's usage/spend collapse the moment a still-active session is archived mid-day (quota stays server-truth via app-server, so the symptom is "quota heavy / spend light"). Files are deduped by name so a session caught mid-move in both roots is not double-counted.
- **Claude quota**: `ClaudeCredentials` (token from `~/.claude/.credentials.json` → Keychain `Claude Code-credentials`) → `ClaudeOAuthFetcher` (`GET api.anthropic.com/api/oauth/usage`) → `ClaudeCLIScraper` (scrape `claude /usage`) → usage-only. **Claude quota requires the network** (reset windows are not on disk); first OAuth read may prompt the Keychain. Usage/spend = `ClaudeJSONLScanner` over `~/.claude/projects/**/*.jsonl`, deduped by `message.id`. **Spend-based plans (e.g. Enterprise) have no `five_hour`/`seven_day*` keys at all** — `ClaudeOAuthFetcher.parseSnapshot` treats an empty `windows` result as a legitimate plan shape, not a parse failure, and dumps the raw body to `~/Library/Application Support/AgentMeter/debug-claude-oauth-usage.json` (capped at 256KB) so real field names can be confirmed instead of guessed. The one confirmed field so far is a one-time Claude Code + Cowork credit exposed under an opaque, Anthropic-assigned codename (currently `cinder_cove`) rather than a fixed key — it's wired through `add(...)` like the other windows but flagged `isOneTimeCredit: true` so `QuotaRow` says "expires" instead of "resets". If Anthropic rotates the codename, this silently stops matching (falls back to the empty-windows note) rather than parsing something wrong — re-check the debug capture file if that happens.
- **Copilot quota**: `CopilotGitHubClient` shells out to `gh api /copilot_internal/user` (reusing the existing `gh` login — token stays in gh's keyring, never read here). Parses `quota_snapshots` into metered windows (e.g. `premium_interactions`), skipping `unlimited` ones; `gh` missing or not authed → unavailable. `copilot_internal` is an undocumented internal endpoint (the one editors use), so its shape can change. Copilot is **flat-rate — no spend/usage history** (`usage` is always empty, so its popover panel shows quota only and `MenuBarLayout` offers no `s:copilot` item).
- **Pricing** (`Services/Pricing/PricingService`): LiteLLM → models.dev fallback → embedded `Resources/embedded-pricing.json`; cached to `~/Library/Application Support/AgentMeter/pricing.json`.
- **Quota trend layer** (`Services/QuotaTrendTracker`): records bounded per-refresh observations (24h / 200 samples) in `StateCache` and derives runway from remaining-percent drain. It only shows popover runway text when current pace would hit that same window before reset; longer windows are suppressed when a shorter same-provider hard limit would stop usage first. A 2-sample instantaneous drain rate is only trusted to extrapolate up to `maxExtrapolationMultiplier` (6x) the timespan it was actually observed over — a short burst projected across a long-horizon window (weekly, or a months-long one-time credit) downgrades from `.atRisk` to `.watch` instead of producing a "would run out in N days" alarm no sustained usage pattern would ever hit.

### Conventions and gotchas

- **`@AppStorage` keys are the settings contract**, written in `SettingsView`, read in multiple places: `menuBarItemsConfig` (the ordered, per-item visible/hidden list — single source of truth for the menu bar, owned by `MenuBarLayout`) + `menuBarShowCaptions`, `popoverOrder` / `popoverHiddenProviders` (provider panels; `PopoverOrder` seeds legacy `codexFirst`, starts Copilot hidden by default, and backfills new providers), `refreshIntervalSeconds`, `warnThresholdPercent` / `alertThresholdPercent` / `alertsEnabled` / `quotaRecoveryNotificationsEnabled` (notifications), `launchAtLogin` (`Services/LoginItem`). The older coarse toggles (`menuBarProvider`, `showPercentInMenuBar`, `showSpendInMenuBar`, `menuBarBothProviders`, `menuBarShowIcon`) survive only as migration defaults in `MenuBarLayout.autoDefault`/`baseConfig`. Adding a setting: wire it and remember the menu-bar live-update path goes through the `UserDefaults.didChangeNotification` observer.
- **Menu-bar content is drawn live, not titled or rasterized.** `Views/MenuBarContentView` is an `NSView` hosted as a subview of the status button (`button.image = NSImage()` reserves the frame; the subview passes clicks through). It draws an ordered list of `MenuBarElement`s (gauge icon + caption/value columns) in `draw(_:)` at native backing scale via baseline-anchored `NSAttributedString.draw(with:)`, mirroring Stats' `Mini` widget. Do **not** go back to a template `NSImage` — template conversion thins out small/light text. Pick colors by appearance (`NSAppearance.currentDrawing()` → white / `.textColor`); each low-quota dot is drawn beside the specific quota segment that triggered it, never as a global corner indicator. `MenuBarLayout` resolves which elements show, in what order, from `menuBarItemsConfig`.
- **Accessory apps open Settings inactive**, which desaturates Toggle/Picker accent colors so on/off look identical. `SettingsView.onAppear` calls `NSApp.activate` + `makeKeyAndOrderFront` to fix it. Gray window traffic-lights are the tell that a window is not key.
- **Quota window short labels** (`QuotaWindow.shortLabel`, e.g. `5h` / `7d`) are derived from the human label and used only in the menu bar; the popover (`QuotaRow`) shows the full `label`. Token counts are formatted everywhere through `TokenFormat.short` (k/M/B/T) — do not reintroduce per-site formatting.
- **Threshold color** (`QuotaColor.forRemaining`) is the green→red scale for the in-popover quota bar and headline %; it is intentionally NOT used in the menu bar.
- **Empty `windows` is not automatically a failure state.** `ProviderSection` (`MenuView.swift`) only shows the red `exclamationmark.triangle` icon when `quota.source == .unavailable` (a genuine fetch failure); any other source with empty windows (e.g. a spend-based Claude plan that fetched fine but has no rate-limit windows) shows a neutral `info.circle` instead. Don't reuse the triangle for "this plan just doesn't have windows."

### Packaging

SwiftPM produces only a bare executable; `Scripts/bundle.sh` assembles the `.app`: copies the binary, the SPM resource bundle (`AgentMeter_AgentMeter.bundle`), a loose `embedded-pricing.json` for `Bundle.main`, `AppIcon.icns`, and `Sparkle.framework`; substitutes versions into `Scripts/Info.plist`; adds an `@executable_path/../Frameworks` rpath; ad-hoc signs (framework first, then app). `Scripts/dmg.sh` uses `dmgbuild` for the styled installer window and falls back to a plain `hdiutil` DMG when `dmgbuild` is unavailable. The app is ad-hoc signed and local-only — on another Mac clear quarantine with `xattr -dr com.apple.quarantine`.

**Sparkle auto-update is wired but inert** until you set `SUPublicEDKey` + `SUFeedURL` in `Scripts/Info.plist` and host an appcast. Until configured, "Check for Updates" shows an explainer instead of crashing.

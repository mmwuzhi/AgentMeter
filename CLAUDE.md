# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

AgentMeter is a menu-bar-only (no Dock icon) macOS app showing Codex and Claude Code usage: quota bars, a usage heatmap, and estimated spend. It is local-first — it reuses the existing CLI logins, so there are no API keys. Requires the Xcode toolchain (Xcode 16+ / Swift 6); SwiftPM executable target, `.macOS(.v14)`, Swift 6 language mode.

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

There is no test suite and no linter configured. Verifying a change means running the app and looking at it.

- **Flaky build error** "input file ... was modified during the build": a running AgentMeter instance touches files SwiftPM is reading. Just re-run `make run` — it succeeds on the second try. `make run` does not kill the old instance, so relaunching leaves the previous process; `pkill -f "AgentMeter.app"` before rebuilding when iterating.
- **You cannot screenshot the menu bar** from this environment (the CLI lacks Screen Recording permission; `screencapture` fails with "could not create image from display"). For any menu-bar visual change, state that you cannot verify the render and hand the exact check to the user.
- **The menu-bar item is easily lost behind the notch.** macOS reassigns status-item position on every relaunch; on a crowded menu bar it lands in the hidden region. "I can't find it" almost always means hidden, not crashed — confirm the process with `pgrep -lf "AgentMeter.app"`.

## Architecture

**Launch → refresh → render** pipeline:

- `App/AppDelegate` sets `NSApp.setActivationPolicy(.accessory)` (menu-bar only) and wires the three long-lived objects: `RefreshCoordinator`, `UpdaterController`, `StatusItemController`, all sharing one `AppViewModel`.
- `Services/RefreshCoordinator` owns a 60s `Timer` plus manual `refresh()`. Each refresh fetches both providers **in parallel** (`async let`) and writes `AppViewModel.codex` / `.claude`. Pricing is refreshed once at `start()`.
- `ViewModels/AppViewModel` is `@MainActor @Observable`. It is the single source of UI truth. Computed properties here drive the menu bar: `headlineWindows` returns the chosen provider's quota windows (which provider is read live from `UserDefaults` key `menuBarProvider`).
- `Controllers/StatusItemController` owns the `NSStatusItem` + the transient popover hosting `MenuView`. It uses `withObservationTracking` to re-render the menu-bar title when the model changes, and listens to `UserDefaults.didChangeNotification` so Settings changes update the menu bar immediately.
- `Views/Menu/MenuView` is the popover root (SwiftUI). `SettingsView` is a separate `Settings` scene (`AgentMeterApp`).

**Per-provider data flow** — `CodexService` and `ClaudeService` each return a `ProviderState(quota:usage:)` (`Models/Models.swift`). Both use a fallback chain, so the source actually used is reported back via `QuotaSnapshot.source` (shown in the UI as "live" / "local log" / "oauth" / "cli" / "usage only"):

- **Codex quota**: `AppServerSession` (`codex app-server` JSON-RPC) → falls back to `CodexRolloutReader` parsing the newest `~/.codex/sessions/**/rollout-*.jsonl` `rate_limits`. Usage/spend = per-day `last_token_usage` summed from rollout logs.
- **Claude quota**: `ClaudeCredentials` (token from `~/.claude/.credentials.json` → Keychain `Claude Code-credentials`) → `ClaudeOAuthFetcher` (`GET api.anthropic.com/api/oauth/usage`) → `ClaudeCLIScraper` (scrape `claude /usage`) → usage-only. **Claude quota requires the network** (reset windows are not on disk); first OAuth read may prompt the Keychain. Usage/spend = `ClaudeJSONLScanner` over `~/.claude/projects/**/*.jsonl`, deduped by `message.id`.
- **Pricing** (`Services/Pricing/PricingService`): LiteLLM → models.dev fallback → embedded `Resources/embedded-pricing.json`; cached to `~/Library/Application Support/AgentMeter/pricing.json`.

### Conventions and gotchas

- **`@AppStorage` keys are the settings contract**, written in `SettingsView`, read in multiple places: `showPercentInMenuBar` + `menuBarProvider` (StatusItemController / AppViewModel), `codexFirst` (MenuView provider order), `launchAtLogin` (`Services/LoginItem`). When adding a setting, wire all three sides and remember the menu-bar live-update path goes through the `UserDefaults.didChangeNotification` observer.
- **Menu-bar text is drawn, not titled.** `NSStatusBarButton` top-aligns and won't size a multi-line `attributedTitle`, so `StatusItemController.renderImage` composes the gauge glyph + up to two quota lines into a vertically-centered **template `NSImage`** (`isTemplate = true`). Template = the system auto-contrasts it on light/dark menu bars; do not hand-pick text colors here. Two lines cap the usable font at ~10.5pt (menu-bar height is fixed). Percentages are right-aligned via a right `NSTextTab`.
- **Accessory apps open Settings inactive**, which desaturates Toggle/Picker accent colors so on/off look identical. `SettingsView.onAppear` calls `NSApp.activate` + `makeKeyAndOrderFront` to fix it. Gray window traffic-lights are the tell that a window is not key.
- **Quota window short labels** (`QuotaWindow.shortLabel`, e.g. `5h` / `7d`) are derived from the human label and used only in the menu bar; the popover (`QuotaRow`) shows the full `label`. Token counts are formatted everywhere through `TokenFormat.short` (k/M/B/T) — do not reintroduce per-site formatting.
- **Threshold color** (`QuotaColor.forRemaining`) is the green→red scale for the in-popover quota bar and headline %; it is intentionally NOT used in the menu bar.

### Packaging

SwiftPM produces only a bare executable; `Scripts/bundle.sh` assembles the `.app`: copies the binary, the SPM resource bundle (`AgentMeter_AgentMeter.bundle`, holding `embedded-pricing.json`), and `Sparkle.framework`; substitutes versions into `Scripts/Info.plist`; adds an `@executable_path/../Frameworks` rpath; ad-hoc signs (framework first, then app). The app is ad-hoc signed and local-only — on another Mac clear quarantine with `xattr -dr com.apple.quarantine`.

**Sparkle auto-update is wired but inert** until you set `SUPublicEDKey` + `SUFeedURL` in `Scripts/Info.plist` and host an appcast. Until configured, "Check for Updates" shows an explainer instead of crashing.


---
# (merged from AGENTS.md on 2026-06-25)

# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

AgentMeter is a menu-bar-only (no Dock icon) macOS app showing Codex and Codex usage: quota bars, a usage heatmap, and estimated spend. It is local-first — it reuses the existing CLI logins, so there are no API keys. Requires the Xcode toolchain (Xcode 16+ / Swift 6); SwiftPM executable target, `.macOS(.v14)`, Swift 6 language mode.

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

There is no test suite and no linter configured. Verifying a change means running the app and looking at it.

- **Flaky build error** "input file ... was modified during the build": a running AgentMeter instance touches files SwiftPM is reading. Just re-run `make run` — it succeeds on the second try. `make run` does not kill the old instance, so relaunching leaves the previous process; `pkill -f "AgentMeter.app"` before rebuilding when iterating.
- **You cannot screenshot the menu bar** from this environment (the CLI lacks Screen Recording permission; `screencapture` fails with "could not create image from display"). For any menu-bar visual change, state that you cannot verify the render and hand the exact check to the user.
- **The menu-bar item is easily lost behind the notch.** macOS reassigns status-item position on every relaunch; on a crowded menu bar it lands in the hidden region. "I can't find it" almost always means hidden, not crashed — confirm the process with `pgrep -lf "AgentMeter.app"`.

## Architecture

**Launch → refresh → render** pipeline:

- `App/AppDelegate` sets `NSApp.setActivationPolicy(.accessory)` (menu-bar only) and wires the three long-lived objects: `RefreshCoordinator`, `UpdaterController`, `StatusItemController`, all sharing one `AppViewModel`.
- `Services/RefreshCoordinator` owns a 60s `Timer` plus manual `refresh()`. Each refresh fetches both providers **in parallel** (`async let`) and writes `AppViewModel.codex` / `.Codex`. Pricing is refreshed once at `start()`.
- `ViewModels/AppViewModel` is `@MainActor @Observable`. It is the single source of UI truth. Computed properties here drive the menu bar: `headlineWindows` returns the chosen provider's quota windows (which provider is read live from `UserDefaults` key `menuBarProvider`).
- `Controllers/StatusItemController` owns the `NSStatusItem` + the transient popover hosting `MenuView`. It uses `withObservationTracking` to re-render the menu-bar title when the model changes, and listens to `UserDefaults.didChangeNotification` so Settings changes update the menu bar immediately.
- `Views/Menu/MenuView` is the popover root (SwiftUI). `SettingsView` is a separate `Settings` scene (`AgentMeterApp`).

**Per-provider data flow** — `CodexService` and `ClaudeService` each return a `ProviderState(quota:usage:)` (`Models/Models.swift`). Both use a fallback chain, so the source actually used is reported back via `QuotaSnapshot.source` (shown in the UI as "live" / "local log" / "oauth" / "cli" / "usage only"):

- **Codex quota**: `AppServerSession` (`codex app-server` JSON-RPC) → falls back to `CodexRolloutReader` parsing the newest `~/.codex/sessions/**/rollout-*.jsonl` `rate_limits`. Usage/spend = per-day `last_token_usage` summed from rollout logs.
- **Codex quota**: `ClaudeCredentials` (token from `~/.Codex/.credentials.json` → Keychain `Codex-credentials`) → `ClaudeOAuthFetcher` (`GET api.anthropic.com/api/oauth/usage`) → `ClaudeCLIScraper` (scrape `Codex /usage`) → usage-only. **Codex quota requires the network** (reset windows are not on disk); first OAuth read may prompt the Keychain. Usage/spend = `ClaudeJSONLScanner` over `~/.Codex/projects/**/*.jsonl`, deduped by `message.id`.
- **Pricing** (`Services/Pricing/PricingService`): LiteLLM → models.dev fallback → embedded `Resources/embedded-pricing.json`; cached to `~/Library/Application Support/AgentMeter/pricing.json`.

### Conventions and gotchas

- **`@AppStorage` keys are the settings contract**, written in `SettingsView`, read in multiple places: `showPercentInMenuBar` + `menuBarProvider` (StatusItemController / AppViewModel), `codexFirst` (MenuView provider order), `launchAtLogin` (`Services/LoginItem`). When adding a setting, wire all three sides and remember the menu-bar live-update path goes through the `UserDefaults.didChangeNotification` observer.
- **Menu-bar text is drawn, not titled.** `NSStatusBarButton` top-aligns and won't size a multi-line `attributedTitle`, so `StatusItemController.renderImage` composes the gauge glyph + up to two quota lines into a vertically-centered **template `NSImage`** (`isTemplate = true`). Template = the system auto-contrasts it on light/dark menu bars; do not hand-pick text colors here. Two lines cap the usable font at ~10.5pt (menu-bar height is fixed). Percentages are right-aligned via a right `NSTextTab`.
- **Accessory apps open Settings inactive**, which desaturates Toggle/Picker accent colors so on/off look identical. `SettingsView.onAppear` calls `NSApp.activate` + `makeKeyAndOrderFront` to fix it. Gray window traffic-lights are the tell that a window is not key.
- **Quota window short labels** (`QuotaWindow.shortLabel`, e.g. `5h` / `7d`) are derived from the human label and used only in the menu bar; the popover (`QuotaRow`) shows the full `label`. Token counts are formatted everywhere through `TokenFormat.short` (k/M/B/T) — do not reintroduce per-site formatting.
- **Threshold color** (`QuotaColor.forRemaining`) is the green→red scale for the in-popover quota bar and headline %; it is intentionally NOT used in the menu bar.

### Packaging

SwiftPM produces only a bare executable; `Scripts/bundle.sh` assembles the `.app`: copies the binary, the SPM resource bundle (`AgentMeter_AgentMeter.bundle`, holding `embedded-pricing.json`), and `Sparkle.framework`; substitutes versions into `Scripts/Info.plist`; adds an `@executable_path/../Frameworks` rpath; ad-hoc signs (framework first, then app). The app is ad-hoc signed and local-only — on another Mac clear quarantine with `xattr -dr com.apple.quarantine`.

**Sparkle auto-update is wired but inert** until you set `SUPublicEDKey` + `SUFeedURL` in `Scripts/Info.plist` and host an appcast. Until configured, "Check for Updates" shows an explainer instead of crashing.

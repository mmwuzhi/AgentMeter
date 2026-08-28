# UI and persisted-state invariants

Read this file before changing menu-bar rendering, popover views, settings,
usage presentation, cached state, or Claude live-session integration.

## State and settings

- `AppViewModel` is the `@MainActor @Observable` source of UI truth.
  `RefreshCoordinator` fetches providers in parallel, updates the model, records
  quota observations, persists state through `StateCache`, and evaluates
  notifications.
- `@AppStorage` keys are a compatibility contract. Current keys include
  `menuBarItemsConfig` (plus per-slot `menuBarItemsConfig.<slot>` variants),
  `menuBarSlotsConfig`, `menuBarShowCaptions`, `refreshIntervalSeconds`,
  threshold and notification settings, `launchAtLogin`,
  `statusHooksEnabled`, and `claudeOAuthSucceededOnce` (gates the one-time
  Keychain primer in the popover).
- `MenuBarLayout` owns which fields each status item shows, in what order.
  `MenuBarSlots` owns which status items exist and starts Copilot hidden by
  default; newly-seen fields are backfilled disabled.
- Older toggles (`menuBarProvider`, `showPercentInMenuBar`,
  `showSpendInMenuBar`, `menuBarBothProviders`, `menuBarShowIcon`) are migration
  inputs only.
- When adding a setting, wire every reader and preserve the live menu-bar update
  path through `UserDefaults.didChangeNotification`.

## Menu bar and popover

- Menu-bar content is drawn live by `MenuBarContentView`, hosted inside the
  status button. Do not revert to a template `NSImage`; template conversion
  thins small/light text.
- Never draw beyond `statusItem.length`. Secondary displays clip replicas to
  the declared width. Tighten slot gaps through the registered
  `NSStatusItemSpacing` / `NSStatusItemSelectionPadding` defaults instead.
- Draw with native backing scale and baseline-anchored attributed strings.
  Resolve color from `NSAppearance.currentDrawing()` (`white` or
  `.textColor`).
- A low-quota dot belongs beside the exact quota segment that triggered it,
  never in a global corner. `.bar` elements carry the same cue in the gauge
  fill itself (yellow/red) instead of a separate dot.
- `QuotaWindow.shortLabel` is menu-bar-only; `QuotaRow` shows the full label.
  Format all token counts with `TokenFormat.short`.
- `QuotaColor.forRemaining` is for popover bars and headline percentages, not
  the menu bar.
- Accessory apps can open Settings inactive, making Toggle/Picker states look
  identical. Keep `SettingsView.onAppear` activation and
  `makeKeyAndOrderFront`; gray traffic lights indicate a non-key window.
- `ProviderSection` shows the red triangle only when
  `quota.source == .unavailable`. A successful source with no windows uses the
  neutral info icon.

## Spend and usage

- The popover's all-time spend comes from `LifetimeSpendTracker`, not from a
  scan-window sum. It keeps one record per provider/day using per-day max merge
  semantics.
- `LifetimeSpendStore` in `lifetime-spend.json` is authoritative. The
  `StateCache` copy exists only for compatibility because older builds rewrite
  `last-state.json` without unknown fields.
- `UsageReport.totalCostUSD`, `totalTokens`, and `byModel` are clamped to
  `UsageReport.totalsWindowDays` (30 days). `buckets` may retain older dates for
  the heatmap because recently touched log files can contain old sessions.
- Any UI labeled “30-day” must use `SpendWindows`; never sum all buckets.

## Claude live sessions

- Live Claude status is opt-in and must preserve user hooks.
- `ClaudeHookInstaller` parses and backs up `~/.claude/settings.json`. It may
  remove only commands whose executable basename is exactly
  `agentmeter-hook`; never delete or replace a whole matcher group that may
  contain user commands.
- Hook metadata comes from the official stdin JSON contract (`session_id`,
  `cwd`, and event fields), not guessed environment variables.
- The bundled helper writes bounded per-session JSON through
  `AgentStatusCore`. Process ancestry distinguishes sessions that share a
  directory.

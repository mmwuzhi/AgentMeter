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
- The pace and run-out lines both show at once; neither replaces the other.
  `QuotaRow.pace` renders `now X%/h · avg Y%/h · budget Z%/h` — `now` is
  dropped when the tracker has nothing recent enough, and the line is nil
  without an `avg`. `QuotaRow.alertLine` adds the run-out estimate on a second
  line for every `.atRisk` runway carrying a depletion date, red inside
  `alertLeadTime` (30 min) and orange beyond it. Gating the estimate on the
  lead time hid exactly the question the user was asking — "how long at this
  pace" is needed well before the last half hour. When `QuotaRunway.pacedBy`
  is set the tracker floored the date at what a shorter limit allows; the line
  reads the same and only the tooltip says so, since the view never re-derives
  that decision.
- The pace line colors on `now` (falling back to `avg`) versus budget, not on
  `avg`: a burst that just started is still under the 20-minute average, and
  after the user stops, the average keeps nagging for 20 more minutes.
- The pace line renders per `QuotaRunway.paceStyle`, which only
  `QuotaTrendTracker` decides (windows resetting within `longWindowHorizon`
  compare drain vs the even-spread budget; longer ones drop the budget segment
  and turn orange only on an `.atRisk` runway — a weekly window's even-spread
  rate sits below any active use, so a raw pace > budget check would stay
  orange whenever the user is working at all). Views must not re-derive
  window-horizon semantics from reset dates. Inside the tracker, everything
  that depends on the style — `averageSpan(for:)`, `nowAnchorsOnLatestStep(for:)`,
  `nowMayEqualAverageSpan(for:)` — is an exhaustive `switch` on
  `QuotaPaceStyle`, never an `== .paceOnly` / `!= .paceVersusBudget` test:
  two negations of a three-case enum once disagreed on `.hidden`, giving a
  nil-reset window a long-horizon `avg` and a short-horizon `now` from one call.
- The pace tooltip names the spans each rate actually covers
  (`QuotaRunway.nowSpan`/`avgSpan`), so a `now` stretched across the 15-minute
  background refresh cadence says so instead of implying it is instantaneous.
  `QuotaRunway.nowAnchor` says how the span was chosen, and the tooltip puts
  words to that rather than to the style: `.step` ("runs from the step before
  the latest whole-point step"), `.lookback` ("fewer than two steps landed in
  the last hour"), nothing for `.burst`/`.slice`. It once said "stretches to
  the latest step" for every long-window `now`, including hours with no step.
- Accessory apps can open Settings inactive, making Toggle/Picker states look
  identical. Keep `SettingsView.onAppear` activation and
  `makeKeyAndOrderFront`; gray traffic lights indicate a non-key window.
- `ProviderSection` shows the red triangle only when
  `quota.source == .unavailable`. A successful source with no windows uses the
  neutral info icon.
- The popover's provider sections live in a `ScrollView` capped to the hosting
  screen's visible height (`MenuView.sectionsCap`, fed by
  `AppViewModel.popoverScreenVisibleHeight`, which the status item controller
  records on each open); header and footer stay fixed. Never let popover
  content grow the window past the screen, including a smaller secondary one.
- A session row names the model behind its newest tokens
  (`ActiveAgentSession.model`, shortened by `ModelLabel.short`), because which
  model a session is burning is what decides whether its spend is reasonable,
  and sessions in one project routinely differ. The row shows the short form
  and the tooltip the full id. `ModelLabel` only strips and reshapes an
  untrusted provider id — it never maps one to a nicer name from a table, and
  it returns nil for the `default`/`<synthetic>` placeholders so no row prints
  a model no provider reported.
- The model reported is the one behind the newest *counted* record, not the
  newest one named. A Codex `turn_context` can name a model before that turn
  spends anything, and a session that has produced no tokens under a model is
  not running it yet.
- The reasoning effort sits right after the model on the row
  (`ActiveAgentSession.effort`, via `SessionLabel.effort`) because it multiplies
  the model's cost. It is read from the same newest counted record: Claude
  writes `effort` at the record's top level, beside `type`, not inside
  `message`, and `perTurnEffort` only repeats it when set. A record without the
  key reports none rather than carrying a stale value forward. Codex rollouts
  never record one (`reasoning_effort` is nested under `turn_context` and null),
  so Codex rows show no effort.
- A session's title (`ActiveAgentSession.title`, via `SessionLabel.title`)
  takes the identity slot: it replaces branch/tty/PID as an in-group row's
  title and stands beside the project name on a lone row, with the branch
  moving into the tooltip. Claude writes titles on their own records,
  `ai-title` / `custom-title`, which carry no `usage`, so `consumeClaude`
  pre-filters on `-title"` too. A user-set custom title outranks the generated
  one whatever order they were written in (a generated title routinely lands
  after a custom one); an empty custom title is the user clearing theirs.
  Codex titles live in `~/.codex/state_5.sqlite`, not the rollout, and are not
  read. Both title and effort are untrusted provider text, and so is the
  transcript's `gitBranch` (`ActiveAgentSession.displayBranch`): `SessionLabel`
  drops control characters, collapses whitespace and caps the length in
  characters *and* in scalars, because one base letter under a hundred
  thousand combining marks is a single `Character`. The identity slot's
  precedence (title, else branch) is defined once, in `ActiveAgent.titleDetail`;
  `inGroupTitle` and the tooltip derive from it.
- `SessionUsageSummary` carries identity (model, effort, title) independently
  of spend: `tokenCount`/`estimatedCostUSD` are nil until a record has been
  counted, so a session titled before its first reply is still titled and the
  row says "No usage yet" beside it. Do not reintroduce a "no tokens, no
  summary" gate — it silently hides every identity fact until the session spends.
- A process with neither a hook-reported state nor an attributed transcript
  (`ActiveAgent.isBlank`) is dropped in `ActiveAgentService.fetch()`, so it
  never reaches the list or its counts. Such a row can only say "open now" —
  no model, no tokens, no spend. In practice these are a day's still-open
  editor tabs whose hook payload the 12-hour `AgentStatusStore.sweepStale`
  removed: a dozen of them buried the six sessions that carried information,
  and their provider-tinted dot read as more alive than the gray idle rows
  above them.
- Session groups start collapsed behind a summary (count · top status ·
  aggregated usage). Groups and subagent disclosures are automatic until the
  user toggles them: expanded exactly while waiting/error — surfacing sessions
  that need the user is the list's job, so keep that behavior when changing
  disclosure logic. Explicit choices live in `AppViewModel.sessionDisclosure`
  (keyed by group ID / `ActiveAgentNode.disclosureKey`), deliberately not
  persisted and pruned by the refresh path as groups disappear.

## Spend and usage

- The popover's all-time spend comes from `LifetimeSpendTracker`, not from a
  scan-window sum. It keeps one record per provider/day. A windowed scan can
  only grow a day; a scan flagged `UsageReport.isCompleteHistory` replaces the
  days it observed, which is the only way an over-count is ever corrected, and
  still leaves days it did not observe alone because their logs are gone.
- `LifetimeSpendStore` in `lifetime-spend.json` is authoritative. The
  `StateCache` copy exists only for compatibility because older builds rewrite
  `last-state.json` without unknown fields.
- `UsageReport.totalCostUSD`, `totalTokens`, and `byModel` are clamped to
  `UsageReport.totalsWindowDays` (30 days). `buckets` may retain older dates
  because recently touched log files can contain old sessions, but that reach is
  incidental — never rely on it for history.
- The Activity sparkline and heatmap render `[UsageDayPoint]` from
  `LifetimeSpendTracker.dayPoints(ledger:report:)`. The scanner's file window
  (`ClaudeJSONLScanner.usageHistoryDays`) only bounds what one refresh re-reads,
  so plotting `buckets` directly loses every day whose logs have not been touched
  lately. The ledger decides every day it holds — the refresh merges the report
  into it first, so it is already at least as complete, and a report restored
  from `last-state.json` must not be able to resurrect a corrected over-count.
  The report only fills days the ledger lacks. `dayPoints` drops the synthetic
  `legacyFloorDay` record, and `UsageHeatmap` scales color from the cells it
  draws, not from every point handed to it.
- Gate the Activity/Spend block on those points, not on `usage.buckets`: a
  provider idle longer than the file window has no buckets but real ledger days.
- Any UI labeled “30-day” must use `SpendWindows`; never sum all buckets.

## Claude live sessions

- Live Claude status is opt-in and must preserve user hooks.
- `ClaudeHookInstaller` parses and backs up `~/.claude/settings.json`. It may
  remove only commands whose executable basename is exactly
  `agentmeter-hook`; never delete or replace a whole matcher group that may
  contain user commands.
- Hook metadata comes from the official stdin JSON contract (`session_id`,
  `cwd`, and event fields), not guessed environment variables.
- `Stop` fires when the main agent's turn ends even while background subagents
  it launched are still running. Their tool calls still fire `PreToolUse` /
  `PostToolUse` with the parent `session_id`, but a subagent's silent thinking
  stretch writes nothing, so a plain `Stop → idle` painted such sessions gray.
  The helper's `idle` command reads `background_tasks` from the Stop input
  (`HookBackgroundTasks`, decoded leniently — hook input is untrusted) and
  records `working` plus the pending counts while anything is in flight; the
  row reads "working · N subagent(s)" (or "background task(s)" when a shell or
  MCP task is among them). The next main `Stop`, fired after the task
  notification wakes the main agent, carries an empty list and returns the row
  to idle. `SubagentStart` / `SubagentStop` stay unwired: the count already
  says what they would.
- The bundled helper writes bounded per-session JSON through
  `AgentStatusCore`. Process ancestry distinguishes sessions that share a
  directory.
- Hook-reported session IDs pin a PID to its exact transcript
  (`identifiedClaudeSession`), so per-session usage stays correct when several
  agents share a working directory. Without a hook payload, the newest-file
  heuristic applies only to a directory's single agent; ambiguous processes get
  no session rather than a guessed one. Session IDs become filenames — keep the
  charset guard.
- Per-session token totals are cached as a partial parse
  (`SessionTokenTotals`: per-model counts, the Claude dedup set, Codex's last
  seen model, and the newest effort and titles), not as the finished summary. A live transcript grows between
  every tick, so caching the summary only ever hit on an idle session; the
  partial resumes from the last consumed line boundary instead. Cache only that
  boundary — folding the trailing, not-yet-terminated record into the cached
  value would count it again once it is complete. `enrichSessionUsage` prunes
  the cache to the running sessions, because each entry now holds a dedup set.

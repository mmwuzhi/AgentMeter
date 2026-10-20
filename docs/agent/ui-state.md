# UI and persisted-state invariants

Read this file before changing menu-bar rendering, popover views, settings,
usage presentation, cached state, or Claude live-session integration.

## State and settings

- `AppViewModel` is the `@MainActor @Observable` source of UI truth.
  `RefreshCoordinator` fetches providers in parallel, updates the model, records
  quota observations, persists state through `StateCache`, and evaluates
  notifications. Claude's usage scan lands separately from the refresh that
  started it (see [providers.md](providers.md), "Refresh coordination"): the
  Activity, token and spend figures can lag the quota by the length of the
  scan, and `isRefreshing` covers the live reads only.
- `NotificationManager` asks for permission the first time an alert would
  fire and parks that evaluation behind the prompt. The parked pass
  evaluates the windows the provider handed over most recently, never the
  ones captured before the prompt: it can stay open for hours, and the
  captured reading may have reset by then, which would announce a stale
  window and store its old `resetsAt`, posting a false recovery on the next
  refresh. Delivery goes through the same `NotificationAuthorizationCenter`
  seam as the request, so tests observe posts without the real center.
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
- The value font uses tabular digits (`monospacedDigitSystemFont`). The
  length follows the text exactly, the menu bar is right-anchored and the
  popover is anchored to the item, so proportional digits moved the open
  popover sideways whenever a refresh changed a digit's width. Only a change
  in digit count or an alert pad may move it now.
- Draw with native backing scale and baseline-anchored attributed strings.
  Resolve color from `NSAppearance.currentDrawing()` (`white` or
  `.textColor`).
- A low-quota dot belongs beside the exact quota segment that triggered it,
  never in a global corner. `.bar` elements carry the same cue in the gauge
  fill itself (yellow/red) instead of a separate dot.
- `QuotaWindow.shortLabel` is menu-bar-only; `QuotaRow` shows the full label.
  Format all token counts with `TokenFormat.short`.
- `StatusItemController.accessibilitySummary` appends `QuotaDisplay.word`
  ("used"/"left") to every segment carrying a `remaining`, because a spoken bare
  "61%" is heard as the remainder by anyone who has not opened Settings. Usage
  and spend segments carry no `remaining` and are read as-is.
- Which end a quota figure counts from is a preference, `QuotaDisplay`
  (`quotaShowsUsed`, default **remaining** — an upgrade must not turn every row
  over). One switch covers the popover headline, its bar, the menu bar's quota
  text segment and the `.bar` gauge together: the same window shown from
  opposite ends on two surfaces is the reading nobody gets right, so it is
  deliberately not per-surface, and it sits under Settings > General rather
  than Menu Bar. Only the rendering turns over — `QuotaWindow.remainingPercent`,
  `QuotaColor.forRemaining`, `MenuBarSegment.remaining` and
  `alertLevel(forRemaining:)` all still speak in remainder, so "how low is low"
  keeps one definition and the notification copy ("15% left", a whole sentence)
  still agrees with the thresholds that fired it. Render through
  `QuotaDisplay.percent(remaining:showsUsed:)`; `usedPercent` is the raw
  provider figure and is not clamped. `MenuBarContentView` reads the preference
  in `apply(elements:showCaptions:)`, not in `draw`, so the status item turns
  over on `UserDefaults.didChangeNotification` (`defaultsChanged` → `updateAll`
  → `updateTitle` → `apply`) instead of on the next quota tick.
- Any display default `MenuBarContentView.apply` reads must also appear in the
  Settings preview zones' rebuild signature (`SlotItemSettings.displaySignature`
  → `LayoutZoneView(signature:)`). `ChipContainerView.configure` returns early
  when the keys and the signature are both unchanged, so a preference left out
  of it renders chips at the previous setting until something else moves. It is
  one string on purpose: a new preference is a new segment in it, not a new
  parameter.
- `QuotaColor.forRemaining` is for popover bars and headline percentages, not
  the menu bar.
- The pace and run-out lines both show at once; neither replaces the other.
  `QuotaRow.pace` renders `now X%/h · avg Y%/h · budget Z%/h` — `now` is
  dropped when the tracker has nothing recent enough, and the line is nil
  without an `avg`. A `now` prefixed `<` is an upper bound
  (`QuotaRunway.nowIsUpperBound`), not a measurement: nothing dropped across
  its span, and utilization arrives in whole points, so all that is known is
  "under one point per span". The span is measured from when the window last
  moved, not from the `nowStepLookback` cap, so an idle window converges toward
  zero instead of parking at one point per hour. Never let a bound decide the
  budget colour — a ceiling cannot establish an overrun, so `pace` falls back
  to `avg` there.
  `QuotaRow.alertLine` adds the run-out estimate on a second
  line for every `.atRisk` runway carrying a depletion date, red inside
  `alertLeadTime` (30 min) and orange beyond it. Gating the estimate on the
  lead time hid exactly the question the user was asking — "how long at this
  pace" is needed well before the last half hour. When `QuotaRunway.pacedBy`
  is set the tracker floored the date at what a shorter limit allows; the line
  reads the same and only the tooltip says so, since the view never re-derives
  that decision. A date further out than `actionableHorizonCycles` x the
  shortest peer cycle is dropped in the tracker (`.atRisk` becomes `.watch`):
  a long projection would assume the current pace holds through several refills. It needs a
  peer that names a `cycle` — a window standing alone is paced by nothing, so
  the rule does not apply to it.
- A `.dormant` `now` renders as `now flat 6h`, not as a rate: the figure would
  be a ceiling that only tightens with time, which reads as a stuck number — the
  reported complaint was a Fable weekly showing `<0.2%/h` for hours. How long it
  has been still is the information. The word is `flat`, never `idle`: the
  measurement is that the counter has not moved, and light use under one whole
  point looks identical, so the tooltip says so.
- The pace line colors on `now` (falling back to `avg`) versus budget, not on
  `avg`: a burst that just started is still under the 20-minute average, and
  after the user stops, the average keeps nagging for 20 more minutes. `now`
  holds that privilege only while the reason for it holds — it must be the
  *fresher* reading. Since every window became step-anchored, `now` reaches back
  further than `avg` whenever the last step is old, and an upper bound says the
  rate is below its figure and so can never establish an overrun. In both cases
  the measured `avg` decides the colour instead; the figure is still rendered,
  it just does not set the colour.
- The pace line renders per `QuotaRunway.paceStyle`, which only
  `QuotaTrendTracker` decides. It keys first on the window's stated refill
  `cycle` when that is credible (the reset no further than one cycle away): a
  cycle longer than `longWindowHorizon` reads pace only, a shorter one compares
  drain vs the even-spread budget. Time-to-reset decides only for windows that
  state no cycle — Copilot allowances, one-time credits, caches written before
  `cycle` existed — or whose stated cycle is not credible (a reset further
  away than one cycle), on the same 24 h split. Long windows drop the budget
  segment and turn orange only on an `.atRisk` runway because a weekly
  window's even-spread rate sits below any active use, so a raw pace > budget
  check would stay orange whenever the user is working at all — and that holds
  however little of the week is left, which is where time-to-reset alone
  failed: a weekly in its final day gained a budget segment, went orange on
  `now`, and had its `avg` shrink from the 24 h span to a 20-minute one. The
  span cuts both ways: the 24 h reading can carry a run-out the 20-minute one
  had just lost, so keying on the cycle is not purely warning-suppressing (the
  `cycle` rule in providers.md says exactly what it adds). Views must not
  re-derive window-horizon semantics from reset dates. Inside the tracker,
  what still depends on the style — `averageSpan(for:)` — is an exhaustive
  `switch` on
  `QuotaPaceStyle`, never an `== .paceOnly` / `!= .paceVersusBudget` test:
  two negations of a three-case enum once disagreed on `.hidden`, giving a
  nil-reset window a long-horizon `avg` and a short-horizon `now` from one call.
  `now` no longer branches on style at all. Every window anchors on its latest
  whole-point step; a fixed five-minute slice only resolves 12%/h, so a 5-hour
  window draining at 3%/h (a point every twenty minutes) read `now 0%/h` three
  ticks in four through an active session. `now` may therefore cover more span
  than `avg`, and may repeat it on a young history — both beat a false zero.
- The pace tooltip names the spans each rate actually covers
  (`QuotaRunway.nowSpan`/`avgSpan`), so a `now` stretched across the 15-minute
  background refresh cadence says so instead of implying it is instantaneous.
  `QuotaRunway.nowAnchor` says how the span was chosen, and the tooltip puts
  words to that rather than to the style: `.step` ("runs from the step before
  the latest whole-point step"), `.lookback` ("fewer than two steps landed in
  the last hour"), `.flat` ("nothing dropped across it ... a ceiling, not a
  measured rate"), `.dormant` (the window is scoped to work that has not run for
  that long), nothing for `.burst`. It once said "stretches to the latest
  step" for every long-window `now`, including hours with no step. `.flat` is
  why the upper-bound path sets its own anchor kind rather than keeping the one
  whose span it replaced: `nowAnchor` means "how `nowSpan` was chosen", so a
  bound that reports the flat stretch has to say so, and the exhaustive `switch`
  then makes a forgotten case a compile error rather than a wrong sentence.
- Accessory apps can open Settings inactive, making Toggle/Picker states look
  identical. Keep `SettingsView.onAppear` activation and
  `makeKeyAndOrderFront`; gray traffic lights indicate a non-key window.
- `ProviderSection` shows the red triangle only when
  `quota.source == .unavailable`. A successful source with no windows uses the
  neutral info icon.
- The header's plan badge text and tooltip come from `QuotaSnapshot.planBadge`,
  never from the view: `TEAM PREMIUM` when the plan is `team` and
  `rateLimitTier` is `default_claude_max_5x` (Claude Code's own test for a
  Team premium seat), otherwise the plan uppercased with the raw tier in the
  tooltip when it is known. `ProviderSection` attaches `.help` only when the
  badge carries one, so there are no empty tooltips.
- The popover's provider sections live in a `ScrollView` capped to the hosting
  screen's visible height (`MenuView.sectionsCap`, fed by
  `AppViewModel.popoverScreenVisibleHeight`, which the status item controller
  records on each open); header and footer stay fixed. Never let popover
  content grow the window past the screen, including a smaller secondary one.
- The header's refresh arrow spins through `RefreshGlyph`. On macOS 15 and
  later that is the symbol's own rotate effect
  (`.symbolEffect(.rotate, options: .repeat(.continuous).speed(2), isActive:)`),
  which turns `arrow.clockwise` about the anchor SF Symbols defines for it;
  a `rotationEffect` pivots on the frame centre, which the arrowhead pushes
  off the arc, so the arc wobbled around it. The effect's own pace is one
  turn per 2 s (measured by frame autocorrelation), so `speed(2)` keeps the
  one turn per second of the fallback. On macOS 14 it is a `SpinningArrow`
  that exists only while `AppViewModel.isRefreshing` is true and rotates from
  the clock (`TimelineView(.animation)`), swapped for a still image otherwise.
  No SwiftUI transaction animation may drive it (a symbol effect is not one:
  it runs on the symbol's layer and captures no layout), and no
  `repeatForever` may exist in the app
  (`MenuViewTests.testNoRepeatingAnimationInSources`). A repeating
  animation lives on the transaction it starts in, and the transaction that
  inserts the spinner is the one that lays out the popover, because
  `showPopover()` starts a refresh right before showing it. Scoped with
  `.animation(_, value:)` the repeat captured the arrow's move between rows
  and slid it bottom-to-top forever; started with `withAnimation` in
  `onAppear` it captured every frame and the whole popover drifted. Both kept
  the process at 12-20% CPU with the popover closed, since the hosting
  controller lives for the app's lifetime.
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
- A session's subagent disclosure lists two kinds of child row: child
  *processes* (`ActiveAgentNode.children`, agents whose nearest agent ancestor
  is this one) and transcript-derived subagents (`ActiveAgentNode.subagents`,
  `ActiveSubagent`). A transcript subagent has no PID and no hook state —
  subagent tool calls report under the parent's session id — so its row is
  not a button, its dot is green while its transcript changed within
  `ActiveAgent.recentActivityWindow` and gray ("done · Xm ago") after, and it
  is listed only while within `ActiveSubagent.lingerWindow` (10 min) of its
  last write. It never moves the parent's status or `topStatus` (the hook
  keeps the parent `working` while background tasks run) and never counts in
  `agentCount`, which stays a process count; the "N subagents" label counts
  both kinds. Title, agent type, model and effort are provider text and go
  through `SessionLabel` / `ModelLabel`. The parent's tooltip ends with
  "incl. N subagents (tokens · $cost of the total)" over every subagent the
  session ran, listed or not.

## Spend and usage

- Token counts are what is stored and carried; dollars are derived where they
  are shown. `UsageReport.dayModels` holds one `DayModelUsage` per (day, model)
  behind the buckets, and a `LifetimeDayRecord` keeps the same split in
  `models`. Every on-screen figure prices those counts under
  `AppViewModel.priceTable`, one table for the whole popover and menu bar: the
  all-time footer (`lifetimeSpendUSD(for:)`), the day/7-day/30-day grid
  (`SpendWindows`), the by-model rows (`UsageReport.modelSpend(from:table:)`),
  the heatmap and sparkline points (`dayPoints(ledger:report:table:)`), and
  the menu-bar `s:` readout (`todaySpendUSD(for:)`). Never read `costUSD`,
  `totalCostUSD` or `byModel` in a view: they are scan-time compatibility
  output for older builds reading `last-state.json` / `lifetime-spend.json`,
  priced under whatever table the scan happened to hold. Mixing them with
  live-priced figures re-creates the bug this replaced: a complete scan
  re-priced every stored day under the table the process held at that moment,
  the bundled snapshot lacked the models in use until the network table
  arrived, and the all-time total moved by $1,400 with no usage behind it.
- Ledger records written by older builds carry no per-model counts
  (`models == nil`) and keep their stored dollars until a scan replaces the
  day: a complete one, or a windowed one that saw at least as many tokens. A
  report restored from an older build's `last-state.json`
  has an empty `dayModels`, and the spend helpers fall back to its scan-time
  dollars until the first refresh. Both fallbacks live inside the helpers;
  neither is a reason for a view to read the compat fields itself.
- The popover's all-time spend comes from `LifetimeSpendTracker`, not from a
  scan-window sum. It keeps one record per provider/day. A windowed scan can
  only grow a day; a scan flagged `UsageReport.isCompleteHistory` replaces the
  days it observed, which is the only way an over-count is ever corrected, and
  still leaves days it did not observe alone because their logs are gone.
- `LifetimeSpendStore` in `lifetime-spend.json` is authoritative. The
  `StateCache` copy exists only for compatibility because older builds rewrite
  `last-state.json` without unknown fields.
- `history.sqlite` (`HistoryStore`, see [providers.md](providers.md), "History
  store") is persisted app state, not user-visible: it lives in Application
  Support next to `last-state.json` (never inside a `claude-usage-cache*`
  directory, whose prune deletes foreign files), and nothing in the UI, the
  ledger or `StateCache` reads it in Phase 0B. Losing or quarantining it never
  changes a figure on screen. Do not add a view that reads it without a
  derived-table design: its raw rows are observations, not display values.
- `UsageReport.totalTokens`, `totalCostUSD`, and `byModel` are clamped to
  `UsageReport.totalsWindowDays` (30 days); the cutoff is
  `UsageReport.totalsCutoff()`, shared by `UsageRollup` and `ModelBreakdown` so
  the by-model rows add up to the grid's 30-day column. `buckets` may retain
  older dates because recently touched log files can contain old sessions, but
  that reach is incidental — never rely on it for history.
- The Activity sparkline and heatmap render `[UsageDayPoint]` from
  `LifetimeSpendTracker.dayPoints(ledger:report:table:)`. The scanner's file
  window (`ClaudeJSONLScanner.usageHistoryDays`) only bounds what one refresh
  re-reads, so plotting `buckets` directly loses every day whose logs have not
  been touched lately. The ledger decides every day it holds — the refresh
  merges the report into it first, so it is already at least as complete, and a
  report restored from `last-state.json` must not be able to resurrect a
  corrected over-count. The report only fills days the ledger lacks.
  `dayPoints` drops the synthetic `legacyFloorDay` record, and `UsageHeatmap`
  scales color from the cells it draws, not from every point handed to it.
- Gate the Activity/Spend block on those points, not on `usage.buckets`: a
  provider idle longer than the file window has no buckets but real ledger days.
- Any UI labeled “30-day” must use `SpendWindows`; never sum all buckets. Its
  token side reads `buckets`; its dollar side goes through
  `UsageReport.costUSD(on:table:)` / `costUSD(from:table:)`, so the headline
  row and the grid agree on the window, and the grid and the footer agree on
  the price.

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
- One `background_tasks` entry is not work: the live-updates subscription
  Claude Code arms by itself after an Artifact publish (description
  `live updates for artifact <url> (…)`, `HookBackgroundTasks.artifactSubscriptionPrefix`).
  It watches for comments for as long as the tab is open, so no later `Stop`
  sees it finish; counting it kept a session that ended its turn by
  publishing a page "working · 1 background task" for days. Match it by
  description — `type` is only a task-kind label, and a Monitor waiting on
  real work has the same kind and must still count.
- `StopFailure` records `error` only for the main turn's own failure
  (`AgentStatusState.recordedState`): inside a subagent the input carries
  `agent_id` beside the parent's `session_id`, and the main agent gets that
  failure back as a tool result and carries on. Nothing but the session's
  next hook event overwrites an `error`, so `ActiveAgent.displayStatus`
  shows it red for `ActiveAgent.errorAttentionWindow` (12 h, the launch
  sweep's age) after the write and gray after that, with the row reading
  "last turn failed · 4d ago". Without the window a 429 in a tab nobody went
  back to turned its group red for four days.
- The bundled helper reads the whole hook input (`HookStandardInput`), never
  a fixed prefix: a `PostToolUse` input carries the tool's response, and a
  fixed-size read could truncate a large input. Only
  a document past 16 MiB is refused, drained and answered with exit 0 and no
  write (the session id is inside it); invalid JSON still exits 64 so a
  schema change stays visible. It writes bounded per-session JSON through
  `AgentStatusCore`.
- A payload attaches to a process by its recorded ancestry only, which is
  what distinguishes sessions that share a directory. There is no session-id
  fallback: the only payloads it could match are the ones the PID-lifetime
  guard refused — a dead predecessor's after a crash or a `--resume`, which
  painted a fresh process yellow or green until its first hook event.
- Hook-reported session IDs pin a PID to its exact transcript
  (`identifiedClaudeSession`), so per-session usage stays correct when several
  agents share a working directory. A pinned ID whose transcript is under
  neither the hook cwd's key nor the process cwd's key gets no session at all:
  the heuristic lists the same directory and could only return another
  session's file. Without a hook payload, the newest-file heuristic applies
  only to a directory's single agent, and only to a transcript launched from
  that cwd — Claude Code's SessionStart hook symlinks every checkout of a repo
  into one store, and the newest file there was another checkout's live
  session, listed twice with its spend counted twice. Ambiguous processes get
  no session rather than a guessed one. Session IDs become filenames — keep
  the charset guard.
- The project key is Claude Code's own: every character outside `[A-Za-z0-9]`
  becomes `-` (`ActiveAgentService.claudeProjectKey`), so
  `.claude/worktrees/sample_12345` is `--claude-worktrees-sample-12345`. Mapping
  only `/` and ` ` left every worktree session without a transcript.
- A row's state comes first from Claude Code's own session registry,
  `~/.claude/sessions/<pid>.json` (`ClaudeSessionRegistry`), and from the
  hook payload only where the registry has nothing usable. Claude Code writes
  the registry's `status` from its own turn state, so it moves where no hook
  fires: `Stop` does not run on a user interrupt, nothing runs when a
  permission prompt is answered, and a background subagent's tool calls
  rewrite the hook file under the parent's session id. `busy` is working,
  `waiting` waiting, `idle` and `shell` (the user's own `!` command) idle; a
  status AgentMeter does not know counts as no entry. Only `<pid>.json` files
  are read, never the `.key` files beside them, and every field but `pid` is
  optional: the layout is internal to Claude Code (`claude agents --json`
  documents the same names), a half-written file is retried once and then
  skipped for the tick, and a corrupt file drops itself, not the listing.
- The registry entry attaches by PID with a PID-reuse guard
  (`ClaudeSessionRegistry.entry`: its `startedAt` may not predate the process
  by more than `startedAtTolerance`), and only to a process that already has a
  transcript or a hook payload. Claude Code registers the short-lived helper
  processes it spawns beside a session too, and a registry state alone would
  make each of them a row; `isBlank` keeps them out as before.
- Merge rule (`ActiveAgentService.resolveStatus`): the registry decides
  whichever source was written later, with one exception — a hook `error`
  stands beside a registry `idle` written for the same turn end (`StopFailure`
  runs 13 ms before Claude Code writes idle, `errorRegistryTolerance` covers
  that and the payload's whole-second time) or after it, since the hook is the
  only source that knows the turn failed; a later `busy`, `waiting` or a much
  later `idle` retires it. `ActiveAgent.statusSource` says which source won.
- `background_tasks` no longer decides the state when the registry is read: a
  turn that ended with subagents in flight is idle to Claude Code and reads
  "idle · 2 subagents" here, the count from the last `Stop`
  (`ActiveAgent.backgroundTaskText`), with the tooltip saying what it counts.
  It is that moment's count, not a reading of what runs now — transcript
  mtimes do not say either way, so nothing infers from them. Without a
  registry entry the helper's `working · N` reading stands as before.
- `waitingFor` reaches the row only through `ActiveAgentWaitingReason`:
  `permission prompt` (and the sandbox/worker requests) read "waiting for
  permission", `input needed` "waiting for your input", `dialog open`
  "waiting · dialog open"; anything else is dropped and a registry row says
  plain "waiting" (a hook-only row keeps "waiting for input"). Never render the registry's string itself.
- The registry's `sessionId` pins the transcript before the hook's does
  (`ActiveAgentService.registrySessionPins`): same id, but present from the
  session's start and after a `/clear`, and present with the hooks off. A pin
  needs the PID guard and a session id no other live Claude process names —
  a helper registered under a session's id would otherwise list it twice.
- While a popover is open, `RefreshCoordinator` re-reads the registry and the
  hook files every 2 s and re-attaches them to the rows the last full refresh
  built (`ActiveAgentService.refreshStatuses`): no `ps`, `lsof`, quota
  request or transcript scan, and a row whose process has exited is dropped.
  A tick whose rows a full refresh replaced meanwhile is discarded. The full
  refresh keeps its own cadence; the tick only moves the dots between them.
- `ps` and `lsof` output is decoded lossily: one process anywhere with a
  non-UTF-8 argument made the listing undecodable and emptied the session
  list, parse cache included, for as long as it lived. `lsof` exits 1 when a
  requested PID ended since the `ps` snapshot and still prints the rest, so
  that status is accepted, and it runs under `LC_ALL=C.UTF-8`: a login-item
  launch has no locale, and without one lsof escapes a non-ASCII cwd
  (`\xe6\x97\xa5…`), which matches no project key. Claude Desktop's own main process
  (`Claude.app/Contents/MacOS/Claude`, cwd `/`) is not an agent; its bundled
  Claude Code under `claude-code/` is.
- Per-session token totals are cached as a partial parse
  (`SessionTokenTotals`: Codex per-model counts, the Claude records as
  `ClaudeJSONLScanner.ParseState` — the usage report's own parser and
  per-key pick — Codex's last seen model, and the newest effort and titles),
  not as the finished summary. A live transcript grows between
  every tick, so caching the summary only ever hit on an idle session; the
  partial resumes from the last consumed line boundary instead. Cache only that
  boundary — folding the trailing, not-yet-terminated record into the cached
  value would count it again once it is complete. `enrichSessionUsage` prunes
  the cache to the running sessions, because each entry holds a record per key.
- A Claude session's tokens and cost include its subagent transcripts,
  `<projectKey>/<sessionID>/subagents/agent-<id>.jsonl`, and the agents of
  its Workflow runs, which Claude Code files one level further down as
  `subagents/workflows/<runID>/agent-<id>.jsonl` beside a `journal.jsonl`
  (`ActiveAgentService.subagentTranscripts(for:provider:)`). Both are found
  only by walking from the already-attributed `logPath` — never from hook
  input — and only for names (file and run directory alike) in the session-id
  charset; meta files, symlinks, the journal and anything deeper are skipped.
  A workflow of a hundred agents that read as a lone "working now" row with
  its pre-workflow total was the case this came from. Each file is its own cached partial
  parse with its own records, and the prune keeps
  main *and* subagent fingerprints — dropping the latter would re-read every
  subagent from the top each tick. Model, effort and title stay the main
  transcript's; subagent transcripts carry no title records. A subagent row
  shows its own file; the session's figure runs every file's records through
  `ClaudeJSONLScanner.UsageSelection`, so a request two of its transcripts
  carry counts once and the figure equals what the usage report makes of the
  same files. (A fork's copied prefix still counts in the fork's row as well
  as the parent's; the report attributes it once.) The row's name for a
  subagent is `description` from the sibling `agent-<id>.meta.json` (read
  under a 64 KB cap), else the first user prompt's opening words. Finished
  subagents stay in the total forever, like finished turns; only the listing
  ages out. The spend scanner's recursive glob already counted these files.
- Listed subagents render through `ActiveAgentNodeRows` on both paths: under
  an expanded group header and for a flat group (one session, no child
  processes). The flat path once drew a bare `ActiveAgentRow`, so a project
  with a single session never showed its subagents at all and the tooltip's
  "incl. N subagents" was the only trace. The disclosure label counts the rows
  and how many are still running ("3 subagents · 2 working"); the rows behind
  it stay collapsed unless a child process needs the user, as before. The
  tooltip brackets the subagent share to clarify that it is already included in the session total.
  `ActiveAgentNodeRows` is a multi-view builder, so its rows take the
  alignment of whatever stack receives them. The flat path's container in
  `ActiveAgentsSection` states `.leading` explicitly: left to the `.center`
  default, the narrow disclosure button floated to the middle of the row while
  its twin under a group header sat at the left.

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
- Events (`Services/Events`, `NotificationManager+Events.swift`) are the
  second, separate path through `NotificationManager`: a producer submits an
  `AgentMeterEvent` whose id names the occurrence, and `AgentMeterEventStore`
  (`events.jsonl` next to `history.sqlite`, an operation log replayed on load)
  records it before anything is posted and refuses an id it already has, so a
  restart or a rescan never announces it again. A run that ends mid-post
  leaves the event pending; the next run's first read marks it
  `interrupted`, terminal and never retried. Delivery re-reads the system
  permission before every post, shares the lazy prompt and `requested` flag
  with the quota path, and records instead of posting when the kind is
  switched off, the event is older than `maximumDeliveryDelay`, or
  permission is denied. Read state changes only on an explicit read (a tap
  on the notification when its handler says the tap reads it,
  `markEventsRead`), never with time, and unread events
  never age out: the 180-day retention applies to read events, and at the
  10,000-event cap read events go first. Only when unread events alone
  exceed the cap do the oldest unread go, counted in `unreadOverflow()` (a
  running total kept in the log) for a view to show. An unread event its
  producer recorded for the history only (delivery suppressed with one of
  `Limits.historyOnlyReasons`) waits for no one: it is kept and dropped like
  a read one and never counted as overflow, and it stays unread (no read
  time is invented for it). The quota
  critical/recovery path is unchanged and records no events.
- `@AppStorage` keys are a compatibility contract. Current keys include
  `menuBarItemsConfig` (plus per-slot `menuBarItemsConfig.<slot>` variants),
  `menuBarSlotsConfig`, `menuBarShowCaptions`, `refreshIntervalSeconds`,
  threshold and notification settings, the event notification switches
  (`taskCompletedNotificationsEnabled`, `taskFailedNotificationsEnabled` and
  `taskWaitingNotificationsEnabled`, all default on; read on every delivery
  by `AgentMeterNotificationPreferences`), `taskNotificationsShowSessionTitle`
  (default on since 2026-10-29, a stored false still wins; read when a task
  event is built),
  `taskNotificationsShowListInMenu` (`TaskEventListVisibility`, default on:
  the popover's task list and the menu bar count), the overflow
  acknowledgement (`taskEventsOverflowAcknowledgedCount` and
  `taskEventsOverflowAcknowledgedDroppedAt`), `launchAtLogin`,
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
- Every column reads from its left edge: caption, value and `.bar` gauge start
  at the column's `x` whatever their lengths, with captions on or off, and an
  alert dot follows the text inside the column's declared width. A gauge
  centred under a countdown caption, or a bare value centred beside its dot
  pad, sat apart from its neighbours. Alignment never changes a width
  (`columnWidth`, `barColumnWidth`); `MenuBarColumnAlignmentTests` checks the
  drawn pixels.
- A low-quota dot belongs beside the exact quota segment that triggered it,
  never in a global corner. `.bar` elements carry the same cue in the gauge
  fill itself (yellow/red) instead of a separate dot.
- `QuotaWindow.shortLabel` is menu-bar-only; `QuotaRow` shows the full label.
  Format all token counts with `TokenFormat.short`.
- What a Claude quota column's caption says is a preference,
  `ResetCaptionMode` (`menuBarResetCaptionMode`, Settings > Menu Bar > Claude
  Quota Labels, where `window` is titled Period): `window` (default; the
  `shortLabel` `5h` / `7d`, exactly what the app always showed, no countdown
  computed and no timer), `countdown` (the time left until that window's own
  `resetsAt`) or `both` (`5h 3h23m`). `ResetCaptionMode.caption` composes the
  caption for the menu bar and for the Settings examples alike. The countdown
  (`ResetCountdown.text`: `45m`, `3h05m`, `6d12h`; minutes round up, so 14:00
  seen at 10:37 reads `3h23m`) comes from the window's own `resetsAt`, never
  from the 5-hour or 7-day cycle. A window with no `resetsAt`, one already
  past, or one 100+ days out keeps its `shortLabel` in every mode, so the
  column never shows a negative or stale countdown. One-time credits (an
  expiry, not a refill), Codex and Copilot keep their codes. The Settings chips
  (`MenuBarLayout.preview`) follow the mode and the colours as of when they are
  built; the mode and the colours are part of `MenuBarPreviewSignature`.
- A countdown's colour is chosen per quota window (Settings > Menu Bar >
  Claude Quota Labels, right under the mode, hidden while it is `window`; hiding
  stores nothing) and keyed by the window's identity, `claude:seven_day_fable`
  (`ResetCaptionColors`, JSON under `menuBarResetColors`), never by a position
  in the layout and not inside `MenuBarItem`, which `commit()` rebuilds from
  bare keys on every drop. Two weeklies are two entries, a text field and a bar
  field of one window share one, and no entry means Automatic: the status
  item's own adaptive text colour. Settings shows Automatic as words with a
  Custom… button, never as a swatch (a swatch of the label colour read as black
  having been chosen); a swatch appears only for a stored colour, beside Use
  Automatic. Colours are picked in the shared `NSColorPanel` through
  `CountdownColorPanel`. The panel reports colours set in code like picks, so
  it is shown with its starting colour before it is attached, and a report of
  that starting colour is not a pick until the user has moved off it: opening
  stores nothing. It stops writing when the mode returns to `window` or the
  Settings window closes, never on `onDisappear`, which a grouped Form sends
  for rows scrolled out of sight. Only the countdown part of the caption is coloured
  (`MenuBarContentView.captionString`); a stale quota dims it like the rest.
- The countdown caption no longer names its window, so the segment carries
  `reset` (window name, instant, countdown, tint) and the tooltip and VoiceOver
  read "5-hour 63% left (resets in 3h23m)". `MenuBarSegment.spokenText`
  appends `QuotaDisplay.word` ("used"/"left") to every segment carrying a
  `remaining`, because a spoken bare "61%" is heard as the remainder by anyone
  who has not opened Settings. Usage and spend segments carry no `remaining`
  and are read as-is.
- Nothing counts down in the model: the caption is a function of the clock, and
  `StatusItemSlotController.updateTitle` re-renders when
  `ResetCountdown.nextChange` says a caption changes. `CountdownTicker` is one
  one-shot timer in the common run-loop modes, re-armed by every render: one
  wake-up a minute while a countdown shows, none otherwise, no network request.
  Sleep stalls it and a clock change can leave it an hour out of step, so
  `NSWorkspace.didWakeNotification` and `NSSystemClockDidChange` re-render too
  (`nonisolated` observers: a main-actor `@objc` thunk traps when called off the
  main thread). The caption font uses tabular digits for the same reason as the
  value font: a tick must not resize the item.
- The Settings provider picker lists `MenuBarSlot.alphabetical`; `allCases`
  stays the menu bar's slot order.
- The Settings field zones scroll sideways (`LayoutZoneView` → `ChipZoneView`):
  the zone's `ChipContainerView` is the document of a horizontal scroll view
  with no scroller (an overlay one covers the strip's bottom 17 pt while it
  shows and took the mouse-down on the chips' lower part; a legacy one takes
  height), so the strip keeps its 46 pt, and the document is never narrower
  than the strip, so the empty space after the last chip is still the drop
  target. A trackpad swipes sideways natively and its vertical swipes go on to
  the Form, the way the gesture began deciding for all of it and its momentum
  (`ChipStrip.GestureLock`). A vertical mouse wheel over a strip that
  overflows scrolls the strip sideways first (down goes right), by design: it
  is how a mouse without horizontal scrolling reaches the far fields. Only at
  the strip's end, or over a strip that fits, does the wheel scroll the Form
  (`ChipStrip.wheelRoute`). A drag held near an edge autoscrolls. A chip goes
  where the pointer's half of a chip says, before it on the left half and
  after it on the right, both on arriving and in the updates AppKit keeps
  sending while the pointer rests, so a drop after the last chip appends it
  (`ChipStrip.dropMove`). The edge fades
  and chevrons are layers (`EdgeHintLayer`), never views, so they take no click
  and no drop; `zPosition` and their place last among the sublayers keep them
  in front. Off screen, AppKit attaches the scroll view's layers only on
  display, so a render needs a layout pass after it (`MenuBarPreviewRenderTests`).
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
- Every way into Settings goes through `SettingsOpener.open()`: it activates
  the app (an accessory app's windows otherwise open inactive, behind the
  active app, with Toggle/Picker states looking identical and gray traffic
  lights), brings an open or minimized window forward into the active Space
  (`.moveToActiveSpace`) with its frame and tab, and only opens a closed one
  through `openSettings`. The window is found by SwiftUI's identifier
  `com_apple_SwiftUI_Settings_window`; its title is the selected tab's. The
  popover's button is not a `SettingsLink` (no activation, no bring-forward,
  popover left open), and `SettingsView` has no `onAppear` activation: SwiftUI
  builds it at launch. It also puts the window on screen at launch, before the
  delegate runs, because the binary records the macOS 14 SDK (SwiftPM's
  stamp); `applicationDidFinishLaunching` withdraws it first thing, so it shows
  for about 0.2–0.3 s instead of staying open behind other windows.
- A popover shown while AgentMeter is active (Settings in front) does not close
  on a click in another app by itself: `.transient` covers that only for a
  popover shown while the app is inactive. The slot closes its popover on
  `NSApplication.didResignActiveNotification`; no mouse-event monitor.
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
  not running it yet. For Claude it is read off the usage scan's records
  (`ClaudeFileUsage.latestCounted`): the standing record with the latest
  timestamp (a zeroed replay by its own time), the later one in the file on
  a tie, so a final record that replaced a streaming one counts as newest and
  a replay of an older request does not. Unlike the parser the rows had
  before Phase 0C, a record without a message id is not keyed and does not
  take part. Effort uses the validated label (1–64 printable ASCII bytes, else none).
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
  `ai-title` / `custom-title`, which carry no `usage`; `consumeTitle` reads
  them (pre-filtered on `-title"`) into `ClaudeSessionTitles`, in memory only:
  they are conversation text and never reach the usage cache or the history.
  A user-set custom title outranks the generated
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
- The popover lists a session only while it is running or did something within
  `ActiveAgent.idleListingWindow` (24 h): `ActiveAgent.isListed`, applied by
  `ActiveAgentListing` where `ProviderSection` draws the list, for every
  provider. Rows come from live processes only (`ps`; a dead PID drops out on
  the next tick, and a registry file only ever attaches to a process alive now,
  guarded against PID reuse), and a Claude Code panel
  keeps its process until the panel is closed. Age
  alone never hides a row and `idle` alone never counts as ended: the registry
  vouches for `busy`/`waiting` whatever the date (a long run with background
  agents keeps its old stamp), a hook-only `working`/`waiting` is trusted only
  while it is itself within the window (an interrupt fires no `Stop`), and the
  clock is the newer of the state's last change and the transcript's last
  write (or a subagent's), never the process's start. Where a process has done
  nothing yet, the registry's stamp is its registration, so a freshly respawned
  panel is listed for the first 24 h. A row with no dated evidence stays, a
  running descendant keeps its ancestors' rows. The popover does not say how
  many it left out (`ActiveAgentListing.hiddenCount` is internal; the "N
  inactive sessions hidden" note was removed as noise), and with nothing
  listed it draws no Sessions box rather than an empty "Sessions 0". Only the drawn list is filtered: `AppViewModel.activeAgents`
  keeps every live process, which task-notification routing, session titles and
  the 2 s status tick read, so a hidden session returns the moment its state or
  transcript moves. Nothing is deleted, killed or unregistered, spend and
  history do not read these rows, and `--resume` starts a new process whose
  fresh registry stamp lists it.
- One time stands behind a session's age: `ActiveAgent.lastActivityAt`, the
  newest of the state's last change, the transcript's last write and its
  subagents' (they work while the main transcript is quiet). The row's
  "idle · 8d ago", the listing (`isListed`), the order and the tooltip all read
  it, and none invents one: a registry state without a stamp stays undated
  (`resolveStatus` does not fill in "now"), an undated session shows no age,
  sorts last among the idle and the tooltip leaves "Last activity" out. A
  failed turn's own row text ("last turn failed · 12h ago") keeps the failure's
  time, which is what it says. A count of background tasks from the last `Stop`
  is not a sign of life.
- Order (`ActiveAgentGrouping.OrderKey`, one comparator for processes, nodes
  and groups): error, then waiting, then working, then idle (and undated)
  sessions newest activity first, then provider, process age (older first), PID.
  The activity time orders only the idle ones: a working session's transcript is
  written to constantly, and ordering by it swapped running sessions on every
  refresh; they keep the stable process-age order. A node is as recent and as
  urgent as its newest, most urgent process, a group as its newest node, so a
  tree is ordered as one and never taken apart. Before this the order was the
  process age alone, which interleaved sessions opened days ago and idle since
  with ones that had just finished. Clicking a row acts on that row's own
  process, so the order cannot change where a click goes.
- Counts are listed sessions (processes, child processes included), at every
  level: the header's `Sessions N` is `ActiveAgentGrouping.sessionCount`, equal
  to the sum of the groups' `N` plus the flat rows; a group's `N` is its listed
  parents and children. Hidden sessions are in none of them; with
  `hiddenCount`, shown plus hidden is every live session once. "Hidden" also
  covers a hook-only `working` or `waiting` nobody has touched for over a day.
- A session row's tooltip (`ActiveAgentTooltip.text`) is plain `.help` text in
  three blocks separated by a blank line: the full name (the title, else the
  project) with "Idle · Last activity: 8d ago (Oct 21, 11:55 AM)" and the
  pending-background-work line; then project and branch, the model (the
  row's own name from `ModelLabel.short`, with the full id in brackets when it
  differs, since the snapshot date is checked there) and effort (as the row
  shows it: there is no friendlier form), the subagent share; then "PID #… · Session <full id>" and what a click
  does. The exact moment joins once the relative age is an hour or more, in
  the user's own locale and clock style, with the date only for earlier days
  and the year only across a year boundary. It is provider text throughout:
  the title is stripped and capped at 240 characters (the row's 80 lifted), the
  model is stripped and capped, and the session id is printed only when it is
  fit to be a file name (`ActiveAgentService.isSafeSessionFilename`).
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
  through `SessionLabel` / `ModelLabel`. The parent's tooltip has a line
  "Includes N subagents (tokens · $cost of the total)" over every subagent the
  session ran, listed or not.

## Task notifications in the menu

- `TaskEventFeed` keeps `AppViewModel.taskEvents` in step with the event log:
  it reads on `NotificationManager.onEventsChanged` (one reload per 150 ms
  burst), when the listing popover opens (another instance may have
  written), and at launch. Never on a timer. `.loading` until the first
  read, so "not read yet" never reads as "nothing happened"; the popover
  header always says which of Loading / None yet (Off without the hooks) /
  All read / N unread holds.
- The section is one header row (chevron, bell, "Task notifications", the
  state above) and opens the list on a click. `AppViewModel.taskEventsExpanded`
  holds that for the popover's lifetime only: collapsed at first and again
  when the popover closes (`resetTaskEventsPresentation`, from
  `popoverDidClose`), so the list squeezes the quotas and sessions only
  while the user asked for it; a banner tap that opens the popover on the
  list (`TaskEventFeed.showList`) expands it first. Expanded: up to 5
  unread rows ("Show N more"), "Read · latest 10" collapsed, and "Mark all
  read" in the header while something is unread. The overflow notice shows
  collapsed too.
- "Show task list in the menu" off (`TaskEventListVisibility`) hides the
  section and the menu bar count and nothing else: events are recorded,
  banners posted per their own switches, read state and history kept, so
  switching it back on shows everything as it stands. A banner tap still
  does what a row click does (tab, app, or nothing) and reads the task, but
  never opens the popover: there would be nothing to show in it.
- One item per task (`<session>|<task>`, `TaskEventItem`): a wait and the
  end replace each other on screen as their banners do, and the item shows
  the latest status. The menu bar counts tasks, not events. A row reads
  "Finished · 12m run" (status and the producer's detail: run time, error,
  what a wait waits for) with its age, then "project · session title" (the
  live row's title, else "Session abcd1234"); never prompt text. Reading an
  item reads every event of the task; Mark all read covers the items the
  user was shown, not what arrived since.
- Status, unread and "for the user" are kept apart. The status is the event
  kind and never changes. The UI says only read and unread (no "seen",
  "handled", "resolved", "dismiss"; `TaskEventListTests` scans the view
  files): read says only that the user looked, never that a wait is over or
  an unconfirmed task finished (an unconfirmed task read stays "Task status
  unconfirmed"). Unread clears on a deliberate act about that task: a tap
  on its banner (the feed reads the task's other listed events too), a
  click on its row, the row's check mark, Mark all read. A click reads the
  task whether or not anything came forward. That reverses the 2026-10-20
  rule "a click that cannot reach the session reads nothing" (2026-10-29):
  editor sessions are never reached, so every VS Code task needed a second,
  manual mark, which the user found pointless, and the click already shows
  the user looked. Closing a banner, opening the popover and time read
  nothing. An event its producer recorded for the history only
  (`TaskOutcomeAnnouncement.historyOnlyReasons`: before launch, a headless
  run, under a minute, a report's turn, crons, interruptions) asks nobody to
  read it: it
  is never listed or counted, stays unread in the log, and the log keeps and
  drops it like a read event (`Limits.historyOnlyReasons`). A kind whose
  banner is switched off in Settings is still listed and counted: the
  switches are about banners only, and Settings says so. Pending events are
  not counted, so the badge does not flicker while an event settles.
- Naming the session. When an
  event is recorded, `TaskSessionLabel.resolve` takes the live row's title
  (`ActiveAgentSession.displayTitle`, the row's own text), else the title in
  the session's own transcript (the ledger's `transcriptPath`, only a
  regular file named `<session id>.jsonl`, read off the main actor by the
  rows' parser `ActiveAgentService.claudeTranscriptTitle`: custom, then
  generated), else none; matched by session id only, never invented. The
  session id is the hook's `session_id`, the main session's even in a
  subagent's hooks, and the ledger keeps main-agent turns only, so an
  `agent-<id>.jsonl` never names one. The title is stored on the subject
  (`sessionTitle`, events.jsonl format 2; a format 1 line reads with nil),
  and so is `sessionKind` (`TaskSessionLaunch`): first the task's attended
  flag from its hooks (`TaskLedgerTask.attended`, below), headless when
  Claude Code said unattended; without one, every live registry entry of
  the session: interactive when any entry's `kind` is `interactive`,
  headless only when every entry has a known SDK entrypoint (`sdk-cli`,
  `sdk-ts`, `sdk-py`), otherwise unknown and no hint; remembered per
  session by `TaskOutcomeTracker`, interactive once seen, since a headless
  process often exits before its end is called. The registry alone cannot
  tell a script's run from the user's session (2026-10-29): a `claude -p`
  started from an editor session's `Bash` inherits `entrypoint`
  `claude-vscode` and registers as `interactive`, exactly like that
  session. Banner: "Finished ·
  <title>" over "<project> · Claude Code · <short id>" ("Headless run" in
  place of "Claude Code"), or without a title (or with the switch off)
  "Finished · <project>" over "Session <short id>" (· "Headless run"); then
  the detail line. Failed, Needs input, Status unconfirmed, Interrupted
  alike, status first so truncation keeps it. The list row names the session
  by the live row's title, else the stored one, else the short id, plus
  "Headless run". Titles in banners are on by default since 2026-10-29, the
  user's choice, superseding the 2026-10-20 short-id default (a title
  without a custom name is Claude's summary of the first prompt, and banners
  reach the lock screen); with the switch off banners use project and short
  id, and the list still shows titles (the title is kept with the event
  either way). Only `interactive` / `claude-vscode` registry entries were
  seen locally, the `claude -p` children included; the SDK entrypoint names
  follow Claude Code's, unverified here.
- Headless runs. A task whose session Claude Code
  counts unattended is announced only with Settings › Alerts › "Notify about
  headless runs" on (`taskNotificationsIncludeHeadlessRuns`, default off).
  Off, every outcome of it (failures and waits included) is recorded with
  `headlessRun`, a history-only reason: no banner, not listed or counted,
  kept and aged out like a read event, never marked read. The switch is
  read at each submit, so it applies from the next outcome. The signal is
  Claude Code's own: it sets `CLAUDE_CODE_SESSION_ATTENDED` ("1"/"0") in
  every command it runs, hooks included, and the helper stores it on the
  task (`TaskLedgerEvent.attended(environmentValue:sessionKind:)`). "0"
  covers `claude -p` and the SDKs, any Claude Code started from inside
  another session (`CLAUDE_CODE_CHILD_SESSION` inherited), and its
  background sessions; "1" an interactive terminal session, and an editor or
  desktop-app session that is not such a child (2.1.312 binary; a probe
  `claude -p` from this session's `Bash` saw "0" on 2.1.301, this editor
  session's own commands "1"). Background sessions
  (`CLAUDE_CODE_SESSION_KIND` `bg`, `daemon`, `daemon-worker`: `claude
  --bg`, routines) are runs a person started and waits on, so the helper
  stores them as attended (read from the binary; no such session seen here).
  No value leaves the task unknown and the registry decides as before; a
  build that does not set the variable passes on whatever its environment
  holds (a parent session's "1" when started from its `Bash`: banners as
  before, never fewer). Limits: a person's own `claude -p` in a terminal
  counts as headless; an editor that drives Claude Code through the Agent
  SDK (not one of Claude Code's own hosts) counts as unattended, and so
  would the sessions of an editor started from inside a Claude Code session
  (it would pass the child marker on); none seen here in 60 days of
  transcripts (726 `claude-vscode`, 3 `cli`, 1 `sdk-cli`), and Settings
  says to turn the switch on for such an editor. Builds without
  `headlessRun` in `historyOnlyReasons` (before this one) list such events
  as unread if they read the same `events.jsonl` (a rollback, a dev build
  beside the installed one); whichever app launched last also owns the
  shared helper, and an older helper writes no flag. No grouping of
  banners: past this rule the bursts left were independent sessions.
- `task_unknown` reads "Task status unconfirmed" with
  `TaskEventStatus.unconfirmedExplanation` ("Background tasks were still
  running at the last check…"), never the stored detail line: 1b wrote
  "N background shells still running", and the shell may have ended since
  with no hook to say so. New events say "N background tasks running at the
  last check". It is listed, never posted.
- The unread count is a blue capsule after the fields of Claude's status
  item, or of the first visible item while Claude's is hidden
  (`StatusItemController.taskEventsSlot`); that item's popover lists the
  tasks. It adds width only while something is unread (`badgeWidth` 0
  otherwise), is capped at "99+", is not dimmed with stale quota, and uses
  no quota cue color. The accessibility label appends the count.
- `unreadOverflow()` shows as a notice in the list until the user
  acknowledges that exact total (count and `lastDroppedAt`, kept in
  defaults); a later drop shows only what was dropped since, and a total
  below the acknowledged one (the log started over) shows all of it.
- Clicks (`TaskSessionRouting`) bring forward only what already runs the
  session. Live processes come from the rows (with the row's start time
  checked against the kernel's) and from the registry read at click time
  (`ClaudeSessionRegistry.entry` guard); helpers registered under the
  session's id descend from it and do not count; unrelated processes make it
  ambiguous. A terminal tab (iTerm2, Terminal, Ghostty) is selected by tty
  (it only selects a tab that exists). Any other app, editors included, is
  activated by the click and nothing more, which never creates a window.
  Ended, unhosted and ambiguous sessions open nothing. A banner tap does
  what a row click does. The row's tooltip names the outcome ("Brings Code
  forward — AgentMeter can't pick the session's window there") from a route
  looked up when the pointer first reaches a row of that session
  (`TaskEventFeed.preview`, kept per session in
  `AppViewModel.taskEventRoutes` until the popover closes; generic until
  then); looking never activates or reads anything. When a click could not
  do what it said, one short line sits under that row (`TaskEventNotice`:
  "Session has ended", "Couldn't switch to the iTerm2 tab"), with no
  buttons, until the next click (a banner tap that worked included) or the
  popover closes; the row stays in place though it was read, and a banner
  tap that brought nothing forward opens the popover on it. A click or a
  lookup still running when the popover closes writes no line or route into
  the next one (`AppViewModel.taskEventsPresentationGeneration`, bumped by
  `resetTaskEventsPresentation`). The session row's click
  (`AgentAppActivator.focus`) is the same: the terminal tab, else the app.
  No URL is ever opened
  (`AgentAppActivatorTests.testNoSourceOpensAnEditorOrSessionURL`), so no
  click can open or resume a session.
- Why no editor window is switched, kept for a future safe way to name the
  window (all as of VS Code 1.142.0 and Claude Code 2.1.301, 2026-10-20):
  `vscode://anthropic.claude-code/open?session=` is handed to the active
  window, and a window that does not own the session opens a panel bound to
  it, a second process resuming it. `vscode://file/<folder>` focuses only a
  window whose single folder is exactly `<folder>` (a `.code-workspace`
  window matches only by its workspace file); with none it reuses the last
  active window and reloads it with the folder (`openInBrowserWindow` →
  `unload(window, LOAD)` in the installed `out/mainImpl.js`), replacing its
  workspace and ending the sessions in it. The Claude Code extension's
  `~/.claude/ide/<port>.lock` lists each window's `workspaceFolders` and the
  editor's main `pid` (and an auth token, never to be read), which shows a
  window holding a folder but neither a one-folder `.code-workspace` nor a
  window closing before the link lands; a link built on it was tried and
  removed (patch `phase1c-wip-on-f249f9c-20261020-2013` in the AgentMeter
  backups). Extension-launched sessions have no tty, are children of their
  window's extension host, and run in realpath(first folder). The CLI's
  hidden `--open-url` with `--user-data-dir` reaches only that instance, the
  isolation route for an experiment; no experiment was run.
- Settings › Alerts shows the three banner switches (default on; labelled as
  banners, with the note that the menu still records, lists and counts the
  task), the session-title switch (default on), "Show task list in the
  menu" (default on), "Notify about headless runs" (default off) and what
  System Settings says (`AgentMeterNotificationSettings`: permission, alert
  style, lock screen, previews), read when the pane appears and when
  AgentMeter becomes active again. Temporary (banners: shown once, gone by
  themselves, kept in Notification Center) and Persistent (alerts: on
  screen until clicked or closed) are the user's choice per app in System
  Settings; `UNNotificationSettings.alertStyle` is read-only and no request
  option or interruption level makes a notification stay. The pane explains
  both, shows the current one and links to AgentMeter's page there
  (`x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=`,
  the extension's own URL scheme; undocumented by Apple). Temporary is the
  default (no `NSUserNotificationAlertStyle` in Info.plist), so only "no
  notifications on screen" and "not allowed" get guidance. AgentMeter never
  changes them and never imitates a persistent notification. With previews hidden, a task banner reads as the
  category's placeholder ("Claude Code task update").

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
- Task outcomes (`Services/Sessions`) come from a second per-session file the
  helper keeps, the turn ledger (`agent-status/turns/<session>.json`,
  `TaskLedger`): replaced atomically, 0600, under a `flock` on `turns/.lock`
  (a write that waits past 0.5 s is dropped, never the hook). Only the main
  thread's `UserPromptSubmit`, `Stop` and `StopFailure`, permission and
  elicitation `Notification`s, `SessionEnd`, and any agent's `PostToolUse`
  whose `tool_response.backgroundTaskId` names a shell it left running move
  it; every new hook field is decoded leniently, so the payload write cannot
  break on it. The task key is the human prompt's `prompt_id`: each report
  from background work arrives as a new prompt with a new `prompt_id`
  (`<task-notification`, `<agent-message`, or any `<tag` while subagents or
  workflows run or within 10 min of an uncertain end) and joins the task, as
  a new segment when the task had really ended. Its location (`cwd`,
  transcript) comes from main-thread events only, and so does `attended`
  (the hook environment's `CLAUDE_CODE_SESSION_ATTENDED`): a task keeps the
  first value one of its main-thread events carried, and a new task starts
  unknown, so a resumed session gets the new process's value. No prompt,
  message or tool text is kept.
- `TaskOutcomeDetector` decides from the ledger, the live registry entry and
  the payload (POC C1–C3 and C1d on 2.1.301). Completed: a main `Stop` with
  no subagent or workflow in flight, and the registry turned idle (or
  `shell`) after it and stayed so 2 s. The registry stays `busy`, keeping
  the stamp of the turn's start, while background agents run, so a busy
  entry holds the task whatever its stamp; a Stop hook that continues the
  turn is expected to keep it busy too (not measured). Paused: the `Stop`
  lists a subagent or workflow. A background shell this task started (main
  agent or subagent) that still runs makes the end uncertain: when it ends,
  its owner wakes and reports, and neither hook input nor registry
  says when — on the SDK path the registry is plain `idle` meanwhile. Such a
  task is never called finished: after `uncertainWindow` (10 min) with no
  report the state is recorded once as `task_unknown`, not announced, and
  the report that eventually comes joins the task, whose real end is then
  announced as Completed. A shell with no launch on record counts as the
  task's that first sees it; a shell an earlier task started or saw (a dev
  server) does not hold it. A session that ends meanwhile ends the watch
  without an outcome. Known limit: completion needs the owner's wake-up
  (a report, then a `Stop`). No hook fires when a background shell ends, the
  SDK registry stays `idle` throughout, and the REPL's `shell` → `idle` edge
  only says the shells ended (a revival followed it by 60 ms in C1a), so a
  shell that ends without waking anyone (killed, or its notification lost)
  leaves the task unknown for good; it is not guessed Completed. Failed: the main `StopFailure`, once the registry is
  idle (10 s quiet without one, 30 s if it stays busy; never seen live
  yet). Waiting: the registry `waiting` for 60 s, timed from the first stamp
  of the wait; without a registry, a permission notice the payload still
  shows for 120 s; at most one per turn. Permission dialogs read
  `permission prompt` and questions `input needed`; `dialog open` counts
  only while the turn runs (Claude Code's "Session paused" decisions:
  fallback model, usage credits), not between turns (a command UI the user
  opened). Interrupted: idle after the prompt with no `Stop` (Esc fires
  none) and the transcript's last message record is the interruption
  marker; without the marker nothing is recorded.
- `TaskOutcomeMonitor` runs the detector on a private utility queue: on a
  directory watch of `turns/` (the ledger's renames), on a timer while a turn
  runs or an end awaits confirmation (Claude Code rewrites registry files in
  place, which a directory watch misses), and every 30 s otherwise. A
  registry entry counts only for a live process that started before it was
  written (the rows' PID-reuse guard), and a single pass that misses it
  reuses the reading from up to 3 s before. It hands
  each outcome on once per run, through `TaskOutcomeQueue` to
  `TaskOutcomeAnnouncement.announce` one at a time in the order found (naming
  a session can wait on a transcript read, and a wait submitted after its
  task's end would replace the "Finished" banner), and the event store's id dedup
  (`task_<kind>|<session>|<task>|<segment>[|…]`) keeps a restart from
  announcing it again. `TaskOutcomeAnnouncement` records without posting
  what happened over 120 s before launch, headless runs (unless switched
  on), tasks under 60 s, tasks a report opened, sessions with crons armed,
  uncertain ends, and every interruption.
  All of one
  task's banners share `agentmeter.task.<session>.<task>`, so a wait and the
  end replace each other. The text is the status, the session's title, the
  project, the short session id, run time and error kind; never a prompt,
  assistant text, error details or the task key. The title is named as in
  "Task notifications in the menu" below.
  Ledgers untouched for 24 h whose session has no live process are swept
  hourly.
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
- A Claude session row's tokens, cost, model and effort come from the usage
  scan's own records: `sessionWithUsage` reads the transcripts through
  `ClaudeJSONLScanner.fileUsages`, i.e. the scan's cache and `cachedUsage`
  (memory, then the store, then a resumed parse checked against the
  boundary digest), and hands what it parsed to the history. There is no
  second Claude parser: until Phase 0C the rows kept their own
  `ParseState` per file in a memory-only cache and re-read every attributed
  transcript and subagent from the top after each launch. What is still
  parsed here is cached as a partial parse resumed at the last line boundary
  (`incrementalParse`): Codex rollouts (`CodexSessionTotals`: per-model
  counts, the last seen model) and Claude titles (`ClaudeSessionTitles`).
  Cache only that boundary — folding the trailing, not-yet-terminated record
  into the cached value would count it again once it is complete.
  `enrichSessionUsage` prunes those two caches to the running sessions' main
  transcripts; the scan's cache is the scans' to prune. Tests default to
  `ClaudeUsageCache.memoryOnly`, so they never touch the real store.
- A Claude session's tokens and cost include its subagent transcripts,
  `<projectKey>/<sessionID>/subagents/agent-<id>.jsonl`, and the agents of
  its Workflow runs, which Claude Code files one level further down as
  `subagents/workflows/<runID>/agent-<id>.jsonl` beside a `journal.jsonl`
  (`ActiveAgentService.subagentTranscripts(for:provider:)`). Both are found
  only by walking from the already-attributed `logPath` — never from hook
  input — and only for names (file and run directory alike) in the session-id
  charset; meta files, symlinks, the journal and anything deeper are skipped.
  A workflow of a hundred agents that read as a lone "working now" row with
  its pre-workflow total was the case this came from. Each file's records
  come from the usage scan's cache like any transcript's, kept between ticks
  by the scans, so a tick reads only what was appended. Model, effort and title stay the main
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
  "Includes N subagents" was the only trace. The disclosure label counts the rows
  and how many are still running ("3 subagents · 2 working"); the rows behind
  it stay collapsed unless a child process needs the user, as before. The
  tooltip brackets the subagent share to clarify that it is already included in the session total.
  `ActiveAgentNodeRows` is a multi-view builder, so its rows take the
  alignment of whatever stack receives them. The flat path's container in
  `ActiveAgentsSection` states `.leading` explicitly: left to the `.center`
  default, the narrow disclosure button floated to the middle of the row while
  its twin under a group header sat at the left.

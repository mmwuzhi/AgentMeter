# Provider and quota invariants

Read this file before changing provider fetchers, usage scanners, quota models,
provider status, pricing, refresh coordination, or quota trend logic.

Every provider returns `ProviderState(quota:usage:)`. The source actually used
must be preserved in `QuotaSnapshot.source` so the UI can distinguish `live`,
`local log`, `oauth`, `cli`, `usage only`, and unavailable data.

## Codex

- Quota fallback order is `CodexOAuthUsageFetcher` (`GET
  chatgpt.com/backend-api/wham/usage` via `CodexCredentials`) →
  `AppServerSession` (`codex app-server`) → `CodexRolloutReader`. Direct HTTPS
  stays primary to avoid spawning a subprocess on every refresh.
- `CodexRolloutReader.rolloutFiles()` must enumerate both date-nested
  `~/.codex/sessions/` and flat `~/.codex/archived_sessions/`, deduplicated by
  filename. Codex CLI ≥0.142 can archive an active session mid-day; omitting
  archived sessions makes current-day usage and spend collapse.
- Usage/spend comes from per-day `last_token_usage` in rollout logs.
- Codex quota source authority is `oauth` > `appServer` > `rolloutFile`. On a
  fallback, preserve only higher-authority windows that are still live in the
  same reset epoch; accept new epochs, unrelated windows, and current snapshot
  metadata. For same-source data, dampen a pre-reset recovery spike per window,
  except when a decreasing reset-credit count confirms a real redemption.
- Reset-credit dates come from
  `chatgpt.com/backend-api/wham/rate-limit-reset-credits`, authenticated with
  the Codex CLI OAuth token. `account/rateLimits/read` does not provide real
  grant/expiry timestamps.
- `CodexResetCreditFetcher.parseCredits` must remain defensive: support the
  known aliases and wrapped/bare-array shapes, treat the response as untrusted,
  and cap it at `CodexResetCreditTracker.maxStoredCredits` (20). Dump an
  unparsable body to
  `~/Library/Application Support/AgentMeter/debug-codex-reset-credits.json`;
  never guess fields.
- Real reset-credit records override `CodexResetCreditTracker`'s local
  observation fallback. The fallback only estimates a 30-day expiry from when
  this app first sees a count increase.
- `RefreshCoordinator` throttles reset-credit fetching independently (20
  minutes). Repeated 401s should degrade silently to local inference.

## Claude

- Credential order is `~/.claude/.credentials.json` → Keychain item
  `Claude Code-credentials`. Quota fallback order is `ClaudeOAuthFetcher`
  (`GET api.anthropic.com/api/oauth/usage`) → `ClaudeCLIScraper` (`claude
  /usage`) → usage-only. Reset windows require network access.
- Claude Code may persist `expiresAt: 0` as an unknown-expiry sentinel. Keep
  that token cached until a real HTTP 401; rate limits and transient server
  errors must not invalidate it because the next Keychain read may prompt.
- Coalesce concurrent credential cache misses into one read. Sleep/wake and a
  stalled refresh can overlap, but must never queue multiple Keychain prompts.
- Usage/spend comes from `ClaudeJSONLScanner` over
  `~/.claude/projects/**/*.jsonl`, deduplicated by `message.id|requestId`.
  Dedup is global across files, not per file: resuming a session copies the
  earlier transcript into a new file, so the same assistant message is present
  in both. Per-file dedup double-counted ~10% of all tokens and nearly doubled
  the oldest days.
- Most refreshes read only files touched in the last `usageHistoryDays` (31).
  Every `fullHistoryInterval` (6 h), and once per launch, the scan reads every
  file instead and marks the report `isCompleteHistory`. Only such a report may
  lower a stored `LifetimeSpendTracker` day; a windowed one can only grow days,
  since a day shrinking there just means its files left the window.
- Scanners must not touch log lines through `String`. `JSONLLineReader` hands
  each record over as a `LogLine` of raw bytes: `String(data:encoding:)`
  validated every byte and `String.contains` resolved to
  Foundation’s locale-aware search. Build `Marker` needles
  once as static constants, and keep every chunk read inside an
  `autoreleasepool`; a cooperative-pool thread drains none on its own, and the
  chunks then pile up to the size of the whole file.
- An OAuth response with no quota windows is a legitimate spend-based plan
  shape, not a parse failure. Preserve the neutral empty-windows state and dump
  the raw response (capped at 256 KB) to
  `~/Library/Application Support/AgentMeter/debug-claude-oauth-usage.json`.
- The confirmed one-time Claude Code + Cowork credit currently uses the opaque
  `cinder_cove` key. Keep it routed through `add(...)` with
  `isOneTimeCredit: true`; if the codename changes, fall back to the empty
  windows note instead of guessing.
- Model-scoped limits live in the newer `limits` array even when named
  `seven_day_*` keys are null. `ClaudeOAuthFetcher.addLimits` maps known kinds:
  `session` → `five_hour`, `weekly_all` → `seven_day`, and `weekly_scoped` →
  `seven_day_<model>` using `scope.model.display_name`.
- Parse named keys first and skip duplicate `limits` ids. This keeps named keys
  authoritative and trend window ids stable. Ignore unknown kinds.

## Copilot

- `CopilotGitHubClient` uses `gh api /copilot_internal/user`, reusing the
  existing `gh` login; never read its token directly.
- Parse metered `quota_snapshots` such as `premium_interactions` and skip
  unlimited entries. Missing or unauthenticated `gh` means unavailable.
- Copilot is flat-rate here: `usage` remains empty and
  `MenuBarLayout` exposes no `s:copilot` spend item.
- `copilot_internal` is undocumented and must be parsed defensively.

## Provider status

- `ProviderStatusService` polls the public Statuspage endpoints:
  `status.openai.com`, `status.claude.com`, and `www.githubstatus.com`.
  Polling is independently throttled to 30 minutes and is not persisted.
- `RefreshCoordinator.mergeProviderStatus` merges results into the existing
  map. One provider's failed poll must not erase the others.
- Sanitize and length-cap descriptions before rendering.
- Preserve both page-wide (`level`/`description`) and component-filtered
  (`componentLevel`/`componentDescription`) readings. Use page-wide status only
  to explain an unavailable quota fetch; use component-filtered status for the
  healthy-quota banner.
- Relevant component matching uses `codex`, `claude code` + `claude api`, and
  `copilot`. If component data is missing or no component matches, mirror the
  page-wide reading rather than hiding a possible incident.
- Status remains popover-only. Do not reuse the low-quota menu-bar dot for
  provider incidents.

## Refresh coordination

- A forced popover refresh must survive refresh coalescing. Queue its scoped
  usage request behind an in-flight refresh instead of dropping it, and do not
  scan unrelated providers merely because their menu-bar slots are visible.

## Pricing and quota trends

- `PricingService` fallback order is LiteLLM → models.dev → bundled
  `Resources/embedded-pricing.json`; cache results under Application Support.
- `QuotaTrendTracker` bounds observations per `(provider, windowID)`, never
  globally: every sample inside `fullFidelitySpan` (60 min) is kept, older ones
  are decimated to one per `decimationInterval` (5 min), anything past
  `maxObservationAge` (24 h) is dropped, and one window holds at most
  `maxObservationsPerWindow` (400). Decimation buckets are keyed off the epoch
  clock and oldest-per-bucket wins, so re-thinning an already-thinned history is
  idempotent. A global cap starves every window at once: five windows sampled
  once a minute cannot each hold an hour under a 200-sample budget.
- Two rates, both owned by the tracker. `nowPercentPerHour` reads the drain
  across `nowMaximumSpan` (5 min), or back to the newest sample at least
  `nowTriggerPercent` (3 points) above the current value when a burst crosses
  that inside the span, floored at `nowMinimumSpan` (2 min). `percentPerHour`
  averages over `shortAverageSpan` (20 min) or `longAverageSpan` (24 h),
  anchored on the carry-forward value at the window boundary. `now` answers
  "how fast right now", the average "how long at the recent pace" — one number
  cannot do both.
- Long-horizon windows (`.paceOnly`: weekly, one-time credits) do not read the
  flat five-minute slice. A weekly point is a large slice of the pool, so at an
  ordinary pace the integer steps every twenty to forty minutes (measured: two
  steps in an hour against eighteen on the 5-hour window), and a five-minute
  slice reads 0 almost always and 12%/h for the five minutes after a step —
  neither is the pace. Their `now` anchors on the sample right after the step
  before the latest one (`latestStepAnchor`): the latest step, over the time
  it has taken so far — its true pace the moment it lands, fading as the next
  fails to arrive. The anchor never sits further back than the carry-forward
  sample at the `nowStepLookback` boundary (60 min; that sample itself is
  accepted up to `nowAnchorSlack`x older), so a window that has not stepped
  inside the hour reads a flat zero across it; a boundary sample past that
  (hours of gap) gives way to the oldest *earlier* sample inside the lookback,
  and when the current sample is the only one there — the first refresh after
  a lid-closed gap of 90 min to a day — `now` is omitted rather than read as 0
  over no time. Every `now`, whatever the anchor, needs at least
  `nowMinimumSpan` (2 min) of span: one refresh is never the whole reading,
  so a point landing a minute into a fresh pool does not print 60%/h. A burst that crosses
  `nowTriggerPercent` inside the five-minute slice still reads like a short
  window's. A fixed longer ceiling (60 min) was tried first and rejected: an
  hour-long average is `avg` under the wrong label, whereas the step span
  shrinks to minutes the moment the window is actually busy.
- On a short-horizon window `now` is dropped when the span it could read is
  no shorter than `avgSpan`, so a young history never prints one number twice;
  that lasts the five minutes after a reset. A long-horizon window keeps `now`
  even then: its step anchor is bounded by the hour-long lookback, so the two
  spans only coincide while history is shorter than that hour (a fresh install,
  a wake after the 24-hour age cap emptied the pool — a weekend with the lid
  closed does it — or the sample after a rise), and an hour of weekly rows
  showing only `avg` read as the segment having been removed. A `now` that
  equals `avg` is the honest reading of a young history.
- Span length costs resolution, and the numbers were picked against measured
  history rather than taste. `utilization` arrives as whole integers, so a
  W-minute span resolves only 60/W %/h. At two minutes `now` reads in 0/30/60/90
  steps and reports a flat 0 for ~42% of the ticks of an actively draining
  5-hour window (~89% for a weekly one) because the integer has not moved in
  that slice; at five minutes that is ~17% at a 12%/h resolution, readable
  against a short window's 20-50%/h budget. On a short window a steady 1%/h
  drain still reads 0 — 0.08 points in five minutes is under the 0.1-point
  floor separating drain from rounding; a long window reads it through the
  step lookback (one point over the hour). `avg` is what carries a usable
  number; `now` is the twitch.
- The short slice needs dense sampling to exist at all: its anchor may carry
  forward only `nowAnchorSlack` (1.5x) the ceiling, so a gap over 7.5 minutes —
  the 15-minute background refresh cadence included — omits `now` rather than
  stretching it. The step anchor's span is tens of minutes by nature, so it
  tolerates that cadence and only applies the same 1.5x rule to its hour-long
  lookback.
- `shortAverageSpan` bounds how far the run-out estimate can reach, through
  `maxExtrapolationMultiplier`: evidence may only project 6x its own span, so
  at 20 minutes a short window's "would run out in" line can only appear when
  depletion is within 2 hours (10 minutes would cap it at 1 hour, 60 minutes at
  6). It also has to stay well above `nowMaximumSpan`, or the two rates
  converge and the row prints one number twice: at a 10-minute average the
  burst case reads avg 36%/h against a 21%/h budget, losing exactly the
  separation the pair exists to show. Changing either span means re-deciding
  that multiplier.
- Everything that projects forward reads the average: the depletion estimate,
  the `.atRisk`/`.watch` decision, the extrapolation limit and the evidence
  gate. `now` is a readout only; never feed it into an ETA.
- Show runway only when the current pace would exhaust that same window before
  reset. Suppress a longer-window projection when a shorter hard limit would
  stop usage first.
- A shorter peer with a known `QuotaWindow.cycle` also floors the estimate:
  both windows count the same tokens, so the longer one can lose at most the
  measured drain ratio × the peer's remaining points before the peer refills
  and ratio × 100 per peer cycle after — an `avg` projection sooner than that
  even-pace floor is replaced by it (`QuotaRunway.pacedBy` names the peer), or
  by `.safe` when the floor lands past the window's own reset. The ratio is
  read over the raw per-window histories, skipping pairs where either window
  rose, and needs 3 window points and 10 peer points before integer
  quantisation stops dominating (measured: the weekly drains ~0.13 and the
  Fable weekly ~0.24 points per 5-hour point). Codex fills `cycle` from
  `limit_window_seconds` / `windowDurationMins`, Claude from the window key,
  Copilot leaves it nil.
- Extrapolation is trusted only up to `maxExtrapolationMultiplier` (6x) the
  observed span, and a window resetting beyond `longWindowHorizon` also needs
  `longWindowMinimumAtRiskEvidence` (30 min) of history. Failing either
  downgrades `.atRisk` to `.watch`.

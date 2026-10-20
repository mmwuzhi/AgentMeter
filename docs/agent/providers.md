# Provider and quota invariants

Read this file before changing provider fetchers, usage scanners, quota models,
provider status, pricing, refresh coordination, quota trend logic, or the
history store (`Services/History`).

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
- Usage/spend comes from per-day `last_token_usage` in rollout logs, each
  delta attributed to the model the session last named, and rolled up per
  (day, model) through `UsageRollup` like Claude's.
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
- The scrape runs when there is no readable token or OAuth answers 401, and
  on any other OAuth failure (5xx, offline; a 429 never scrapes) only when
  there is no live reading worth keeping: `ClaudeService.oauthFallback`
  returns `.unavailable` while the previous snapshot is `.oauth`, still has a
  usable window, and is at most `recentLiveQuotaMaxAge` (1 h) old, so
  `preservingLiveQuota` keeps the live reading and the stale banner reports
  the failure. `claude /usage` hits the same endpoint with the same token and,
  when that fails, prints the `cachedUsageUtilization` it keeps in
  `~/.claude.json` — a scrape under a 429 is never fresher than the live
  reading it would replace, and it costs a full Claude Code session start.
- After the CLI exits, `ClaudeCLIScraper.cachedReadingTime` compares every
  scraped window with that cache (same window id, within one point — the
  panel prints whole percents). When they all match, the snapshot's
  `cachedAt` is the cache's `fetchedAtMs`: the numbers were measured then,
  possibly days ago.
  `fetchedAt` stays the scrape's own time on purpose: the forced-refresh
  spacing reads it, and dating it back would let a wake re-read OAuth at
  once. The output itself cannot tell: on a pipe the CLI runs in print mode
  (`Current session: N% used · resets …`), which prints a cached reading
  without any annotation. Rows the cache holds no named figure for — a
  model-scoped weekly printed from `limits[]` as `Current week (<model>)` —
  are compared with that `weekly_scoped` limit; a row with no figure at all
  is left out of the comparison, and at least one row must compare. The
  config file is resolved as Claude Code does: a non-empty regular
  `<config home>/.config.json` (symlinks followed) first, else `.claude.json`
  (`.claude-custom-oauth.json` under `CLAUDE_CODE_CUSTOM_OAUTH_URL`) in
  `$CLAUDE_CONFIG_DIR` or the home directory. `readingTime` is
  `min(cachedAt, fetchedAt)`, or `fetchedAt` without a cache time. A cache
  more than `QuotaSnapshot.staleCacheTolerance` (5 min) older than the scrape
  makes the snapshot `echoesStaleCache`: never an observation, never handed
  to alerts (`RefreshCoordinator.notificationWindows(for:)`), counted as a
  failed cycle and marked stale at once (the banner, dated by `readingTime`,
  shows on the first cycle — the two-failure threshold is for blips, and an
  echo is dated). `preservingLiveQuota` keeps a usable reading on screen
  whose `readingTime` is at least the echo's; with nothing usable there the
  echo is shown as the CLI fallback. Request spacing, reading time and what
  is shown are kept apart: `RefreshCoordinator.lastQuotaRead` records each
  fetch that brought back a reading, and `lastLiveQuotaFetch` takes the later
  of that and the shown snapshot's `fetchedAt`, so keeping an older reading
  on screen never releases a forced refresh earlier than showing the echo
  would have (`testKeepingTheOlderReadingSendsNoExtraQuotaRead`). Copilot's quota also uses `.cli`; nothing
  filters on that source.
- `/api/oauth/usage` answers 429 to a burst of requests and can then
  refuse further requests for several minutes. Every
  request to the endpoint therefore goes through `ClaudeUsageGate`: a 429
  (quota or reset read) blocks all of them — the quota read, the reset read
  and the `claude /usage` scrape, from any trigger, "Refresh now" included —
  until `Retry-After` (honoured in full, rounded up to 15 s; a value over 24 h
  or an unreadable one counts as missing) or, without it, 60 s doubling to
  5 min. A 200 lifts the wait only if its request was sent after the latest
  429 was learned of, since answers arrive in completion order; several 429s
  from requests sent before the wait began count as one. The fetchers and the
  scrape check the gate again right before sending, because the credential
  read can wait on the Keychain while another refresh is told 429. While
  blocked a cycle sends nothing and returns the "rate-limiting"
  `.unavailable` note, so the last live reading stays and the stale banner
  takes over as for any failed cycle. The wait lives in memory only: a
  relaunch sends one request and learns it again. Response headers are not in
  the unified log, so whether the server sends `Retry-After` is unconfirmed;
  both cases are handled.
- `/api/oauth/usage` carries no plan field. `ClaudeOAuthFetcher.planType`
  precedence is explicit response key >
  `ClaudeCredentials.Token.subscriptionType` (Claude Code's
  `claudeAiOauth.subscriptionType`, from the same Keychain item /
  `.credentials.json`) > `inferredPlanType` window-shape guess. A Team premium
  seat's windows (`five_hour`, `seven_day`, `seven_day_fable`) make the guess
  say pro, which is why the credential outranks it.
  The credential is read with the token and cached with it
  (`ClaudeCredentials.Cache`), so after a plan change the badge can lag the
  live windows for the token's remaining life — until expiry, a 401 or a
  relaunch re-reads the Keychain — where the window-shape guess it replaced
  tracked the response within a tick. Accepted: a plan change is rare and a
  relaunch corrects it, while re-reading on disagreement would re-prompt every
  tick for a Team seat, whose guess ("pro") never agrees with its credential.
  Every plan source — credential, response field — passes
  `PlanLabel.normalized` (ASCII, at most 32 characters) or counts as unstated,
  and the CLI scrape carries the credential's plan and tier the OAuth path
  held when it failed, so the badge survives the tick a rejected token spends
  on the scrape.
- `ClaudeCredentials` also reads `claudeAiOauth.rateLimitTier` (e.g.
  `default_claude_max_5x`), validated against `^[a-z][a-z0-9_]{0,63}$` —
  Claude Code's own check for the field — and carries it on
  `QuotaSnapshot.rateLimitTier`. `QuotaSnapshot.planBadge` marks a Team
  premium seat as `team` + `default_claude_max_5x`, the exact test Claude
  Code's binary uses; no field spells "premium", and `seatTier` in
  `~/.claude.json` is opaque and unused. Any other plan keeps the plan
  uppercased, with the raw tier in the badge tooltip when it is known.
- Claude Code may persist `expiresAt: 0` as an unknown-expiry sentinel. Keep
  that token cached until a real HTTP 401; rate limits and transient server
  errors must not invalidate it because the next Keychain read may prompt.
- Coalesce concurrent credential cache misses into one read. Sleep/wake and a
  stalled refresh can overlap, but must never queue multiple Keychain prompts.
- Usage/spend comes from `ClaudeJSONLScanner` over
  `~/.claude/projects/**/*.jsonl`, one record per `message.id|requestId`.
  Dedup is global across files, not per file: resuming a session copies the
  earlier transcript into a new file, so the same assistant message is present
  in both. Per-file dedup double-counted ~10% of all tokens and nearly doubled
  the oldest days.
- Which record of a key counts (`KeyedUsage.outranks`, the same in a file,
  across a resume boundary and across files): a record with a `stop_reason`
  (final) beats one without (partial, written mid-stream), which beats a
  zeroed replay (top-level `input/output/cache_read/cache_creation_input_tokens`
  all 0 — a resumed session re-appends old messages this way, keeping the
  `cache_creation` split, `iterations` and the stop reason, so zeroed is
  judged before the stop reason); of two partial records the larger output
  wins; otherwise the earlier one stays (path order across files). One whole
  record is taken, never a per-field maximum — but a record that replaces
  another keeps the day the request was first counted on
  (`KeyedUsage.replacing`, unless that was a zeroed replay): a request whose
  final record lands after midnight would otherwise move to the next day,
  and a windowed scan cannot lower the old day in the spend ledger, so the
  all-time total and the heatmap would count it twice until the next
  complete scan. In subagent and workflow
  transcripts the early records carry `message_start` usage,
  so first-wins undercounted their output.
  Since Claude Code 2.1.282, sidechain requests can have **no** final
  record at all: their output is a lower bound that no transcript can
  complete. Each record keeps its `UsageFinality`, and the report carries
  per-day `requestFinality` (final / partial / zeroed requests, partial
  output) so later phases can show or correct it; nothing here estimates the
  missing output. When `usage.iterations` has more than one element (a Fable
  attempt that fell back to Opus) each iteration counts under its own model
  and the top level, which repeats only the last call, is not added on top.
- Both scanners hand their per-(day, model) counts to
  `UsageRollup.report(provider:entries:table:)`. The report carries the counts
  themselves (`dayModels`: what the spend ledger stores and what every
  on-screen dollar figure is priced from, see [ui-state.md](ui-state.md))
  beside `buckets`, `totalCostUSD` and `byModel`, which are priced once under
  the scan's `PricingService.snapshot()` only for older builds reading
  `last-state.json`. Nothing in this build reads those dollars back.
- Most refreshes read only files touched in the last `usageHistoryDays` (31).
  Every `fullHistoryInterval` (6 h), and once per launch, the scan reads every
  file instead and marks the report `isCompleteHistory`; which scans do so is
  `RefreshCoordinator`'s decision (`usageReport(completeHistory:)`), counted
  from the last complete report that landed. Only such a report may
  lower a stored `LifetimeSpendTracker` day; a windowed one can only grow days,
  since a day shrinking there just means its files left the window. Either
  way the ledger takes the day's counts (tokens decide whether a windowed day
  has grown); the `costUSD` written beside them is for older builds only and
  nothing here reads it back. A complete scan once re-priced every stored
  dollar figure under the table the process held, and that is how the
  all-time total moved by $1,400 with no usage behind it.
- `ClaudeJSONLScanner` reads through `ClaudeUsageCache`: the in-memory
  `LogFileParseCache` every scan consults first and, for the app
  (`ClaudeUsageCache.shared`), a `ClaudeUsageCacheStore` under
  `~/Library/Application Support/AgentMeter/claude-usage-cache-v3/` — one entry
  file per log file, named by a digest of the log's resolved path, holding
  the log's fingerprint, the parsed byte boundary and a `ClaudeFileUsage`:
  per record a 128-bit `DedupKey` (SHA-256 of `message.id|requestId`,
  truncated; never Swift's seeded `hashValue`), day, finality, model and
  counts (plus each earlier iteration's model and counts), and the unkeyed
  sums. No conversation text. Without it the first scan of a
  launch and the 6-hourly complete scan re-parsed every file; with
  it they stat every file and read only what changed.
- An entry is used only while the log's fingerprint (size, mtime, inode)
  matches it exactly, or as the head of a resume when the same inode grew
  past the boundary under a date no older — and the 4 KiB before the
  boundary still digest to what was stored (`boundaryDigest`: the first 14
  bytes of their SHA-256, `boundaryDigestLength`, the most a `Data` holds
  inline, so no file's cached value carries a heap object for it), so a file
  rewritten in place to something longer reads from the top when the change
  reaches those 4 KiB. The same size under a newer mtime is a rewrite, not an
  append (`LogFileParseCache.canResume`). Truncation, replacement (new inode),
  a version or calendar-tag mismatch (days are cut at local midnight, so the
  time zone is part of validity), a failed SHA-256 trailer or a torn file all
  discard the entry and parse the log again: the cache is never the only
  source of a figure.
- The resume relies on Claude Code only appending to a transcript. Two
  in-place changes break that and go unseen: one that keeps size, mtime and
  inode (`rsync --inplace` with preserved times), and one that ends before
  the 4 KiB sample in a file that also grew. The second resumes as an
  append, so the changed records never reach the cache, the report or the
  history, while a cold parse of the same file reads them (only a file
  already past 4 KiB at the earlier scan can be affected). Neither has been
  seen from Claude Code.
- Entries are written whole (temp file + `rename`, no fsync — a crash
  mid-write fails the checksum and re-parses), only after a parse that
  committed new newline-terminated bytes; a trailing partial line is shown but
  never stored. Only a complete scan may prune the store, to the files it
  listed (an empty list prunes nothing), because a windowed scan lists only
  recent files and the next complete scan needs the rest; the memory cache is
  still pruned to the scan's files every time, so the old corpus lives on disk
  between complete scans, not in memory. Each scan takes a ticket from
  `LogFileParseCache.beginScan`, and neither cache lets a scan that started
  earlier overwrite what a later-started one stored (refreshes stalled past
  30 s do overlap). Bump `ClaudeUsageCacheStore.formatVersion` whenever the
  layout or what `consume` records changes. There is one directory per
  RELEASED format (`claude-usage-cache-v<directoryFormat>`; version 1 used
  `claude-usage-cache`), so when the version being replaced has shipped,
  move `directoryFormat` with it: a build deletes entries it cannot decode
  and prunes files it did not write, so an installed older build running
  beside a newer local one would otherwise throw away each other's entries
  at every complete scan. Version 3 never shipped, so version 4 kept its
  `claude-usage-cache-v3` directory (`directoryFormat` 3): a version-3 entry
  there fails the version check, is deleted and its log parsed again, and
  `legacyDirectories` stays `claude-usage-cache` and `claude-usage-cache-v2`.
  The first launch of a new format therefore parses the whole corpus once
  in the background; a complete scan removes a legacy
  directory nothing has written for `legacyIdleInterval` (7 days). Everything a resumed parse
  compares (`finality`, output) is in the entry, so a final record appended
  after the cached boundary replaces the streaming one exactly as a parse
  from the top does. `ClaudeUsageCacheGoldenTests`
  parses one fixture with and without the store and requires identical
  reports across append, truncation, replacement, same-size edit, deletion,
  corruption, version change, torn write and concurrent scans;
  `usageReport(files:)` defaults to `ClaudeUsageCache.memoryOnly`, so tests
  never touch the real store.
- Version 4 (in `claude-usage-cache-v3`) holds what the history store
  reads, so it never re-parses a transcript: per keyed record a
  `RecordStamp` of absolute Int64 Unix-ms times (`firstMs` = MIN over every
  record of the key in the file, zeroed replays included; `latestMs` = MAX
  over its non-zeroed records; `ownFinalMs` = the standing record's own
  time, final records only; `RecordStamp.noTime`, `Int64.min`, = not
  stated), its thinking tokens, an index into the file's interned (version,
  effort, entrypoint) sets and the `fast` / `abortedMidStream` flags OR-ed
  over every record: 31 bytes on disk, 101 for the whole keyed record
  (`keyedRecordLength`). Version 3 stored the later times as u32 offsets
  from the first, which a span over 49.7 days could not hold. The stamp is
  declared before `finality`, which then fills its last padding byte:
  `KeyedUsage` has a 120-byte stride this way, 128 the other
  (`ClaudeUsageStampTests.testKeyedUsageStrideIsPinned`). Per file: the
  attribute sets, the running MAX usage time, the first-of-key record's cwd
  / entrypoint / version, and the `<synthetic>` 429 limit events, `/usage`
  reports, `cost-state` records and `compact_boundary` records (the global
  scan only: `ParseState.collectsExtras`; the session path reads none).
  `replacing` and a record that does not stand fold their times into the
  held stamp (first = MIN, last = MAX; the standing record's own final time
  stays); stamps never decide which record counts. The codec is lossless —
  limits (labels 1–64 printable ASCII bytes, cwd ≤ 4,096 bytes, ≤ 4,096
  events per kind) are applied when a record is parsed, never when it is
  encoded; strings decode strictly, and a stamp no parse can produce is
  rejected (a time beyond ±10^15 ms, a later time without a first one,
  last < first, a final time outside [first, last] or on a non-final
  record, a last time on a zeroed record) — so a resumed parse continues
  from exactly the state a parse from the top reaches
  (`ClaudeHistoryBatchTests` resumes at every line boundary). Reads stop at
  the fingerprinted size, so an entry never claims more bytes than its
  fingerprint.
- With a `history` (`HistoryIngesting`), `usageReport(files:)` hands it one
  `HistoryScanBatch` per scan after the last file, synchronously and without
  awaiting it: a `HistoryFileBatch` per listed file whose read did not fail,
  carrying the committed state only (never the unterminated last line), the
  watermark (fingerprint, parsed bytes, boundary digest, format version),
  and for a resumed parse a delta of every keyed record whose value differs
  from the base in any field, stamps included (`ClaudeHistoryBatch.swift`).
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
- Limit resets (program `cedar_ember`, launched with Opus 5.5) come from
  `ClaudeResetGrantFetcher`: `GET /api/oauth/usage?cedar_ember=1&skip_spend=1`,
  the variant Claude Code itself sends for reset status, read separately from
  the quota call because what `skip_spend` drops is unverified. The schema is
  Claude Code 2.1.292's (`eligible`, `ineligible_reason`, `grants[]` with `id`
  `^[a-z0-9_-]{1,40}$`, integer `resets_left`, ISO `ends_at`, `clears`
  filtered to its known limit keys); follow it rather than guessing. The count
  is the sum of `resets_left`, paused grants included, as Claude Code sums it,
  over grants still before `ends_at` and capped at 20 grants. A null or missing
  block is a real "no resets"; a malformed block — including a `grants` that is
  neither an array nor null, which Claude Code would read as none — keeps the
  previous state and dumps only the block to
  `~/Library/Application Support/AgentMeter/debug-claude-reset-grants.json`.
- The reset read runs only after that cycle's OAuth quota read succeeded, with
  `ClaudeCredentials.cachedToken()` (never a Keychain read of its own), every
  20 minutes on its own clock; a cycle that sent no reset request does not
  advance that clock. "Refresh now" reads it too, but not within 60 s of the
  last read, and refreshes that overlap share it (`ClaudeUsageGate.readResets`:
  a caller joins a read in flight, or takes the state of one that succeeded in
  the last 60 s, so a refresh whose plan cannot see an unlanded read still
  does not send a second): each read is a second `/api/oauth/usage`
  request, and repeated requests can hit a rate limit. It
  times out at 8 s because it holds back the whole refresh's landing. It sends `claude-cli/<version> (external,
  cli)` because the block can answer `ineligible_reason: cli_version`; a 401
  there never invalidates the credential cache — the quota read owns that.
  `ClaudeResetState.ineligibleReason` is stored for diagnosis only. Spending a
  reset (`POST /api/organizations/{org}/reset_rate_limits`) is deliberately
  not implemented: it is a write on an undocumented endpoint that Claude Code
  itself keeps behind a feature flag.

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
- When the 30 s escape starts a second refresh beside a stalled one, only the
  latest-started refresh may land its result. A superseded refresh that
  finishes later is discarded whole (state, trend samples, cache,
  notifications, refresh markers). "Latest landed" would not do, because a
  refresh merges into the snapshots it captured at its start.
- `QuotaTrendTracker.record` stamps a sample at the snapshot's
  `readingTime`, not at landing, records its `source`, and adds a window's
  sample only when it is later than every sample already held for that
  window. A snapshot `preservingLiveQuota` kept across a failed or
  rate-limited cycle, or one restored from `last-state.json`, therefore adds
  nothing; before, each such cycle re-recorded the old numbers at the current
  time. Observations from older builds carry no `source` (unknown); anything
  that may only trust Claude's live reads has to require `.oauth`. Pace and
  runway still read every source, as before; the up to 24 h of history an
  older build left, CLI echoes stamped "now" included, ages out on its own.
  A held sample dated after `now` (the clock was set back) is dropped: kept,
  it would stall recording or sort last and stand in for the newest reading
  until the clock caught up.
- A forced (popover-open, wake) refresh skips the quota fetch for a provider
  whose last live reading is younger than
  `ProviderRefreshPlan.minimumForcedQuotaSpacing` (20 s); usage and
  active-agent work still run, timer ticks and `forceAll` are unaffected, and
  a provider whose fetch is failing is never held back. Seven
  `/api/oauth/usage` requests in 50 s produced a 429 streak. "Refresh now"
  (`forceAll`) applies the same spacing to Claude alone: a click queued behind
  a running refresh replays when it lands and can otherwise repeat the quota read.
- A refresh stalled past 30 s lets a second one start beside it, and the
  stalled one still sends its requests. Anything that must not be sent twice
  therefore needs a guard at the request, not only in `ProviderRefreshPlan`,
  which only sees what earlier refreshes have landed. `ClaudeUsageGate` does
  this for the Claude quota read (joined while in flight; refreshes stacked
  behind a Keychain prompt would otherwise all send when it is answered) and
  the reset read. A read in flight longer than its request timeout plus margin
  (20 s quota, 10 s reset) is not joined, so a hung one cannot capture every
  later refresh. Other requests of a stalled-and-escaped pair (status pages,
  Codex) are still sent twice.
- Claude's usage scan is not part of the refresh that asks for it. The first
  scan after launch reads every log file and used to hold that refresh whole: the
  quota read it was started beside, the reset read sequenced behind it, every
  other provider's result, and `isRefreshing`, which is how the 30 s escape
  started a second refresh that parsed the same files beside it and left the
  first — complete-history report included — to be discarded. Now
  `RefreshCoordinator.startClaudeUsageScan` runs the scan in its own task;
  the refresh reads Claude's quota alone (`ClaudeService.fetch(refreshUsage:
  false)`), reads the reset grants right behind it, lands with the other
  providers, and keeps whatever usage is on screen rather than the usage it
  captured at its start. The scan lands through `applyClaudeUsage` whenever it
  is ready, onto whatever quota is on screen then, and carries its report into
  the spend ledger and `last-state.json` as the refresh used to. Quota
  observations, staleness and notifications belong to the live reads only.
  One scan at a time: a refresh that wants usage while one runs takes that
  scan's result instead of starting another. Whether a scan reads every file
  is decided in the coordinator (`claudeCompleteHistoryDue`): the first scan
  of the process, then one every `ClaudeJSONLScanner.fullHistoryInterval`
  counted from the last complete report that landed, so a complete scan whose
  result never applied (the process stopped) is not counted as done.
  `RefreshEnvironment` is the seam the coordinator reaches providers and
  persistence through; `RefreshCoordinatorDecouplingTests` drive these
  orderings with latches, not clocks.
- While Claude is rate-limiting, cycles the gate skips still count as failed
  quota cycles, so the stale banner shows from the second one. An isolated 429
  therefore shows it after one tick, where a plain retry used to clear it; the
  server's block lasts about five minutes either way.

## Pricing and quota trends

- `PricingService` layers one `PriceTable`: the bundled
  `Resources/embedded-pricing.json`, the cached network table (`pricing.json`
  under Application Support) merged over it, then whatever `refresh()` fetches
  — LiteLLM, else models.dev — persisted back to that cache. `localTable()`
  (bundle + cache, readable without the actor) loads the cache however old it
  is: age decides nothing now, `refresh()` re-fetches at every launch anyway,
  and a stale cache still knows every model the network did where the bundle
  alone may not. `snapshot()` is the table as it stands;
  `AppViewModel.priceTable` holds the one every on-screen dollar figure uses
  (see [ui-state.md](ui-state.md)), starting from `localTable()` so restored
  state is priced at once.
- The bundled `embedded-pricing.json` must list every model in current use
  with its own cache-read price — 0.1× input as a rule, 0.025× on Fable 5.1,
  0.05× on Opus 5.5 — checked against
  https://platform.claude.com/docs/en/about-claude/pricing. A model missing
  from it prices at the `default` 3/15 entry, which is what a launch whose
  network table had not arrived priced the whole ledger under.
  `PriceTableTests.testBundledTableCarriesTheModelsInUse` pins the entries.
- `PriceTable.price(for:)` takes the exact id, else the longest key that is a
  prefix of the id or that the id is a prefix of (a transcript's dated
  `claude-opus-4-8-20260101` finds `claude-opus-4-8`; a bare `claude-opus-5`
  finds `claude-opus-5-5` only while no `claude-opus-5` key exists), equal
  lengths alphabetical, else `default`, else `PriceTable.unknownModelPrice`.
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
- **Every** window anchors `now` on the sample right after the step before the
  latest one (`latestStepAnchor`): the latest whole-point step, over the time it
  has taken so far — its true pace the moment it lands, fading as the next fails
  to arrive. This was once long-horizon only, with short windows reading a flat
  five-minute slice, and that slice was the bug: `utilization` arrives as whole
  integers, so five minutes resolves only 12%/h, and a 5-hour window draining at
  3%/h drops a point every twenty minutes, so the slice read a flat 0 three
  ticks in four through an active session. A stale-but-true rate beats a fresh
  false one. `now` may therefore span more history than `avg`, and may repeat it
  on a young history; the view compensates where it matters (see
  [ui-state.md](ui-state.md) on the budget colour).
  The anchor never sits further back than the carry-forward sample at the
  `nowStepLookback` boundary (60 min; that sample itself is accepted up to
  `nowAnchorSlack`x older); a boundary sample past that (hours of gap) gives way
  to the oldest *earlier* sample inside the lookback, and when the current
  sample is the only one there — the first refresh after a lid-closed gap of
  90 min to a day — `now` is omitted rather than read as 0 over no time. Every
  `now`, whatever the anchor, needs at least `nowMinimumSpan` (2 min) of span:
  one refresh is never the whole reading, so a point landing a minute into a
  fresh pool does not print 60%/h. A burst that crosses `nowTriggerPercent`
  inside the five-minute slice still wins over the step anchor, so a spike is
  read on the minutes it happened in.
- A span with no drop in it is **not** reported as 0. Utilization is whole
  points, so it only bounds the rate: under one point (`nowResolutionPercent`)
  in however long the window has been still. `now` reports that ceiling with
  `QuotaRunway.nowIsUpperBound` set and `nowAnchor == .flat`; the two are
  written in one place and always agree, and the view renders the figure with a
  `<`. The bound's span is measured from the last movement rather than from the
  lookback cap — the cap exists to stop an hours-old *slope* being called "now",
  and a longer flat stretch only makes a bound tighter — so an idle window
  converges toward zero instead of parking at one point per hour. "0%/h" while
  the user is mid-session was the reported bug.
- Past `flatThreshold(for:)` the window is read as dormant (`nowAnchor ==
  .dormant`) and the view stops printing a rate at all, saying how long it has
  been still instead. Checked *before* the step anchor: two old steps still
  yield a measured rate, so a window that stopped an hour ago would otherwise
  keep printing the pace it held while running. The threshold is
  `modelScopedFlatThreshold` (10 min) for a weekly the provider scoped to one
  model and `nowStepLookback` (60 min) for the rest. A scoped weekly drains only
  while its one model runs, so it ticks steadily or stops dead.
  Scoping is read from `QuotaWindow.isModelScoped`, set from Claude's
  `kind == "weekly_scoped"` — a documented `limits` field. Never match on the
  model name: `scope.model.id` is null in live responses, so the window id is
  built from a display name, and joining that to a session's raw model id would
  be a guess. Nothing here needs to know *which* model is running; the provider
  already reports that window's own percentage.
- "Still" is measured against the current value, not step to step: the newest
  sample more than the rounding floor above it, then the sample after that (the
  first reading at today's value, which is when it demonstrably settled). A
  step-to-step test assumes whole-point reporting, and a window draining
  smoothly in sub-0.1 increments takes no such step, so it read as still for its
  whole history while draining a steady 1%/h. Taking the high sample itself
  instead of the one after it claims stillness from before the drop, which reads
  as hours of quiet on a window that drained across a sampling gap.
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
  and ratio × 100 at each peer reset after. A refill lands whole and is spent
  at the `avg` pace, so the floor is the refill that finally covers the rest
  plus the time to spend it; an `avg` projection sooner than that is replaced
  by it (`QuotaRunway.pacedBy` names the peer), or by `.safe` when the floor
  lands past the window's own reset. Do not spread a refill evenly across its
  cycle: that reads later than any real session can run. A peer
  whose ratio was measured skips the "hits first" rule above when its floor
  does not bite, since that rule ignores the refill. The ratio is read over
  the raw per-window histories, skipping pairs where either window rose, and
  needs 3 window points and 10 peer points before integer quantisation stops
  dominating (measured: the weekly drains ~0.13 and the Fable weekly ~0.17-0.24
  points per 5-hour point). A model-scoped weekly also skips pairs from before
  its first move and from stretches it has sat still past
  `modelScopedFlatThreshold`: peer points spent on other models meanwhile
  diluted its ratio from 0.17 to 0.10. Codex fills `cycle` from
  `limit_window_seconds` / `windowDurationMins`, Claude from the window key,
  Copilot leaves it nil.
- `cycle` is untrusted on every provider but Claude, whose value is derived from
  the window key. It feeds only rules that *suppress* a warning, so a units
  change or a truncated field would quietly take the quota alarm away rather
  than raise a false one. `CodexRolloutReader.cycle(forMinutes:)` therefore
  reports anything outside `minimumCycle`…`maximumCycle` (5 min … 31 days, NaN
  and infinity included) as no cadence stated, which every consumer already
  handles, and the run-out horizon below carries its own independent floor.
  `QuotaTrendTracker.paceStyle` is keyed on it as well, with one exception to
  that shape that is stated rather than hidden: it reads the cycle only when
  credible (the reset no further than one cycle away), and since a credible
  short cycle also puts the reset inside `longWindowHorizon`, it can only turn
  `.paceVersusBudget` into `.paceOnly` — dropping the budget comparison and
  its orange — never the reverse. But the style also picks the `avg` span, and
  the 24 h span can carry a run-out the 20-minute span had just lost: a weekly
  in its last day that drained hard and then idled reads "pace steady" on the
  short span and "would run out in 5h" on the long one (the intended,
  consistent weekly reading), and a wrong *long* cycle on a 5-hour window
  would raise that alarm rather than hide one. Both are pinned in
  `QuotaTrendTrackerTests` (`testWeeklyInItsLastDayKeepsTheLongSpanRunOut`,
  `testAnInflatedCycleRaisesRatherThanHidesARunOut`). Any new rule keyed on
  `cycle` needs the same treatment: suppress-only, or say exactly what it can
  add.
- A run-out date further ahead than `actionableHorizonCycles` (2) x the shortest
  peer cycle drops to `.watch` with no date: past a couple of the peer's refills
  the projection only says "if you hold this pace through several full peer
  resets", which is not something to act on now. Runs last, after the capacity
  floor, because the floor can push the date further out. The peer must refill
  faster than this window (`cycle < window.cycle`) and the window must name a
  cycle of its own, so a window nothing paces — Copilot's allowances — keeps the
  runway it had; and the horizon is floored at `minimumActionableHorizon` (2 h),
  far below any real cadence, so one bad `cycle` cannot hide a run-out an hour
  out.
- Extrapolation is trusted only up to `maxExtrapolationMultiplier` (6x) the
  observed span, and a long-cycle window — one the pace line reads pace-only,
  a weekly in its last day included — also needs
  `longWindowMinimumAtRiskEvidence` (30 min) of history. Failing either
  downgrades `.atRisk` to `.watch`.

## History store (`history.sqlite`)

- `HistoryStore.shared` keeps raw, persistent, incrementally updated,
  idempotent observations in
  `~/Library/Application Support/AgentMeter/history.sqlite` (with `-wal`,
  `-shm` and `history.sqlite.lock`): Claude's requests and transcript events
  from the usage scan, Claude's quota readings and limit-reset grants from the
  refresh. Never inside a `claude-usage-cache*` directory —
  `ClaudeUsageCacheStore.prune` deletes every file it did not write there.
  Nothing reads it in Phase 0B: the usage report, the spend ledger,
  `last-state.json`, `quotaObservations` and every view are exactly what they
  were. No conversation content — no prompt, reply, thinking, tool input or
  output, error text or title. It holds ids (request keys as 16-byte hashes,
  session, agent and run ids, event uuids, request ids, grant ids), times,
  token counts, Claude Code's own per-session cost in USD (`cost-state`),
  `/usage` and OAuth quota figures, model / version / effort / entrypoint
  labels, window metadata, transcript paths and each session's first cwd.
  The paths name the user's projects: private metadata.
  `HistoryPrivacyTests` puts a canary in every text field of every record
  shape and byte-scans everything the scan, the usage cache and the store
  write, `-wal` and `-shm` included.
- Wiring is `RefreshEnvironment.live()` alone: `fetchClaudeUsage` passes
  `history: HistoryStore.shared` to `usageReport(completeHistory:history:)`;
  `recordQuotaReading` maps a landed snapshot through
  `QuotaSampleRow.rows(from:recordedAt:)` (Claude only; no `.unavailable`,
  no `.rolloutFile`, no stale CLI echo; an empty result submits nothing);
  `importLegacyQuota` hands `legacyRows(from:)` once per process (the store
  imports once per database); `recordResetGrants` hands the grant set as read.
  The defaults record nothing, so a test that builds the environment by hand
  never reaches a database, and every history test builds its own store over a
  temporary directory. The file is first opened at launch, by the drain that
  applies the legacy import, on the store's queue.
- Nothing waits for it (`HistoryIngesting`): `submit` is non-isolated, O(1)
  and never throws — it appends to a lock-protected FIFO inbox and starts a
  drain only when none is running (the `draining` flag lives inside the lock,
  so there is exactly ONE consumer and commands apply in call order). The
  store is an actor on a private `.utility` serial queue, so an fsync stall
  (0.4–2.7 s under disk load) never holds the MainActor or a cooperative-pool
  thread. The scan builds one `HistoryScanBatch` from values it already holds
  and returns its report without awaiting the store
  (`HistoryEndToEndTests.testTheReportReturnsWhileTheHistoryIsBlocked`).
  `flush()` is a barrier for tests. `close()` while commands are queued is
  undone by the drain's next command, which reopens: flush first. Quit is the
  one bounded wait (below).
- Tables (`HistorySchema`: `user_version` 1, `application_id` `AMHS`, STRICT,
  SQLite ≥ 3.37): `meta` (accounting zone `acct_tz`, coverage, maintenance
  stamps, `quota_conflicts`), `dict` (interned labels), `session` (one per
  session id, with the first cwd / entrypoint / version of its MAIN
  transcript), `source_file` (one per transcript path: class, session, agent,
  run, `birth_ms`, and the ingest watermark), `request` (one row per iteration
  of one API request — the billable unit), `request_occurrence` (raw facts:
  what each file said about each key), `ingest_scan` (one row per scan that
  wrote a file or read every file: start, landing, complete or not, files,
  files written — "requests complete through T" for attribution),
  `quota_sample`, `reset_event`, `reset_grant_sample`, `limit_event`
  (`<synthetic>` 429s), `usage_report_sample` / `usage_report_limit`
  (`/usage` runs), `cost_state_sample` / `cost_state_model` (Claude Code's own
  per-session totals), `compact_event`. Surrogate ids (`file_ref`,
  `session_ref`, dict ids, rowids) are arrival-order artefacts: never
  compared, never persisted outside the database, never keyed on.
- Request identity is `(key, iteration_idx)`: `key` is the 16-byte
  `DedupKey` (`message.id|requestId`; unkeyed records are not stored),
  `iteration_idx` the position in `usage.iterations` when it has two or more
  elements (else 0). Of every observation of a key the one with the highest
  rank `(ingest_version, finality, output_total, rec_sig, −final_ms)` writes
  the rows; `rec_sig` hashes billing content only (finality, parts, thinking —
  no times, labels or flags); rows of a losing shape are deleted, so idx 0
  always holds the winner. `thinking` sits on the last iteration's row. The
  record that counts follows the scanner's `KeyedUsage.outranks`; the two
  orders differ only when two records of one finality carry different counts
  (two finals, or two partials with equal output): the scanner keeps the
  first in path order, the store the higher rank. Never seen in the corpus.
- An occurrence `(key, file)` keeps NULL-aware MIN first / MAX last times, the
  attributes of that file's standing record (replaced only by a greater
  `(ingest_version, finality, output, att_sig)`; `att_sig` is signed 64
  bits like `rec_sig`: its high 32 bits are `rec_sig`'s, its low 32 hash the
  billing content AND the version / effort / entrypoint labels, so a
  transcript rewritten in place keeps the same attributes in every arrival
  order, and when its two contents' counts differ the attributes come from
  the content `rec_sig` ranks higher, as the row's counts do), and flags
  OR-ed. The OWNER of a key
  is the occurrence with a counted record (`last_ms` not NULL) whose file was
  born first, ties and unknown births by path bytes: a fork copies its
  parent's prefix into a newer file, and path order alone mis-attributes 605
  of 2,957 cross-file keys. `owner_file_ref`, `session_ref`, `class`,
  `last_seen_ms` and the attributes are the owner's; `first_seen_ms` is the
  MIN over occurrences, `flags` the OR, `acct_day` the day of
  `first_seen_ms`. All derived, recomputed after every observation, and pure
  functions of stored facts plus the zone and birth times.
- Times are Unix ms UTC; NULL is "not stated", never `Date()`:

  | column | meaning |
  |---|---|
  | `first_seen_ms` | MIN time over every record of the key in every file, zeroed replays included (they keep the original's time). Identity time. |
  | `last_seen_ms` | MAX time over the key's non-zeroed records in the OWNER file: the EVENT time for quota attribution (about the request's end). For a partial-only request (most 2.1.282+ sidechains) the last streamed block, a lower bound. |
  | `final_ms` | time of the counted record when it is final; provenance only, not a completion time. |
  | `acct_day` | YYYYMMDD of `first_seen_ms` in the Gregorian calendar under `meta.acct_tz` (never `Calendar.current`'s calendar). A final after midnight never moves it, the same day the ledger keeps (`KeyedUsage.replacing`). The day cache takes the day's own interval (`Calendar.dateInterval(of: .day)`) and never caches a day whose UTC offset differs at its two ends, so a DST change at midnight (Santiago, Cairo, Havana, Asuncion, Beirut, Azores; historically Sao Paulo, Tehran, Amman, Damascus, St_Johns) files every instant on Foundation's day: checked against uncached Foundation around every transition near midnight of every known zone, 2010–2027 (`HistoryDayTests`; `AGENTMETER_HISTORY_TZ_SWEEP=1` runs the full 21.2 M-instant sweep of every transition). |
  | `reading_ms` | `quota_sample`: when the numbers were measured (`QuotaSnapshot.readingTime`), raw; `recorded_ms` is the landing. |

  Append order is not time order:
  nothing derives time from file position. The accounting zone:
  `HistoryStore.shared` follows `TimeZone.current` (the zone of the ledger's
  `Calendar.current` days) and re-reads it before every command and every
  read; once `TimeZone.current` reports another zone, the next scan or read
  recomputes every `acct_day` in one transaction. Whether a running process
  sees a system zone change before its next launch is Foundation's cache
  (not verified; nothing here resets it); the ledger reads the same zone, so
  the two move together either way (nothing sets `NSTimeZone.default`, the
  one thing that would part them). Tests pin a zone with `timeZone:` or
  inject `timeZoneSource:`. The store keeps only times with |ms| < 10^15
  (`HistoryTime.maxMagnitudeMs`, the scanner's own bound); an observation,
  event or quota row with a time at or beyond it is skipped and counted, and
  `HistoryEpoch.seconds` returns nil there, so no stored time can overflow
  a rounding or the rank's negation.
- Union semantics: the store is append-only history. A transcript rewritten
  in place keeps what its earlier content contributed; a transcript Claude
  Code deleted (`cleanupPeriodDays`) keeps all its rows. Only a higher
  `ingest_version` (the AMCU `formatVersion` that produced an observation,
  which is also the watermark's `parserVersion`; 4 now) supersedes stored
  rows per key: a file a version-3 parse fed is re-ingested whole by the
  next scan, and its version-4 observations outrank the version-3 rows.
  Timestamps are MIN/MAX-monotone and cannot be corrected by a version bump;
  `submitRebuildRequests()` (explicit, never automatic, and queued behind
  every earlier command so it never lands between two chunks of a scan;
  `rebuildRequests()` itself is private, and nothing in the app calls either
  yet) truncates the request tables, the scan coverage and the watermarks,
  and the next scan re-ingests from AMCU, losing the rows of vanished
  transcripts. Order independence: the logical dump (`HistoryLogicalDump`,
  rows joined back to key hex, paths and labels) is the same for any order,
  partition, duplication or restart of the same contributions — the
  end-to-end suite compares it with a fresh store's cold scan after every
  step, and `HistoryMergePropertyTests` with a closed form over random
  schedules.
- Ingest: the history never reads a transcript. Per file the batch carries
  the AMCU committed state (never the unterminated last line), its
  watermark (fingerprint, parsed bytes, boundary digest, format version) and,
  for a resumed parse, a delta. The store skips a batch whose watermark equals
  the stored one or whose scan ticket is older than one already applied for
  the path (tickets are process-wide, `LogFileParseCache.beginScan`, and held
  in memory only, so after a restart any batch applies); applies the delta
  only when its base IS the stored watermark; otherwise builds every request
  of the batch (`allRequests()`). A watermark can move back to fewer bytes (a
  rewrite): union semantics make that harmless. Observations are validated
  before the transaction, so one bad value never rolls back its chunk; what
  fails is skipped and counted (`HistoryStoreStatistics`): a request with no
  part or more than 64, a count or thinking count outside 0…2^48 (the
  scanner reads a token count outside that range as absent,
  `ClaudeJSONLScanner.tokenCount`, so a transcript never produces one), a time
  out of range (above), or a version / effort / entrypoint over 256 bytes
  (the scanner already holds them to 64); a model name that is not 1–128
  printable ASCII bytes is stored as `<unrecognized>` with its counts
  (`HistoryObservationCheck.unrecognizedModel`), never dropped. An event
  text over 1,024 bytes (`HistoryEventCheck.maxText`) or a non-finite
  number drops that event, and a first cwd over 4,096 bytes
  (`HistoryEventCheck.maxCwdBytes`, the scanner's `cwd()` bound) drops the
  file's first-cwd fold. Files are packed into transactions of at most
  `scanChunkObservations` (1,000) with a yield between them, and a file's last
  piece, its events, its session fold and its watermark commit together. A
  cold start or a lost database re-ingests every file whole from the cache
  entries without opening a transcript.
- Coverage (`HistoryDatabase.recordScanCoverage`): a scan that wrote a file,
  and every complete-history scan, records an `ingest_scan` row and advances
  `meta.latest_scan_ms`; a complete scan none of whose files failed (each
  applied, or skipped because its watermark was stored or a newer scan of the
  path was applied) also advances `meta.complete_scan_ms`. Neither moves back
  (scans overlap and land out of order). A windowed scan that wrote no file —
  the per-minute scan while nothing changes — writes no row, and
  `latest_scan_ms` only once the stored value is 15 minutes old
  (`HistoryDatabase.latestScanGranularityMs`), so it may lag such a scan by
  up to 15 min and an idle hour costs at most four single-row commits, not
  sixty (`HistoryScanCoverageTests`: 50 unchanged scans within a minute, zero
  changes; 20 unchanged scans 60.000 s / 60.005 s apart, at most 2 commits).
- Quota samples: natural key `(provider, window_id, source, reading_ms)`,
  first writer wins; a second value counts in `meta.quota_conflicts` only
  when a measured field differs (a joined flight lands one reading twice).
  `source` is `oauth|cli|appServer|rolloutFile|unknown`; a legacy observation
  without one is `unknown` (flag `legacy`), never `oauth` — calibration must
  filter `provider = 'claude' AND source = 'oauth'` (`oauthSamples`). A window
  with no stated utilization stores NULL with `value_not_stated`; a reading
  later than its landing keeps its raw time with `future_reading`. Thinning
  per (provider, window, source) on the arrival stream: an unchanged, newer
  reading less than 10 min after the last stored one is skipped; a change, a
  decrease, an epoch change, an out-of-order or first reading is stored, and
  before a change the most recent skipped reading is stored too (the step's
  lower bound). Thinning state is seeded from the database, never from
  `last-state.json`. `reset_event` is `ResetDetector` over two consecutive
  Claude OAuth samples of a window (`rebuildResetEvents()` re-derives it);
  `reset_grant_sample` stores the already-fetched grant set only when it
  differs from the set in force at its `recorded_ms` (the newest stored set
  not after it); a different set at an already-stored `recorded_ms` is
  skipped, first writer wins, never merged; a set with an id that is not
  1–64 printable ASCII bytes (`HistoryDatabase.maxGrantIDBytes`) is skipped
  whole (an empty set is one marker row). Thinning and reset events are
  defined on the arrival stream and are not part of the logical dump.
- Events from transcripts: limit events keyed by request id (else
  `uuid:<uuid>`), `/usage` reports by time + a hash of their limits, cost
  states by (record's session, start time, total duration), compactions by
  (time, trigger, token counts) — every key survives a fork's re-stamped
  uuids. A copied event belongs to the copy in the best-ranked file (birth,
  then path, as for requests), so no row depends on which file arrived first;
  a cost state's `after_ts_ms` (running MAX usage time before the line) merges
  as a NULL-aware MAX.
- Failure and recovery: NOTADB, CORRUPT (or a short read) or a foreign file
  at open or in any later statement closes the connection, moves
  `history.sqlite[-wal|-shm|-journal]` together to
  `history.corrupt-<yyyyMMdd'T'HHmmss'Z'>[-<n>].sqlite…` (`<n>` continues the
  highest sequence of any quarantined file present; the newest 3 are kept by
  that sequence, not by the clock, and the file just moved is never pruned),
  creates a fresh database and reports `.rebuilt` for the rest of the
  process: requests refill from the usage cache on the next scan; quota and
  event samples older than that, and rows of transcripts Claude Code has
  since deleted, are lost. A newer schema (`user_version` above the known
  one) is never touched; it, a failed migration, a failed quarantine and an
  SQLite older than 3.37 latch the store unavailable for the process.
  Everything else is retried every 60 s (`defaultLockRetryInterval`), never
  latched for good. A second instance (`make run` beside the installed app,
  a Sparkle relaunch) fails the `flock` and runs without history; only
  `flock`'s EWOULDBLOCK means another instance, and any other directory,
  lock-file or `flock` failure is `lockUnavailable(step:errno:)` (ENOSPC,
  EDQUOT, EMFILE, ENFILE, ENOMEM, EINTR labelled transient; ENOTSUP "the
  volume does not support flock"). A non-holder never writes or
  quarantines. A write-protected `history.sqlite` is reported unavailable
  (SQLITE_READONLY) before anything reads it and is never quarantined while
  it stays so. A file deleted or moved under the running app (IOERR_VNODE,
  READONLY_DBMOVED) closes the handle; the reopen 60 s later creates a fresh
  file at the path. Submissions to an unavailable store are dropped and
  counted, never retried. No `quick_check` at open; `integrity_check` weekly
  and once after an unclean shutdown (a non-empty `-wal` at open: a crash,
  since a normal quit closes the store, or a quit during that check, whose
  read-only connection keeps the WAL), on a separate read-only connection
  off the store's queue; `wal_checkpoint` PASSIVE after 20,000 changes. WAL,
  `synchronous=NORMAL`, `cache_size=-2048`, `journal_size_limit` 8 MiB.
- Quit: `AppDelegate.applicationShouldTerminate` returns `.terminateLater`.
  `QuitSequence` stops the refresh and runs `HistoryStore.shared.shutdown()`
  within `QuitSequence.historyDeadline` (1.5 s; the timer's leeway makes it
  up to about 1.65 s), then replies once through the main run loop
  (`RunLoop.main.perform` in the common and modal-panel modes). The deadline
  timer is armed before `applicationShouldTerminate` returns and replies
  from its own serial dispatch queue (overcommit: a global queue's thread
  can wait while CPU-bound work at its QoS fills every CPU), so neither waits
  for a cooperative-pool thread (work that never suspends can hold them
  all for seconds). The
  reply never goes through the main queue: AppKit waits for the reply in a
  modal run loop that does not drain the main queue when `terminate` was
  itself called from main-queue code (a Sparkle relaunch, a MainActor task),
  so such a reply would hang the quit. `shutdown()` applies the queued
  quota, legacy-quota and reset-grant commands (the last readings cannot be
  fetched again), drops queued scans and custom commands (counted; the next
  launch's scan re-feeds what AMCU holds), resumes queued `flush()` barriers,
  latches `.closed` and closes; the WAL is checkpointed, so the next launch
  opens clean (unless the quit came during an `integrity_check`: see above).
  A scan in flight stops at its next chunk (~50–85 ms); a
  file's watermark is written only with its last piece, so the next launch
  re-applies the rest. Past the deadline the process exits as before.
- Health: only `HistoryStore.shared` logs, to the unified log
  (`Logger`, subsystem `com.shu.agentmeter`, category `history`, text
  marked public) as `AgentMeter: history …`: one line per state change
  (`opened (schema 1, clean)`, or
  `… after an unclean shutdown, integrity check due`;
  `unavailable, retrying after 60.0 seconds: <reason>` once per distinct
  reason, or `unavailable for the rest of this process: <reason>`;
  `… quarantined as <file>, rebuilt empty`; `closed for quit (…)`), and the
  1st and every 100th dropped submission, rolled-back transaction or failed
  command. Nothing per scan; reasons are error cases and SQLite codes, file
  names only, never a SQLite message, SQL or transcript content, which is
  what makes marking the text public safe (`NSLog` would land as
  `<private>`). Read them with `/usr/bin/log show --last 1d --predicate
  'subsystem == "com.shu.agentmeter" AND category == "history"'`. Without
  the log: `meta.latest_scan_ms` lags the newest scan that reached the store by
  at most 15 min, `complete_scan_ms` is the start of the last complete scan
  none of whose files failed;
  `history.corrupt-*` files mean a rebuild happened; `status()` and
  `statistics()` are in memory only.
- Inspecting and resetting:
  `sqlite3 -readonly ~/Library/Application\ Support/AgentMeter/history.sqlite`
  reads it while the app runs (WAL: the committed rows are visible and
  nothing is written); STRICT tables need a sqlite3 of 3.37 or later
  (macOS's `/usr/bin/sqlite3` is 3.51). Never open it read-write while the
  app runs. `PRAGMA user_version` is 1, `PRAGMA application_id` 1095583827
  (`AMHS`), and `SELECT key, value FROM meta` shows the zone, the coverage
  and the maintenance stamps. To reset, quit the
  app and delete `history.sqlite*` (the database, `-wal`, `-shm` and the lock
  file; `history.corrupt-*` are earlier quarantines): the next launch creates
  an empty file and its first, complete scan refills every request and
  transcript event from the usage cache without opening a transcript, but
  quota samples, reset events and grants, and the rows of transcripts Claude
  Code has deleted since, are gone for good.
- Retention: maintenance at most once a day prunes `quota_sample`,
  `reset_event` and the `ingest_scan` rows of complete scans older than 400
  days, and the `ingest_scan` rows of windowed scans older than 14 days
  (`HistoryRetention.quotaSampleDays` / `windowedScanDays`; the counts are in
  `HistoryMaintenanceOutcome`), then runs `PRAGMA optimize`. Request,
  occurrence, file, event, session and reset-grant rows are never deleted
  automatically. Phase 0B performs no compaction.
- Deferred to later phases: anything that reads the store (attribution,
  calibration, dashboards, alerts, the per-session switch), Codex and Copilot
  quota samples (`QuotaHistoryPolicy.ingestedProviders` is Claude only),
  `request_start_ms`, `extra_usage.utilization`, request compaction. Derived
  data goes in derived tables keyed by `(key, iteration_idx)`, never by
  rowids; raw rows are never estimates.

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
- Usage/spend comes from `ClaudeJSONLScanner` over
  `~/.claude/projects/**/*.jsonl`, deduplicated by `message.id`.
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
- `QuotaTrendTracker` retains at most 24 hours / 200 observations and computes
  runway from remaining-percent drain.
- Show runway only when the current pace would exhaust that same window before
  reset. Suppress a longer-window projection when a shorter hard limit would
  stop usage first.
- Average drain across `runwayLookback` (10 minutes), falling back to the full
  same-reset-epoch span when too sparse. Do not project from only the last two
  refreshes.
- Extrapolation is trusted only up to `maxExtrapolationMultiplier` (6×) the
  observed span. Longer projections downgrade from `.atRisk` to `.watch`.

# AgentMeter

A native macOS menu bar app that shows **Codex** and **Claude Code** usage at a glance —
remaining quota (battery bar), a usage heatmap, and estimated spend. Local-first: it
reuses your existing CLI logins, so there are **no API keys to configure**.

Inspired by [bob-zebedy/CodexBar](https://github.com/bob-zebedy/CodexBar) and
[steipete/codexbar](https://github.com/steipete/codexbar), narrowed to the two agents
this workspace actually uses.

## Features

- **Quota battery bar** — remaining % per window with reset countdowns.
- **Usage heatmap** — 30-week GitHub-style grid per provider.
- **Spend** — 7-day and all-time cost, computed from local logs × live pricing.
- **Auto-update** — Sparkle (once you host an appcast; see below).
- Menu-bar only (no Dock icon), refresh every minute + manual refresh.

## How it gets data (all local-first)

| | Quota (live) | Usage + spend |
|---|---|---|
| **Codex** | `codex app-server` JSON-RPC → falls back to newest `~/.codex/sessions/**/rollout-*.jsonl` (`rate_limits`) | sum `last_token_usage` per day from rollout logs |
| **Claude** | OAuth: token from `~/.claude/.credentials.json` → macOS Keychain `Claude Code-credentials`, then `GET api.anthropic.com/api/oauth/usage` → falls back to scraping `claude /usage`, then usage-only | `~/.claude/projects/**/*.jsonl`, dedup by `message.id`, sum `message.usage.*` |

Pricing comes from [LiteLLM](https://github.com/BerriAI/litellm) (fallback models.dev),
cached to `~/Library/Application Support/AgentMeter/pricing.json`, with an embedded
offline snapshot in `Resources/embedded-pricing.json`.

> **Claude quota needs the network.** Unlike Codex, Claude does not store its 5-hour /
> weekly reset windows on disk — the only source is the OAuth usage endpoint (or scraping
> the CLI). The first OAuth read may show a one-time macOS Keychain prompt ("AgentMeter wants
> to use the keychain"); click **Always Allow**. If you decline or are offline, Claude
> degrades to usage/spend only and Codex is unaffected.

## Build & run

Requires the Xcode toolchain (Xcode 16+ / Swift 6).

```bash
make run          # build release, assemble dist/AgentMeter.app, launch
make debug        # quick terminal build+run of the data layer
make app          # just assemble dist/AgentMeter.app
make dmg          # package dist/AgentMeter-<version>.dmg
make clean
```

The app is ad-hoc signed and runs locally. To move it to another Mac, clear quarantine:
`xattr -dr com.apple.quarantine /Applications/AgentMeter.app`.

## Enabling auto-update (Sparkle)

Auto-update is wired in code but inert until you configure a feed:

1. Download Sparkle's tools from the [releases page](https://github.com/sparkle-project/Sparkle/releases).
2. Run `./bin/generate_keys` once. Paste the **public** key into `Scripts/Info.plist` →
   `SUPublicEDKey`.
3. Set `SUFeedURL` in `Scripts/Info.plist` to where you'll host `appcast.xml`
   (e.g. a GitHub Releases raw URL).
4. `make dmg && make appcast` (needs `generate_appcast` on PATH) → produces
   `dist/appcast.xml`. Upload the DMG + `appcast.xml` to your feed host.

Until configured, **Check for Updates** shows a short explainer instead of crashing.

## Layout

```
Sources/AgentMeter/
  App/            AgentMeterApp (@main), AppDelegate
  Controllers/    StatusItemController (NSStatusItem + popover)
  Models/         QuotaSnapshot, UsageBucket, ProviderState
  Services/       Codex/, Claude/, Pricing/, RefreshCoordinator, LoginItem, UpdaterController
  ViewModels/     AppViewModel (@Observable)
  Views/          Menu/ (battery bar, quota row, heatmap, spend), SettingsView
Scripts/          Info.plist, bundle.sh, dmg.sh, appcast.sh
```

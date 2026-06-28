# AgentMeter

[English](README.md) | [中文](README.zh-CN.md) | [日本語](README.ja.md)

A native macOS menu bar app that shows **Codex** and **Claude Code** usage at a glance:
remaining quota (battery bar), a usage heatmap, and estimated spend. Local-first: it
reuses your existing CLI logins, so there are **no API keys to configure**.

Inspired by [bob-zebedy/CodexBar](https://github.com/bob-zebedy/CodexBar) and
[steipete/codexbar](https://github.com/steipete/codexbar), narrowed to the two agents
this workspace actually uses.

## Features

- **Quota battery bar**: remaining % per window with reset countdowns.
- **Usage heatmap**: 30-week GitHub-style grid per provider.
- **Spend**: 7-day and all-time cost, computed from local logs × live pricing.
- **Auto-update**: Sparkle, once you host an appcast. See below.
- Menu-bar only (no Dock icon), refresh every minute + manual refresh.

## How it gets data (all local-first)

| | Quota (live) | Usage + spend |
|---|---|---|
| **Codex** | `codex app-server` JSON-RPC, then falls back to newest `~/.codex/sessions/**/rollout-*.jsonl` (`rate_limits`) | sum `last_token_usage` per day from rollout logs |
| **Claude** | OAuth: token from `~/.claude/.credentials.json` to macOS Keychain `Claude Code-credentials`, then `GET api.anthropic.com/api/oauth/usage`, then falls back to scraping `claude /usage`, then usage-only | `~/.claude/projects/**/*.jsonl`, dedup by `message.id`, sum `message.usage.*` |

Pricing comes from [LiteLLM](https://github.com/BerriAI/litellm) (fallback models.dev),
cached to `~/Library/Application Support/AgentMeter/pricing.json`, with an embedded
offline snapshot in `Resources/embedded-pricing.json`.

> **Claude quota needs the network.** Unlike Codex, Claude does not store its 5-hour /
> weekly reset windows on disk. The only source is the OAuth usage endpoint, or scraping
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

## Install

Download the latest `AgentMeter-<version>.dmg` from
[GitHub Releases](https://github.com/mmwuzhi/AgentMeter/releases/latest), open
the DMG, and drag `AgentMeter.app` into `/Applications`.

Because the current release is ad-hoc signed and not notarized, macOS may block
the first launch. If that happens, right-click `AgentMeter.app`, choose
**Open**, and confirm. If macOS still keeps quarantine attached, run:

```bash
xattr -dr com.apple.quarantine /Applications/AgentMeter.app
```

## GitHub Releases

GitHub Actions can build and publish a DMG automatically. Push a version tag:

```bash
git tag v1.2.3
git push origin v1.2.3
```

Or run the **Release** workflow manually from GitHub Actions and enter `1.2.3`.
The workflow builds with `MARKETING_VERSION` set to the tag/input version,
verifies the app bundle and DMG, uploads the DMG as a workflow artifact, and
creates or updates a GitHub Release with the DMG plus `SHA256SUMS`.

The release artifact is ad-hoc signed. Sparkle appcast generation is still a
separate step because it requires your private Sparkle signing key.

## Enabling auto-update (Sparkle)

Auto-update is wired in code but inert until you configure a feed:

1. Download Sparkle's tools from the [releases page](https://github.com/sparkle-project/Sparkle/releases).
2. Run `./bin/generate_keys` once. Paste the **public** key into `Scripts/Info.plist` →
   `SUPublicEDKey`.
3. Set `SUFeedURL` in `Scripts/Info.plist` to where you'll host `appcast.xml`
   (e.g. a GitHub Releases raw URL).
4. `make dmg && make appcast` (needs `generate_appcast` on PATH) produces
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

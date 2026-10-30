# AgentMeter

[English](README.md) | [中文](README.zh-CN.md) | [日本語](README.ja.md)

A native macOS menu bar app that shows **Codex**, **Claude Code**, and
**GitHub Copilot** usage at a glance: remaining quota (battery bar), reset timing,
usage heatmaps, estimated spend, and menu-bar status. Local-first: it reuses your
existing CLI logins, so there are **no API keys to configure**.

Inspired by [bob-zebedy/CodexBar](https://github.com/bob-zebedy/CodexBar) and
[steipete/codexbar](https://github.com/steipete/codexbar), focused on local-first
agent usage tracking.

## Features

- **Quota bar**: % per window with reset countdowns — remaining by default
  (battery-style) or used, one switch in Settings turning the popover rows and
  the menu bar over together. An always-visible `now · avg · budget` pace
  readout puts the current burn rate beside the recent average, so you can react
  to a burst and still see how long the quota lasts; `now` reads `<x%/h` while
  the window has not ticked a whole point yet, because usage arrives in whole
  percent and that is a ceiling rather than a zero. A run-out estimate appears
  when the average pace would hit the window before it resets, and stays hidden
  while that date is more than two refill cycles away, since holding one pace
  through that many full resets is not something you can act on now.
- **Usage heatmap**: 24-week GitHub-style grid per provider.
- **Spend**: local-day, 7-day, and 30-day cost, computed from local logs × live pricing.
- **Custom menu bar**: drag visible items into order — each quota window as a
  text % and/or a mini gauge — with per-window warning dots anchored to the
  quota item that triggered them.
- **Notifications**: critical quota alerts, plus optional recovery alerts after a
  previously critical window resets.
- **Auto-update**: Sparkle, once you host an appcast. See below.
- Menu-bar only (no Dock icon), refresh every minute + manual refresh.

## How it gets data (all local-first)

| | Quota (live) | Usage + spend |
|---|---|---|
| **Codex** | `codex app-server` JSON-RPC, then falls back to newest `~/.codex/sessions/**/rollout-*.jsonl` (`rate_limits`) | sum `last_token_usage` per day from rollout logs |
| **Claude** | OAuth: token from `~/.claude/.credentials.json` to macOS Keychain `Claude Code-credentials`, then `GET api.anthropic.com/api/oauth/usage`, then falls back to scraping `claude /usage`, then usage-only | `~/.claude/projects/**/*.jsonl`, one record per `message.id|requestId` (the final one when there is one), sum `message.usage.*` |
| **Copilot** | `gh api /copilot_internal/user`, reusing your existing GitHub CLI login; unavailable if `gh` is missing or not authenticated | flat-rate, so no token spend is shown |

Pricing comes from [LiteLLM](https://github.com/BerriAI/litellm) (fallback models.dev),
cached to `~/Library/Application Support/AgentMeter/pricing.json`, with an embedded
offline snapshot in `Resources/embedded-pricing.json`.

> **Claude quota needs the network.** Unlike Codex, Claude does not store its 5-hour /
> weekly reset windows on disk. The only source is the OAuth usage endpoint, or scraping
> the CLI). AgentMeter reads Claude Code's Keychain item through macOS's
> `security` tool, the way Claude Code itself does, so its own code signature no longer
> decides whether macOS asks. If the read fails or you are offline, Claude
> degrades to usage/spend only and Codex is unaffected.

> **Spend-based Claude plans (e.g. Enterprise) don't have 5-hour/weekly windows at
> all** — they're billed against an org spend limit instead of session-based rate
> limits. AgentMeter shows whatever one-time included credit the account has (e.g.
> "Included credit" for a Claude Code + Cowork allowance) and falls back to a plain
> "no session-based quota windows" note plus usage/spend when there's nothing else
> to show.

## Build & run

Requires the Xcode toolchain (Xcode 16+ / Swift 6).

```bash
make run          # build release, assemble dist/AgentMeter.app, launch
make debug        # quick terminal build+run of the data layer
make app          # just assemble dist/AgentMeter.app
make dmg          # package dist/AgentMeter-<version>.dmg
make clean
```

Local builds are signed with your own certificate (ad-hoc without one) and are not notarized.
On another Mac, macOS blocks the first launch; open it there the way the Install section below describes.

### Signing and the Keychain prompt

`Scripts/bundle.sh` signs with your first `Developer ID Application` certificate, else your first `Apple Development` one, and falls back to ad-hoc (`-`) otherwise (override with `CODESIGN_IDENTITY`). A real certificate also turns on the hardened runtime. AgentMeter reads the `Claude Code-credentials` Keychain item with `/usr/bin/security`, the tool Claude Code writes it with. The item already trusts that tool, so a rebuild or an ad-hoc signature no longer matters. Reading it in process, as earlier builds did, brought the prompt back after Claude Code rotated its OAuth token, whatever the signing. If macOS does ask during a read (a locked keychain, say) and the dialog is cancelled or denied, AgentMeter waits 5 minutes before trying again. On a system without that tool it reads the item itself, as before. This is a Keychain ACL, not a TCC permission, so `tccutil` does not apply here. Releases stay ad-hoc — there is no paid Apple Developer Program account.

## Install

Download the latest `AgentMeter-<version>.dmg` from
[GitHub Releases](https://github.com/mmwuzhi/AgentMeter/releases/latest), open
the DMG, and drag `AgentMeter.app` into `/Applications`.

Because the current release is ad-hoc signed and not notarized, macOS blocks
the first launch. Open the app once, then go to **System Settings › Privacy &
Security** and click **Open Anyway** (on macOS 15 and later right-click **Open**
no longer works). Builds that are not notarized have not been checked by Apple;
open one only if you trust where it came from.

## GitHub Releases

GitHub Actions can build and publish a DMG automatically. Push a version tag:

```bash
git tag v1.2.3
git push origin v1.2.3
```

Or run the **Release** workflow manually from GitHub Actions and enter `1.2.3`.
The version comes from the `VERSION` file; the tag/input must match it. The
build number is the Asia/Tokyo time (`Scripts/build-number.sh`). The workflow
verifies the app bundle and DMG, uploads the DMG as a workflow artifact, and
creates or updates a GitHub Release with the DMG plus `SHA256SUMS`.

The release artifact is ad-hoc signed. Sparkle appcast generation is still a
separate step on a machine that has the Sparkle private signing key, or in CI
with `SPARKLE_PRIVATE_KEY` configured as a secret.

## Enabling auto-update (Sparkle)

Auto-update is configured to read the feed from GitHub Releases:
`https://github.com/mmwuzhi/AgentMeter/releases/latest/download/appcast.xml`.

Generate an appcast for a release after building the matching DMG:

```bash
version=0.4.2
make dmg
SPARKLE_VERSION="$version" \
SPARKLE_DOWNLOAD_URL_PREFIX="https://github.com/mmwuzhi/AgentMeter/releases/download/v$version/" \
make appcast
gh release upload "v$version" "dist/AgentMeter-$version.dmg" dist/appcast.xml --clobber
```

`Scripts/appcast.sh` uses Sparkle's `generate_appcast` from PATH, or the
SwiftPM-downloaded tool under `.build/artifacts/sparkle/Sparkle/bin/`. If
`SPARKLE_VERSION` is set, only `dist/AgentMeter-$SPARKLE_VERSION.dmg` is used,
which avoids accidentally including old local DMGs in the feed.

## Layout

```
Sources/AgentMeter/
  App/            AgentMeterApp (@main), AppDelegate
  Controllers/    StatusItemController (NSStatusItem + popover)
  Models/         QuotaSnapshot, UsageBucket, ProviderState
  Services/       Codex/, Claude/, Copilot/, Pricing/, QuotaTrendTracker, RefreshCoordinator
  ViewModels/     AppViewModel (@Observable)
  Views/          Menu/ (battery bar, quota row, heatmap, spend), MenuBarContentView, SettingsView
Scripts/          Info.plist, bundle.sh, dmg.sh, appcast.sh
```

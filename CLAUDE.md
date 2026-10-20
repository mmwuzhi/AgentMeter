# AgentMeter agent guide

AgentMeter is a menu-bar-only macOS app for Codex, Claude Code, and GitHub
Copilot quota, runway, usage, and estimated spend. It is local-first and reuses
existing CLI logins; never introduce API-key setup. The project is a SwiftPM
executable targeting macOS 14+, Xcode 16+, and Swift 6.

`AGENTS.md` is a symlink to this file, so this is the shared source of truth for
Claude Code and Codex.

## Read before editing

Load only the references relevant to the task:

- Provider fetchers, usage scanners, quota models, status, pricing, or runway:
  [docs/agent/providers.md](docs/agent/providers.md)
- Menu bar, popover, settings, cached state, spend/usage presentation, or
  Claude hooks: [docs/agent/ui-state.md](docs/agent/ui-state.md)
- Package, scripts, signing, versions, Sparkle, DMG, release workflow, or
  installed-app handoff: [docs/agent/release.md](docs/agent/release.md)

For cross-cutting changes, read every applicable reference before editing.

## Project map

- `Sources/AgentMeter/App` — launch and app lifecycle
- `Sources/AgentMeter/Controllers` — status item and popover ownership
- `Sources/AgentMeter/ViewModels` — `AppViewModel`, the UI source of truth
- `Sources/AgentMeter/Views` — menu bar, popover, and Settings UI
- `Sources/AgentMeter/Services` — refresh orchestration, providers, state,
  notifications, pricing, quota trends, and active-agent integration
- `Sources/AgentMeter/Services/History` — `HistoryStore`, the append-only
  SQLite history (`history.sqlite`) of Claude requests, transcript events and
  quota readings, fed by the usage scan and the refresh without ever being
  awaited (quit alone waits, about 1.5 s at most, for it to close); read nothing
  from it in the UI yet
- `Sources/AgentMeter/Services/Events` — `AgentMeterEvent` and
  `AgentMeterEventStore` (`events.jsonl`): dedup, delivery outcome and read
  state of what the shared event path (`NotificationManager+Events.swift`)
  announces
- `Sources/AgentMeter/Services/Sessions` — the first event producer: Claude
  task outcomes (Completed / Failed / Waiting / Interrupted) from the hook
  helper's turn ledgers (`agent-status/turns/`), the registry and the payloads
- `Sources/AgentStatusCore` / `Sources/AgentMeterHook` — Claude status helper
- `Tests/AgentMeterTests` — XCTest suite
- `Scripts` / `.github/workflows/release.yml` — bundle and release tooling

The main runtime path is:
`AppDelegate → RefreshCoordinator → AppViewModel → StatusItemController/MenuView`.
`RefreshCoordinator` fetches providers in parallel, records quota observations,
persists cacheable state, and evaluates notifications.

## Commands and verification

```bash
make run      # release build, assemble dist/AgentMeter.app, launch that copy
make debug    # debug build and run from the terminal
make app      # assemble dist/AgentMeter.app
make dmg      # package dist/AgentMeter-<version>.dmg
make appcast  # regenerate the Sparkle feed entry
make clean    # remove .build and dist
swift test    # run the XCTest suite
```

- Run `swift test` after code changes. Use the narrowest relevant test during
  iteration, then the full suite before handoff.
- For UI/menu-bar changes, also run the app and inspect it. This environment
  cannot capture the menu bar because it lacks Screen Recording permission;
  hand the user an exact visual checklist when render verification is needed.
- A running AgentMeter can cause SwiftPM's transient “input file was modified
  during the build” error. Stop the old process and rebuild. `make run` launches
  `dist/AgentMeter.app` and does not replace or terminate an installed copy.
- After producing a newer local build for the user, follow the installed-app
  handoff in [docs/agent/release.md](docs/agent/release.md). Do not add install
  side effects to shared Make targets.
- The status item may land behind the notch after relaunch. Confirm the process
  with `pgrep -lf "AgentMeter.app"` before treating a missing icon as a crash.

## Cross-cutting rules

- Preserve `QuotaSnapshot.source`; the UI distinguishes live, fallback, and
  unavailable data.
- Treat provider responses and status descriptions as untrusted input: parse
  defensively, sanitize displayed text, and do not invent undocumented fields.
- Keep persisted settings and state backward compatible. Migration-only keys
  must not become new sources of truth.
- Raw history rows are never estimates: `history.sqlite` stores what the
  transcripts and quota responses said. Anything derived (attribution,
  calibration, filled-in output) goes in derived tables keyed by
  `(key, iteration_idx)`, never by rowids or other surrogate ids.
- For visual changes, preserve native menu-bar rendering and declared status
  item bounds; secondary displays clip content outside that width.
- GitHub releases are automated, but Sparkle appcast generation is manual
  because it needs the private signing key.

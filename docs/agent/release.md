# Build, installation, and release

Read this file before changing `Package.swift`, `Scripts/`, Sparkle, signing,
DMG creation, versions, or the GitHub release workflow.

## Bundle and packaging

- SwiftPM produces `AgentMeter`, `AgentMeterHook`, the resource bundle, and
  Sparkle.
- `Scripts/bundle.sh` assembles `dist/AgentMeter.app`: it copies the app binary,
  helper (`Contents/Helpers/agentmeter-hook`), resource bundle, loose
  `embedded-pricing.json`, `AppIcon.icns`, and `Sparkle.framework`; substitutes
  versions into `Scripts/Info.plist`; adds the Frameworks rpath; then signs
  nested code before the app. It first runs `strip -S` on the app binary and the
  helper: a release link keeps a debug map (OSO entries) with the absolute path
  of every object file in the build directory, and `-S` drops it without
  touching the other symbols. Check with `nm -ap <binary> | grep -c " OSO "`
  (0) and `grep -a -c "/Users/" <binary>` (0); `strings -a` does not read that
  table and shows 0 either way.
- `Scripts/dmg.sh` uses `dmgbuild` for the styled installer and falls back to
  plain `hdiutil`. Release images are `AgentMeter-<version>.dmg`; an rc build
  (`UPDATE_CHANNEL=rc`) makes `AgentMeter-<version>-rc.dmg`. The suffix comes
  from the packaged app's `AgentMeterUpdateChannel`, and `dmg.sh` fails when
  `UPDATE_CHANNEL` says otherwise, so an rc app can never be packaged under a
  release name. The CI verify step also fails a release app that carries the
  channel key or lacks an https `SUFeedURL`. Never publish an rc
  image. `Scripts/appcast.sh` leaves `*-rc.dmg` out of `make appcast` (it says
  so), refuses a `SPARKLE_VERSION` that names one, and exits non-zero when only
  rc images exist.

## Version and build number

- Marketing version: the `VERSION` file at the repo root (`X.Y.Z`).
  `bundle.sh` and `dmg.sh` default `MARKETING_VERSION` from it; the env var
  still overrides. `release.yml` fails when the tag version differs from it, so
  bump `VERSION` in the commit that gets the tag.
- Build number (`CFBundleVersion`, what Sparkle compares with
  `sparkle:version`): `Scripts/build-number.sh` prints
  `TZ=Asia/Tokyo date +%Y%m%d%H%M`, 12 digits. `bundle.sh` defaults
  `BUILD_VERSION` from it and `release.yml` uses it instead of the run number.
  The zone is fixed to Asia/Tokyo so the number does not depend on the
  machine, has no DST step, stays above earlier local builds (for example
  `202610301854`), and is comparable between local and CI builds.
- Never twice: with a floor argument the script prints a number strictly
  above it, waiting for the next minute when the floor is this minute and
  failing when the clock is behind it (Sparkle never offers an update whose
  number equals the installed one; two builds of one minute would collide).
  `bundle.sh` passes the last number it generated in this checkout
  (`.build/last-build-number`, written after a successful build; an explicit
  `BUILD_VERSION` is used as given and never becomes the floor), so
  consecutive local builds differ. Builds in two checkouts, two concurrent
  builds in one checkout, or a rebuild right after `make clean` can still
  share a minute; locally that only decides which copy owns the hook helper
  (then the last launched wins). `release.yml` passes the published feed's
  highest `sparkle:version`, and its `concurrency` group runs one release at a
  time, so a release can never repeat or undercut the number of the one
  before. GitHub keeps only one pending run per group: a third trigger cancels
  the pending second one, which then has to be re-run. Do not re-run an older
  tag after a newer release: it would get a higher build number and become
  the newest version Sparkle offers.
- Releases up to v0.8.2 used the CI run number (v0.8.2 is build 19), so any
  12-digit number is greater and Sparkle offers it. The verify step in
  `release.yml` requires 12 digits and a number above the `sparkle:version` of
  the published latest appcast (it only prints a notice when there is none).
- `HookHelperOwnership` ranks running copies by version, then build.

## Update channel

- `UPDATE_CHANNEL=release` (default) keeps the Info.plist feed settings.
- `UPDATE_CHANNEL=rc` is a test build: `bundle.sh` removes `SUFeedURL`, sets
  `SUEnableAutomaticChecks` to false and adds `AgentMeterUpdateChannel` = `rc`.
  `UpdatePolicy` (`Sources/AgentMeter/Services/UpdatePolicy.swift`) reads that
  key: `UpdaterController` does not start Sparkle, and Settings › Software
  Update shows the version as `0.9.0 RC (<build>)` with a line saying updates
  are off, instead of "Check Now".

## Signing

`bundle.sh` picks the identity: `CODESIGN_IDENTITY`, else the first
`Developer ID Application:` identity, else the first `Apple Development:`
(revoked ones are skipped), else ad-hoc (`-`). It prints which one it uses. A
signing failure fails the script, and it ends with
`codesign --verify --deep --strict`.

- Never `--deep` when signing. Order, inside-out: Sparkle's
  `Installer.xpc`, `Downloader.xpc` (with `--preserve-metadata=entitlements`),
  `Autoupdate`, `Updater.app`, then `Sparkle.framework`; then
  `Contents/Helpers/agentmeter-hook` with `--identifier com.shu.agentmeter.hook`;
  then the app with `--entitlements Scripts/AgentMeter.entitlements`.
- A real identity signs every item with `--options runtime` (hardened
  runtime). `--timestamp` is added for Developer ID only (notarization needs it
  and it needs the network); otherwise `--timestamp=none`.
- Ad-hoc signs the same way without the hardened runtime: library validation
  would refuse to load an ad-hoc Sparkle. `make adhoc` builds that way on any
  Mac (`CODESIGN_IDENTITY=- UPDATE_CHANNEL=rc`): no certificate, no Team ID,
  updates off. The script then fails unless every signed item reports
  `Signature=adhoc`, `TeamIdentifier=not set` and no `Authority`. On a Mac
  that has a certificate, plain `make app` still picks it.
- After signing the helper, `bundle.sh` writes its SHA-256 into the app's
  Info.plist as `AgentMeterHookSHA256`, which the app's signature then seals.
  An ad-hoc app installs the helper copy only when the bytes match it
  (`HookHelperTrust`); a team-signed app checks the helper's team instead.
  The script fails when the sealed value and the helper differ.
- The only entitlement is `com.apple.security.automation.apple-events`: the app
  drives Terminal, iTerm2 and Ghostty with `NSAppleScript`, and the hardened
  runtime denies Apple Events without it.
- Local and rc builds are not notarized. On macOS 15+ the right-click Open
  bypass is gone: open the app once, then System Settings › Privacy & Security
  › Open Anyway. Do not tell other people to clear quarantine with `xattr`:
  that skips Gatekeeper instead of passing it. No Developer ID identity or
  notarization credentials exist on the dev Mac; the Developer ID and
  notarization path is untested.

## Hook helper and Gatekeeper

- Claude Code runs a copy of `Contents/Helpers/agentmeter-hook` in the app's
  support directory, not the bundle's file. The app installs it only after
  the bundled helper passes a strict signature check plus, for a team-signed
  app, the same team, or, for an ad-hoc app, the SHA-256 its own signature
  seals (a content match with the app the user opened, not a developer
  identity), and writes it from the bytes it read, so a download's
  quarantine is not carried onto it (`HookHelperTrust`,
  `ClaudeHookInstaller.refreshManagedCLI`). Re-signing the whole bundle
  (`codesign --force --deep -s -`, a common workaround for "damaged" apps)
  re-signs the helper, so an ad-hoc app then refuses it: rebuild instead.
- What was measured (2026-10-30, macOS 26, in scratch): a quarantined copy of
  a non-notarized helper, run from zsh, sh or node the way Claude Code runs
  hooks, raises "Not Opened" and hangs until killed; a copy without
  quarantine runs. Removing the attribute from a copy that already had an
  unanswered dialog did not unblock it — the likely cause is the pending
  assessment for that file, not a lasting verdict; not established.
- Local and rc builds: the copy runs on the user's Open Anyway for the app
  and the signature check, without a Gatekeeper assessment of its own. That
  is a limitation of those builds, not a distribution Gatekeeper approved.
- A release for other people needs: Developer ID Application signing with the
  hardened runtime and a secure timestamp on every item (helper included),
  notarization of the app (which covers the helper inside it), stapling, and
  an acceptance run on a clean Mac or a separate macOS user: download the
  DMG, open the app without Open Anyway, enable the hooks, run a real Claude
  Code session, and confirm no Gatekeeper prompt and that the copy's
  signature verifies as Developer ID. Before that release, decide whether to
  keep the copy or point the hooks at the helper inside the bundle (Apple's
  preferred layout, but the path changes when the app moves and under app
  translocation).
- Tests that can raise Gatekeeper, TCC or other permission prompts are not
  run on the developer's working desktop without a plan the user approved
  first; prefer a separate macOS user or another Mac.

## Release automation

- `.github/workflows/release.yml` runs for `vX.Y.Z` tags or manual Release
  dispatch. It builds the DMG, verifies bundle contents/version/signature,
  uploads artifacts, and creates or updates the GitHub Release.
- Sparkle appcast generation remains manual because it needs the private EdDSA
  key. The feed URL is
  `https://github.com/mmwuzhi/AgentMeter/releases/latest/download/appcast.xml`;
  the public key lives in `Scripts/Info.plist`.
- Generate a feed with:

  ```bash
  SPARKLE_VERSION=<version> \
  SPARKLE_DOWNLOAD_URL_PREFIX=https://github.com/mmwuzhi/AgentMeter/releases/download/v<version>/ \
  make appcast
  ```

  This prevents stale local DMGs from leaking into the feed.

## Agent handoff to the installed app

After an agent updates the app version or produces a newer local build for the
user, it must stop the installed AgentMeter process, replace
`/Applications/AgentMeter.app` with that exact `dist/AgentMeter.app`, relaunch
the installed copy, and verify its process path plus bundle version/build.

This is an agent handoff step. Do not add installation side effects to
`make run`, `make app`, or other shared repository targets.

Keep the replaced copy as an archive (`ditto -c -k --keepParent`), not as a
loose `.app` in a backup folder, and check afterwards that
`NSWorkspace.shared.urlForApplication(withBundleIdentifier:
"com.shu.agentmeter")` names `/Applications/AgentMeter.app`. A banner click
opens whatever that resolves to: on 2026-10-30 it resolved to an old build
moved into `~/Backups` while it was registered as launchable, and the click
started that copy next to the installed one. Unregister such a copy with
`lsregister -u <path>` (repeat until `lsregister -dump` no longer lists it).

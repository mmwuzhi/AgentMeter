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
  nested code before the app.
- `Scripts/dmg.sh` uses `dmgbuild` for the styled installer and falls back to
  plain `hdiutil`.
- Local releases are ad-hoc/not notarized. On another Mac, clear quarantine
  with `xattr -dr com.apple.quarantine`.

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

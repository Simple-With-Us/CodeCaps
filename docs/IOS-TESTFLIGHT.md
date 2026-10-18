# CodeCaps Companion TestFlight Shipping

A merge to `main` that touches the iOS app uploads a fresh TestFlight build with no human step.  This page is the contract; `scripts/ios-ship-workflow.test.mjs` pins it in CI (the `iOS ship contract` check).

## What Triggers A Build

`.github/workflows/ios-ship.yml` runs on a push to `main` whose changed files match `on.push.paths`:

- `ios/CodeCapsCompanion/**`.
- The shared `Sources/QuotaCore/*.swift` files the app and widget targets compile (the `../../Sources/QuotaCore/...` entries in `ios/CodeCapsCompanion/project.yml`).  They are listed one by one on purpose: most QuotaCore edits are Mac-only and must not ship a build.  The contract test fails when `project.yml` and the workflow disagree, so adding a shared file to a target means adding it to the push paths and to the scheduled gate in the same change.
- The workflow itself, `scripts/ios-fleet/**` (test scripts excluded), the ship and signing scripts, and the Infisical fetch helper.

A cron tick (`26,56 * * * *`) is the catch-up for merges GitHub does not announce (a merge made with `GITHUB_TOKEN` fires no push run).  It ships only when `scripts/ios-fleet/scheduled-ship-gate.sh` finds a change under one of the same paths since the last successful ship.  `workflow_dispatch` ships without the gate.

The ship script keeps its own rate gate and the same-HEAD skip.  Never set `IOS_TF_MIN_INTERVAL_SEC` or `--force-ship` in the workflow.

## Credentials

- The App Store Connect key (`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`) is read from Fleet-OPS Infisical prod `/asc`, the fleet's single copy.  The multiline key is staged to a mode-600 file by `scripts/ios-stage-asc-key.sh`; only its path reaches later steps.
- The same-named repository secrets are a stale copy that App Store Connect rejects with HTTP 401 (CC-163).  The workflow does not read them and has no fallback to them.
- `IOS_DIST_P12_BASE64` and `IOS_DIST_P12_PASSWORD` (the Apple Distribution identity) stay repository secrets.
- `SENTRY_DSN` and `SENTRY_AUTH_TOKEN` are best-effort: Infisical first, same-named repository secrets as fallback.

## Versions And Notes

The marketing version train is `1.0.N` (`marketingVersionDefault` in `scripts/ios-fleet/apps.json`); the older `0.1.N` builds stay in TestFlight and `1.0.1` is above every one of them.  The build number is the UTC `YYYYMMDDHHMM` stamp.  Every upload publishes What to Test from the commit subjects since the last ship, with agent names removed.

## When A Build Is Missing

1. `gh workflow view ios-ship.yml -R Simple-With-Us/CodeCaps` must say the workflow is active, and the latest `main` push touching the paths above should have a run.
2. A failed run names its step.  `Load ASC credentials (Fleet-OPS prod /asc)` failing means the CI Infisical identity lost read access to Fleet-OPS `/asc`; that is an owner fix in Infisical, never a new App Store Connect key.
3. Compare the newest processed TestFlight build against `git log -1 -- ios/CodeCapsCompanion` before saying the app is up to date.

## CodeCaps For Mac (TestFlight)

The Mac App Store build of CodeCaps ships the same way, from `.github/workflows/macos-ship.yml`, and `scripts/macos-ship-workflow.test.mjs` pins it in the same `iOS ship contract` check.  It was manual only until Sat, Oct 17, 2026, so merges never reached TestFlight.

- **What it builds.**  The `CodeCapsCompanionMac` scheme of `ios/CodeCapsCompanion/CodeCapsCompanion.xcodeproj`, bundle `com.simplewithus.codecaps.macos`, ship key `codecaps-mac`.  It is not the SwiftPM tree under `Sources/`: that is the Sparkle app, released by `mac-release.yml` as a Developer ID build, and a change there ships no TestFlight build.
- **What triggers it.**  The same list as the iOS ship: `ios/CodeCapsCompanion/**` plus the eight exact `Sources/QuotaCore` files the Mac app and widget targets compile, the workflow, `scripts/ios-fleet/**` (test scripts excluded) and the Mac ship and signing scripts.  A cron tick (`11,41 * * * *`) catches merges GitHub does not announce and ships only when the scheduled gate (`codecaps-mac`) finds a change under those paths since the last successful ship.  `workflow_dispatch` ships without the gate.  The contract test fails when `project.yml` and the workflow disagree.
- **Credentials.**  The App Store Connect key comes from Fleet-OPS Infisical prod `/asc` through the same step as `ios-ship.yml` (the test fails if the two copies drift).  `IOS_DIST_P12_*` and `MAC_INSTALLER_P12_*` stay repository secrets.  The same-named repository `ASC_*` secrets are the stale copy and are not read.
- **Versions.**  Marketing train `1.0.N` (`codecaps-mac` in `scripts/ios-fleet/apps.json`); the older `0.1.N` builds, newest `0.1.12`, stay in TestFlight and `1.0.1` is above them.  The state cache key family is `ios-fleet-state-codecaps-mac-v1-`, so the retired sequence cannot carry over.  Every upload publishes What to Test.
- **Gates.**  The ship script keeps its rate gate and the same-HEAD skip, and the job waits for Swift CI (`Mac package build and test` and `iOS companion compile`) on the commit first.  Swift CI builds the Mac widget extension (`CodeCapsWidgetsMac`) but not the `CodeCapsCompanionMac` app target, so a break in the Mac app alone shows up in the archive step, not before it.
- **When a Mac build is missing.**  `gh workflow view macos-ship.yml -R Simple-With-Us/CodeCaps` must say active, and the latest `main` push touching the paths above should have a run.  A failed `Load ASC credentials (Fleet-OPS prod /asc)` step is an owner fix in Infisical, never a new App Store Connect key.  Then run the fleet's TestFlight freshness check for `codecaps-mac`; its verdict says whether the newest processed build contains the newest native commit.

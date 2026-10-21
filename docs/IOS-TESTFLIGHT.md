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

Marketing and build both come from the repo's commit count: `1.0.<commit_count>` and `<commit_count>`, so the pair always describes one commit (the older `0.1.N` builds stay in TestFlight and `1.0.1` is above every one of them).  UTC `YYYYMMDDHHMM` stamps are retired.  Every upload publishes What to Test from the commit subjects since the last ship, with agent names removed.

## When A Build Is Missing

1. `gh workflow view ios-ship.yml -R Simple-With-Us/CodeCaps` must say the workflow is active, and the latest `main` push touching the paths above should have a run.
2. A failed run names its step.  `Load and stage the ASC credentials (Fleet-OPS prod /asc)` failing means the CI Infisical identity lost read access to Fleet-OPS `/asc`; that is an owner fix in Infisical, never a new App Store Connect key.
3. Compare the newest processed TestFlight build against `git log -1 -- ios/CodeCapsCompanion` before saying the app is up to date.

## CodeCaps For Mac (Retired From TestFlight)

CodeCaps for Mac no longer ships to TestFlight or the Mac App Store (CC-169, owner ruling Mon, Oct 19, 2026).  The Mac app is a direct download: the Sparkle app under `Sources/`, released as a signed and notarized DMG on GitHub Releases by `.github/workflows/mac-release.yml` and linked from https://simplewithus.com/codecaps/.

- **What was removed.**  `.github/workflows/macos-ship.yml` and its contract test, the Mac App Store signing and export scripts, `mac-appstore-profiles.json`, the `codecaps-mac` entry in `scripts/ios-fleet/apps.json`, and the Apple Distribution signing overrides on the `CodeCapsCompanionMac` and `CodeCapsWidgetsMac` targets in `project.yml`.  `scripts/mac-ship-testflight.sh` remains as a stub that exits non-zero.
- **What stays.**  The `CodeCapsCompanionMac` and `CodeCapsWidgetsMac` targets still build (Swift CI compiles the widget extension without signing), but nothing archives or uploads them.
- **Not changed.**  The iOS ship above, and `mac-release.yml`.

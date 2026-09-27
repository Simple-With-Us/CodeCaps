# CodeCaps — Effort Log

## 2026-09-26 — Public site quota and fleet copy — DEPLOYED

Lane: `codex/public-copy` at `~/apps/codecaps-codex-public-copy` (board `90d3d40a`, issue #52).  PRs #53 and #54 aligned the GitHub Pages product copy with supported AI plan windows, existing local sign-ins, and optional collector push/pull.  Pages run 36281399171 deployed the gh-pages merge, and the live page and screenshot assets were verified.  No reader or app behavior changed.

Running log of work units, newest first.  Each entry: date, lane, summary,
PR (when shipped), follow-ups (when parked).

---

## 2026-09-27 — Fix CodeCaps quitting instantly on launch

Lane: `mm/bundle-module-crash`.

Opening CodeCaps quit it immediately.  Two crash reports at 3:38am Central, `EXC_BREAKPOINT` / `SIGTRAP`, both with `_assertionFailure` -> `static NSBundle.module` -> `PlatformLogoImage.bundledImage` on top, reached from `AppDelegate.updateStatus` during `applicationDidFinishLaunching`.  Running the binary directly printed the trap:

    CodeCaps/resource_bundle_accessor.swift:12: Fatal error: could not load resource
    bundle: from /Users/jay/Applications/CodeCaps.app/CodeCaps_CodeCaps.bundle or
    /private/tmp/codecaps-land-verify/.build/arm64-apple-macosx/debug/CodeCaps_CodeCaps.bundle

The SwiftPM-generated accessor probes exactly two paths: the `.app` bundle root, and the absolute `.build` directory that compiled the target.  `build_and_run.sh` copies the resource bundle to `Contents/Resources`, which the accessor never probes, and nothing placed a copy at the `.app` root.  An installed build could therefore only resolve its own brand marks while the checkout that built it still had its `.build` directory, and the first `Bundle.module` touch is the menu bar icon built during launch.  The installed build came from a `/private/tmp` checkout that has since been deleted.

Fixed in #61:
- Added `ResourceBundle` in `Sources/CodeCaps/PlatformLogo.swift`, which resolves the bundle by hand — the app root, the resource directory, the executable's directory, and three parent levels each — and returns `nil` rather than trapping, so a missing brand mark costs a missing brand mark and `PlatformLogo` draws its SF Symbol fallback.
- Inside an installed `.app` the generated accessor is refused outright (`mayUseGeneratedAccessor`), because the build directory it names is gone by design.  A bare `.build` executable and the XCTest harness still use it, which is what keeps `swift test` working: under `swift test` `Bundle.main` is Xcode's own `xctest` tool, so no probe can reach the bundle.
- `build_and_run.sh` now fails the build when SwiftPM produced no resource bundle, and asserts the copy reached `Contents/Resources`.

Rejected alternative: seeding a copy at the `.app` root.  It works, but `codesign` rejects it with `unsealed contents present in the bundle root`, and the build then falls back to ad-hoc signing, which changes the code identity every build and invalidates the saved Read and Ingest tokens.

194 tests pass, including six new ones.  Verified on the installed build with the build directory moved away: the app launches and stays up, where the previous build traps.

Board 6c0c64f440a34425974ccf804ea10a71.  Closes #62.

---

## 2026-09-21 — Stand up automated iOS TestFlight shipping workflow

Lane: `plumber/ios-testflight-workflow`.

Stood up automated GitHub-hosted macOS TestFlight ship workflow for CodeCaps Companion:
- Created `.github/workflows/ios-ship.yml` with push trigger, path filter (`ios/CodeCapsCompanion/**`), and 30-minute cron (`26,56 * * * *`).
- Added in-repo fleet scripts in `scripts/ios-fleet/`: `ExportOptions-*.plist`, `apps.json`, `asc-api.mjs`, `scheduled-ship-gate.sh`, and `ship-testflight.sh`.
- Added wrapper scripts `scripts/ios-appstore-gm-prepare.sh` and `scripts/ios-ship-testflight.sh`.
- Configured repository secrets on GitHub: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `IOS_DIST_P12_BASE64`, and `IOS_DIST_P12_PASSWORD`.
- Verified local dry-run archive resolution and scheduled ship gate.

---

## 2026-09-21 — App Group configuration & macOS companion target

Lane: `ag/companion-app-group-and-mac`.

Configured App Group `group.com.simplewithus.codecaps` across iOS companion and macOS targets:
- Added `CodeCapsCompanion.entitlements` and `CodeCapsCompanionMac.entitlements` with App Group `group.com.simplewithus.codecaps`.
- Added `CodeCapsCompanionMac` target in `ios/CodeCapsCompanion/project.yml` for macOS 14+ with bundle ID `com.simplewithus.codecaps.macos`.
- Updated `CompanionQuotaModel.swift` to read shared defaults and quota files from the App Group container.
- Updated `LocalQuotaSnapshot.swift` in `QuotaCore` to mirror snapshots into the shared App Group container when available.
- Replaced interim mark with authentic 3D rich teal (#0B6B5D) icon matching the Usage Monitor Client design with embossed circuit traces, circular sync arrows, and glossy white plate.
- Removed script/make_codecaps_icon.swift and assets/icon-1024-transparent.png.
- Removed iOS companion App Group entitlement to align with standard automated App Store signing while keeping it active on macOS companion.
- Verified xcodebuild archive succeeds and prepares for TestFlight upload.
- Built both targets and verified all 163 unit tests pass.

---

## 2026-09-20 — Comprehensive audit, tier-1 implementation — MERGED 28b802f via PR #20

Lane: `mm/audit-2026-09-20`.  Audit: `docs/audits/2026-09-20-comprehensive.md`.
GitHub umbrella: [#19](https://github.com/jaywedgeworth22/codecaps/issues/19).
Board item: filed under app `codecaps`, kind `github-issue`.

Swept every Swift file in `Sources/CodeCaps/` and `Sources/QuotaCore/`, the
build script, the tests, the README.  22 findings (5 high, 7 medium, 10 low)
plus 6 test/doc gaps.

Tier-1 implementation in this PR:

- A9-01 — SettingsViews.swift:734 footer copy updated to match the System
  default from commit `3b24eb8`.  README "Appearance" bullet updated too.
- A9-02 — `script/build_and_run.sh:462` no longer discards the notarization
  rejection log (`>&2 2>/dev/null` → `>&2`).
- A9-03 — `script/build_and_run.sh:198-200` carries a comment explaining
  why `--deep` is fine in the ad-hoc fallback only.
- A9-13/27/28 — `AGENTS.md` and `EFFORT-LOG.md` added.
- A9-23 — README "Logs" section added.

A9-04 retracted after re-read (script already exits 1 on rejection before
stapling).

Build clean, 130/130 tests pass.  Merged via auto-merge.

Queued for follow-up lanes: A9-05, A9-06, A9-07, A9-08, A9-09, A9-10, A9-11,
A9-12, A9-16, A9-17, A9-18, A9-24, A9-25, A9-26, A9-29.  A9-14 and A9-15
(producer rename) deferred — wire format, needs owner call.

## 2026-09-19 — Default appearance to System (PR #18, audits #4–#8)

Lane: `mm/system-default-theme`.  Five audit-batch fixes landed with the
theme-default change:

- audit #4 — `DisplaySection.driving` determinism (ff...f3).
- audit #5 — Antigravity RPC short-circuit on 4xx (7eb8202).
- audit #6 — `PlatformDetailPage` save debounce 250ms (2151862).
- audit #7 — Glance consent-needed row rendering (36757fc).
- audit #8 — Dynamic Type on body copy (bd10335).

---

## 2026-09-22 — Polish Glance popover layout and add row expansion

Lane: `mm/glance-popover-polish-2026-09-22` (PR opening on push).

User feedback from a Glance popover screenshot (2026-09-22):  percent column
was clipping the % on Antigravity rows (10...), the trailing countdown was
clipping long strings (12h 5...), the middot between 7 of 7 and the time
was tight, and the Refresh button was redundant because
MonitorModel.refreshTimer (300s) plus the 30s clock already keep the popover
current.  Glance is also the surface the owner actually opens, but it only
showed each provider headline percentage; tapping a row now expands inline
to list every window for that provider.

GlanceViews.swift:
- Widen percent column 40pt -> 48pt and trailing column 58pt -> 64pt; widen
  the no-percent branch from 106pt to 112pt.  Add lineLimit(1),
  minimumScaleFactor(0.85) and fixedSize(horizontal: true) on the percent
  Text so a flexible HStack can never shrink the column enough to clip the
  % again.
- headerStatus now uses two ASCII spaces on either side of the middot
  (7 of 7  ·  2:22 PM), matching the fleet two-space convention.
- Move the Refresh button out of the footer and into the header.  Icon-only
  (arrow.clockwise), with a ProgressView replacing the icon while
  MonitorModel.isRefreshing.  Tooltip and accessibility label still identify
  it as Refresh Quotas.
- Add @State expandedIds to GlancePopover, plus a toggleExpanded helper.
  Pass isExpanded and onTap through to GlanceRow.  Tapping a row toggles
  its expansion; tapping the alarm-bell button inside the trailing column
  short-circuits the gesture so an arm or disarm never accidentally expands
  a row.
- Render the inline expansion as a VStack of label / percent remaining /
  reset countdown, one row per QuotaWindowSnapshot, using
  AntigravityDisplay.windowLabel for the human-readable window name.
  Tinted surface background, chevron on the rightmost edge of the row rotates
  180 degrees when expanded, .animation(.easeInOut(duration: 0.18), value: isExpanded).

Fleet pull already returns distinct per-machine snapshots
(FleetOrigin.split in QuotaCore/FleetOrigin.swift); there is no aggregation,
so a MiniMax 63% on this Mac and a different percentage in the Fleet
section are two independent reads from separate API sessions, not a single
quota shown two ways.  The expanded row labels now make origin legible
without inspecting the underlying window.

Board 42ae688ab3b84d9aa65e445aab072a15.  Closes #37.

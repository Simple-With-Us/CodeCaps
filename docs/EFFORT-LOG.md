# CodeCaps — Effort Log

Running log of work units, newest first.  Each entry: date, lane, summary,
PR (when shipped), follow-ups (when parked).

---

## 2026-09-28 — iOS Settings refresh button responsiveness, visual press feedback, and pull-to-refresh on main and settings screens [AG, in progress]

Lane: `ag/ios-pull-to-refresh-and-button-polish` (issue #70, board `30d3165e`).

Responsiveness and pull-to-refresh polish for CodeCaps iOS companion:
- Settings Refresh Quotas button: Fixed unresponsiveness and lack of touch-down visual feedback inside the Form by introducing `SettingsRefreshButtonStyle` with scale, opacity, and accent tint changes on press.  Expanded touch target to full width (`maxWidth: .infinity, minHeight: 44`) with `.contentShape(Rectangle())` so taps register anywhere on the button.  Added medium haptic impact and in-flight `ProgressView()` spinner with "Refreshing Quotas..." label and timestamp/error status.
- Pull-to-refresh on main screen and settings: Added `.scrollBounceBehavior(.always, axes: .vertical)` on the main `ScrollView` so vertical bounce and pull-to-refresh work reliably even when content is short or empty.  Added `.refreshable` to `companionSettingsView` so pulling down on Settings refreshes quotas with known endpoint/cache info.
- Initial startup and local snapshot persistence: Updated `refresh()` to save successful payloads to local sandbox storage (`CodeCaps/quota-windows.json` in Application Support and Caches) in addition to the App Group container.  Updated `loadLocalFallback()` to check local sandbox storage and retain file modification timestamps, preventing the app from appearing blank on launch when info is already known.  Added `.task` on `CompanionContentView` to trigger background refresh on appear.
- Unit tests: Added 2 unit tests in `CompanionModelTests.swift` covering local snapshot persistence methods and pull-to-refresh/button responsiveness hygiene.  All 238 tests pass.

---

## 2026-09-27 — iOS multi-window allowance periods, customizable platform order, duplicate source folding, and foreground push alerts [AG, completed]

Lane: `ag/ios-multi-window-reorder-notifications` (issue #66, PR #67).

Parity updates for CodeCaps iOS companion matching macOS menu bar Glance popover:
- Multi-window expansion: Tapping any platform card expands inline to show each allowance period / window with label, reset countdown, mini progress bar, and percentage.  Consolidates multi-window platforms (e.g. MiniMax 4 active windows, Claude Code 5h and 7d windows).
- Customizable platform order: Full reordering in Companion Settings with up/down arrows and drag-to-reorder, with persistence to UserDefaults and App Group (`group.com.simplewithus.codecaps`).  Includes a navigation toolbar shortcut.
- Duplicate source folding: When multiple readers report for the same window (e.g. Cursor DashboardService and `gbu` for Grok Bot weekly), the primary controls the platform card and duplicates fold cleanly under an expandable "Additional Sources" disclosure section.
- Foreground notification delegate: Fixed iOS suppressing foreground local/test notifications by configuring `CodeCapsNotificationDelegate` with `UNUserNotificationCenterDelegate` `willPresent` returning banner, sound, badge, and list.  Verified test alerts and remote push display banners immediately.
- Fixed `AlarmSoundPlayer.swift` `AVAudioSession` conditional compilation for macOS companion target `CodeCapsCompanionMac`.
- Added 5 unit tests in `CompanionModelTests.swift` covering App Group parity, sentence gap hygiene, platform ordering, duplicate source separation, and Antigravity controlling-cap masking.  All 222 tests pass.

---

## 2026-09-27 — Public site and README Simple With Us attribution [CODEX, deployed]

Board: `4ddf224d`.  Issue #56.  Site PR #59 merged to `gh-pages`; README PR #58 merged to `main`.  The published `codecaps.simplewithus.com` footer visually shows the complete official SWU logo and its WebP returns HTTP 200.  README and GitHub About now describe supported AI plan usage and quota windows; app runtime unchanged.  The site Seer check was canceled after early merge without a finding; source and live page were reviewed manually.

---

## 2026-09-25 — Ingest Token save fails with a false "Unlock your login Keychain" [CLAUDE, in review]

Lane: `claude/keychain-save` (`~/apps/codecaps-claude-keychain`).  Board: `dcf96412`.

Share This Mac could not save the rotated Ingest Token.  The unified log showed `SecItemDelete` -25244 (errSecInvalidOwnerEdit) and then `SecItemAdd` -25299 (errSecDuplicateItem): the `sync-token` item came from an ad-hoc AgentBar build (2026-09-15), and its owner entry trusts no app.  The stale item (holding the rotated token, which was getting 401) was deleted.  PR #46 updates the item in place when a delete is refused and shows the real OSStatus.  Open for adversarial review, not merged.  Reinstalled from `origin/main`.

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

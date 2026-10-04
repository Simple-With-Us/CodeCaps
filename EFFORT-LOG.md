# CodeCaps — Effort Log

## 2026-10-03 — MiniMax 5h/7d normalization, pacing marker prominence, and touch targets [AG, in progress]

Lane: `ag/ios-minimax-and-meter-prominence`.

- MiniMax cadence normalization: normalized "Coding plan (all models)" and interval tokens directly into the 5-hour quota (`5h`) and weekly into `7d`, consolidating MiniMax into two primary windows side by side without duplicate model metrics.
- Prominent pacing markers on iOS: updated `CompanionUsageBar` to an 18pt capsule marker with a 3.0pt width and 20pt allocated frame height, matching Mac prominence and eliminating clipping.
- Touch target polish: enlarged the reset alarm bell button to 44x44 points with `.contentShape(Rectangle())` for Apple HIG compliance.
- Verified with 17 passing `CompanionModelTests` and clean local Xcode build for `CodeCapsCompanion` iOS Simulator target.

---

## 2026-10-03 — Companion Shared-Keychain Read Token [CODEX, in progress]

Lane: `codex/companion-shared-keychain`.  Board `7175aba0`; GitHub issue #129.

- Migrate the companion read token from standard and App Group preferences into an App Group Keychain item shared by the app and iOS widget.  Keep legacy values until a successful Keychain write, provide explicit removal, and test migration/failure paths without real credentials.
- iOS App Store profiles already authorize `group.com.simplewithus.codecaps` for both targets.  XcodeGen will include the shared store in app and widget targets; no hand-edited entitlements or project file.

---

## 2026-10-03 — Canonical brand icon, Glance meter alignment, iOS dual meters, and runaway alert history [AG, completed]

Lane: `ag/companion-bars-and-icons`.

- Canonical CodeCaps brand icon: restored the owner's authentic 3D gauge squircle mark from `/Users/jay/Code/Icons-Logos/CodeCaps/CodeCaps-Icon.icns` as `assets/AppIcon.icns`, updated `assets/icon-1024.png`, populated all 15 iOS and Mac asset catalog sizes in `ios/CodeCapsCompanion/Assets.xcassets/AppIcon.appiconset/`, and updated `script/build_and_run.sh` to use canonical `assets/AppIcon.icns` directly without double-plate resizing.
- Glance meter alignment: decoupled percentage and reset countdown in `GlanceMeter` (`GlanceViews.swift`) into distinct columns with fixed widths (44pt percent trailing-aligned, 50pt countdown centered in an invisible column with fixed gap) so countdown alignment never shifts based on 100% vs 2-digit percentages.
- iOS companion dual quota meters & MiniMax parity: updated `CompanionQuotaModel.swift` to exclude MiniMax supplementary video quota matching Mac Glance, added `shortWindow` / `longWindow` cadence resolution, replaced single overarching progress bar in `CompanionContentView.swift` (`quotaCard`) with two side-by-side meters (`CompanionMeterView`) visible without expanding, and increased `CompanionUsageBar` pacing marker height to 16pt (width 2.5pt) matching Mac Glance.
- Runaway usage alerting visibility: updated `BurnRateNotification` in `BurnRateMonitor.swift` to explicitly name the provider and quota window in notification title and body; created `RunawayAlertRecord` history persisted in `MonitorModel.swift`; rendered recent runaway alert log in Settings under Runaway Agents; and updated Glance footer detail to surface recent alerts from the last 24 hours even after active burst subsides.
- Verification: all 590 unit tests pass (0 failures, 4 skipped); iOS simulator builds clean via `xcodebuild`.

---

## 2026-10-03 — Fleet Antigravity row says when the weekly reading is missing [GROK-BUILD, in progress]

Lane: `grok-build/fleet-weekly-gap`.  Board `47021e4c`.  Worktree `~/apps/codecaps-grok-build`.

- A fleet Antigravity row whose payload has a 5h meter and no weekly meter used to leave the second column blank.  The long column now says "no weekly reading reported".  A masked weekly says the existing masked caption.  A weekly that is already on screen, a local row, and a one-meter provider leave the column alone.
- Files: `Sources/CodeCaps/GlanceViews.swift`, `Tests/CodeCapsTests/GlanceRowTests.swift`.  Codex's runaway-alert footer in the same file is left as it landed in #128.

---

## 2026-10-03 — Native Widgets and Independent Data Setup [CODEX, in progress]

Lane: `/Users/jay/.codex/worktrees/codecaps-board/CodeCaps`, `codex/alerts-provenance-20261003`.  Boards `508560f7`, `9a3d1a21`, `bc0f76fd`, `29df655f`, `1b71afd1`.

- Public setup guide shipped in PR #127: https://codecaps.simplewithus.com/setup.html.  Runtime alerts and client machine identity shipped in PR #128.
- Native widget repair adds correct shared-group signing on Mac and iOS, independent real widget cache, optional iOS timeline pulls, and in-app setup links.  iOS drag reorder, menu presets, and Gemini CLI reader included in the active batch.
- Verification is in progress.  Do not mark widgets shipped until signed package and actual data access are verified.  Usage-Monitor #1583 remains blocked by an upstream unpatched development dependency advisory; no audit bypass.

---

## 2026-10-03 — App design audit F-02 iOS Theme tokens & F-06 Console toolbar density [AG, completed]

Lane: `ag/design-audit-f02-f06`.

- iOS Companion Theme tokens (F-02, issue #41): added `CompanionTheme.swift` providing appearance-sensitive dynamic color tokens (`accent`, `warning`, `danger`, `barUsed`, `barRemaining`) matching macOS `Theme` (0x087370 teal, 0xA85C05 warning, 0xBF3339 danger).  Replaced hardcoded red/orange/green values across `CompanionQuotaModel.swift` and `CompanionContentView.swift`.
- Console toolbar density (F-06, issue #41): replaced the segmented Compact / Detailed layout control with a borderless View Options gear menu on All Platforms; repositioned the Find a Platform search field immediately adjacent to the page title; added `minWidth: 200` to the page title to prevent middle truncation at minimum window width.
- Unit tests & build verification: verified clean builds on macOS (`swift build`) and iOS Simulator (`xcodebuild`); extended `ConsoleNavigationTests.swift` with layout test coverage; 581/581 unit tests passing.
- Board & audit reconciliation: closed remaining actionable items for design audit issue #41 / board `4cef1b89`.

---

## 2026-10-03 — Console sidebar arrow navigation, window min size bump, iOS settings detents, and board completion [AG, completed]

Lane: `ag/arrow-nav-and-board-parity`.

- Console sidebar arrow navigation: added focus-aware keyboard navigation to `ConsoleSidebar` (`ConsoleViews.swift`) using `@FocusState`, `.focusable()`, and `.onMoveCommand`, allowing Up/Down arrow keys to navigate seamlessly between All Platforms, platform detail rows, and Settings pages while preserving custom button styling and accent highlights (closes issue #9).
- Console window minimum size: bumped `Metrics.consoleMin` in `QuotaComponents.swift` from 820 × 560 to 880 × 600 per app-wide design audit finding F-07 (issue #41).
- iOS companion settings presentation: added `.presentationDetents([.medium, .large])` to the settings sheet on iOS in `CompanionContentView.swift` so the underlying quota list remains visible (finding F-05, issue #41).
- Unit tests: added `ConsoleNavigationTests.swift` covering `Metrics.consoleMin`, page serialization round-trip, and settings page filtering; all 581 tests green in `swift test`.
- AGENTS.md coordination protocol: documented inter-agent coordination stanzas, `#agent-sync` header formats, and per-bot routing policies per fleet instruction.
- Board & issue reconciliation: conducted full board review against shipping codebase.  Verified and reconciled completed work: closed issue #44 (iOS preview sound shipped in #65) and issue #57 (public site screenshots redrawn by Claude on Sep 30); resolved 17 open board items confirmed landed in previous PRs (#40, #43, #53, #65, #67, #74, #75, #103, #109, #110, #111, #112, #113, #115, #117, #118).

---

## 2026-10-02 — Custom mark sync, updated app icons, quota bar parity, cadence fix, and honest fallbacks [AG, completed]

Lane: `feat/ios-icons-bar-parity-glance-logos` (PR #115, squash `f48fbda`).

- Custom mark sync over wire: added `CustomMarkPayload` transport in `LocalQuotaSnapshot.swift` and `WireEnvelope`.  Mac `LocalQuotaSnapshot.write` auto-exports loaded custom provider marks to `group.com.simplewithus.codecaps/CustomMarks/` using private 0600 file descriptors; iOS companion unmarshals and renders them in-app.
- Glance popover custom logo resolution: resolved bug where custom marks loaded in Settings but failed to render in the docked Glance popover/menu bar; added multi-extension lookup and candidate pool matching in `PlatformLogoImage`.  Updated `markStyle` and `glanceMarkStyle` to detect disk-resident custom marks and return `.custom`.
- App icons regenerated: updated all 26 sizes across iPhone, iPad, and macOS AppIcon sets in `ios/CodeCapsCompanion/Assets.xcassets/AppIcon.appiconset/` from `assets/icon-1024.png`.  Staged and running on Mac at `/Users/jay/Applications/CodeCaps.app` (PID 51106).
- Real MiniMax mark on iOS: replaced SVG monogram in `ios/CodeCapsCompanion/Assets.xcassets/provider-minimax.imageset/` with official raster waveform scales (`@1x`, `@2x`, `@3x`).
- MiniMax cadence fix: updated `formatCadence` in `CompanionQuotaModel.swift` and `WidgetPresentation.swift` to inspect `w.window` first and correctly parse `4h`, `5h`, `1d`, and `1w` intervals.
- Quota bar parity: added `CompanionUsageBar` with two-tone segments (red used + green remaining) and vertical pacing indicator with white halo to iOS companion cards and widget `MiniProgressBar`.
- Fleet-wide fallback rule: replaced lookalike SF Symbols with `"questionmark.square.dashed"` across Mac and iOS.
- Remote runner CI: iOS TestFlight build dispatched to GitHub-hosted macOS runner (`ios-ship.yml`, run 37087309918).
- Coordination: briefed MiniMax (`[MM]`) in Slack `#agent-sync` (thread `1790990134.027879`); Apple Note created and pinned headlessly in iCloud folder `Coding`.

---

## 2026-10-02 — Mac widget embedding, honest widget empty state, Glance and Settings UI polish, and custom logo fixes [AG, completed]

Lane: `ag/ui-widgets-polish-and-embed` (issue #111, PR #112, squash `7c25e14`).

- Embedded macOS widget extension: Updated `script/build_and_run.sh` to compile `CodeCapsWidgetsMac` universal target (`arm64`/`x86_64`) and embed `CodeCapsWidgets.appex` inside `Contents/PlugIns/`, signed and validated with Developer ID.
- Honest widget presentation: Eliminated misleading sample/placeholder numbers (e.g. 94%, 74%, 91%) across iOS and macOS widgets (`WidgetDataProvider.swift`, `WidgetViews.swift`); unconfigured or un-synced widgets now render an explicit, honest `WidgetEmptyStateView`.
- Platform marks & fallback hygiene: Added `CustomMarkMode` (`.color` vs `.template`) and dark appearance variant support (`<key>-dark.<ext>`).  Enforced fleet-wide rule replacing sneaky SF Symbol lookalikes (`sparkles`, `cpu`, `bolt`, `cursorarrow.rays`) with `"questionmark.square.dashed"` across all unresolved logos.
- Glance popover polish: Increased row spacing (`glanceLocalRowHeight = 42pt`) with a visible faint grey hairline divider (`Theme.hairline`), high-contrast timeframe label styling, and italic reset countdowns placed directly adjacent to percentages.
- Settings & console layout: Removed dark tick before time elapsed; enforced strict Title Case "Under Pace" / "Over Pace" (dropped "cap"); removed duplicative provider names in footer; enlarged pacing marker (18pt height) standing proud of the quota bar; arranged multi-window models side-by-side in `HStack`.
- Coordination: Polled and posted progress on `#agent-sync` (`[AG->MM]`), collaborating with MiniMax (`[MM]`) in `~/apps/codecaps-mm-finish`.
- Verification: 576/576 unit tests green in `swift test`; staged bundle validated by `codesign --verify --deep --strict`.
- Local installation: Staged, signed, and launched into `/Users/jay/Applications/CodeCaps.app` (PID 35926), replacing stale Oct 1 build.

## 2026-10-01 — Custom platform logo color version and light/dark variant modes [AG, completed]

Lane: `ag/custom-logo-color-and-dark-mode` (board `6a375482`, issue #102, PR #103, squash `b1d38a7`).

- Fixed bug where uploaded custom logos (such as MiniMax) were treated as monochrome template marks and tinted pure black `#1F2B3A` / `Theme.ink`.
- Added `CustomMarkMode`: `.color` (Color Version, default) preserves full original artwork with `.renderingMode(.original)` and no tint; `.template` (Light/Dark Version) renders an adaptive silhouette.
- Added support for dedicated Dark Appearance variant uploads (`<key>-dark.<ext>`) alongside primary custom logos (`<key>.<ext>`), resolving automatically across SwiftUI views and the status item when dark appearance is active.
- Updated Settings `SettingsLogoStylePage` with segmented mode picker, distinct primary and dark variant action rows, and clear helper copy.
- Updated menu bar status item in `AppDelegate` and `PlatformLogoImage.menuBarImage` to honor `CustomMarkMode` and appearance variants.
- Verified with 557 passing tests in `swift test`, including new test cases for custom mark mode persistence, cache busting, and dark variant resolution.

## 2026-09-29 — WidgetKit widgets for CodeCaps (iOS Home Screen, Lock Screen & Mac desktop) [AG, completed]

Lane: `ag/widgets-ios-mac` (issue #76).

WidgetKit widget extension for CodeCaps across iOS and macOS:
- Overview widget (`systemSmall`, `systemMedium`, `systemLarge`): displays active AI provider quotas, remaining percentages, and reset countdowns.
- Single Provider Focus widget (`systemSmall`, `systemMedium`): dedicated circular/linear gauge tracking a chosen AI provider or closest-to-cap provider.
- Lock Screen / StandBy accessory widgets (`accessoryCircular`, `accessoryRectangular`, `accessoryInline`) for at-a-glance monitoring on iOS.
- App Group container data bridge (`group.com.simplewithus.codecaps`) reading `quota-windows.json` and UserDefaults platform order.
- Live timeline reloads wired into `MonitorModel.swift` (macOS) and `CompanionQuotaModel.swift` (iOS).
- Verified via `xcodebuild` (iOS simulator and macOS targets) and unit tests in `WidgetTests.swift` (all 285 tests passing).


## 2026-09-29 — Sparkle 2 auto-update pilot (fleet Mac apps auto-update) [CLAUDE, merged]

Lane: `claude/sparkle-auto-update` at `~/apps/codecaps-claude-sparkle` (board `7d27a555`).  PR #75, squash `eba1706`.

Owner ruling today: every fleet Mac app updates itself through Sparkle 2 from signed releases CI publishes on each merge to `main`; CodeCaps is the pilot and `docs/AUTO-UPDATE.md` is the pattern to copy.  Sparkle 2.10.0 via SwiftPM, `AppUpdater` installs as soon as CodeCaps is not frontmost, **Check For Updates…** in both menus and Settings ▸ About.  `build_and_run.sh` embeds and inside-out signs `Sparkle.framework` and verifies strictly; `mac-release.yml` publishes `v<VERSION>-build.<N>` releases marked latest, feed `releases/latest/download/appcast.xml`.  Local rehearsal: notarized build 66 updated itself to build 67 in about ten seconds.  Main run 36653509344 built and verified the bundle on CI, then skipped publishing: `MAC_CERT_P12_BASE64` and `MAC_CERT_PASSWORD` are not reachable (no Infisical wiring or repository secrets on CodeCaps yet).  `SPARKLE_ED_PRIVATE_KEY` was set; `ASC_*` already existed.

## 2026-09-29 — Glance popover shows the 4-5hr and weekly/monthly bar on every row [MINIMAX, merged]

Lane: `mm/glance-dual-bars` at `~/apps/codecaps-mm-glance-bars` (board `792f3427`).  PR #74, squash `4bc714e`.

The compact row spoke for one window only — the one closest to its cap — so seeing both cadences meant expanding every row.  A plan could read 92% on the 5h window while the weekly cap sat at 11%, and the glanceable surface hid that.

- Popover widened 400pt to 560pt.  Each row carries two meters on the collapsed line: caption, bar, percentage, one per cadence.  Both stay on one line, so `QuotaGlanceMetrics.popoverHeight` and the popover's height behaviour are unchanged.
- Windows pair by cadence, not array order: short = closest to cap among sub-day cadences, long = closest among weekly-or-longer, read from each reader's own token and falling back to time-to-reset.  Captions come from the token, so Antigravity's "Claude & GPT · Weekly" renders as "7d".
- Antigravity masked 5h windows stay out of a meter; a row with every window masked falls back to its driving window rather than rendering blank.  Single-cadence providers fill slot one only — they used to be able to resolve both slots to the same snapshot, which renders one meter duplicated.  MiniMax supplementary video quota never displaces a real cap.
- Column widths are `Metrics` constants and `glanceRowIntrinsicWidth` is computed from them, so a widened column fails a test instead of clipping the `Open CodeCaps ⌘1` footer the way the old 360pt width did.
- 269/269 `swift test` green, 19 new in `GlanceMeterTests`.  Rendering the real rows at 560pt caught a collision no test could see: `meterArea` is a single child of the row's `HStack`, so the gap written outside it never landed between the two meters and the first meter's percentage ran into the second meter's caption.
- The chevron stays.  The expansion is now for detail the meters leave out: a third cadence, or a per-model split inside a pool.

## 2026-09-26 — Public site quota and fleet copy — DEPLOYED

Lane: `codex/public-copy` at `~/apps/codecaps-codex-public-copy` (board `90d3d40a`, issue #52).  PRs #53 and #54 aligned the GitHub Pages product copy with supported AI plan windows, existing local sign-ins, and optional collector push/pull.  Pages run 36281399171 deployed the gh-pages merge, and the live page and screenshot assets were verified.  No reader or app behavior changed.

Running log of work units, newest first.  Each entry: date, lane, summary,
PR (when shipped), follow-ups (when parked).

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
GitHub umbrella: [#19](https://github.com/Simple-With-Us/codecaps/issues/19).
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

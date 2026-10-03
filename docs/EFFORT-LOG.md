# CodeCaps — Effort Log

Running log of work units, newest first.  Each entry: date, lane, summary,
PR (when shipped), follow-ups (when parked).

---

## 2026-10-03 — Remove Obsolete Pin Control and MiniMax Asset [CODEX, in review]

Lane: `codex/remove-stale-controls-20261003`.  Boards `11b25418`, `979b2c38`.

- Removed the inert Keep In Front menu action and unused stored model property.
  Toolbar pin removal and single-meter alignment had already shipped.
- Retained the newer #117 activation policy: menu-bar-only stays accessory;
  Dock-capable modes show the icon with an open window and remove it on close.
- Removed unused fabricated `minimax.svg`; the real `minimax.png` remains the
  rendering source.  Corrected both resource and root README rendering/provenance.
- Verification: focused PlatformLogoResourceTests 4/4 and DocsScreenshotTests
  render 1/1 passed from a fresh build.  No installed app changed.
- Reconciliation correction: `20dc3a22` reopened after tracing the runtime path.
  #109 records history and exposes thresholds but never invokes anomaly evaluation.
  Actual evaluation and notifications remain active work, not complete.

---

## 2026-10-03 — Console sidebar arrow navigation, window min size bump, iOS settings detents, and board completion [AG, completed]

Lane: `ag/arrow-nav-and-board-parity`.

- Console sidebar arrow navigation: added focus-aware keyboard navigation to `ConsoleSidebar` (`ConsoleViews.swift`) using `@FocusState`, `.focusable()`, and `.onMoveCommand`, allowing Up/Down arrow keys to navigate seamlessly between All Platforms, platform detail rows, and Settings pages while preserving custom button styling and accent highlights (closes issue #9).
- Console window minimum size: bumped `Metrics.consoleMin` in `QuotaComponents.swift` from 820 × 560 to 880 × 600 per app-wide design audit finding F-07 (issue #41).
- iOS companion settings presentation: added `.presentationDetents([.medium, .large])` to the settings sheet on iOS in `CompanionContentView.swift` so the underlying quota list remains visible (finding F-05, issue #41).
- Unit tests: added `ConsoleNavigationTests.swift` covering `Metrics.consoleMin`, page serialization round-trip, and settings page filtering; all 581 tests green in `swift test`.
- AGENTS.md coordination protocol: documented inter-agent coordination stanzas, `#agent-sync` header formats, and per-bot routing policies per fleet instruction.
- Board & issue reconciliation: conducted full board review against shipping codebase.  Verified and reconciled completed work: closed issue #44 (iOS preview sound shipped in #65) and issue #57 (public site screenshots redrawn by Claude on Sep 30); resolved 17 open board items confirmed landed in previous PRs (#40, #43, #53, #65, #67, #74, #75, #103, #109, #110, #111, #112, #113, #115, #117, #118).
- CODEX correction (Oct 3): #57 screenshots existed on main but were not published on gh-pages; live HTTP verification still found AgentBar imagery.  Publishing fix is #123.  #109 also lacks runtime anomaly evaluation, so board 20dc3a22 remains active.  These corrections preserve the implementation history while qualifying the broad closeout.

---

## 2026-10-03 — Coordinated Board Reconciliation [CODEX, merged]

Lane: `codex/board-completion-20261003` at
`/Users/jay/.codex/worktrees/codecaps-board/CodeCaps`.  Board `45805a06`.  PR #120.
Owner requested joint completion with AG, MM, GROK, and CODEX.
Coordination packet: https://fleetlink.online/codecaps-board-20261003.

- Baseline `87544c2` has no open PRs and successful Swift CI, secret scan,
  and Mac Release checks.  The initial board has 24 open/in-progress rows;
  GitHub has 11 open issues.  Each stale item is checked against current code.
- Initially reconciled, then corrected below: runaway alerts `20dc3a22`
  were not complete.  Confirmed completed on the board: contrast `966fdffc` and row alignment `01b6d75a`
  (#111), custom marks `6a375482` (#103/#115), visual assets `eafb250b`
  (#113/#115/#117/#118), and reset sound options `2b922851` (#43).
  Cross-device push remains separately tracked in issue #42.
- External TestFlight `a464226b` is complete: live App Store Connect reports
  public group enabled with assigned build `202609240254` externally
  `IN_BETA_TESTING`.  Newest build `202610031929` is valid but still
  `READY_FOR_BETA_SUBMISSION`; external beta enablement does not imply that
  every subsequent build has been promoted.
- GROK-BUILD acknowledged read-only reconciliation of issues #8/#10/#12/#13.
  AG and MM were contacted for iOS and Mac UI reconciliation respectively;
  their proposed assignments are not accepted claims until acknowledged.
- Remaining discrepancies include the inert Keep In Front menu command,
  missing alert-enabled copy, and obsolete MiniMax SVG documentation.
  PR #117 explicitly preserves menu-bar-only mode without a Dock icon;
  confirm later owner intent before reversing that behavior to match an
  older board description.
- Monetization awaits the requested owner product choice.  Public embeds
  and cross-device push require a concrete server/privacy contract before
  implementation.  They remain open, not silently counted as complete.

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

---

## 2026-09-30 — Glance v3: top bar, Title Case switch, Grok Bot stray bar, bar ends [CLAUDE, local]

Lane: `claude/glance-v3-topbar` (worktree `~/apps/codecaps-claude-glance-v3`).  Owner delta on top of Glance v2.

- Header: one centre line.  `CodeCaps`, a 20pt gap, the switch, a spring (never under 16pt), then `[bell] All • 6 of 7 • 4:27 PM [reload]` at an even 10pt between neighbours.  The header is 40pt tall and every control is 22pt, so each has 9pt of air above and below.  The dots are drawn, not typed, so the rhythm holds at "12 of 12", "12:59 PM" and "12 sources".
- Switch labels are Title Case, `From Mac` and `From Fleet`, in two equal boxes, with tooltips that say what the list becomes.  The bell label is `All`, not `ALL`.
- Grok Bot's stray extra, empty `7d` bar: the second meter slot took any other window of the row, and `gbu`'s no-reading placeholder (or the second source's copy of the same weekly) captioned `7d` like the reading beside it.  Fixed in the reader merge (`droppingSupersededPlaceholders`) and in Glance (`glanceDrawableWindows`, `glanceIsCopy`).
- Bars: 0% used draws no red (and 0% left no green); a marker near an end stands at the bar's end instead of leaving a cap of bar beside it.
- Evidence: `GlanceRenderTests` (`CODECAPS_GLANCE_RENDER_DIR`).

---

## 2026-09-30 — Glance v2: From Mac / From Fleet, source bands, thicker bars, two-unit countdowns, MiniMax expand [CLAUDE, in review]

Lane: `claude/glance-v2-polish` (worktree `~/apps/codecaps-claude-glance-v2`, board `622653dd`).  Owner delta on top of the switch below, which this renames: `THIS MAC | FLEET REPORTED` is now `FROM MAC | FROM FLEET` everywhere (titles, VoiceOver, empty states, tests).  The stored `glanceView` values stay `thisMac` and `fleetReported`, so a saved choice survives.

- Header: the right side is one line, `[bell] ALL   •   6 of 7   •   4:27 PM   [reload]`, live.  With All off, each row starts with a faint bell (solid when picked) and its logo and name shift right.
- From Fleet: no per-row FLEET badge.  Rows sit under an uppercase heading per reporting source (`FleetOrigin.identity`, for example `CHATGPT.COM`) on a band darker than the list, with the source's latest reading on the right.  A source that names nothing reads `UNNAMED SOURCE`.  Band text has its own colour (`Theme.groupBandLabel`, 4.5:1 or better in both appearances, tested).  A fleet MiniMax row never expands.
- Bars are 6pt (1.5x) with a 16pt elapsed marker (2x, same 2pt width); the gap between the two meters is 48pt (was 24pt); the popover stays 624pt.
- Countdowns show the two largest non-zero units (`4d 2h`, `4d 59m`, `2h 42m`, `45m`, `<1m`), with the full value and the reset's date and time in a tooltip on the countdown.  The Console's Next Reset tile keeps the whole value.  The row's own tooltip now sits on the logo and name, so it never nests with the countdown's.
- Expanded rows list only windows the row's two meters leave out, as meter lines in the row's columns (local MiniMax opens to its video 1d / 7d line).  A second source's copy of a shown window is not listed again.  VoiceOver reads each line with its captions and resets.
- A row with no reading (`not signed in`, `unavailable`, `login idle`, `needs permission`) starts its text where a single bar starts; `GlanceAlignmentTests` lays a real row out and compares pixels.
- Third-Party star: pure black on Light, pure white on Dark.  Gemini keeps the colour star.  Cursor's plan reads `1m`.
- Evidence: `GlanceRenderTests` (`CODECAPS_GLANCE_RENDER_DIR`) draws From Mac and From Fleet (two sources), All on and off, MiniMax expanded, Claude signed out and the fleet empty state, Light and Dark.  The docs Glance screenshots are regenerated.

---

## 2026-09-30 — Glance view switch, per-provider reset alarms, Third-Party pool, 1m, roomier rows [CLAUDE, in review]

Lane: `claude/glance-toggle-alarms` (worktree `~/apps/codecaps-claude-glance-toggle`, board `e551b867`).

- Glance header: a two-box `THIS MAC | FLEET REPORTED` switch beside the name shows one set of rows at a time and is remembered across launches (`glanceView`).  The in-list "THIS MAC" heading is gone; fleet sources keep a heading each, now carrying their "reported" time, and the header counts "N sources".  Fleet Reported with nothing connected explains how to connect an endpoint.
- Reset alarms are one model.  The header's **All** bell turns every provider's alarm on; with All off a faint bell at the left of each row picks providers one by one.  `ResetAlarmTracker` (QuotaCore, pure, persisted) decides: the largest window alarms on every reset, a smaller one only after reaching 20% or less remaining, never on a first reading, once per reset across restarts and across This Mac and Fleet Reported.  Nothing else suppresses an alarm: a first draft held a smaller window's alarm back while a larger window read 0%, but that is not the owner's rule and it swallowed alarms whenever a model-only cap (Claude's Sonnet weekly, another MiniMax model's weekly) was spent.
- The tracker also restarts a window silently when its owner changes (Grok Bot's `gbu` reuses one id for whichever account is active; `QuotaWindow.accountKey`, local only), ignores stamps more than five minutes in the future, and counts an early provider reset with a short reset-time move when the percentage climbs back by 10 points or more.
- The iOS companion and its Mac build use the same tracker and wording (`ResetAlarmTracker`, `ResetAlarmMessage`, `ResetAlarmCadence` are compiled into the companion targets from `Sources/QuotaCore`).  Its per-row armed bells and "Notify on Quota Reset" switch are gone, replaced by the same All switch (Settings) and per-provider bells; old choices migrate once.
- Antigravity's "Claude & GPT" pool is "Third-Party" on Mac, iOS and in the docs.  The Gemini pool wears the colour Gemini star, the Third-Party pool the same star in one adaptive colour.  OpenAI, Cursor, Grok and MiniMax marks now follow light and dark like the Third-Party star, so they no longer draw black on the dark Glance surface.
- Monthly and billing-cycle windows caption as `1m` (Cursor's plan was "Plan").
- Rows: the percentage column fits "100%" plus a real gap, the two meter groups sit 24pt apart, and the countdown matches the caption's type (11pt medium, secondary, not italic), in the inline expansion too.  Popover 560 → 624pt; widths measured in tests.  The popover height now counts the row hairlines, so the list no longer scrolls by 7pt; a test lays the real view out and compares.  The Console sidebar's percent column fits "100%".
- Docs: `glance-light`, `glance-dark`, `glance-fleet`, `console-light`, `console-dark`, `platform-antigravity` and `settings-sources-fleet` are redrawn from invented demo readings by `DocsScreenshotTests` (opt-in, `CODECAPS_DOCS_RENDER_DIR`), so none still says "AgentBar" or "Claude & GPT".
- Known gaps: the Sources list in Console Settings describes Grok Bot as "Cursor app session" (old copy, not touched here).

---

## 2026-09-30 — CodeCaps iOS Release signs with the App Store profiles [GROK, completed]

Lane: `grok/codecaps-ios-sign` at `~/apps/codecaps-grok-ios-sign` (board `0f6b32c1`).

Xcode 26 automatic signing calls the developer provisioning service, and this API key gets 401 there.  The App Store Connect API still works, but every CodeCaps App Store profile has an empty App Group list, so a signature that requests `group.com.simplewithus.codecaps` cannot match.  Release now uses manual signing with "CodeCaps Companion AppStore" and "CodeCaps Companion Widgets AppStore", and those configurations omit the group entitlement.  Debug keeps the group for a logged-in Xcode session.  Widgets fall back to standard defaults, so a TestFlight build will not share quota data with the widget until the group is assigned on both App IDs and the profiles are regenerated.  Local Release archive succeeded with Apple Distribution and `get-task-allow` false.  GitHub-hosted ios-ship run 36768356017 uploaded build 202609301951, and App Store Connect reports it VALID.

---

## 2026-09-30 — Quota bars show used (red) then remaining (green), with the elapsed-time marker on every window [CLAUDE, in review]

Lane: `claude/quota-bar-used-remaining`.

Owner request: the black elapsed-time line sat in the right place but did not read against a bar that only filled for what was left.  Every quota bar is now one full-width two-segment bar: a red segment for the share used (`100 - remaining`) starting at the left, then a green segment for the rest.  Red reaching past the marker means a window is being burned faster than time.  The "% remaining" text and the reset countdown are unchanged.
- One bar, three surfaces: `QuotaUsageBar` (`QuotaComponents.swift`) now draws the Glance meters and both Console rows (paced and compact).  The Console's separate time-shaded pacing bar is gone.
- The math is pure and lives in QuotaCore (`QuotaBarMetrics.swift`): `QuotaPeriod` reads a window's period from its token, `QuotaPeriodSpan` turns that and the reset into a start, and `QuotaBarMetrics` gives segment widths, marker offset and the spoken value.  A monthly or billing-cycle window starts one calendar month before its reset, never 30 days.
- The marker is now on Cursor's monthly Plan and on any window whose period can be read, including tokens the old substring parser misread (`31d` as one day, `15h` as five hours) and `1w`.  A window with no derivable period has no marker.
- An explicit period start wins when the provider gives one: `QuotaWindow.periodStart` (local only, not a wire field) is filled from Cursor's `billingCycleStart`, Grok's period start and MiniMax's window start times.
- VoiceOver says "85 percent remaining, 15 percent used, 40 percent of period elapsed".
- Tests: `QuotaBarMetricsTests` (QuotaCore), `QuotaUsageBarTests` and `QuotaBarRenderTests` (CodeCaps); the render test writes light and dark PNGs when `CODECAPS_BAR_RENDER_DIR` is set and skips otherwise.
- Months are counted on a Gregorian calendar fixed to UTC (`QuotaPeriod.billingCalendar`), because provider resets are UTC instants.  On the Mac's local calendar a Mar 1 03:00Z reset started on Jan 29 in Chicago and skewed the marker and the "Day N of M" caption; tests now run the default path under America/Chicago and across a daylight-saving change.
- The percent column is 32pt wide (was 28pt) so "100%" no longer touches the reset countdown.
- iOS companion and widgets draw remaining-only bars with no elapsed marker, so they are unchanged.  Whether they should get the red-used and green-remaining split (no marker needed) is an open owner question.

---

## 2026-09-30 — Glance popover row spacing, left-alignment, pacing indicators, and per-meter countdowns [AG, completed]

Lane: `ag/glance-row-polish-and-pacing` (issue #78, board `0766f1a9`).

Glance popover UI refinements per user requirements:
- Row expansion and strict left-alignment: Restricted inline row expansion to platforms with more than 2 windows (`canExpand`), eliminating unnecessary expansion and chevron clutter for 1- or 2-window providers.  Enforced `alignment: .leading` and `.frame(maxWidth: .infinity, alignment: .leading)` across all row containers, preventing any horizontal shift or centering when expanded.
- Platform title gap and timeframe label styling: Halved the whitespace gap between provider logos and the first quota bar by reducing `glanceRowTitleWidth` from 136pt to 72pt.  Restyled timeframe labels ("5h", "7d", "Plan") to 11pt medium weight with secondary opacity, matching percentage clarity and balancing spacing before and after each bar.
- Per-meter reset countdowns: Embedded italicized reset countdowns in secondary gray directly to the right of every meter percentage, showing hours/minutes for short cadences and days/hours/minutes for weekly/monthly allowances.  Removed the single formulaic trailing countdown from the row's right edge.
- Window pacing indicators: Added a medium 2pt vertical pacing line crossing each bar vertically at the exact point in time elapsed within that window, calculated from window duration and time to reset via `glanceElapsedFraction`.
- Row dividers and vertical spacing: Increased row vertical spacing (`glanceLocalRowHeight` to 38pt, `glanceFleetRowHeight` to 50pt) and added faint hairline divider lines between rows on the main view.
- Tests: Added 4 unit tests in `GlanceRowTests.swift` covering `glanceElapsedFraction` calculations and weekly countdown formatting with minutes.  All 289 tests passing.

---

## 2026-09-29 — WidgetKit widgets for CodeCaps (iOS Home Screen, Lock Screen & Mac desktop) [AG, completed]

Lane: `ag/widgets-ios-mac` (issue #76).

WidgetKit widget extension for CodeCaps across iOS and macOS:
- Overview widget (`systemSmall`, `systemMedium`, `systemLarge`): displays active AI provider quotas, remaining percentages, and reset countdowns.
- Single Provider Focus widget (`systemSmall`, `systemMedium`): dedicated circular/linear gauge tracking a chosen AI provider or closest-to-cap provider.
- Lock Screen / StandBy accessory widgets (`accessoryCircular`, `accessoryRectangular`, `accessoryInline`) for at-a-glance monitoring on iOS.
- App Group container data bridge (`group.com.simplewithus.codecaps`) reading `quota-windows.json` and UserDefaults platform order.
- Live timeline reloads wired into `MonitorModel.swift` (macOS) and `CompanionQuotaModel.swift` (iOS).
- Verified via `xcodebuild` (iOS simulator and macOS targets) and unit tests in `WidgetTests.swift` (all 285 tests passing).

---

## 2026-09-29 — Sparkle 2 auto-update pilot (fleet Mac apps auto-update) [CLAUDE, completed]

Lane: `claude/sparkle-auto-update` at `~/apps/codecaps-claude-sparkle` (board `7d27a555`).

Owner ruling today: every fleet Mac app updates itself through Sparkle 2 from signed releases CI publishes on each merge to `main`, with CodeCaps as the pilot.  Sparkle 2.10.0 via SwiftPM; `AppUpdater` checks hourly, downloads in the background and installs the moment CodeCaps is not frontmost, relaunching without reopening the Console.  **Check For Updates…** is in both menus and Settings ▸ About.  `build_and_run.sh` embeds and inside-out signs `Sparkle.framework`, verifies with `codesign --verify --deep --strict`, notarizes with the App Store Connect API key when `NOTARY_KEY_*` are set, and runs `spctl` on the stapled app and DMG.  `mac-release.yml` publishes `v<VERSION>-build.<N>` releases (ZIP, DMG, appcast) marked latest; the feed is `releases/latest/download/appcast.xml`.  A local rehearsal notarized build 66 and watched it update itself to build 67 in about ten seconds.  Publishing stays gated until `MAC_CERT_P12_BASE64` and `MAC_CERT_PASSWORD` are reachable (Infisical or repository secrets).  The pattern and the copy-to-another-app recipe are in `docs/AUTO-UPDATE.md`.

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

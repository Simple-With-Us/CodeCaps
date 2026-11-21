# Phone Quota And Shared-Pool Parity

Refs CC-237.

The iPhone companion uses compact rows with inline red/teal meters, rectangular elapsed-time ticks, pace-sensitive percentage badges and each meter’s reset countdown.  Caps, stale-reading notices, both Antigravity pools, model-limit expansion and alarm controls remain available.  Accessibility text sizes stack the row rather than squeezing its labels.  The existing provider marks render directly in the compact rows.

The shared pool’s fast-usage indicator reaches Cursor, Grok Bot, xAI and Grok when they show the same account and reset period.  Collector identity, slight reading differences and weekly-token aliases do not split that state.  API-credit windows, other accounts and other periods stay separate.  Equally fresh native participants keep provenance through response deduplication, and the widget publisher coalesces otherwise-identical raw/projected copies without losing that provenance.

A shared normalization rule repairs legacy MiniMax general/coding-plan interval rows mislabeled as daily before phone/widget captioning and allowance pairing.  It preserves weekly, video, other model and other provider cadences.  The widget contract fixture keeps the coding pair at 5h and 7d.  Empty model aliases fall through to the usable model type.

Validation uses the actual phone-row and widget views in a native resource-bundled SwiftUI probe.  Fourteen sample rows occupy 686 points at 375- and 393-point widths, with separate accessibility coverage.  The iOS app/widget simulator-platform compile and pinned XcodeGen regeneration check pass.  The connected Mac has no simulator runtime; native phone-width fixtures are not simulator screenshots.  Full package results, hosted checks and release state are recorded in the PR and CC-237 before readiness is claimed.

## Verification Commands And Records

Run from the repository root on the Mac unless a subshell changes directory.

```sh
swift test -j 4
CODECAPS_WIDGET_RENDER_DIR=.build/cc237-native bash scripts/test-widget-ui-native.sh
(cd ios/CodeCapsCompanion && xcodegen generate)
git diff --exit-code -- ios/CodeCapsCompanion/CodeCapsCompanion.xcodeproj/project.pbxproj
xcodebuild -project ios/CodeCapsCompanion/CodeCapsCompanion.xcodeproj \
  -scheme CodeCapsCompanion -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/cc237-ios -jobs 4 \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

The complete run at `25f5a09` executed 1,872 tests (22 widget parse, 1,098 QuotaCore, 752 app), with 10 skipped and zero failures.  Local log: `/tmp/cc237-full-tests-verified.log`.  Review follow-ups are checked again before readiness; this record does not substitute for current-head CI.

The iOS command ended with `BUILD SUCCEEDED` in `/tmp/cc237-ios-build-final.log`.  XcodeGen 2.46.0 generation and the tracked-project diff both exited zero.  Native render log: `/tmp/cc237-native-ui-final.log`; artifacts: `.build/cc237-native/companion-375-light.png`, `companion-393-light.png`, `companion-accessibility.png`, and widget galleries.  The render command asserts actual provider-mark resolution and the 686-point row bound.

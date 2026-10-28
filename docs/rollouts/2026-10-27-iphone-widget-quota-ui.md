# iPhone and widget quota presentation

This correction is based on the October 27 iPhone/widget screenshots. The Mac screenshot is a good content reference, not a defect target. No subscription pools are merged and no telemetry completeness is inferred from a placeholder.

- Widget missing/masked readings keep a neutral track and do not show a pacing marker. Real zero remains a spent red segment.
- iPhone cards no longer repeat meter cadences under the platform name. The meter percentage and reset are left-aligned together with distinct styles.
- Generic unclassified windows say Limit; actual extra allowances say Extra. Muse Assist keeps weekly zero visible while showing its usable extra balance. A missing reset timestamp stays unknown; it does not assert that the allowance never resets.
- Large overview widgets offer plan detail and All Plans buttons backed by an AppIntent, without launching the app. The Compact option omits the detail controls. Small and medium widgets keep their compact layouts and existing edit options.

Detail selection is presentation-only App Group state, scoped by widget configuration. Identical overview configurations share the selection. This is a bounded detail pane, not arbitrary navigation or an expandable/resizable PiP window. It displays up to four windows and states if more are available in the app.

## Validation

Use `scripts/test-widget-ui-native.sh` on macOS to compile the production widget sources, test missing/zero/extra caption states and select/back persistence, and render light/dark views without a live account or network fetch. Inspect the resulting pixels. `swift test --filter 'WidgetTests|CompanionModelTests'` checks the companion contracts. Build the iOS app and widgets using the generated Xcode project with signing disabled for compile qualification.

Native component renders and AppIntent persistence tests do not prove a physical iPhone Home Screen tap. That final hosted interaction check and release-artifact qualification remain separate from source tests and compilation.

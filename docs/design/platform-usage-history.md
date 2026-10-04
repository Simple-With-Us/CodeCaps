# Platform Usage History

Owner direction, October 3, 2026: remove All Platforms and make usage history visible on each individual platform page.  Alerts must identify the affected quota and open its details.

## Review Evidence

The UI review used the supplied macOS notification screenshot and the native source at `659e6f5`, including the alert identity/history work in PR #134.  The screenshot showed a generic runaway banner with a 13.7× comparison.  It did not show the full application window.  These recommendations are a source-based design review, not a completed runtime visual audit.

## Page Hierarchy

The full application opens the last available platform, or the first platform in display order.  An obsolete All Platforms selection migrates to a platform.  When no platform exists, the app offers source setup.  The Settings keyboard shortcut retains the last settings destination.

Each platform page places usage history before display customization.  Current quota values remain visible alongside the history context.  Independent quota windows and Antigravity pools have clear labels; percentages from different allowances are not added together.

The chart defaults to 24 hours, with a 7-day option.  Its vertical scale is remaining quota from 0% to 100%, and its horizontal axis is local time.  Consumption rates use percentage points per hour.  These readings do not establish dollar spending, token consumption, or which individual agent caused a spike.

## Data Honesty

Reset boundaries, account changes, and missing observation intervals break the line.  Re-reading an unchanged observation does not create a new point.  Empty history, insufficient rate history, and stale readings are distinct states.  A graph must not imply continuous monitoring when the app was inactive.

Comparisons describe the history actually available.  A short history is not called a seven-day average, and a zero comparison rate cannot produce a meaningful finite multiplier.  Notification text and detail views use the same measured rates.

## Alert Navigation

A notification, recent alert row, or chart marker selects the affected platform and quota window.  Antigravity pool windows resolve to their own visible section.  If the original source is no longer available, the UI explains that rather than selecting a misleading replacement silently.

Keep provider, quota window, observation time, measured rate, and available comparison together.  Native buttons, keyboard focus, VoiceOver descriptions, explicit units, and text states accompany color and chart marks.

## Surface Names

The attached menu-bar popover is the Docked Bar.  Floating Window describes a detached persistent version of that surface only if that behavior is implemented.  It does not rename the macOS Dock or the separate platform/settings window.

## Validation

Navigation migration, alert identity routing, legacy history decoding, finite quota values, duplicate timestamps, reset/gap segmentation, and sparse or flat comparison history need behavioral tests.  Native Mac visual claims require appropriate review or captured evidence; iOS screenshots remain required for iOS UI changes.

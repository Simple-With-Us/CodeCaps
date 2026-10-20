# Alert Parity And APNs

CodeCaps now has independent choices for usage anomalies, runaway usage, vendor quota resets, scheduled quota resets, and actual quota exhaustion.  Mac preferences select notification, popup, and sound separately for each category.  Companion preferences select notifications and sound independently of Mac delivery choices.  Existing forecast warnings and provider reset bells remain available.

The Mac computes anomaly decisions using its measured history and can relay all five categories to Usage Monitor.  The companion continues to detect resets and exhaustion from fresh quota readings, while remote push can deliver Mac decisions when the companion is closed.  Category choices are personal preferences; no new runtime Infisical settings are fetched by either native app.

## Remote Push Setup

1. Deploy the matching Usage Monitor CodeCaps push endpoints and database migration from `codex/codecaps-push`.  Its server needs its existing APNs provider key and the separate `CODECAPS_PUSH_REGISTRATION_TOKEN` through Infisical.
2. Enable Push Notifications for `com.simplewithus.codecaps.ios` and create the production profile with `node scripts/ios-enable-apns.mjs`.  The helper uses existing ASC credentials, preserves old profiles, verifies production push plus the App Group, and reuses a valid replacement profile.  The existing iOS ship workflow invokes it before installing profiles.
3. Enable quota push on the Mac, then enable Send Alerts To iPhone under Notifications & Alarms.  The existing Push Token authenticates alert signals separately from quota telemetry.
4. On iPhone, configure the quota endpoint, save the server's separate push registration credential in Remote Push, enable remote push, and choose each desired category.  The credential and device token remain in the device Keychain.  The read token never grants enrollment authority.

Development builds register with sandbox APNs; TestFlight and App Store builds register with production.  Push registration uses HTTPS without redirects.  Disabling push unregisters with Apple and removes server enrollment; failed server removal remains visible and retryable.  Ordered enrollment requests prevent a late registration from reversing a later opt-out.

## Verification And Limits

- Local checks: Node provisioning and release-workflow tests; Git whitespace validation.
- Added Swift tests cover preference migration, persistence, delivery gating, occurrence identity, endpoint safety, and exhaustion recovery.
- This Linux host has no Swift, Xcode, or Simulator.  Native build, Swift test execution, and screenshots require the existing hosted Swift CI workflow.
- The local ASC client could not resolve `ASC_KEY_ID` and `ASC_ISSUER_ID`.  Live Apple capability/profile registration was not performed here.  The script is prepared for the already configured CI signing environment.
- The local board and Zulip CLIs have no CODEX credentials.  The hosted coordination connector offers only JET; no JET identity was borrowed.  `docs/EFFORT-LOG.md` is explicitly archived and was preserved.
- End-to-end APNs delivery requires a signed physical-device install, server deployment/configuration, and an enrolled device.  A successful local registration callback alone is insufficient evidence of delivery.

## Parity Boundaries

The iOS companion displays shared quota readings, platform order, provider/window drill-down, reset information, and the same five alert categories.  Local provider credential readers, the menu bar, Mac popup windows, and Mac burn-rate history remain Mac capabilities.  iOS notification banner style and system sound permission remain controlled by iOS Settings.

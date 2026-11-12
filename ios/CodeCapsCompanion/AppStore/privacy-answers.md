# App Privacy answers

Use these answers only after confirming that the submitted binary still
matches this repository.  Re-evaluate before every App Store or TestFlight
upload if `SentryTelemetry.swift` or `PrivacyInfo.xcprivacy` changes what
is captured.

- Tracking: **No**
- Data used for third-party advertising, developer advertising, or marketing:
  **None**
- Third-party advertising or analytics SDKs: **None** for advertising or
  product analytics.  The companion links the **Sentry** crash-reporting SDK
  (`sentry-cocoa`, see `App/SentryTelemetry.swift`).  It is inactive unless
  the build was cut with a `SENTRY_DSN`.  The TestFlight workflow resolves
  one from Infisical prod (GitHub Actions secret `SENTRY_DSN` as a fallback)
  before archiving, and ships the app with Sentry inert rather than failing
  the build when neither resolves.
- Data used for **App Functionality** (diagnostics, not linked to the user):
  - Diagnostics: **Crash Data**, **Performance Data** (app hangs longer than
    two seconds, a 20% sample of traces, a 10% sample of continuous
    profiles, and failed HTTP 5xx requests with their URL), and **Other
    Diagnostic Data** (device model, OS version, app version, an anonymous
    installation identifier).
  - Sentry is configured with `sendDefaultPii = false`.  On iOS,
    `attachScreenshot = false` and `attachViewHierarchy = false`, so a
    crash report carries no screenshot and no view-hierarchy dump.  Query
    parameters named `token`, `key`, `secret`, `auth`, or `password` are
    redacted on the device before an event is sent.  Read tokens, quota
    payloads, and provider credentials are never attached to an event.
  - **Session replay is enabled on iOS only**: `sessionSampleRate = 0.1`
    and `onErrorSampleRate = 0.1`.  It records the app's own user
    interface, with `maskAllText = true` and `maskAllImages = true`, so
    the recording carries the shape of the screen and not the values on
    it.  Declare it in App Store Connect as collected screen content used
    for App Functionality, not as tracking.
- Data linked to the user: **None** from Sentry.  Quota windows the
  companion already displays stay on-device / in the owner's Usage Monitor
  account and are not sent to Sentry.
- Privacy policy URL: use the existing CodeCaps listing URL.

`PrivacyInfo.xcprivacy` declares Crash Data, Performance Data, and Other
Diagnostic Data.  Session replay is iOS-only and masked; confirm Apple's
current App Store Connect category for a text-masked recording of the
app's own screens before the next upload, and add that type to the
manifest if review requires it.

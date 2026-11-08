# CC-205: Monitoring And Alert Controls

CodeCaps previously announced a new MiniMax quota week when an early reset timestamp changed, even if the remaining quota fell or a producer reused its window ID for another cadence.  The tracker now rebaselines a known cadence change and requires a quota rise before interpreting a pre-end timestamp jump as a reset.  Scheduled rollovers and demonstrated quota restores retain their existing alert rules.

## Quit Behavior

A user quit offers Close Window And Keep Running, Quit CodeCaps, and Cancel.  The first choice hides the app windows, preserves quota checks, and provides menu-bar access even in Dock-only mode.  Confirmed Quit retains the snapshot-write drain.  Explicit system shutdown/restart/logout and an active Sparkle installation bypass the prompt.

## Providers And Plugins

Kimi and Z.ai / ZCode use their existing readers and local sign-ins.  Sources & Fleet now offers separate quota-check switches.  Disabling one skips reader construction and credential/network access, removes its cached local rows, and invalidates an in-flight refresh.

New providers can implement LocalQuotaReading and register a stable ID, label, configuration metadata, and factory in LocalQuotaReaderRegistry.  Personal enable choices remain on the device.  This typed extension point does not execute downloaded code.

The Muse monitor preserves Rob/MA's original 95fc887 -> 5c2d697 -> f83d825 stack, supplied as a Git bundle after its VM worktree was identified.  It provides a Plugins section with deterministic Mac-local session monitoring.  A first-seen standard-model session alerts once; a sustained standard session stays silent; a return to contributor mode rearms the next standard transition.  Missing model IDs are ignored.  Codable state in UserDefaults survives relaunch.  The 90-minute, 4-million-token burn rule requires a currently observed standard session; contributor share is display-only.  The standard-session popup starts off and uses the same per-kind preference as Alerts & Alarms.

Mac-local Muse stores do not reveal sessions running exclusively in another seat's cloud VM.

## SMS Delivery

Alerts & Alarms offers an independent SMS method for Muse Standard Sessions, Muse Token Burn, and Quota Exhaustion.  SMS starts off for every kind.  The category itself must also be enabled.  SMS remains available when local notification and popup methods are off.

Save a Twilio account SID, API key SID/secret, Messaging Service SID, and E.164 recipient.  The credential record is kept in a separate build-scoped Keychain item; personal display configuration and alert choices remain in UserDefaults.  Saving setup sends no message.  Blank API secrets preserve a matching saved key; changing account/key requires the new secret.  Re-Authorize Saved Setup is the explicit interactive Keychain action.

Only newly detected events enter SMS delivery.  A persistent hashed reservation is saved before submission, including uncertain outcomes, to avoid duplicate paid messages after relaunch.  The client uses a fixed Twilio HTTPS endpoint, rejects redirects, and does not retry automatically.  An accepted submission is reported as accepted, without claiming handset delivery.  No live SMS was sent during development or automated testing.

## Verification

Run swift build and swift test on macOS.  Tests cover reset corrections and scheduled rollovers, quit choices, disabled-reader non-invocation, Muse transition persistence and burn gating, SMS routing with local methods off, Keychain isolation, and durable deduplication.  Tests use private defaults, fake credentials, and injected transports.  No iOS simulator is used.

## Provider Authentication And Optional Infisical

Kimi config fallback selects only an explicit Kimi coding provider with an approved coding URL.  The reader preserves long OAuth and JSON API keys, accepts finite numeric-string counters, and stops fallback after cancellation.

Z.ai / BigModel quota checks use an explicitly saved coding-plan API key, with a region-paired endpoint and separate build-scoped Keychain record.  CodeCaps does not send ZCode OAuth tokens to the coding-plan quota API or create account API credentials.

Infisical remains optional.  Its setup stores multiple labeled Keychain bindings by project, environment, folder, authentication method, and intended read or write use.  Service tokens are sent intact as Bearer credentials; app-local machine identities remain an explicit option.  A write binding must be selected independently and match the active read scope.  Existing single-identity records migrate in memory to read-only bindings.

Release automation uses one scoped read service token for Fleet-OPS prod / and /asc, with no Universal Auth fallback.  Replacement token binding and workflow publication must be verified before release.

Native validation before the companion follow-up: swift build passed; swift test executed 1,563 tests with 10 skipped and zero failures.  The automation contract suite passed 79 tests.

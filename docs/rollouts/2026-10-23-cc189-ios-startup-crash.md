# CC-189: iOS Startup Crash In Alert Persistence

The shared TestFlight report for CodeCaps 1.0.270 (270) shows a foreground
SIGABRT about half a second after launch, on October 23 at 1:04 PM.  The
symbolicated exception stack points to `CompanionQuotaModel.announcedAlertIds.setter`
from `deliverAlert`.  App Store Connect feedback ID:
`ANy7nFjhz0Fnjj4YYxcP9-4`.

The setter passed an `ArraySlice<String>` directly to `UserDefaults.set`.
Preferences require property-list values; materializing the bounded suffix
as `[String]` prevents the Objective-C exception.  The existing preference
key and 200-ID retention limit are preserved, so an update can use saved
preferences without clearing settings.

`CompanionAlertPersistenceTests` extracts the actual companion property and
executes it in a child Swift process against an isolated preferences suite.
It checks first insertion, duplicate insertion, overflow retention, reading
the history through a new instance, and clearing the history.  A preferences
exception fails the child process without killing the package test runner.
The companion model is outside the Mac package target, so this executes its
persistence code without copying the implementation into a test double.

Local validation: `git diff --check`.  Swift and Xcode are unavailable on
this Linux host; package tests and iOS compile/launch validation run through
the existing GitHub-hosted macOS checks.  Merge triggers the established iOS
TestFlight ship workflow.  Upload, processing and tester availability must
be checked separately before reporting the replacement build available.

Linear CC-189 is the work record.  GitHub issues are disabled for this
repository, and `docs/EFFORT-LOG.md` is archived read-only history.

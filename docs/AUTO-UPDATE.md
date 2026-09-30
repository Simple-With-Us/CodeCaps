# Auto-Update (Sparkle 2)

Owner ruling, Tue, Sep 29, 2026: every fleet Mac app updates itself seamlessly, through Sparkle 2, from signed releases that CI publishes on each merge to `main`.  CodeCaps is the pilot, and this document is the pattern the other Mac apps copy.

## What Happens

1. A PR merges to `main` and changes the app (`Sources/`, `Package.*`, `VERSION`, the icon, or the build scripts).
2. `.github/workflows/mac-release.yml` builds a universal Release bundle, signs it with the Developer ID Application certificate (hardened runtime, secure timestamp, nested code signed inside-out), notarizes and staples the app and the DMG, and writes an appcast whose one item is the new ZIP, signed with the app's EdDSA key.
3. The workflow publishes a GitHub release tagged `v<VERSION>-build.<N>`, marked latest, carrying `CodeCaps.zip`, `CodeCaps.dmg`, their `.sha256` files, and `appcast.xml`, then confirms the live feed names build N.
4. Every installed copy checks `https://github.com/jaywedgeworth22/CodeCaps/releases/latest/download/appcast.xml` once an hour, downloads the new ZIP in the background, verifies its EdDSA signature before unpacking it, and checks that it is signed by the same Developer ID team.
5. As soon as CodeCaps is not the frontmost app (for a menu-bar app, nearly always), `AppUpdater` installs the update and relaunches.  The relaunch stays in the background: the Console window is not reopened and focus is not taken.  If the owner is using CodeCaps at that moment, the install waits until they switch away.

Settings ▸ About shows "Automatic updates: On" and a **Check For Updates…** button.  The same command is in the app menu and the menu-bar item's right-click menu.

## The Pieces

| Piece | Role |
|---|---|
| `Package.swift` | Sparkle 2 (`https://github.com/sparkle-project/Sparkle`, from 2.10.0) as a dependency of the `CodeCaps` executable target. |
| `Sources/CodeCaps/AutoUpdate.swift` | `AutoUpdateAvailability` (should this build run Sparkle at all), `UpdateRelaunchMarker` (keep the post-update relaunch in the background), `AppUpdater` (owns `SPUStandardUpdaterController`, installs as soon as the app is idle). |
| `Sources/CodeCaps/AppDelegate.swift` | Starts the updater first thing at launch, adds **Check For Updates…** to both menus. |
| `Tests/CodeCapsTests/AutoUpdateTests.swift` | The availability gate and the relaunch marker. |
| `script/build_and_run.sh` | Embeds `Sparkle.framework` in `Contents/Frameworks`, adds the `@executable_path/../Frameworks` rpath, signs inside-out, runs `codesign --verify --deep --strict`, writes the Sparkle Info.plist keys, notarizes with an App Store Connect API key when `NOTARY_KEY_*` are set, and runs `spctl --assess` on the stapled app and DMG. |
| `script/make_appcast.sh` | Runs Sparkle's `generate_appcast` over one archive and checks the result: one item, EdDSA-signed, pointing at the right URL. |
| `.github/workflows/mac-release.yml` | The release job.  Also builds and verifies (never publishes) on PRs that touch the bundle. |
| `.github/actions/infisical-secrets`, `scripts/infisical-fetch.mjs` | Copied from BotFleet: reads the signing certificate from Infisical with a repository-secret fallback. |

## Info.plist Keys

`build_and_run.sh` writes these only into a build whose bundle identifier is the release one (`com.jays.agent-bar.mac`), or when `CODECAPS_SPARKLE_FEED_URL` is set explicitly:

| Key | Value | Why |
|---|---|---|
| `SUFeedURL` | `https://github.com/jaywedgeworth22/CodeCaps/releases/latest/download/appcast.xml` | Always the newest release's appcast. |
| `SUPublicEDKey` | `Ou2J0syHZawPSY3JLTLVyhbOylmtyr0QnZPbq7acETQ=` | Verifies each archive.  Public, committed in the build script. |
| `SUEnableAutomaticChecks` | true | No "check automatically?" prompt. |
| `SUAutomaticallyUpdate` | true | Download and install without asking. |
| `SUAllowsAutomaticUpdates` | true | |
| `SUScheduledCheckInterval` | 3600 | Hourly, which is Sparkle's minimum. |
| `SUVerifyUpdateBeforeExtraction` | true | The EdDSA check happens before the archive is unpacked. |

A `--dev` build (identifier `com.jays.agent-bar.mac.dev`) gets none of them, so a development copy never replaces itself with the release build, and `AutoUpdateAvailability` keeps Sparkle off instead of letting it raise its "updater failed to start" alert.  `CODECAPS_SPARKLE_FEED_URL=` (set but empty) turns updates off for any build.

## Versions

`CFBundleVersion` is `git rev-list --count HEAD`, so every squash merge to `main` raises it by one, and Sparkle compares that number.  CI checks out with `fetch-depth: 0`; a shallow clone would make every build number 1.  `CFBundleShortVersionString` is the `VERSION` file and stays human.  A local build from a feature branch can carry a higher count than `main`; that copy simply waits until `main` passes it.

## Keys

The EdDSA key pair is per app, so one app's key cannot sign another app's updates.

- Generated with Sparkle's `generate_keys --account codecaps`, which put the private key in the owner's login Keychain (service `https://sparkle-project.org`, account `codecaps`).
- Exported value-blind with `generate_keys --account codecaps -x ~/.secrets/codecaps-sparkle-ed25519.key` and `chmod 600`.  That file is the backup.
- Stored as the repository secret `SPARKLE_ED_PRIVATE_KEY` by piping the file into `gh secret set`.  It reaches `generate_appcast` on standard input, never as an argument.
- The public key is `Ou2J0syHZawPSY3JLTLVyhbOylmtyr0QnZPbq7acETQ=`, in `script/build_and_run.sh`.

If the private key is lost, installed copies can no longer be updated by Sparkle; they need one manual install of a build carrying a new public key.  If it leaks, rotate: generate a new pair, ship one release signed with the **old** key that carries the **new** public key, then switch the secret.

## Hosting

The repository is public, so GitHub Releases are downloadable anonymously, which Sparkle needs.  That is the simplest host that works: no extra service, no extra credential, and the release history doubles as the rollback list.  `releases/latest/download/<asset>` redirects to the latest release's asset, and Sparkle follows the redirect.  The landing page's `releases/latest/download/CodeCaps.dmg` link now always serves the newest notarized build too.

A private repository cannot do this, because anonymous clients cannot download its release assets.  An app in a private repository hosts `appcast.xml` and its archives on Cloudflare R2 or Pages instead (see `Fleet-OPS/docs/DOMAINS-AND-ROUTING.md`), and the rest of this pattern is unchanged.

## Secrets

| Name | Where | Status on Tue, Sep 29, 2026 |
|---|---|---|
| `MAC_CERT_P12_BASE64`, `MAC_CERT_PASSWORD` | Infisical (the way BotFleet's `release.yml` reads them), needing `INFISICAL_PROJECT_ID` and `INFISICAL_UNIVERSAL_AUTH_CLIENT_ID`/`_SECRET` (or `INFISICAL_CLIENT_ID`/`_SECRET`) repository secrets; or same-named repository secrets as the fallback | Missing.  Publishing is gated until they exist. |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` | Repository secrets, shared with `ios-ship.yml` | Present. |
| `SPARKLE_ED_PRIVATE_KEY` | Repository secret | Present. |

While any of them is missing, the release job still builds the bundle and verifies its signature ad hoc, then finishes green with a notice naming what is missing.  Nothing is published.

## Signing, Inside-Out

Sparkle ships helpers inside its framework, and each one is signed before the thing that contains it, in the order Sparkle's code-signing guide gives:

1. `Sparkle.framework/Versions/B/XPCServices/Installer.xpc` and `Downloader.xpc` (entitlements preserved)
2. `Sparkle.framework/Versions/B/Updater.app`
3. `Sparkle.framework/Versions/B/Autoupdate`
4. `Sparkle.framework`
5. the SwiftPM resource bundle (sealed as a resource), then the app

Release builds add `--options runtime --timestamp` to every step.  No `--deep` on the signing path; `codesign --verify --deep --strict` afterwards is the check, and a bundle that fails it is never installed or packaged.  CodeCaps is not sandboxed, so Sparkle's XPC services are unused, but they are signed rather than stripped so the recipe also holds for a sandboxed app.

## Rehearse An Update Locally

This proves the whole loop on one Mac without touching the installed copy.  Use a scratch bundle identifier and a feed on `127.0.0.1` (plain HTTP is allowed only for a loopback feed, and only such a build gets `NSAllowsLocalNetworking`).  Pick a port nothing else listens on (`lsof -nP -iTCP:<port> -sTCP:LISTEN`), because build N carries it in its Info.plist.

```bash
export AGENTBAR_BUNDLE_ID=com.jays.codecaps.sparkle-e2e
export CODECAPS_SPARKLE_FEED_URL=http://127.0.0.1:18765/appcast.xml
E2E="$(mktemp -d)"; mkdir -p "$E2E/install" "$E2E/feed"

# Build N and install it to the scratch folder.  --release keeps the staged
# app and also notarizes it (NOTARY_KEY_* or the keychain profile); --build-only
# is the quick alternative (debug, no hardened runtime).
script/build_and_run.sh --release
mv dist/CodeCaps.app "$E2E/install/"

# Build N+1 from one more commit, and serve it.
git commit --allow-empty -m "e2e: build N+1"
script/build_and_run.sh --package
git reset --soft HEAD~1
mv dist/CodeCaps.zip "$E2E/feed/"
script/make_appcast.sh "$E2E/feed/CodeCaps.zip" http://127.0.0.1:18765/ "$E2E/feed"
(cd "$E2E/feed" && python3 -m http.server 18765 --bind 127.0.0.1) &

# Launch N in the background, menu-bar only, with the last check long ago.
defaults write "$AGENTBAR_BUNDLE_ID" displayMode menuBar
defaults write "$AGENTBAR_BUNDLE_ID" SULastCheckTime -date "2020-01-01 00:00:00 +0000"
open -g "$E2E/install/CodeCaps.app"

# Within a minute: the server logs GET /appcast.xml and GET /CodeCaps.zip, the
# app relaunches, and the scratch copy reports N+1.
plutil -extract CFBundleVersion raw "$E2E/install/CodeCaps.app/Contents/Info.plist"
```

Afterwards quit the scratch process by its exact executable path, delete `$E2E`, run `defaults delete com.jays.codecaps.sparkle-e2e`, remove its preferences file, and stop the server.

**Rehearsed Tue, Sep 29, 2026 at 8:01 PM CT.**  Build 66 was built with `--release`: universal, Developer ID with hardened runtime, `codesign --verify --deep --strict` clean, ZIP and DMG both notarized ("Accepted") and stapled, and `spctl` accepted the app and the DMG as "Notarized Developer ID".  Build 67 was served from `127.0.0.1`.  About ten seconds after launch, build 66 fetched the appcast, downloaded the ZIP, installed it and relaunched as build 67 with no window or prompt; the updated bundle still passed `codesign --verify --deep --strict`, carried no quarantine attribute, and the relaunch marker had been consumed.  (Port 8765 turned out to be taken on this Mac, so the rehearsal pointed build 66 at port 18765 through Sparkle's `SUFeedURL` user-defaults override instead of rebuilding; the recipe above uses 18765 from the start.)

## Roll Back A Bad Release

Sparkle never downgrades, so a rollback is a fix forward:

1. **Stop the spread (seconds).**  `gh release edit <last-good-tag> --latest -R jaywedgeworth22/CodeCaps`.  The feed now names the good build, so copies that have not updated yet stay where they are.  Copies already on the bad build are not moved back by this.
2. **Fix forward (one merge).**  Revert the bad PR on `main`.  CI publishes build N+1 containing the old code with a higher build number, and every copy, including the ones on the bad build, updates to it within the hour.
3. **If the bad build cannot update itself** (for example it crashes before `AppUpdater.start()` runs), those copies need a manual install of the fixed DMG from the Releases page.  `AppUpdater.shared.start()` is the first thing `applicationDidFinishLaunching` does for exactly this reason.

To pause releases entirely, disable the workflow (`gh workflow disable mac-release.yml -R jaywedgeworth22/CodeCaps`).

## Copy This To Another Swift Mac App

1. **Package.**  Add `.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")` and `.product(name: "Sparkle", package: "Sparkle")` on the executable target.  Commit `Package.resolved`.
2. **App code.**  Copy `Sources/CodeCaps/AutoUpdate.swift` and `Tests/CodeCapsTests/AutoUpdateTests.swift`, renaming the `CodeCaps` prefixes.  Call `AppUpdater.shared.start()` first in `applicationDidFinishLaunching`, consume `UpdateRelaunchMarker` before opening any window, add a **Check For Updates…** menu item that calls `AppUpdater.shared.checkForUpdates()`, and validate it with `canCheckForUpdates`.  For an Xcode-project app, the same file works; `SPUStandardUpdaterController` can also be instantiated in a nib.
3. **Bundle script.**  Port from `script/build_and_run.sh`: `embed_frameworks`, `framework_helper_paths` and the signing loop in `sign_with_identity`, `verify_app_signature`, `sparkle_feed_url`, `sparkle_plist_entries` (and the `$(sparkle_plist_entries)` line in the Info.plist heredoc), and the `NOTARY_AUTH` block.  Make `CFBundleVersion` monotonic (`git rev-list --count HEAD`).  An Xcode-built app gets the embedding and rpath from Xcode's "Embed Frameworks" phase instead, but still needs the inside-out re-sign if it re-signs after the build.
4. **Keys.**  `swift package resolve`, then `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account <app>`; export with `-x ~/.secrets/<app>-sparkle-ed25519.key` and `chmod 600`; put the public key (`generate_keys --account <app> -p`) in the build script; `gh secret set SPARKLE_ED_PRIVATE_KEY -R <repo> < ~/.secrets/<app>-sparkle-ed25519.key`.  Never print the private key.
5. **Hosting.**  Public repository: GitHub Releases, feed `https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml`.  Private repository: Cloudflare R2 or Pages.
6. **CI.**  Copy `.github/workflows/mac-release.yml`, `.github/actions/infisical-secrets/`, `scripts/infisical-fetch.mjs`, and `script/make_appcast.sh`.  Change the app name, the `paths:` filter, the artifact names, and `SPARKLE_APP_LINK`.  Make sure the signing certificate, the notarization key and the Sparkle key are reachable (see Secrets).
7. **Rehearse.**  Run the local rehearsal above with a scratch bundle identifier.
8. **First install.**  Copies built before Sparkle cannot update themselves.  Install one Sparkle-enabled build by hand (the DMG from the first CI release, or `script/build_and_run.sh`); every release after that arrives on its own.

## Known Limits

- Copies installed before this change (CodeCaps 1.1.0 and earlier) have no Sparkle, so they need one manual install of a release built after it.
- The Homebrew cask (`jaywedgeworth22/tap/codecaps`) still pins the `v1.1.0` DMG and keeps working.  Pointing it at the per-build releases and adding `auto_updates true` is a follow-up in the tap repository.
- Pure documentation or iOS changes do not publish a Mac release, because the workflow's `paths:` filter skips them; the next app change carries them along.

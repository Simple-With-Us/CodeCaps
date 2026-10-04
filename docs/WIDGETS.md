# Native Widgets

CodeCaps widgets display real quota readings from the app's shared cache.  They do not generate sample readings outside the system widget preview.

## Data Flow

On macOS, the running CodeCaps host writes a dedicated widget snapshot to the Mac App Group container.  The snapshot includes merged local and pulled quota windows, plus custom marks.  It is separate from the local BotFleet handoff at `~/Library/Application Support/Usage Monitor/quota-windows.json`, which remains local-reader data.  The host asks WidgetKit to reload timelines after a successful shared-cache write.

The macOS widget reads that shared snapshot and makes no network request.  It can update only after the host has refreshed and published new data and WidgetKit runs the extension.  It retains the observation timestamp from the quota windows rather than treating snapshot serialization time as a fresh reading.

On iOS, the companion app writes readings to its App Group cache when it refreshes.  When WidgetKit requests a timeline, the widget makes a bounded HTTPS pull only if the companion has a configured endpoint.  With no endpoint, it makes no request.  The widget uses the existing companion sync token from shared preferences; it does not copy the token elsewhere.  A failed request leaves the dated cache in place, while a valid empty snapshot clears old readings.  WidgetKit controls when timeline requests run, so a pull is not guaranteed at a particular time or frequency.

System widget previews use placeholder rows supplied to WidgetKit.  Those placeholders are preview-only and are not presented as live quota readings.

## App Groups And Signing

The iOS app and its WidgetKit extension use the provisioned group `group.com.simplewithus.codecaps`.  The existing App Store profiles for `com.simplewithus.codecaps.ios` and `com.simplewithus.codecaps.ios.widgets` must authorize that group.

The macOS companion app and extension use `CC8UTF7ATG.codecaps`, a team-prefixed macOS App Group identifier.  XcodeGen generates their entitlement plists from `ios/CodeCapsCompanion/project.yml` under `ios/CodeCapsCompanion/Generated/`; regenerate the project with `cd ios/CodeCapsCompanion && xcodegen generate` after changing the specification.  The standalone CodeCaps host remains unsandboxed so it can read existing local provider files.  The release script derives host entitlements from the generated widget entitlements, removes the sandbox entitlement for that host, then explicitly signs and checks both the host and embedded extension.  Missing extension packaging or required team signing fails the release path.

The iOS and macOS identifiers are distinct containers.  They do not share files across platforms; cross-device readings use the configured sync service.

## Verification

For a team-signed Mac build, run the release script's build-only mode, then verify the host and embedded extension:

```sh
./script/build_and_run.sh --build-only
APP=dist/CodeCaps.app
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements :- "$APP" > /tmp/codecaps-host-entitlements.plist
codesign -d --entitlements :- "$APP/Contents/PlugIns/CodeCapsWidgets.appex" > /tmp/codecaps-widget-entitlements.plist
/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' /tmp/codecaps-host-entitlements.plist
/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' /tmp/codecaps-widget-entitlements.plist
codesign -dv --verbose=4 "$APP" 2>&1 | sed -n 's/^TeamIdentifier=/TeamIdentifier=/p'
```

Both group checks should print `CC8UTF7ATG.codecaps`, and the team identifier should be `CC8UTF7ATG`.  The build-only ad-hoc structural validation path (`CODECAPS_ALLOW_ADHOC_VALIDATION=1`) checks bundle structure and entitlement declarations but explicitly does not verify runtime App Group access.  A valid team signature and successful group-container read/write are required before claiming runtime verification.

For an iOS archive at `$IOS_APP`, inspect both signed bundles and confirm each declares `group.com.simplewithus.codecaps`:

```sh
codesign -d --entitlements :- "$IOS_APP" > /tmp/codecaps-ios-entitlements.plist
codesign -d --entitlements :- "$IOS_APP/PlugIns/CodeCapsWidgets.appex" > /tmp/codecaps-ios-widget-entitlements.plist
/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' /tmp/codecaps-ios-entitlements.plist
/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' /tmp/codecaps-ios-widget-entitlements.plist
```

These commands verify signed entitlement declarations.  They do not by themselves prove that a device can access the container or that WidgetKit has refreshed a timeline.

For setup and sync configuration, see the [Setup & Data Guide](https://codecaps.simplewithus.com/setup.html).  Apple references: [App Groups entitlement](https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.security.application-groups), [Accessing App Group containers](https://developer.apple.com/documentation/xcode/accessing-app-group-containers), and [App Group access for sandboxed and notarized apps](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox).

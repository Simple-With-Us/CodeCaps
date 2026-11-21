#!/usr/bin/env bash
# Native widget fixtures without a live account, network pull, or app launch.
set -euo pipefail
cd "$(dirname "$0")/.."
out="${CODECAPS_WIDGET_RENDER_DIR:-$(mktemp -d -t codecaps-widget-ui)}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
files=(ios/CodeCapsCompanion/Widgets/*.swift)
sources=()
for file in "${files[@]}"; do
  [[ "$file" == */CodeCapsWidgetBundle.swift ]] || sources+=("$file")
done
for name in AppGroupSnapshotReadPolicy ResetAlarmCadence QuotaWindowVocabulary QuotaWindowCaption QuotaWindowPairing QuotaMeterCadence FleetSourceDisagreement WidgetPlatformDisplay PlanMetadata WidgetSnapshotFetcher CompanionReadTokenStore; do
  sources+=("Sources/QuotaCore/$name.swift")
done
# Compile the actual companion model and views without constructing the stateful model.
sources+=("ios/CodeCapsCompanion/App/Models/CompanionQuotaModel.swift"
         "ios/CodeCapsCompanion/App/Models/CompanionTheme.swift"
         "ios/CodeCapsCompanion/App/Models/AlarmSoundPlayer.swift"
         "ios/CodeCapsCompanion/App/Models/SentenceGap.swift"
         "ios/CodeCapsCompanion/App/Views/CompanionContentView.swift"
         "Sources/QuotaCore/UsageAlertPreferences.swift" "Sources/QuotaCore/ResetAlarmSound.swift"
         "Sources/QuotaCore/ResetAlarmTracker.swift" "Sources/QuotaCore/ResetAlarmMessage.swift")
# A real resource bundle lets SwiftUI load both vector and raster provider marks.
bundle="$out/CodeCapsUIProbe.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.simplewithus.codecaps.ui-probe</string>
<key>CFBundleExecutable</key><string>CodeCapsUIProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
xcrun actool ios/CodeCapsCompanion/Assets.xcassets --compile "$bundle/Contents/Resources" \
  --platform macosx --minimum-deployment-target 14.0 --output-format human-readable-text \
  > "$out/assets.log" 2>&1
swiftc -parse-as-library "${sources[@]}" Tests/Fixtures/WidgetUIProbe.swift -o "$bundle/Contents/MacOS/CodeCapsUIProbe"
CODECAPS_WIDGET_RENDER_DIR="$out" "$bundle/Contents/MacOS/CodeCapsUIProbe"
printf 'Native render artifacts: %s\n' "$out"

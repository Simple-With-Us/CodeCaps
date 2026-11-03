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
for name in ResetAlarmCadence QuotaWindowVocabulary QuotaWindowCaption FleetSourceDisagreement WidgetPlatformDisplay PlanMetadata WidgetSnapshotFetcher CompanionReadTokenStore; do
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
swiftc -parse-as-library "${sources[@]}" Tests/Fixtures/WidgetUIProbe.swift -o "$out/probe"
CODECAPS_WIDGET_RENDER_DIR="$out" "$out/probe"
printf 'Native render artifacts: %s\n' "$out"

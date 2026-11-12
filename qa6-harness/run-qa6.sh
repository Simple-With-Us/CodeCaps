#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
out="$(pwd)/qa6-harness/render"
mkdir -p "$out"
files=(ios/CodeCapsCompanion/Widgets/*.swift)
sources=()
for file in "${files[@]}"; do
  [[ "$file" == */CodeCapsWidgetBundle.swift ]] || sources+=("$file")
done
for name in AppGroupSnapshotReadPolicy ResetAlarmCadence QuotaWindowVocabulary QuotaWindowCaption FleetSourceDisagreement WidgetPlatformDisplay PlanMetadata WidgetSnapshotFetcher CompanionReadTokenStore; do
  sources+=("Sources/QuotaCore/$name.swift")
done
swiftc -parse-as-library "${sources[@]}" qa6-harness/QA6CapProbe.swift -o "$out/qa6probe"
CODECAPS_WIDGET_RENDER_DIR="$out" "$out/qa6probe"
printf 'QA6 render artifacts: %s\n' "$out"

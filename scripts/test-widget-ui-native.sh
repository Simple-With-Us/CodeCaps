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
swiftc -parse-as-library "${sources[@]}" Tests/Fixtures/WidgetUIProbe.swift -o "$out/probe"
CODECAPS_WIDGET_RENDER_DIR="$out" "$out/probe"
printf 'Native render artifacts: %s\n' "$out"

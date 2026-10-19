#!/usr/bin/env bash
#
# Capture App Store screenshots for the CodeCaps iOS companion.
#
# Runs on a macOS runner that has an iOS simulator runtime.  Builds the
# companion for one iPhone and one iPad simulator, seeds each simulator with a
# realistic quota snapshot, and writes one PNG per screen at the exact pixel
# size App Store Connect accepts.  The size is asserted before the file is
# handed on, so a mis-sized capture fails here instead of at upload time.
#
# The companion reads its readings from
#   <app container>/Library/Application Support/CodeCaps/quota-windows.json
# (see CompanionQuotaModel.loadLocalFallback), so seeding that file is enough
# to put real-looking quota cards on screen without a live sync endpoint.
#
# Usage: scripts/ios-fleet/capture-appstore-screenshots.sh [OUTPUT_DIR]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT_DIR="$REPO_ROOT/ios/CodeCapsCompanion"
SCHEME="CodeCapsCompanion"
BUNDLE_ID="com.simplewithus.codecaps.ios"
OUT_DIR="${1:-${REPO_ROOT}/.build/appstore-screenshots}"
DERIVED_ROOT="${DERIVED_ROOT:-${RUNNER_TEMP:-/tmp}/codecaps-appstore-derived}"

mkdir -p "$OUT_DIR"

# App Store Connect accepts exactly these display sizes.  The capture asserts
# the produced pixel size against the one paired with the simulator, so a
# simulator that renders at an unexpected size fails loudly instead of
# uploading a screenshot Apple rejects.
#
#   iPhone 6.9"    1320 x 2868   (iPhone 16 Pro Max and friends)
#   iPhone 6.7"    1290 x 2796   (iPhone 16 Plus and friends)
#   iPad    13"    2064 x 2752   (iPad Pro 13-inch, M4)
#   iPad    12.9"  2048 x 2732   (iPad Pro 12.9-inch, 6th generation)
IPHONE_PREFERRED="iPhone 16 Pro Max|iPhone 15 Pro Max|iPhone 14 Pro Max|iPhone 16 Plus|iPhone 15 Plus|iPhone 14 Plus"
IPAD_PREFERRED="iPad Pro 13-inch (M4)|iPad Pro 13-inch (M5)|iPad Pro 12.9-inch (6th generation)|iPad Pro 12.9-inch (5th generation)"

log() { echo "capture: $*"; }
fail() { echo "::error::capture: $*" >&2; exit 1; }

# Print the UDID of the first available simulator whose display name matches
# one of the pipe-separated preferred names, in order.
pick_simulator() {
  python3 - "$1" <<'PY'
import json, subprocess, sys

preferred = sys.argv[1].split("|")
raw = subprocess.run(
    ["xcrun", "simctl", "list", "devices", "available", "-j"],
    capture_output=True, text=True, check=True,
).stdout
data = json.loads(raw)
devices = [
    d
    for group in data.get("devices", {}).values()
    for d in group
    if d.get("isAvailable")
]
for want in preferred:
    for device in devices:
        if device.get("name") == want:
            print(device["udid"])
            sys.exit(0)
sys.exit(1)
PY
}

# Write a realistic quota snapshot into the simulator's app container.
seed_snapshot() {
  local container="$1"
  python3 - "$container" <<'PY'
import datetime, json, os, sys

container = sys.argv[1]
target = os.path.join(container, "Library", "Application Support", "CodeCaps", "quota-windows.json")
os.makedirs(os.path.dirname(target), exist_ok=True)

now = datetime.datetime.now(datetime.timezone.utc)
observed = now.isoformat(timespec="seconds").replace("+00:00", "Z")


def reset_in(hours, minutes=0):
    when = now + datetime.timedelta(hours=hours, minutes=minutes)
    return when.isoformat(timespec="seconds").replace("+00:00", "Z")


# (id, provider, providerKey, providerLabel, label, window token, percent, reset offset)
providers = [
    ("anthropic-5h", "anthropic", "anthropic", "Claude Code", "5-hour window", "5h", 72.0, (3, 40)),
    ("anthropic-7d", "anthropic", "anthropic", "Claude Code", "7-day window", "7d", 44.0, (86, 0)),
    ("openai-weekly", "openai", "openai", "Codex", "7-day window", "7d", 61.0, (41, 15)),
    ("cursor-fast", "cursor", "cursor", "Cursor", "Fast Requests window", "fast", 28.0, (1, 12)),
    ("cursor-total", "cursor", "cursor", "Cursor", "Total Requests window", "total", 83.0, (13, 5)),
    ("xai-monthly", "xai", "xai", "xAI", "1-month window", "1m", 55.0, (212, 0)),
    ("minimax-5h", "minimax", "minimax", "minimax", "5-hour window", "5h", 38.0, (2, 20)),
    ("antigravity-daily", "google-antigravity", "google-antigravity", "Antigravity", "1-day window", "1d", 91.0, (9, 45)),
]

windows = []
for (wid, provider, key, _label, label, token, percent, (hours, minutes)) in providers:
    windows.append({
        "id": wid,
        "provider": provider,
        "providerKey": key,
        "label": label,
        "window": token,
        "remainingPercent": percent,
        "isExhausted": False,
        "resetAt": reset_in(hours, minutes),
        "occurredAt": observed,
        "source": "studio-mac",
        "via": "oauth",
    })

groups = []
for index, (_wid, provider, key, provider_label, _label, _token, _percent, _offset) in enumerate(providers):
    if any(group["provider"] == provider for group in groups):
        continue
    groups.append({
        "provider": provider,
        "providerKey": key,
        "providerLabel": provider_label,
        "via": "oauth",
        "sortOrder": index,
    })

with open(target, "w", encoding="utf-8") as snapshot:
    json.dump({"windows": windows, "providerGroups": groups}, snapshot, indent=2)
print(f"seeded {len(windows)} windows across {len(groups)} platforms -> {target}")
PY
}

# Assert the PNG is exactly the pixel size App Store Connect accepts for the
# paired display size, and that it carries no alpha channel (Apple rejects
# screenshots with transparency).
assert_screenshot() {
  local file="$1" want_w="$2" want_h="$3"
  local width height alpha
  width="$(sips -g pixelWidth "$file" | awk '/pixelWidth/ {print $2}')"
  height="$(sips -g pixelHeight "$file" | awk '/pixelHeight/ {print $2}')"
  alpha="$(sips -g hasAlpha "$file" | awk '/hasAlpha/ {print $2}')"
  if [ "$width" != "$want_w" ] || [ "$height" != "$want_h" ]; then
    fail "$(basename "$file") is ${width}x${height}; App Store Connect wants ${want_w}x${want_h}"
  fi
  if [ "$alpha" = "yes" ]; then
    # Flatten to JPEG, which cannot carry an alpha channel, and use that file.
    local flattened="${file%.png}.jpg"
    sips -s format jpeg -s formatOptions 92 "$file" --out "$flattened" >/dev/null
    rm -f "$file"
    log "flattened $(basename "$flattened") (the PNG carried an alpha channel)"
    echo "$flattened"
    return
  fi
  echo "$file"
}

# Build, install, seed, launch and capture on one simulator.
capture_on() {
  local udid="$1" label="$2" want_w="$3" want_h="$4"
  local derived="$DERIVED_ROOT/$label"
  local app="$derived/Build/Products/Debug-iphonesimulator/CodeCapsCompanion.app"
  local container bundle_id

  log "booting $label ($udid)"
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null

  log "building $label"
  ( cd "$PROJECT_DIR" && xcodebuild -project CodeCapsCompanion.xcodeproj \
      -scheme "$SCHEME" \
      -destination "platform=iOS Simulator,id=$udid" \
      -derivedDataPath "$derived" \
      CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" \
      build >/dev/null )
  [ -d "$app" ] || fail "no app built at $app"

  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
  log "installing $bundle_id"
  xcrun simctl install "$udid" "$app"

  container="$(xcrun simctl get_app_container "$udid" "$bundle_id" data)"
  seed_snapshot "$container"

  # Three screens per device: the quota list, the settings sheet, and the
  # platform-order editor.  The settings sheet and the editor are opened
  # with the launch arguments the app itself understands.
  local shot
  shot="$(xcrun simctl io "$udid" screenshot "$OUT_DIR/$label-fleet-status.png" 2>/dev/null)" || true
  [ -s "$OUT_DIR/$label-fleet-status.png" ] || fail "no screenshot for $label fleet-status"

  xcrun simctl terminate "$udid" "$bundle_id" 2>/dev/null || true
  xcrun simctl launch --terminate-running-process "$udid" "$bundle_id" -openSettings >/dev/null
  sleep 4
  xcrun simctl io "$udid" screenshot "$OUT_DIR/$label-settings.png" >/dev/null 2>&1 || true
  [ -s "$OUT_DIR/$label-settings.png" ] || fail "no screenshot for $label settings"

  xcrun simctl terminate "$udid" "$bundle_id" 2>/dev/null || true
  xcrun simctl launch --terminate-running-process "$udid" "$bundle_id" -reorderPlatforms >/dev/null
  sleep 4
  xcrun simctl io "$udid" screenshot "$OUT_DIR/$label-platform-order.png" >/dev/null 2>&1 || true
  [ -s "$OUT_DIR/$label-platform-order.png" ] || fail "no screenshot for $label platform-order"

  xcrun simctl terminate "$udid" "$bundle_id" 2>/dev/null || true

  local name
  for name in fleet-status settings platform-order; do
    local candidate="$OUT_DIR/$label-$name.png"
    local checked
    checked="$(assert_screenshot "$candidate" "$want_w" "$want_h")"
    if [ "$checked" != "$candidate" ]; then
      mv "$checked" "$OUT_DIR/$label-$name.jpg"
      rm -f "$candidate"
      checked="$OUT_DIR/$label-$name.jpg"
    fi
    log "$label $name -> $(basename "$checked")"
  done
}

main() {
  command -v xcodegen >/dev/null 2>&1 || fail "xcodegen is not installed"
  if [ ! -f "$PROJECT_DIR/CodeCapsCompanion.xcodeproj/project.pbxproj" ] \
     || [ "$PROJECT_DIR/project.yml" -nt "$PROJECT_DIR/CodeCapsCompanion.xcodeproj/project.pbxproj" ]; then
    log "regenerating the companion project"
    ( cd "$PROJECT_DIR" && xcodegen generate )
  fi

  local iphone_udid ipad_udid
  if ! iphone_udid="$(pick_simulator "$IPHONE_PREFERRED")"; then
    fail "no preferred iPhone simulator on this runner"
  fi
  if ! ipad_udid="$(pick_simulator "$IPAD_PREFERRED")"; then
    fail "no preferred iPad simulator on this runner"
  fi

  log "iPhone simulator $iphone_udid"
  log "iPad simulator $ipad_udid"

  capture_on "$iphone_udid" "iphone-6.9" 1320 2868
  capture_on "$ipad_udid" "ipad-13" 2064 2752

  log "captured:"
  ls -1 "$OUT_DIR"
}

main "$@"

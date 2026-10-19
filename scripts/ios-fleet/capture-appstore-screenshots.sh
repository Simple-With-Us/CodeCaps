#!/usr/bin/env bash
#
# Capture App Store screenshots for the CodeCaps iOS companion.
#
# Runs on a macOS runner that has an iOS simulator runtime.  Builds the
# companion for one iPhone and one iPad simulator, seeds each simulator with a
# realistic quota snapshot, and writes one PNG per screen at the exact pixel
# size App Store Connect accepts.
#
# The companion reads its readings from
#   <app container>/Library/Application Support/CodeCaps/quota-windows.json
# (see CompanionQuotaModel.loadLocalFallback), so seeding that file is enough
# to put real-looking quota cards on screen without a live sync endpoint.
#
# The pixel size is measured from the capture rather than assumed, and every
# file has to land on a size App Store Connect accepts for its display class.
# A simulator whose native size Apple does not accept fails the run here
# instead of producing a file that is rejected at upload time.
#
# Usage: scripts/ios-fleet/capture-appstore-screenshots.sh [OUTPUT_DIR]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT_DIR="$REPO_ROOT/ios/CodeCapsCompanion"
SCHEME="CodeCapsCompanion"
OUT_DIR="${1:-${REPO_ROOT}/.build/appstore-screenshots}"
DERIVED_ROOT="${DERIVED_ROOT:-${RUNNER_TEMP:-/tmp}/codecaps-appstore-derived}"

mkdir -p "$OUT_DIR"

# App Store Connect accepts these display sizes:
#
#   iPhone 6.9"    1320 x 2868   (iPhone 16 Pro Max and friends)
#   iPhone 6.7"    1290 x 2796   (iPhone 16 Plus and friends)
#   iPhone 6.5"    1284 x 2778   (iPhone 13 Pro Max and friends)
#   iPhone 6.5"    1242 x 2688   (iPhone 12 Pro Max and friends)
#   iPad    13"    2064 x 2752   (iPad Pro 13-inch)
#   iPad    12.9"  2048 x 2732   (iPad Pro 12.9-inch, 6th generation)
#   iPad    12.9"  2000 x 2664   (iPad Pro 12.9-inch, 2nd generation)
#
# The first entry for each display class is the one the App Store Connect
# screenshot set expects, and the upload step maps a captured file to its set
# from these numbers.
IPHONE_PREFERRED="iPhone 17 Pro Max|iPhone 16 Pro Max|iPhone 15 Pro Max|iPhone 14 Pro Max|iPhone 17 Plus|iPhone 16 Plus|iPhone 15 Plus|iPhone 14 Plus|iPhone 13 Pro Max|iPhone 12 Pro Max"
IPAD_PREFERRED="iPad Pro 13-inch (M5)|iPad Pro 13-inch (M4)|iPad Pro 12.9-inch (6th generation)|iPad Pro 12.9-inch (5th generation)|iPad Pro 12.9-inch (3rd generation)"

# log() writes to stderr on purpose: its output is captured by command
# substitution in assert_screenshot, and anything on stdout would be read
# back as part of the returned file path.
log() { echo "capture: $*" >&2; }
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

# Print "<width>x<height>" for a PNG, or nothing if it cannot be read.
png_size() {
  sips -g pixelWidth -g pixelHeight "$1" 2>/dev/null \
    | awk '/pixelWidth/ {w = $2} /pixelHeight/ {h = $2} END {if (w && h) print w "x" h}'
}

# Print the App Store Connect display class for a pixel size, or nothing.
display_class_for_size() {
  case "$1" in
    1320x2868|1290x2796|1284x2778|1242x2688) echo "iphone" ;;
    2064x2752|2048x2732|2000x2664) echo "ipad" ;;
  esac
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
#
# The window tokens are the ones QuotaWindowVocabulary.cadenceFromToken
# recognises ("5h", "7d", "1d", "1m"), so each card shows a clean cadence
# caption.  Two windows of the same provider must have different cadences:
# a second window of the same cadence is folded in as a duplicate source
# rather than shown as its own row.  Antigravity is left out on purpose, as
# the app pools its windows into per-model sections and it would not read as
# one platform card.
providers = [
    ("anthropic-5h", "anthropic", "anthropic", "Claude Code", "5-hour window", "5h", 72.0, (3, 40)),
    ("anthropic-7d", "anthropic", "anthropic", "Claude Code", "7-day window", "7d", 78.0, (86, 0)),
    ("openai-weekly", "openai", "openai", "Codex", "7-day window", "7d", 61.0, (41, 15)),
    ("cursor-monthly", "cursor", "cursor", "Cursor", "1-month window", "1m", 34.0, (313, 0)),
    ("xai-monthly", "xai", "xai", "xAI", "1-month window", "1m", 55.0, (212, 0)),
    ("minimax-5h", "minimax", "minimax", "MiniMax", "5-hour window", "5h", 38.0, (2, 20)),
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

# Check a captured PNG against the size App Store Connect accepts for its
# display class, and flatten it if it carries an alpha channel, which Apple
# rejects.  The accepted file path is printed on stdout; every log line goes
# to stderr so the caller can capture the path cleanly.
assert_screenshot() {
  local file="$1" want="$2"
  local size alpha flattened
  size="$(png_size "$file")"
  if [ -z "$size" ]; then
    fail "$(basename "$file") could not be read"
  fi
  if [ "$size" != "$want" ]; then
    fail "$(basename "$file") is $size, but the other captures are $want"
  fi
  if [ -z "$(display_class_for_size "$size")" ]; then
    fail "$(basename "$file") is $size, which App Store Connect does not accept for any display class"
  fi
  alpha="$(sips -g hasAlpha "$file" 2>/dev/null | awk '/hasAlpha/ {print $2}')"
  if [ "$alpha" = "yes" ]; then
    # Flatten to JPEG, which cannot carry an alpha channel, and use that file.
    flattened="${file%.png}.jpg"
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
  local udid="$1" label="$2" kind="$3"
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
  # platform-order editor.  The settings sheet and the editor are opened with
  # the launch arguments the app itself understands.  The app is launched
  # before every capture, so no shot is ever the home screen.
  local name
  for name in fleet-status settings platform-order; do
    local args=()
    case "$name" in
      settings) args=(-openSettings) ;;
      platform-order) args=(-reorderPlatforms) ;;
    esac
    xcrun simctl terminate "$udid" "$bundle_id" 2>/dev/null || true
    xcrun simctl launch --terminate-running-process "$udid" "$bundle_id" "${args[@]}" >/dev/null
    sleep 4
    xcrun simctl io "$udid" screenshot "$OUT_DIR/$label-$name.png" >/dev/null 2>&1 || true
    [ -s "$OUT_DIR/$label-$name.png" ] || fail "no screenshot for $label $name"
  done
  xcrun simctl terminate "$udid" "$bundle_id" 2>/dev/null || true

  # The captured size decides the display class and the file name, so the
  # output says what the pixels actually are.
  local size class_name
  size="$(png_size "$OUT_DIR/$label-fleet-status.png")"
  class_name="$(display_class_for_size "$size")"
  [ -n "$class_name" ] || fail "$label rendered at $size, which App Store Connect does not accept"

  local checked
  for name in fleet-status settings platform-order; do
    checked="$(assert_screenshot "$OUT_DIR/$label-$name.png" "$size")"
    if [ "$checked" != "$OUT_DIR/$label-$name.png" ]; then
      mv "$checked" "$OUT_DIR/$class_name-$name.jpg"
      rm -f "$OUT_DIR/$label-$name.png"
    else
      mv "$checked" "$OUT_DIR/$class_name-$name.png"
    fi
    log "$class_name $name ($size)"
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

  capture_on "$iphone_udid" "iphone" "iphone"
  capture_on "$ipad_udid" "ipad" "ipad"

  log "captured:"
  ls -1 "$OUT_DIR"
}

main "$@"

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
# The app needs several seconds to draw its first frame on a cold simulator,
# so the script polls the screen and keeps the first frame that holds more
# than the status bar.  A fixed sleep captured a blank window, and a blank
# window is a screenshot of nothing at all.
#
# Usage: scripts/ios-fleet/capture-appstore-screenshots.sh [OUTPUT_DIR]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$REPO_ROOT/ios/CodeCapsCompanion"
SCHEME="CodeCapsCompanion"
OUT_DIR="${1:-${REPO_ROOT}/.build/appstore-screenshots}"
DERIVED_ROOT="${DERIVED_ROOT:-${RUNNER_TEMP:-/tmp}/codecaps-appstore-derived}"

# How long to wait for the app to draw a screen, and how often to look.  A
# cold simulator took about eighteen seconds to show its first frame and a
# warm one about nine, so the budget is generous on purpose: a slow frame is
# cheap, a blank one is a wasted run.
RENDER_TIMEOUT_SEC="${RENDER_TIMEOUT_SEC:-180}"
RENDER_POLL_SEC="${RENDER_POLL_SEC:-2}"
# The share of non-background pixels a frame has to hold before it counts as
# a drawn screen.  A window that has drawn nothing but its status bar measures
# about 0.3 percent, a frame that has drawn the navigation bar and no content
# about 4, and a finished screen between 40 and 55.  Ten percent is clear of
# both ends: a half-drawn screen is never mistaken for a finished one.
RENDER_MIN_PERCENT="${RENDER_MIN_PERCENT:-10.0}"

mkdir -p "$OUT_DIR"

# App Store Connect accepts these display sizes.  The list is Apple's own:
# developer.apple.com/help/app-store-connect/reference/screenshot-specifications
#
#   iPhone 6.9"    1320 x 2868   (iPhone 16 Pro Max and friends)
#   iPhone 6.7"    1290 x 2796   (iPhone 16 Plus and friends)
#   iPhone 6.5"    1284 x 2778   (iPhone 13 Pro Max and friends)
#   iPhone 6.5"    1242 x 2688   (iPhone 12 Pro Max and friends)
#   iPad    13"    2064 x 2752   (iPad Pro 13-inch, M4 and M5)
#   iPad    12.9"  2048 x 2732   (iPad Pro 12.9-inch, 6th generation)
#
# The iPad Pro 12.9-inch of the 2nd generation captures at 2048 x 2732 like
# the other 12.9-inch Pro generations.  There is no 2000 x 2664 device.
#
# The first entry for each display class is the one the App Store Connect
# screenshot set expects, and the upload step maps a captured file to its set
# from these numbers.
IPHONE_PREFERRED="iPhone 17 Pro Max|iPhone 16 Pro Max|iPhone 15 Pro Max|iPhone 14 Pro Max|iPhone 17 Plus|iPhone 16 Plus|iPhone 15 Plus|iPhone 14 Plus|iPhone 13 Pro Max|iPhone 12 Pro Max"
IPAD_PREFERRED="iPad Pro 13-inch (M5)|iPad Pro 13-inch (M4)|iPad Pro 12.9-inch (6th generation)|iPad Pro 12.9-inch (5th generation)|iPad Pro 12.9-inch (3rd generation)"

# log() writes to stderr on purpose: it is called from inside command
# substitution in some places, and anything on stdout would be read back as
# part of a captured value.
log() { echo "capture: $*" >&2; }
fail() { echo "::error::capture: $*" >&2; exit 1; }

# Print the UDID of the first available simulator whose display name matches
# one of the pipe-separated preferred names, in order.
#
# The picker matches on a prefix, because Xcode names some iPads with their
# storage variant ("iPad Pro 13-inch (M5) (16GB)"), and an exact match would
# find no iPad at all on a current runner.  Its tests live next to it in
# scripts/ios-fleet/test_pick_simulator.py.
pick_simulator() {
  python3 "$SCRIPT_DIR/pick_simulator.py" "$1"
}

# Print "<width>x<height>" for an image, or nothing if it cannot be read.
image_size() {
  sips -g pixelWidth -g pixelHeight "$1" 2>/dev/null \
    | awk '/pixelWidth/ {w = $2} /pixelHeight/ {h = $2} END {if (w && h) print w "x" h}'
}

# Print the App Store Connect display class and the device family for a pixel
# size, separated by a pipe, or nothing if the size is not one Apple accepts.
#
#   1320x2868 -> APP_IPHONE_67|iphone
#   2064x2752 -> APP_IPAD_PRO_129|ipad
#
# App Store Connect has no APP_IPHONE_69 and no APP_IPAD_PRO_13: the
# 6.9-inch iPhone size lives in APP_IPHONE_67 and the 13-inch iPad size in
# APP_IPAD_PRO_129.
class_for_size() {
  case "$1" in
    1320x2868|1290x2796) echo "APP_IPHONE_67|iphone" ;;
    1284x2778|1242x2688) echo "APP_IPHONE_65|iphone" ;;
    2064x2752) echo "APP_IPAD_PRO_129|ipad" ;;
    2048x2732) echo "APP_IPAD_PRO_3GEN_129|ipad" ;;
  esac
}

# Write a realistic quota snapshot to the file named by the first argument.
seed_snapshot() {
  local target="$1"
  python3 - "$target" <<'PY'
import datetime, json, os, sys

target = sys.argv[1]
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

# Wait until the app has drawn its first frame, then leave that frame at the
# path given by the second argument.
#
# The companion takes seconds to render on a cold simulator, and a fixed sleep
# captured a blank window more than once.  This polls instead: take a frame,
# measure how much of it is not background, and stop as soon as the screen
# holds more than the status bar.
wait_for_render() {
  local udid="$1" frame="$2"
  local deadline=$((SECONDS + RENDER_TIMEOUT_SEC))
  while [ "$SECONDS" -lt "$deadline" ]; do
    xcrun simctl io "$udid" screenshot --type=jpeg "$frame" >/dev/null 2>&1 || true
    if [ -s "$frame" ]; then
      local status=0
      python3 "$SCRIPT_DIR/screenshot_ink.py" "$frame" \
        --min-percent "$RENDER_MIN_PERCENT" || status=$?
      if [ "$status" -eq 0 ]; then
        return 0
      fi
      if [ "$status" -ne 1 ]; then
        fail "could not measure the screen on $udid"
      fi
    fi
    sleep "$RENDER_POLL_SEC"
  done
  fail "the app drew no screen within ${RENDER_TIMEOUT_SEC}s on $udid"
}

# Check a captured file against the size App Store Connect accepts and
# against the size the other captures on this device have.  The file to keep
# is left in CHECKED_FILE: the check must not delete anything, because a
# command substitution would swallow whatever the delete printed.
CHECKED_FILE=""
check_capture() {
  local file="$1" want="$2"
  local size alpha
  size="$(image_size "$file")"
  if [ -z "$size" ]; then
    fail "$(basename "$file") could not be read"
  fi
  if [ "$size" != "$want" ]; then
    fail "$(basename "$file") is $size, but the other captures are $want"
  fi
  if [ -z "$(class_for_size "$size")" ]; then
    fail "$(basename "$file") is $size, which App Store Connect does not accept for any display class"
  fi
  alpha="$(sips -g hasAlpha "$file" 2>/dev/null | awk '/hasAlpha/ {print $2}')"
  if [ "$alpha" = "yes" ]; then
    fail "$(basename "$file") still has an alpha channel, which App Store Connect rejects"
  fi
  CHECKED_FILE="$file"
}

# Build, install, seed, launch and capture on one simulator.
capture_on() {
  local udid="$1" label="$2" kind="$3"
  local derived="$DERIVED_ROOT/$label"
  local app="$derived/Build/Products/Debug-iphonesimulator/CodeCapsCompanion.app"
  local container group_container bundle_id

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
  # The companion reads the App Group container when the build is signed and
  # its own sandbox when it is not, so seed whichever ones exist.
  group_container="$(xcrun simctl get_app_container "$udid" "$bundle_id" groups 2>/dev/null | head -1)"

  # Three screens per device: the quota list, the platform-order editor, and
  # the reset-alarm settings.  The last two are tabs of the settings sheet, so
  # each one needs the sheet opened as well as its own argument.  The app is
  # launched before every capture, so no shot is ever the home screen.
  local name
  for name in fleet-status platform-order alarms; do
    local args=()
    case "$name" in
      platform-order) args=(-openSettings -reorderPlatforms) ;;
      alarms) args=(-openSettings -openAlarms) ;;
    esac
    xcrun simctl terminate "$udid" "$bundle_id" 2>/dev/null || true
    # Re-seed before each launch so the "Updated" time on the cards is the
    # time of the shot rather than the time the run started.
    seed_snapshot "$container/Library/Application Support/CodeCaps/quota-windows.json" >/dev/null
    if [ -n "$group_container" ]; then
      seed_snapshot "$group_container/quota-windows.json" >/dev/null
    fi
    # ${args[@]:+...} rather than "${args[@]}": the first capture passes no
    # arguments, and Bash 3.2 (the runner's system Bash) reads an empty array
    # under `set -u` as an unbound variable and exits.
    xcrun simctl launch --terminate-running-process "$udid" "$bundle_id" \
      ${args[@]:+"${args[@]}"} >/dev/null

    # The simulator writes JPEG, which cannot carry an alpha channel, and
    # App Store Connect rejects a screenshot that has one.  It is converted
    # back to PNG so the upload step can read the size out of the header.
    local raw="$derived/$label-$name.jpg"
    wait_for_render "$udid" "$raw"
    sips -s format png "$raw" --out "$OUT_DIR/$label-$name.png" >/dev/null
    log "captured $label $name"
  done
  xcrun simctl terminate "$udid" "$bundle_id" 2>/dev/null || true

  # The captured size decides the display class and the file name, so the
  # output says what the pixels actually are.
  local size class_name family
  size="$(image_size "$OUT_DIR/$label-fleet-status.png")"
  class_name="$(class_for_size "$size")"
  [ -n "$class_name" ] || fail "$label rendered at $size, which App Store Connect does not accept"
  IFS='|' read -r display_type family <<<"$class_name"
  # The family we booted has to be the family the pixels are, or the two
  # captures would be uploaded into the wrong screenshot sets.
  [ "$family" = "$kind" ] \
    || fail "$label rendered at $size, which is a $family capture, not a $kind one"

  # The file is named after the display set it belongs to, so the two
  # families cannot be mixed up when the files are handed to the upload.
  local stem
  stem="$(echo "$display_type" | tr '[:upper:]' '[:lower:]')"
  for name in fleet-status platform-order alarms; do
    check_capture "$OUT_DIR/$label-$name.png" "$size"
    mv "$CHECKED_FILE" "$OUT_DIR/$stem-$name.png"
    log "$display_type $name ($size)"
  done
}

main() {
  command -v xcodegen >/dev/null 2>&1 || fail "xcodegen is not installed"
  # Always regenerate.  The checked-in project is stale: it is missing shared
  # QuotaCore files the companion compiles against, and a checkout gives
  # project.yml and the project file the same mtime, so comparing them would
  # skip the regeneration and build a project that does not compile.
  log "regenerating the companion project"
  ( cd "$PROJECT_DIR" && xcodegen generate )

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

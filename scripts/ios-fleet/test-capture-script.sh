#!/usr/bin/env bash
#
# Contract test for the App Store screenshot capture script.
#
# The capture runs on a macOS runner whose system Bash is 3.2, and Bash 3.2
# reads an empty array under "set -u" as an unbound variable.  The first
# capture passes no launch arguments at all, so the unguarded form
# "${args[@]}" aborts the run on the very first screen, after the build has
# already spent its time.  The guarded form ${args[@]:+"${args[@]}"} is safe
# on every Bash the fleet uses, and this test keeps it that way.
#
# Usage: bash scripts/ios-fleet/test-capture-script.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAPTURE="$SCRIPT_DIR/capture-appstore-screenshots.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $1"; }

[[ -f "$CAPTURE" ]] || fail "the capture script is missing at $CAPTURE"

# It still has to parse.
bash -n "$CAPTURE" || fail "the capture script does not parse"

# Every expansion of the launch-argument array has to be guarded, so an empty
# array stays empty under "set -u" instead of becoming an unbound variable.
# shellcheck disable=SC2016  # the pattern is matched literally, not expanded
unguarded="$(grep -n '\${args\[@\]}' "$CAPTURE" | grep -v '\${args\[@\]:+' || true)"
[[ -z "$unguarded" ]] || fail "an unguarded array expansion is left in the capture script:
$unguarded"
pass "no unguarded array expansion"

# The guarded form has to survive "set -u" with an empty array.
output="$(/bin/bash -c 'set -u; args=(); printf "%s" ${args[@]:+"${args[@]}"}' || true)"
[[ -z "$output" ]] || fail "the guarded expansion produced output for an empty array: $output"
pass "the guarded expansion is safe with an empty array"

# Bash 4 builtins do not exist on the runner's system Bash.
newer="$(grep -nE '\b(readarray|mapfile)\b' "$CAPTURE" || true)"
[[ -z "$newer" ]] || fail "the capture script uses a Bash 4 builtin, which the runner's Bash 3.2 does not have:
$newer"
pass "no Bash 4 builtin"

# The script must wait for a drawn frame rather than sleep a fixed number of
# seconds, which is what captured a blank window.
grep -q 'wait_for_render' "$CAPTURE" || fail "the capture script no longer waits for a drawn frame"
grep -q 'screenshot_ink.py' "$CAPTURE" || fail "the capture script no longer measures the frame before keeping it"
pass "the capture waits for a drawn frame"

# The quota list fills the screen and the settings sheets do not, so one
# threshold for all three screens either fails the two settings captures or
# lets a half-drawn frame through.  The settings screens need their own bar.
grep -q 'RENDER_MIN_PERCENT_SETTINGS' "$CAPTURE" \
  || fail "the capture script has no separate minimum for the settings screens"
grep -q 'wait_for_render "$udid" "$raw" "$min"' "$CAPTURE" \
  || fail "the capture script does not give each screen its own minimum"
pass "each screen is measured against a minimum that fits it"

# A screen that is sparse but finished never reaches the high bar, so the
# wait has to be able to keep a frame that has stopped changing.
grep -q 'RENDER_STABLE_FLOOR' "$CAPTURE" \
  || fail "the capture script cannot keep a sparse screen that has settled"
grep -q 'RENDER_STABLE_POLLS' "$CAPTURE" \
  || fail "the capture script does not require the frame to hold still"
pass "a sparse screen that has settled is kept"

# Both simulators run the same runtime and the same product, so the app is
# built once and installed on both.  A second build compiles the companion and
# the shared QuotaCore files from scratch again, for nothing.
builds="$(grep -c 'xcodebuild' "$CAPTURE" || true)"
[[ "$builds" -eq 1 ]] || fail "the capture script runs $builds xcodebuild calls; it has to build the app once:
$builds"
grep -q 'APP_PATH=' "$CAPTURE" || fail "the capture script has no shared app path"
pass "the app is built once and installed on both simulators"

echo "capture script contract: 7 checks passed"

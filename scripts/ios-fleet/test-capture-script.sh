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
# shellcheck disable=SC2016  # the pattern is matched literally, not expanded
grep -q 'wait_for_render "$udid" "$raw" "$min" "$RENDER_MIN_CONTENT_PERCENT"' "$CAPTURE" \
  || fail "the capture script does not give each screen its own minimum and the content bar"
pass "each screen is measured against a minimum that fits it"

# A frame that has drawn only its navigation bar covers a few percent of the
# frame, so a threshold on the whole frame alone cannot tell it from a
# finished screen.  The content region below the header is what can, and it
# has to be part of the gate rather than a separate check.
grep -q 'RENDER_MIN_CONTENT_PERCENT' "$CAPTURE" \
  || fail "the capture script does not measure the content region"
grep -q 'p >= m && c >= k' "$CAPTURE" \
  || fail "the capture script does not require the content region to hold ink"
pass "the content region below the header is part of the gate"

# Holding still is a second condition on top of the thresholds, never a way
# around them: a frame that is still filling in has not finished drawing even
# when it has already cleared them.
if grep -q 'RENDER_STABLE_FLOOR' "$CAPTURE"; then
  fail "the capture script has a stable-frame floor that can bypass the minimum"
fi
grep -q 'RENDER_STABLE_DELTA' "$CAPTURE" \
  || fail "the capture script does not require the frame to hold still"
grep -q 'RENDER_STABLE_POLLS' "$CAPTURE" \
  || fail "the capture script does not require the frame to hold still"
pass "the settled path cannot bypass the minimum"

# A measurement that failed is not a blank frame.  Swallowing it would spend
# the whole render budget on every screen and then report the wrong reason.
grep -q 'INK_ERROR_FILE' "$CAPTURE" \
  || fail "the capture script discards the ink measurement error"
grep -q 'status" -ge 2' "$CAPTURE" \
  || fail "the capture script does not fail fast on a failed measurement"
pass "a failed measurement stops the capture instead of timing out"

# The decisions the capture makes are exercised against the real numbers, not
# only checked for their presence in the source.  The script is sourced with
# the run guarded off, so the functions can be called directly.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
gate() {
  # gate <overall> <content> <min_overall> <min_content> -> exit 0 when drawn
  (
    cd "$work"
    OUT_DIR="$work/out" DERIVED_ROOT="$work/derived" CAPTURE_SOURCE_ONLY=1 \
      bash -c ". '$CAPTURE'; frame_clears_thresholds \"\$1\" \"\$2\" \"\$3\" \"\$4\"" \
      _ "$1" "$2" "$3" "$4"
  ) >/dev/null 2>&1
}

# A navigation bar and no content: about four percent of the frame, and none
# of it below the header.  It has to be rejected for every screen, which is
# the case a threshold on the whole frame alone got wrong.
gate 4.6 0.0 10.0 0.5 && fail "a navigation bar with no content passed the quota-list gate"
gate 4.6 0.0 5.0 0.5 && fail "a navigation bar with no content passed the settings gate"
gate 4.6 0.0 4.5 0.4 && fail "a navigation bar with no content passed a low gate"
pass "a navigation bar with no content never passes the gate"

# A half-drawn screen: some content, but the content share is under the bar.
gate 12.0 0.2 10.0 0.5 && fail "a half-drawn screen passed the quota-list gate"
gate 12.0 0.2 5.0 0.5 && fail "a half-drawn screen passed the settings gate"
pass "a half-drawn screen never passes the gate"

# The finished quota list and the finished settings sheet both pass.
gate 43.0 12.0 10.0 0.5 || fail "the finished quota list did not pass the gate"
gate 6.2 1.1 5.0 0.5 || fail "the finished settings sheet did not pass the gate"
# Exactly on the bar still passes.
gate 10.0 0.5 10.0 0.5 || fail "a frame exactly on the bar did not pass the gate"
pass "a finished screen passes the gate"

# Both simulators run the same runtime and the same product, so the app is
# built once and installed on both.  A second build compiles the companion and
# the shared QuotaCore files from scratch again, for nothing.
builds="$(grep -c 'xcodebuild' "$CAPTURE" || true)"
[[ "$builds" -eq 1 ]] || fail "the capture script runs $builds xcodebuild calls; it has to build the app once:
$builds"
grep -q 'APP_PATH=' "$CAPTURE" || fail "the capture script has no shared app path"
pass "the app is built once and installed on both simulators"

echo "capture script contract: 12 checks passed"

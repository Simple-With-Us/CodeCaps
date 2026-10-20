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

echo "capture script contract: 4 checks passed"

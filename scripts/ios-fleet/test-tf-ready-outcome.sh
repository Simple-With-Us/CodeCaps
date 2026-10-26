#!/usr/bin/env bash
# test-tf-ready-outcome.sh - Offline tests for the ensure-tf-ready exit-code
# wording (scripts/ios-fleet/tf-ready-outcome.sh).
#
# Why this test exists: the ship script used to send every exit code other
# than 0, 3 and 4 to one generic warning, "build may be stuck on export
# compliance".  For rc=5 that warning names the wrong cause.  rc=5 means the
# build WAS processed and export compliance WAS declared, but ZERO internal
# testers can install it.  CodeCaps iOS 1.0.263 / build 281 shipped that way
# on 2026-10-25 with a green job, and 14 green ships reached nobody on the
# internal path the same way before that (GH #1018).
#
# The wording is scoped to the INTERNAL path on purpose, because rc=5 counts
# only internal all-builds testers.  It says nothing about external testers, and
# build 281 was in an external Public Beta group at the same time.
#
# The wording states only what the exit code PROVES.  rc=5 fires on the
# tester count being zero (asc-api.mjs: nobody = testers === 0), so an app
# whose internal group exists with no members also yields rc=5.  A wording
# that claims "no internal group" contradicts the group count on the
# ensure-tf-ready line the ship script forwards, and it prescribes a group
# that already exists.
#
# Everything here is offline: no network, no credentials, no App Store
# Connect, no xcodebuild.
#
# Usage: bash scripts/ios-fleet/test-tf-ready-outcome.sh
#
# ASCII-only (Apple bash 3.2 safe).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTCOME="${SCRIPT_DIR}/tf-ready-outcome.sh"
SHIP="${SCRIPT_DIR}/ship-testflight.sh"
[[ -f "$OUTCOME" ]] || { echo "missing $OUTCOME"; exit 1; }
[[ -f "$SHIP" ]] || { echo "missing $SHIP"; exit 1; }

# shellcheck source=scripts/ios-fleet/tf-ready-outcome.sh
source "$OUTCOME"

PASS=0
FAIL=0
check() {
  # check <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    echo "  ok  : $1 (=$3)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $1 (expected '$2', got '$3')"
    FAIL=$((FAIL + 1))
  fi
}
contains() {
  # contains <label> <needle> <haystack>
  if [[ "$3" == *"$2"* ]]; then
    echo "  ok  : $1"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $1 (missing '$2')"
    FAIL=$((FAIL + 1))
  fi
}
lacks() {
  # lacks <label> <needle> <haystack>
  if [[ "$3" != *"$2"* ]]; then
    echo "  ok  : $1"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $1 (unexpectedly contains '$2')"
    FAIL=$((FAIL + 1))
  fi
}

echo "== rc=5 names the real cause, not export compliance =="
R5="$(tf_ready_outcome_lines 5)"
contains "rc=5 says zero internal testers" "ZERO internal testers" "$R5"
contains "rc=5 says compliance WAS declared" "export compliance WAS declared" "$R5"
contains "rc=5 points at the standing-testers secret" "ASC_STANDING_TESTERS" "$R5"
lacks "rc=5 never says the build may be stuck on compliance" "stuck on export compliance" "$R5"
lacks "rc=5 never says compliance was not declared" "export compliance not declared" "$R5"
lacks "rc=5 never says compliance was NOT declared" "export compliance NOT declared" "$R5"

echo "== rc=5 states only what the exit code proves =="
# The exit code fires on the TESTER count being zero, so it cannot tell a
# missing group from an empty one.  A wording that names the group count
# contradicts the ensure-tf-ready line the ship script forwards, and a remedy
# that says "create the group" is wrong when the group is already there.
lacks "rc=5 never claims the app has no internal group" "no internal TestFlight group" "$R5"
lacks "rc=5 never states a group count" "groups=0" "$R5"
lacks "rc=5 never says the remedy creates the group" "creates the group" "$R5"
contains "rc=5 points at the ensure-tf-ready line for the group count" "ensure-tf-ready line" "$R5"
contains "rc=5 says no tester can install the build" "no tester in an internal group with access to all builds can install this build" "$R5"

echo "== rc=5 is scoped to the internal path, never to external testers =="
# The count behind rc=5 is the INTERNAL all-builds tester count, so the wording
# must not claim that nobody can install the build.  CodeCaps iOS 1.0.263 /
# build 281 had no internal group AND sat in an external Public Beta group at
# the same time, so a wording that says "the build reaches nobody" is wrong in
# the one case this label exists to explain.
contains "rc=5 scopes the failure to the internal path" "INTERNAL path reaches nobody" "$R5"
contains "rc=5 says external testers are a separate question" "External testers are a separate question" "$R5"
contains "rc=5 points at External Testing" "TestFlight > External Testing" "$R5"
lacks "rc=5 never claims installable by nobody" "installable by NOBODY" "$R5"
lacks "rc=5 never says the build reaches nobody" "the build reaches nobody" "$R5"

echo "== the rc=5 count really is the internal all-builds tester count =="
# If the client ever starts counting external groups, the rc=5 wording has to
# be rewritten, so the filter is pinned here rather than left to a comment.
ASC_API="${SCRIPT_DIR}/asc-api.mjs"
if [[ -f "$ASC_API" ]]; then
  ASC_TEXT="$(cat "$ASC_API")"
  contains "the client filters the groups on isInternalGroup" "isInternalGroup === true" "$ASC_TEXT"
  contains "the client filters the groups on hasAccessToAllBuilds" "hasAccessToAllBuilds === true" "$ASC_TEXT"
  # The exit code fires on the TESTER count, never on the group count:  a group
  # that exists with no members gives the same zero as no group at all, so the
  # wording may not name the group count.
  contains "the client decides rc=5 on the tester count" "internalTesters.ok && internalTesters.testers === 0" "$ASC_TEXT"
  contains "the client exits 5 for zero testers" "nobody ? 5 : internalTesters.ok ? 0 : 6" "$ASC_TEXT"
else
  echo "  FAIL: missing ${ASC_API}"
  FAIL=$((FAIL + 1))
fi

echo "== rc=6 says the count is unreadable, not that compliance failed =="
R6="$(tf_ready_outcome_lines 6)"
contains "rc=6 says the count could not be read" "could not be read" "$R6"
contains "rc=6 scopes the unverified verdict to the internal path" "on the INTERNAL path is UNVERIFIED" "$R6"
lacks "rc=6 never says the build may be stuck on compliance" "stuck on export compliance" "$R6"
lacks "rc=6 never says compliance was not declared" "export compliance not declared" "$R6"

echo "== every other code keeps the compliance wording =="
R2="$(tf_ready_outcome_lines 2)"
contains "rc=2 keeps the generic warning" "stuck on export compliance" "$R2"
RUNKNOWN="$(tf_ready_outcome_lines 42)"
contains "an unknown code keeps the generic warning" "stuck on export compliance" "$RUNKNOWN"

echo "== the GitHub annotations stand on their own =="
A5="$(tf_ready_outcome_annotation 5 com.example.ios 281)"
contains "rc=5 annotation names the code" "rc=5" "$A5"
contains "rc=5 annotation names the app" "com.example.ios" "$A5"
contains "rc=5 annotation names the build" "281" "$A5"
contains "rc=5 annotation says zero internal testers can install it" "ZERO internal testers" "$A5"
contains "rc=5 annotation scopes the failure to the internal path" "internal path reaches nobody" "$A5"
contains "rc=5 annotation says external testers are not counted" "External testers are not counted" "$A5"
lacks "rc=5 annotation never claims installable by nobody" "installable by NOBODY" "$A5"
lacks "rc=5 annotation never says compliance was not declared" "export compliance not declared" "$A5"
lacks "rc=5 annotation never claims the app has no internal group" "no internal TestFlight group" "$A5"
contains "rc=5 annotation points at the ensure-tf-ready line for the group count" "ensure-tf-ready line" "$A5"
A6="$(tf_ready_outcome_annotation 6 com.example.ios 281)"
contains "rc=6 annotation names the code" "rc=6" "$A6"
A2="$(tf_ready_outcome_annotation 2 com.example.ios 281)"
contains "rc=2 annotation keeps the compliance wording" "export compliance not declared" "$A2"

echo "== the ship script routes rc=5 and rc=6 through the helper =="
SHIP_TEXT="$(cat "$SHIP")"
contains "the ship script calls the helper for the outcome lines" "tf_ready_outcome_lines" "$SHIP_TEXT"
contains "the ship script calls the helper for the annotation" "tf_ready_outcome_annotation" "$SHIP_TEXT"
contains "the ship script has an rc=5 or rc=6 branch" "rc -eq 5" "$SHIP_TEXT"
contains "the ship script has an rc=6 branch" "rc -eq 6" "$SHIP_TEXT"
contains "the ship script sources the helper" "tf-ready-outcome.sh" "$SHIP_TEXT"

echo
echo "passed: ${PASS}  failed: ${FAIL}"
[[ $FAIL -eq 0 ]] || exit 1
exit 0

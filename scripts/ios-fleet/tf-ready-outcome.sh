#!/usr/bin/env bash
# tf-ready-outcome.sh - What each ensure-tf-ready exit code actually means.
#
# ensure-tf-ready (scripts/ios-fleet/asc-api.mjs) exits with a code that names
# the state of the build in App Store Connect.  The ship script used to map
# every code other than 0, 3 and 4 to one generic warning, "build may be stuck
# on export compliance", which named the wrong cause for the codes that matter
# most:
#
#   0  internal testers can install the build.
#   2  a usage error or an App Store Connect API error.  Export compliance was
#      NOT declared, so this is the one generic warning that fits.
#   3  ASC has not reached IN_BETA_TESTING yet.  The upload succeeded.
#   4  ASC never surfaced the build in time.  Export compliance was NOT
#      declared on it.
#   5  READ AND ZERO ON THE INTERNAL PATH: the build was found, Apple finished
#      processing it, and export compliance WAS declared (the compliance PATCH
#      lands before the readiness poll, so the poll's enc=false is the answered
#      state, not a missing declaration).  The number behind the exit code is
#      the count of INTERNAL TestFlight testers in internal groups that have
#      access to all builds (asc-api.mjs countInternalTesters filters on
#      isInternalGroup AND hasAccessToAllBuilds).  The exit code fires on that
#      TESTER count being zero (asc-api.mjs: nobody = testers === 0), so rc=5
#      proves that zero internal testers can install the build.  It does NOT
#      prove that the app has no internal group:  a group that exists with no
#      members gives the same zero, and the remedy for that is testers, not a
#      group.  The group count is on the ensure-tf-ready line that the ship
#      script forwards, so the wording here leaves it there.  This is how 14
#      green ships reached nobody on the internal path (GH #1018), and how
#      CodeCaps iOS 1.0.263 / build 281 shipped with a green job on
#      2026-10-25.
#
#      It says NOTHING about external testers.  A build assigned to an external
#      group reaches that group's testers, subject to Apple's beta review of
#      the build, and external group assignment is independent of the internal
#      group.  CodeCaps iOS 1.0.263 / build 281 is the live example of both
#      halves at once: no internal group at all, and at the same time assigned
#      to an existing Public Beta external group.  So rc=5 never justifies
#      "nobody can install this build", only "the internal path reaches nobody".
#   6  the internal tester count could not be read, so installability on the
#      internal path is unverified.  Not a compliance problem either.
#
# APPLY WHEN: reading a TestFlight ship log that says "rc=5".  The named cause
# is the one to fix: the internal tester group (and the ASC_STANDING_TESTERS
# repository secret that creates it), never export compliance.  Before telling
# anyone a build "reaches nobody", read TestFlight > External Testing for that
# build's group assignment and beta review state, because rc=5 cannot see it.

# tf_ready_outcome_lines <rc>
#
# The log lines for one exit code, one per line.  Every code except 5 and 6
# keeps the generic export-compliance wording on purpose: for 2 and for an
# unknown code the upload really may have missed its compliance declaration.
tf_ready_outcome_lines() {
  local rc="${1:-}"
  case "$rc" in
    5)
      printf '%s\n' \
        "warning: build was processed by App Store Connect and export compliance WAS declared, but ZERO internal testers can install it:  no tester in an internal group with access to all builds can install this build" \
        "warning: the INTERNAL path reaches nobody.  External testers are a separate question:  this build may already be assigned to an external group, and external installability then depends on Apple's beta review of that build.  Check TestFlight > External Testing for this build's group assignment and review state" \
        "warning: the ensure-tf-ready line above carries the internal tester count and the number of matching internal groups, so that line says which of the two is the cause" \
        "warning: to populate the internal path, set the ASC_STANDING_TESTERS repository secret to the standing tester emails so every ship adds them to the internal group, or add testers by hand in App Store Connect > TestFlight > Internal Testing"
      ;;
    6)
      printf '%s\n' \
        "warning: build was processed by App Store Connect and export compliance WAS declared, but the internal tester count could not be read, so installability on the INTERNAL path is UNVERIFIED" \
        "warning: check App Store Connect > TestFlight > Internal Testing by hand;  this is not a compliance problem"
      ;;
    *)
      printf '%s\n' "warning: ensure-tf-ready failed (rc=${rc}); build may be stuck on export compliance"
      ;;
  esac
}

# tf_ready_outcome_annotation <rc> <bundle-id> <build-number>
#
# The one-line GitHub Actions warning for one exit code.  It has to stand on
# its own in the run summary, where nobody sees the surrounding log lines.
tf_ready_outcome_annotation() {
  local rc="${1:-}" bundle="${2:-}" build="${3:-}"
  case "$rc" in
    5)
      printf '%s' "ensure-tf-ready rc=5 for ${bundle} build ${build}: the build was processed and export compliance was declared, but ZERO internal testers can install it, so the internal path reaches nobody.  The exit code proves the tester count is zero;  the internal group count is on the ensure-tf-ready line in the log.  External testers are not counted here:  check TestFlight > External Testing for this build's group assignment and Apple's beta review state.  Set ASC_STANDING_TESTERS (or add testers by hand in TestFlight > Internal Testing) to populate the internal path."
      ;;
    6)
      printf '%s' "ensure-tf-ready rc=6 for ${bundle} build ${build}: the build was processed and export compliance was declared, but the internal tester count could not be read, so installability on the internal path is unverified.  Check TestFlight > Internal Testing by hand."
      ;;
    *)
      printf '%s' "ensure-tf-ready failed (rc=${rc}) for ${bundle} build ${build}; export compliance not declared"
      ;;
  esac
}

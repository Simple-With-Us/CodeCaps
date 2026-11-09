#!/usr/bin/env bash
# ios-recheck-tf-ready.sh — read-only post-sync ensure-tf-ready for CI.
#
# The ship script calls ensure-tf-ready before the workflow's standing-tester
# sync step, so an rc=5 "zero internal testers" verdict there can be a false
# alarm when the sync step then creates the internal group (OPS-1052).  This
# wrapper re-runs the same asc-api.mjs check after sync and writes the second
# verdict to $GITHUB_STEP_SUMMARY with the same rc wording as ship-testflight.sh
# (scripts/ios-fleet/tf-ready-outcome.sh).
#
# Usage: bash scripts/ios-recheck-tf-ready.sh --build <CFBundleVersion>
#
# Env:
#   IOS_TF_READY_TIMEOUT_SEC  bounded poll timeout for ensure-tf-ready (default 900)
#
# Exit: ensure-tf-ready's exit code (callers in CI should continue-on-error).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLEET_DIR="${ROOT}/scripts/ios-fleet"
APPS_JSON="${FLEET_DIR}/apps.json"
APP_KEY="codecaps"

BUILD_NUM=""

usage() {
  echo "usage: $0 --build <CFBundleVersion>" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build)
      BUILD_NUM="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage
      ;;
  esac
done

[[ -n "$BUILD_NUM" ]] || usage
[[ -f "$APPS_JSON" ]] || { echo "missing ${APPS_JSON}" >&2; exit 2; }

BUNDLE_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["apps"]["codecaps"]["bundleId"])' "$APPS_JSON")"
MARKETING="$(python3 -c 'import json,sys; v=json.load(open(sys.argv[1]))["apps"]["codecaps"]; print(v.get("fixedMarketingVersion") or v.get("marketingVersionDefault") or "")' "$APPS_JSON")"
[[ -n "$BUNDLE_ID" && -n "$MARKETING" ]] || { echo "codecaps entry in apps.json is incomplete" >&2; exit 2; }

# shellcheck source=scripts/ios-fleet/tf-ready-outcome.sh
source "${FLEET_DIR}/tf-ready-outcome.sh"

LOG_DIR="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/ios-recheck-tf-ready"
mkdir -p "$LOG_DIR"

set +e
node "${FLEET_DIR}/asc-api.mjs" ensure-tf-ready "$BUNDLE_ID" "$BUILD_NUM" "$MARKETING" \
  >"${LOG_DIR}/ensure-tf-ready.json" 2>"${LOG_DIR}/ensure-tf-ready.err"
rc=$?
set -e

log_line() {
  printf '%s\n' "$1"
}

if [[ -s "${LOG_DIR}/ensure-tf-ready.err" ]]; then
  while IFS= read -r line; do
    [[ -n "$line" ]] && log_line "tf-ready (post-sync): ${line}"
  done <"${LOG_DIR}/ensure-tf-ready.err"
fi

case "$rc" in
  0)
    log_line "Post-sync: TestFlight internal testers can install ${BUNDLE_ID} build ${BUILD_NUM} (ensure-tf-ready rc=0)"
    ;;
  3)
    log_line "Post-sync: upload succeeded but ASC has not reached IN_BETA_TESTING yet for build ${BUILD_NUM} (ensure-tf-ready rc=3)"
    ;;
  4)
    log_line "Post-sync: ASC never surfaced build ${BUILD_NUM} in time (ensure-tf-ready rc=4)"
    ;;
  5|6)
    while IFS= read -r line; do
      [[ -n "$line" ]] && log_line "$line"
    done <<< "$(tf_ready_outcome_lines "$rc")"
  ;;
  *)
    log_line "Post-sync: ensure-tf-ready failed (rc=${rc}); build may be stuck on export compliance"
    ;;
esac

if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  case "$rc" in
    0|3|4)
      ;;
    5|6|*)
      echo "::warning::Post-sync $(tf_ready_outcome_annotation "$rc" "$BUNDLE_ID" "$BUILD_NUM")"
      ;;
  esac
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## TestFlight readiness after standing-tester sync"
    echo ""
    echo "| Field | Value |"
    echo "| --- | --- |"
    echo "| Bundle | \`${BUNDLE_ID}\` |"
    echo "| Build | \`${BUILD_NUM}\` |"
    echo "| **ensure-tf-ready rc** | **${rc}** |"
    echo ""
    if [[ -s "${LOG_DIR}/ensure-tf-ready.err" ]]; then
      echo "<details><summary>ensure-tf-ready log (post-sync)</summary>"
      echo ""
      echo '```'
      cat "${LOG_DIR}/ensure-tf-ready.err"
      echo '```'
      echo ""
      echo "</details>"
      echo ""
    fi
    case "$rc" in
      0)
        echo "Post-sync verdict: internal testers can install this build."
        ;;
      3)
        echo "Post-sync verdict: upload succeeded; ASC has not reached IN_BETA_TESTING yet."
        ;;
      4)
        echo "Post-sync verdict: build never appeared in ASC within the timeout; export compliance may not be declared on this build."
        ;;
      5|6)
        while IFS= read -r line; do
          [[ -n "$line" ]] && echo "- ${line}"
        done <<< "$(tf_ready_outcome_lines "$rc")"
        echo ""
        echo "> $(tf_ready_outcome_annotation "$rc" "$BUNDLE_ID" "$BUILD_NUM")"
        ;;
      *)
        echo "> $(tf_ready_outcome_annotation "$rc" "$BUNDLE_ID" "$BUILD_NUM")"
        ;;
    esac
  } >>"$GITHUB_STEP_SUMMARY"
fi

exit "$rc"

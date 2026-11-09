#!/usr/bin/env bash
# Post-sync ensure-tf-ready recheck for hosted ios-ship.yml (OPS-1052).
#
# Re-invokes the same asc-api.mjs ensure-tf-ready subcommand the ship script
# already ran (export-compliance PATCH when still unanswered, optional What to
# Test notes, then readiness poll).  Those writes are idempotent on a build that
# already shipped; the point of this pass is to re-read internal tester counts
# after standing-tester sync, not to introduce new ASC mutations.
set -euo pipefail

APP_KEY="${1:-codecaps}"
BUILD_NUM="${2:-}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLEET_DIR="${ROOT}/scripts/ios-fleet"
APPS_JSON="${FLEET_DIR}/apps.json"

if [[ -z "$BUILD_NUM" ]]; then
  echo "usage: $0 <app-key> <12-digit-build>" >&2
  exit 2
fi

[[ "$BUILD_NUM" =~ ^[1-9][0-9]{11}$ ]] || {
  echo "::error::recheck-tf-ready for ${APP_KEY}: build '${BUILD_NUM}' is not a 12-digit merge-stamp build" >&2
  exit 1
}

[[ -f "$APPS_JSON" ]] || { echo "missing ${APPS_JSON}" >&2; exit 2; }

mapfile -t _APP_META < <(python3 - "$APP_KEY" "$APPS_JSON" <<'PY'
import json, sys
app_key, path = sys.argv[1], sys.argv[2]
root = json.load(open(path, encoding="utf-8"))
app = (root.get("apps") or {}).get(app_key) or {}
marketing = app.get("fixedMarketingVersion") or app.get("marketingVersionDefault") or ""
print(app.get("bundleId") or "")
print(marketing)
print(app.get("appleId", ""))
PY
)
BUNDLE_ID="${_APP_META[0]:-}"
MARKETING="${_APP_META[1]:-}"
APPLE_ID="${_APP_META[2]:-}"
[[ -n "$BUNDLE_ID" && -n "$MARKETING" ]] || { echo "apps.json entry for ${APP_KEY} is incomplete" >&2; exit 2; }

# shellcheck source=scripts/ios-fleet/tf-ready-outcome.sh
source "${FLEET_DIR}/tf-ready-outcome.sh"

LOG_DIR="${TMPDIR:-/tmp}/ios-tf-recheck-${APP_KEY}-$$"
mkdir -p "$LOG_DIR"

set +e
if [[ -n "$APPLE_ID" ]]; then
  node "${FLEET_DIR}/asc-api.mjs" ensure-tf-ready "$BUNDLE_ID" "$BUILD_NUM" "$MARKETING" "$APPLE_ID" \
    >"${LOG_DIR}/ensure-tf-ready.json" 2>"${LOG_DIR}/ensure-tf-ready.err"
else
  node "${FLEET_DIR}/asc-api.mjs" ensure-tf-ready "$BUNDLE_ID" "$BUILD_NUM" "$MARKETING" \
    >"${LOG_DIR}/ensure-tf-ready.json" 2>"${LOG_DIR}/ensure-tf-ready.err"
fi
rc=$?
set -e

if [[ -s "${LOG_DIR}/ensure-tf-ready.err" ]]; then
  while IFS= read -r line; do
    [[ -n "$line" ]] && echo "tf-ready (post-sync): ${line}"
  done <"${LOG_DIR}/ensure-tf-ready.err"
fi

summary="$(tf_ready_rc_summary_label "$rc")"
echo "post-sync readiness for ${APP_KEY} (${BUNDLE_ID} build ${BUILD_NUM}): rc=${rc} — ${summary}"

if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  case "$rc" in
    0|3|4)
      ;;
    5|6|*)
      echo "::warning::Post-sync $(tf_ready_outcome_annotation "$rc" "$BUNDLE_ID" "$BUILD_NUM")"
      ;;
  esac
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "tf_ready_rc=${rc}"
    echo "tf_ready_summary=${summary}"
    echo "tf_ready_bundle=${BUNDLE_ID}"
    echo "tf_ready_build=${BUILD_NUM}"
  } >>"$GITHUB_OUTPUT"
fi

exit 0

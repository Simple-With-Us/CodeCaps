#!/usr/bin/env bash
# Offline checks for scripts/ios-recheck-tf-ready.sh (OPS-1052).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${ROOT}/scripts/ios-recheck-tf-ready.sh"

[[ -f "$SCRIPT" ]] || { echo "missing $SCRIPT"; exit 1; }

PASS=0
FAIL=0
ok() { echo "  ok  : $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

if bash -n "$SCRIPT"; then
  ok "bash -n ios-recheck-tf-ready.sh"
else
  bad "bash -n ios-recheck-tf-ready.sh"
fi

grep -q 'tf-ready-outcome.sh' "$SCRIPT" && ok "sources tf-ready-outcome.sh" || bad "sources tf-ready-outcome.sh"
grep -q 'tf_ready_rc_summary_label' "$SCRIPT" && ok "uses tf_ready_rc_summary_label" || bad "uses tf_ready_rc_summary_label"
grep -q 'GITHUB_OUTPUT' "$SCRIPT" && ok "writes GITHUB_OUTPUT" || bad "writes GITHUB_OUTPUT"
! grep -q 'GITHUB_STEP_SUMMARY' "$SCRIPT" && ok "does not write GITHUB_STEP_SUMMARY (workflow owns summary)" || bad "must not write GITHUB_STEP_SUMMARY"
grep -q "mapfile -t _APP_META" "$SCRIPT" && ok "reads app metadata via python heredoc" || bad "reads app metadata via python heredoc"
grep -q 'ensure-tf-ready' "$SCRIPT" && ok "calls ensure-tf-ready" || bad "calls ensure-tf-ready"

set +e
bash "$SCRIPT" 2>/dev/null
no_args_rc=$?
set -e
if [[ "$no_args_rc" -eq 2 ]]; then
  ok "missing build arg exits 2"
else
  bad "missing build arg exits 2 (got ${no_args_rc})"
fi

set +e
bash "$SCRIPT" codecaps not-a-build 2>/dev/null
bad_build_rc=$?
set -e
if [[ "$bad_build_rc" -eq 1 ]]; then
  ok "non-12-digit build exits 1"
else
  bad "non-12-digit build exits 1 (got ${bad_build_rc})"
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
export GITHUB_OUTPUT="${tmpdir}/output.txt"
export IOS_TF_READY_TIMEOUT_SEC=1
set +e
bash "$SCRIPT" codecaps 199901011200 2>/dev/null
run_rc=$?
set -e
[[ "$run_rc" -eq 0 ]] && ok "exits 0 after recheck (non-fatal to job)" || bad "exits 0 after recheck"
grep -q 'tf_ready_rc=' "$GITHUB_OUTPUT" && ok "GITHUB_OUTPUT has tf_ready_rc" || bad "GITHUB_OUTPUT has tf_ready_rc"
grep -q 'tf_ready_summary=' "$GITHUB_OUTPUT" && ok "GITHUB_OUTPUT has tf_ready_summary" || bad "GITHUB_OUTPUT has tf_ready_summary"
grep -vq 'tf_ready_summary=rc=' "$GITHUB_OUTPUT" && ok "summary label omits duplicate rc= prefix" || bad "summary label must not repeat rc= code"

set +e
bash "$SCRIPT" no-such-app 199901011200 2>/dev/null
missing_app_rc=$?
set -e
if [[ "$missing_app_rc" -eq 2 ]]; then
  ok "missing apps.json entry exits 2"
else
  bad "missing apps.json entry exits 2 (got ${missing_app_rc})"
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "all tests passed (${PASS} ok)"
  exit 0
fi
echo "${FAIL} test(s) failed, ${PASS} ok"
exit 1

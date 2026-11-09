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
grep -q 'GITHUB_STEP_SUMMARY' "$SCRIPT" && ok "writes GITHUB_STEP_SUMMARY" || bad "writes GITHUB_STEP_SUMMARY"
grep -q 'tf_ready_outcome_lines' "$SCRIPT" && ok "uses tf_ready_outcome_lines" || bad "uses tf_ready_outcome_lines"
grep -q 'tf_ready_outcome_annotation' "$SCRIPT" && ok "uses tf_ready_outcome_annotation" || bad "uses tf_ready_outcome_annotation"
grep -q 'ensure-tf-ready' "$SCRIPT" && ok "calls ensure-tf-ready" || bad "calls ensure-tf-ready"

set +e
bash "$SCRIPT" 2>/dev/null
no_build_rc=$?
set -e
if [[ "$no_build_rc" -eq 2 ]]; then
  ok "missing --build exits 2"
else
  bad "missing --build exits 2 (got ${no_build_rc})"
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
export GITHUB_STEP_SUMMARY="${tmpdir}/summary.md"
set +e
bash "$SCRIPT" --build 199901011200 2>/dev/null
run_rc=$?
set -e
[[ -f "$GITHUB_STEP_SUMMARY" ]] && ok "creates step summary file" || bad "creates step summary file"
grep -q 'ensure-tf-ready rc' "$GITHUB_STEP_SUMMARY" && ok "summary names rc" || bad "summary names rc"

if [[ "$FAIL" -eq 0 ]]; then
  echo "all tests passed (${PASS} ok)"
  exit 0
fi
echo "${FAIL} test(s) failed, ${PASS} ok"
exit 1

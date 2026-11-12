#!/usr/bin/env bash
# Add required status checks to CodeCaps ruleset 24433457.
#
# Dry-run unless --apply.  --apply refuses unless the Swift CI job names
# and gitleaks are already success on the default branch tip, so a starved or
# red Swift CI cannot become a gate that wedges every merge.
#
# Needs a token that can administer repository rulesets (GITHUB_TOKEN from
# Actions cannot).  The token is never printed.
#
#   scripts/apply-main-compile-gate-ruleset.sh
#   scripts/apply-main-compile-gate-ruleset.sh --apply

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="${REPO:-Simple-With-Us/CodeCaps}"
RULESET_ID="${RULESET_ID:-24433457}"
APPLY=0

if [[ "${1:-}" == "--apply" ]]; then
  APPLY=1
elif [[ -n "${1:-}" ]]; then
  echo "usage: $0 [--apply]" >&2
  exit 2
fi

[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
  echo "REPO is not owner/name" >&2
  exit 1
}

current="$(mktemp)"
updated="$(mktemp)"
trap 'rm -f "$current" "$updated"' EXIT

gh api "repos/${REPO}/rulesets/${RULESET_ID}" >"$current"
python3 "$ROOT/compile_gate_ruleset.py" --ruleset "$current" >"$updated"

echo "ruleset ${RULESET_ID} on ${REPO}"
python3 - "$current" "$updated" "$ROOT/compile_gate_ruleset.py" <<'PY'
import importlib.util
import json
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location("compile_gate_ruleset", sys.argv[3])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
current = json.loads(Path(sys.argv[1]).read_text())
updated = json.loads(Path(sys.argv[2]).read_text())
print("current contexts:", ", ".join(module.contexts_of(current)) or "(none)")
print("updated contexts:", ", ".join(module.contexts_of(updated)))
print("other rules kept:", ", ".join(
    rule.get("type") for rule in updated["rules"] if rule.get("type") != "required_status_checks"
))
PY

branch="$(gh api "repos/${REPO}" --jq .default_branch)"
sha="$(gh api "repos/${REPO}/commits/${branch}" --jq .sha)"
echo "default branch ${branch} @ ${sha}"

set +e
ONCE=1 REPO="$REPO" SHA="$sha" \
  bash "$ROOT/await-swift-ci-checks.sh" \
    "Mac package build and test" \
    "iOS companion compile" \
    "gitleaks"
checks=$?
set -e
if [[ "$checks" -eq 0 ]]; then
  echo "compile checks on ${branch} are success"
else
  echo "compile checks on ${branch} are not success (exit ${checks})"
fi

if [[ "$APPLY" -eq 0 ]]; then
  echo "dry-run only.  Re-run with --apply after those checks are success."
  exit 0
fi

if [[ "$checks" -ne 0 ]]; then
  echo "refusing --apply until Mac package build and test, iOS companion compile, and gitleaks are success on ${branch}" >&2
  exit 1
fi

gh api --method PUT "repos/${REPO}/rulesets/${RULESET_ID}" --input "$updated" \
  --jq '{id,name,enforcement,rule_types:[.rules[].type]}'
echo "updated ruleset ${RULESET_ID}"

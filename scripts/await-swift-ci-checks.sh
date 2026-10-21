#!/usr/bin/env bash
# Wait until the Swift CI compile checks on one commit have succeeded.
#
# Required environment:
#   REPO   GitHub owner/name
#   SHA    40-character commit
#   GH_TOKEN  token that can read check runs (unless CHECKS_JSON is set)
#
# Optional arguments:
#   check names to require.  The default is the Swift CI job names on main.
#   Names may contain spaces, so pass each as its own argument.
#
# Optional environment:
#   DEADLINE_SECONDS  how long to poll (default: 5100, just under 90 minutes)
#   POLL_SECONDS      delay between polls (default: 30)
#   ONCE              if 1, decide from one fetch and do not poll
#   CHECKS_JSON       one-shot fixture path; skips the network
#   REDISPATCH_ON_CANCEL  if 1, a cancelled compile run is replaced by a
#                       fresh dispatch of the compile workflow on the same
#                       commit, instead of the gate waiting for a run that
#                       will never arrive (default: 0)
#   REDISPATCH_WORKFLOW  the workflow file to dispatch (default: swift-ci.yml)
#   MAX_REDISPATCH    how many replacements to dispatch (default: 3)
#
# Exit 0 when every named check's newest github-actions run succeeded.
# Exit 1 on a failed, skipped, or cancelled check, or on timeout.
# Exit 2 when ONCE or CHECKS_JSON sees a check that has not finished.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="${REPO:-}"
SHA="${SHA:-}"
DEADLINE_SECONDS="${DEADLINE_SECONDS:-5100}"
POLL_SECONDS="${POLL_SECONDS:-30}"
ONCE="${ONCE:-0}"
REDISPATCH_ON_CANCEL="${REDISPATCH_ON_CANCEL:-0}"
REDISPATCH_WORKFLOW="${REDISPATCH_WORKFLOW:-swift-ci.yml}"
MAX_REDISPATCH="${MAX_REDISPATCH:-3}"
redispatches=0
if [[ $# -gt 0 ]]; then
  CHECK_NAMES=("$@")
else
  CHECK_NAMES=(
    "Mac package build and test"
    "iOS companion compile"
  )
fi

die() {
  echo "await-swift-ci-checks: $*" >&2
  exit 1
}

[[ -n "$REPO" || -n "${CHECKS_JSON:-}" ]] || die "REPO is required"
[[ -n "$SHA" || -n "${CHECKS_JSON:-}" ]] || die "SHA is required"
if [[ -z "${CHECKS_JSON:-}" ]]; then
  [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "REPO is not owner/name"
  [[ "$SHA" =~ ^[0-9a-fA-F]{40}$ ]] || die "SHA is not a 40-character commit"
  if [[ -z "${GH_TOKEN:-}" ]]; then
    gh auth status >/dev/null 2>&1 || die "GH_TOKEN is required"
  fi
fi
for name in "${CHECK_NAMES[@]}"; do
  [[ "$name" =~ ^[A-Za-z0-9_.\ -]+$ ]] || die "check name has an unexpected character: ${name}"
done

decide() {
  python3 "$ROOT/swift_ci_check_status.py" --names "${CHECK_NAMES[@]}" --json "$@"
}

if [[ -n "${CHECKS_JSON:-}" ]]; then
  decide "$CHECKS_JSON"
  exit $?
fi

deadline=$(( $(date +%s) + DEADLINE_SECONDS ))
details="$(mktemp)"
trap 'rm -f "$details"' EXIT
while true; do
  files=()
  for name in "${CHECK_NAMES[@]}"; do
    payload="$(mktemp)"
    files+=("$payload")
    encoded="$(python3 -c 'import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$name")"
    gh api "repos/${REPO}/commits/${SHA}/check-runs?check_name=${encoded}&per_page=100" >"$payload"
  done
  set +e
  verdict="$(decide "${files[@]}" 2>"$details")"
  code=$?
  set -e
  rm -f "${files[@]}"
  if [[ "$code" -eq 0 ]]; then
    echo "Swift CI checks succeeded on ${SHA}: ${CHECK_NAMES[*]}"
    exit 0
  fi
  if [[ "$code" -eq 1 ]]; then
    echo "::error::Swift CI checks failed on ${SHA}: ${verdict}"
    exit 1
  fi
  if [[ "$code" -ne 2 ]]; then
    echo "::error::Could not read Swift CI checks on ${SHA} (exit ${code})"
    exit 1
  fi
  if [[ "$ONCE" == "1" || "$(date +%s)" -ge "$deadline" ]]; then
    if [[ "$ONCE" == "1" ]]; then
      echo "Swift CI checks still pending on ${SHA}: ${verdict}" >&2
      exit 2
    fi
    echo "::error::Timed out after ${DEADLINE_SECONDS}s waiting for Swift CI on ${SHA}: ${verdict}"
    exit 1
  fi
  # A cancelled run never finished, so it is no verdict at all about the
  # code.  Waiting for a run that will never arrive only wastes the window
  # the release has, so dispatch a replacement on the same commit instead.
  if [[ "$code" -eq 2 && "$REDISPATCH_ON_CANCEL" == "1" ]] \
    && [[ "$redispatches" -lt "$MAX_REDISPATCH" ]] \
    && grep -q "=cancelled" "$details"; then
    redispatches=$(( redispatches + 1 ))
    echo "::notice title=Swift CI cancelled::the compile run on ${SHA} was cancelled before it finished.  Dispatching a replacement (${redispatches} of ${MAX_REDISPATCH})."
    if gh api --method POST \
      "repos/${REPO}/actions/workflows/${REDISPATCH_WORKFLOW}/dispatches" \
      -f ref="$SHA" >/dev/null 2>&1; then
      echo "dispatched ${REDISPATCH_WORKFLOW} on ${SHA}"
    else
      echo "::warning title=Swift CI cancelled::the replacement compile run could not be dispatched; the gate keeps waiting for a run to appear."
    fi
  fi
  echo "Waiting for Swift CI on ${SHA}: ${verdict}"
  sleep "$POLL_SECONDS"
done

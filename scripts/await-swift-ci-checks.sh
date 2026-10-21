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
#   REDISPATCH_ON_CANCEL  if 1, a cancelled compile run is pending rather than
#                       a failure, and the gate replaces it by re-running the
#                       workflow run it belonged to.  The re-run keeps the
#                       commit exact, which a fresh dispatch cannot:  the
#                       dispatch endpoint takes a branch or tag name and
#                       rejects a commit sha with "No ref found".  With the
#                       flag off a cancelled run is a failure and the gate
#                       says so at once (default: 0)
#   MAX_REDISPATCH    how many replacements to run (default: 3).  It also
#                       bounds the failed attempts, so a token without
#                       actions: write cannot turn the gate into a loop.
#
# Exit 0 when every named check's newest github-actions run succeeded.
# Exit 1 on a failed or skipped check, on a timeout, and on a cancelled
#          check when REDISPATCH_ON_CANCEL is 0.
# Exit 2 when ONCE or CHECKS_JSON sees a check that has not finished.  With
#          REDISPATCH_ON_CANCEL=1 a cancelled check is also exit 2: it waits
#          for its replacement.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="${REPO:-}"
SHA="${SHA:-}"
DEADLINE_SECONDS="${DEADLINE_SECONDS:-5100}"
POLL_SECONDS="${POLL_SECONDS:-30}"
ONCE="${ONCE:-0}"
REDISPATCH_ON_CANCEL="${REDISPATCH_ON_CANCEL:-0}"
MAX_REDISPATCH="${MAX_REDISPATCH:-3}"
redispatches=0
redispatch_failures=0
budget_notice=0
if [[ $# -gt 0 ]]; then
  CHECK_NAMES=("$@")
else
  CHECK_NAMES=(
    "Mac package build and test"
    "iOS companion compile"
  )
fi
# The check run id of the cancelled row each name was last replaced at.
# A replacement only earns a new attempt when the cancelled row it sees is
# newer than that, so a replacement that has not shown up in the API yet
# cannot spend the whole budget before any replacement run exists.
floor_ids=()
for _name in "${CHECK_NAMES[@]}"; do
  floor_ids+=("0")
done

die() {
  echo "await-swift-ci-checks: $*" >&2
  exit 1
}

# The detail lines of the last classification, on one line.
join_details() {
  local first=1 line summary=""
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if [[ "$first" -eq 1 ]]; then
      summary="$line"
      first=0
    else
      summary="${summary}, ${line}"
    fi
  done < "$1"
  printf '%s' "$summary"
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
  if [[ "$REDISPATCH_ON_CANCEL" == "1" ]]; then
    python3 "$ROOT/swift_ci_check_status.py" --names "${CHECK_NAMES[@]}" \
      --redispatch-on-cancel --json "$@"
  else
    python3 "$ROOT/swift_ci_check_status.py" --names "${CHECK_NAMES[@]}" --json "$@"
  fi
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
  runs="$(python3 "$ROOT/swift_ci_check_status.py" --names "${CHECK_NAMES[@]}" \
    --json "${files[@]}" --latest-runs)"
  runs_code=$?
  set -e
  rm -f "${files[@]}"
  if [[ "$runs_code" -ne 0 ]]; then
    echo "::error::Could not read the Swift CI check run ids on ${SHA} (exit ${runs_code})"
    exit 1
  fi
  # One line per requested name: name, check run id, workflow run id.
  check_ids=()
  workflow_run_ids=()
  while IFS=$'\t' read -r _name check_id workflow_run_id; do
    [[ -n "$_name" ]] || continue
    check_ids+=("$check_id")
    workflow_run_ids+=("$workflow_run_id")
  done <<<"$runs"
  if [[ "$code" -eq 0 ]]; then
    echo "Swift CI checks succeeded on ${SHA}: ${CHECK_NAMES[*]}"
    exit 0
  fi
  if [[ "$code" -eq 1 ]]; then
    summary="$(join_details "$details")"
    if [[ "$REDISPATCH_ON_CANCEL" != "1" ]] && grep -Fq "=cancelled" "$details"; then
      echo "::error::Swift CI checks failed on ${SHA}: ${summary}.  Re-dispatch is off (REDISPATCH_ON_CANCEL=${REDISPATCH_ON_CANCEL}), so the gate fails here instead of waiting for a run that will never arrive."
      exit 1
    fi
    echo "::error::Swift CI checks failed on ${SHA}: ${summary}"
    exit 1
  fi
  if [[ "$code" -ne 2 ]]; then
    echo "::error::Could not read Swift CI checks on ${SHA} (exit ${code})"
    exit 1
  fi
  summary="$(join_details "$details")"
  if [[ "$ONCE" == "1" || "$(date +%s)" -ge "$deadline" ]]; then
    if [[ "$ONCE" == "1" ]]; then
      echo "Swift CI checks still pending on ${SHA}: ${summary}" >&2
      exit 2
    fi
    if [[ "$redispatches" -gt 0 ]]; then
      echo "::error::Timed out after ${DEADLINE_SECONDS}s waiting for Swift CI on ${SHA}: ${summary} (${redispatches} replacement run(s) dispatched)"
    else
      echo "::error::Timed out after ${DEADLINE_SECONDS}s waiting for Swift CI on ${SHA}: ${summary}"
    fi
    exit 1
  fi
  # A cancelled run never finished, so it is no verdict at all about the
  # code.  Waiting for a run that will never arrive only wastes the window
  # the release has, so replace it by re-running the workflow run it
  # belonged to:  the re-run keeps the commit exact.
  if [[ "$code" -eq 2 && "$REDISPATCH_ON_CANCEL" == "1" ]] \
    && grep -Fq "=cancelled" "$details"; then
    # Only a cancelled row that is newer than the one this gate already
    # replaced earns another attempt:  the replacement may not have shown
    # up in the API yet, and a second attempt against the same stale row
    # spends the whole budget before any replacement run exists.
    eligible_name=""
    eligible_run_id=0
    index=0
    for name in "${CHECK_NAMES[@]}"; do
      check_id="${check_ids[index]:-0}"
      if [[ "$check_id" -gt "${floor_ids[index]:-0}" ]] \
        && grep -Fxq "${name}=cancelled" "$details"; then
        eligible_name="$name"
        eligible_run_id="${workflow_run_ids[index]:-0}"
        break
      fi
      index=$(( index + 1 ))
    done
    if [[ -n "$eligible_name" ]]; then
      if [[ "$redispatch_failures" -ge "$MAX_REDISPATCH" ]]; then
        echo "::error::the replacement compile run could not be started after ${redispatch_failures} attempts; the ${eligible_name} run on ${SHA} is still cancelled and no replacement was created, so the gate fails instead of waiting for a run that will never arrive."
        exit 1
      fi
      if [[ "$redispatches" -ge "$MAX_REDISPATCH" ]]; then
        if [[ "$budget_notice" -eq 0 ]]; then
          budget_notice=1
          echo "::notice title=Swift CI cancelled::the ${eligible_name} run on ${SHA} was cancelled and the replacement budget (${MAX_REDISPATCH}) is spent; the gate keeps waiting for a run to appear."
        fi
      elif [[ "$eligible_run_id" -eq 0 ]]; then
        redispatch_failures=$(( redispatch_failures + 1 ))
        echo "::warning title=Swift CI cancelled::the ${eligible_name} run on ${SHA} was cancelled, but its workflow run is unknown, so no replacement can be started (${redispatch_failures} failed attempt(s)); no budget was spent and the gate keeps waiting for a run to appear."
      elif gh api --method POST \
        "repos/${REPO}/actions/runs/${eligible_run_id}/rerun" >/dev/null 2>&1; then
        redispatches=$(( redispatches + 1 ))
        redispatch_failures=0
        echo "started a replacement compile run for ${eligible_name} on ${SHA} by re-running workflow run ${eligible_run_id} (${redispatches} of ${MAX_REDISPATCH})"
        # The re-run restarts every job of that workflow run, so every
        # cancelled row on the board right now is covered by it.
        index=0
        for name in "${CHECK_NAMES[@]}"; do
          if grep -Fxq "${name}=cancelled" "$details"; then
            floor_ids[index]="${check_ids[index]:-0}"
          fi
          index=$(( index + 1 ))
        done
      else
        redispatch_failures=$(( redispatch_failures + 1 ))
        echo "::warning title=Swift CI cancelled::the replacement compile run could not be started (${redispatch_failures} failed attempt(s)); no replacement run was created and no budget was spent, so the gate keeps waiting for a run to appear."
      fi
    fi
  fi
  echo "Waiting for Swift CI on ${SHA}: ${summary}"
  sleep "$POLL_SECONDS"
done

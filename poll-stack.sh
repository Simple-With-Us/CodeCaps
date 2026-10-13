#!/usr/bin/env bash
set -u
REPO=Simple-With-Us/CodeCaps
LOG=/workspace/codecaps-stack/poll.log
DEADLINE=$(( $(date +%s) + 7200 ))
echo "poll start $(date -Iseconds) deadline=$(date -d @$DEADLINE -Iseconds)" | tee "$LOG"

merge_if_ready() {
  local pr=$1
  local json
  json=$(gh pr view "$pr" --repo "$REPO" --json state,isDraft,mergeable,mergeStateStatus,headRefOid,statusCheckRollup 2>/dev/null) || return 1
  local state isDraft mergeable mss head
  state=$(echo "$json" | jq -r .state)
  isDraft=$(echo "$json" | jq -r .isDraft)
  mergeable=$(echo "$json" | jq -r .mergeable)
  mss=$(echo "$json" | jq -r .mergeStateStatus)
  head=$(echo "$json" | jq -r .headRefOid)
  if [[ "$state" == "MERGED" ]]; then
    local sha
    sha=$(gh pr view "$pr" --repo "$REPO" --json mergeCommit --jq .mergeCommit.oid)
    echo "PR #$pr MERGED $sha" | tee -a "$LOG"
    echo "$sha"
    return 0
  fi
  local failing pending success
  failing=$(echo "$json" | jq '[.statusCheckRollup[] | select(.conclusion=="FAILURE" or .conclusion=="CANCELLED" or .conclusion=="TIMED_OUT")] | length')
  pending=$(echo "$json" | jq '[.statusCheckRollup[] | select(.status!="COMPLETED")] | length')
  # required: package, companion, gitleaks success (Kody optional if skipped)
  local pkg comp git
  pkg=$(echo "$json" | jq -r '[.statusCheckRollup[] | select(.name=="package") | .conclusion] | last // "MISSING"')
  comp=$(echo "$json" | jq -r '[.statusCheckRollup[] | select(.name=="companion") | .conclusion] | last // "MISSING"')
  git=$(echo "$json" | jq -r '[.statusCheckRollup[] | select(.name=="gitleaks") | .conclusion] | last // "MISSING"')
  local threads
  threads=$(gh api graphql -f query="query { repository(owner:\"Simple-With-Us\", name:\"CodeCaps\") { pullRequest(number:$pr) { reviewThreads(first:50) { nodes { isResolved } } } } }" --jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved==false)] | length')
  echo "PR #$pr draft=$isDraft mergeable=$mergeable mss=$mss pkg=$pkg comp=$comp git=$git pending=$pending failChecks=$failing threads=$threads head=${head:0:8}" | tee -a "$LOG"
  if [[ "$pkg" != "SUCCESS" || "$comp" != "SUCCESS" || "$git" != "SUCCESS" ]]; then
    return 2
  fi
  if [[ "$threads" != "0" ]]; then
    echo "PR #$pr blocked: $threads unresolved threads" | tee -a "$LOG"
    return 3
  fi
  if [[ "$mergeable" != "MERGEABLE" ]]; then
    return 4
  fi
  if [[ "$isDraft" == "true" ]]; then
    gh pr ready "$pr" --repo "$REPO" 2>&1 | tee -a "$LOG" || true
  fi
  # re-fetch head in case ready changed nothing
  head=$(gh pr view "$pr" --repo "$REPO" --json headRefOid --jq .headRefOid)
  echo "Merging #$pr at $head" | tee -a "$LOG"
  if gh pr merge "$pr" --repo "$REPO" --squash --match-head-commit "$head" 2>&1 | tee -a "$LOG"; then
    sleep 5
    local sha
    sha=$(gh pr view "$pr" --repo "$REPO" --json mergeCommit --jq .mergeCommit.oid)
    echo "PR #$pr MERGED $sha" | tee -a "$LOG"
    echo "$sha"
    return 0
  fi
  return 5
}

# Phase 1: shepherd #226
while (( $(date +%s) < DEADLINE )); do
  state=$(gh pr view 226 --repo "$REPO" --json state --jq .state)
  if [[ "$state" == "MERGED" ]]; then
    echo "226 already merged $(gh pr view 226 --repo $REPO --json mergeCommit --jq .mergeCommit.oid)" | tee -a "$LOG"
    break
  fi
  out=$(merge_if_ready 226); rc=$?
  if [[ $rc -eq 0 ]]; then break; fi
  # if package failed on latest head after our fix, stop for 226
  head=$(gh pr view 226 --repo "$REPO" --json headRefOid --jq .headRefOid)
  pkg_fail=$(gh pr view 226 --repo "$REPO" --json statusCheckRollup --jq --arg h "$head" '[.statusCheckRollup[] | select(.name=="package" and .conclusion=="FAILURE")] | length')
  # Only treat as hard fail if package completed FAILURE and companion completed (run done)
  pkg=$(gh pr view 226 --repo "$REPO" --json statusCheckRollup --jq '[.statusCheckRollup[] | select(.name=="package") | {status,conclusion}] | last')
  if echo "$pkg" | jq -e '.status=="COMPLETED" and .conclusion=="FAILURE"' >/dev/null 2>&1; then
    # verify it's for current head by checking latest run
    echo "package FAILURE on current rollup — will keep polling briefly in case of new push" | tee -a "$LOG"
    # check if head matches our known fix tip; if CI failed on 03d1f75, hard stop
    run_sha=$(gh run list --repo "$REPO" --branch cursor/quota-vocabulary-pr1-6ec3 --workflow "Swift CI" --limit 1 --json headSha,conclusion --jq '.[0] | "\(.headSha) \(.conclusion)"')
    echo "latest Swift CI: $run_sha" | tee -a "$LOG"
    if [[ "$run_sha" == "$head FAILURE" || "$run_sha" == "$head failure" ]]; then
      echo "HARD BLOCK #226 package failed on tip $head" | tee -a "$LOG"
      echo "BLOCKED_226=$head" > /workspace/codecaps-stack/result.env
      exit 10
    fi
  fi
  sleep 90
done

# After #226 merged: retarget #229 to main, update-branch
if [[ "$(gh pr view 226 --repo $REPO --json state --jq .state)" != "MERGED" ]]; then
  echo "STOP: #226 not merged by deadline" | tee -a "$LOG"
  echo "BLOCKED_226=timeout" > /workspace/codecaps-stack/result.env
  exit 11
fi
echo "226_SHA=$(gh pr view 226 --repo $REPO --json mergeCommit --jq .mergeCommit.oid)" | tee /workspace/codecaps-stack/result.env

# Retarget 229 if needed
base229=$(gh pr view 229 --repo "$REPO" --json baseRefName --jq .baseRefName)
if [[ "$base229" != "main" ]]; then
  echo "Retargeting #229 base $base229 -> main" | tee -a "$LOG"
  gh api -X PATCH "repos/$REPO/pulls/229" -f base=main 2>&1 | tee -a "$LOG" | tail -5
fi
echo "update-branch #229" | tee -a "$LOG"
gh api -X PUT "repos/$REPO/pulls/229/update-branch" 2>&1 | tee -a "$LOG" || true
# nudge kody
gh pr comment 229 --repo "$REPO" --body "@kody start-review" 2>&1 | tee -a "$LOG" || true

while (( $(date +%s) < DEADLINE )); do
  state=$(gh pr view 229 --repo "$REPO" --json state --jq .state)
  if [[ "$state" == "MERGED" ]]; then break; fi
  # conflict?
  mergeable=$(gh pr view 229 --repo "$REPO" --json mergeable --jq .mergeable)
  if [[ "$mergeable" == "CONFLICTING" ]]; then
    echo "HARD BLOCK #229 CONFLICTING" | tee -a "$LOG"
    echo "BLOCKED_229=conflict" >> /workspace/codecaps-stack/result.env
    exit 12
  fi
  out=$(merge_if_ready 229); rc=$?
  if [[ $rc -eq 0 ]]; then break; fi
  pkg=$(gh pr view 229 --repo "$REPO" --json statusCheckRollup --jq '[.statusCheckRollup[] | select(.name=="package") | {status,conclusion}] | last')
  head=$(gh pr view 229 --repo "$REPO" --json headRefOid --jq .headRefOid)
  if echo "$pkg" | jq -e '.status=="COMPLETED" and .conclusion=="FAILURE"' >/dev/null 2>&1; then
    run_sha=$(gh run list --repo "$REPO" --branch cursor/mac-quota-surfaces-pr2-6ec3 --workflow "Swift CI" --limit 1 --json headSha,conclusion --jq '.[0] | "\(.headSha) \(.conclusion)"')
    echo "latest #229 Swift CI: $run_sha" | tee -a "$LOG"
    # allow time for update-branch to trigger new runs
    sleep 120
    pkg2=$(gh pr view 229 --repo "$REPO" --json statusCheckRollup --jq '[.statusCheckRollup[] | select(.name=="package") | {status,conclusion}] | last')
    head2=$(gh pr view 229 --repo "$REPO" --json headRefOid --jq .headRefOid)
    if [[ "$head2" == "$head" ]] && echo "$pkg2" | jq -e '.status=="COMPLETED" and .conclusion=="FAILURE"' >/dev/null 2>&1; then
      echo "HARD BLOCK #229 package failed on tip $head2" | tee -a "$LOG"
      echo "BLOCKED_229=$head2" >> /workspace/codecaps-stack/result.env
      exit 13
    fi
  fi
  sleep 90
done

if [[ "$(gh pr view 229 --repo $REPO --json state --jq .state)" != "MERGED" ]]; then
  echo "STOP: #229 not merged by deadline" | tee -a "$LOG"
  echo "BLOCKED_229=timeout" >> /workspace/codecaps-stack/result.env
  exit 14
fi
echo "229_SHA=$(gh pr view 229 --repo $REPO --json mergeCommit --jq .mergeCommit.oid)" | tee -a /workspace/codecaps-stack/result.env

# Retarget 227 — base was ios-widgets-pr3; after 228/229 land, target main
base227=$(gh pr view 227 --repo "$REPO" --json baseRefName --jq .baseRefName)
if [[ "$base227" != "main" ]]; then
  echo "Retargeting #227 base $base227 -> main" | tee -a "$LOG"
  gh api -X PATCH "repos/$REPO/pulls/227" -f base=main 2>&1 | tee -a "$LOG" | tail -5
fi
echo "update-branch #227" | tee -a "$LOG"
gh api -X PUT "repos/$REPO/pulls/227/update-branch" 2>&1 | tee -a "$LOG" || true
gh pr comment 227 --repo "$REPO" --body "@kody start-review" 2>&1 | tee -a "$LOG" || true

while (( $(date +%s) < DEADLINE )); do
  state=$(gh pr view 227 --repo "$REPO" --json state --jq .state)
  if [[ "$state" == "MERGED" ]]; then break; fi
  mergeable=$(gh pr view 227 --repo "$REPO" --json mergeable --jq .mergeable)
  if [[ "$mergeable" == "CONFLICTING" ]]; then
    echo "HARD BLOCK #227 CONFLICTING" | tee -a "$LOG"
    echo "BLOCKED_227=conflict" >> /workspace/codecaps-stack/result.env
    exit 15
  fi
  out=$(merge_if_ready 227); rc=$?
  if [[ $rc -eq 0 ]]; then break; fi
  pkg=$(gh pr view 227 --repo "$REPO" --json statusCheckRollup --jq '[.statusCheckRollup[] | select(.name=="package") | {status,conclusion}] | last')
  head=$(gh pr view 227 --repo "$REPO" --json headRefOid --jq .headRefOid)
  if echo "$pkg" | jq -e '.status=="COMPLETED" and .conclusion=="FAILURE"' >/dev/null 2>&1; then
    sleep 120
    pkg2=$(gh pr view 227 --repo "$REPO" --json statusCheckRollup --jq '[.statusCheckRollup[] | select(.name=="package") | {status,conclusion}] | last')
    head2=$(gh pr view 227 --repo "$REPO" --json headRefOid --jq .headRefOid)
    if [[ "$head2" == "$head" ]] && echo "$pkg2" | jq -e '.status=="COMPLETED" and .conclusion=="FAILURE"' >/dev/null 2>&1; then
      echo "HARD BLOCK #227 package failed on tip $head2" | tee -a "$LOG"
      echo "BLOCKED_227=$head2" >> /workspace/codecaps-stack/result.env
      exit 16
    fi
  fi
  sleep 90
done

if [[ "$(gh pr view 227 --repo $REPO --json state --jq .state)" != "MERGED" ]]; then
  echo "STOP: #227 not merged by deadline" | tee -a "$LOG"
  echo "BLOCKED_227=timeout" >> /workspace/codecaps-stack/result.env
  exit 17
fi
echo "227_SHA=$(gh pr view 227 --repo $REPO --json mergeCommit --jq .mergeCommit.oid)" | tee -a /workspace/codecaps-stack/result.env
echo "STACK_DONE $(date -Iseconds)" | tee -a "$LOG"
exit 0

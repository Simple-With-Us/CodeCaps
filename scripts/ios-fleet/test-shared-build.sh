#!/usr/bin/env bash
# test-shared-build.sh - Offline tests for the shared merge-timestamp build
# planning (scripts/ios-fleet/ship-testflight.sh asc_next_shared_build and
# asc_this_platform_max).
#
# Covers:
#   1. whitespace-padded <sparkle:version> values join the plan
#   2. a non-https pairedBuildFeed is refused before curl runs
#   3. a feed floor that is not a 1..18 digit integer >= 1 fails closed with
#      the URL named (and 9999, once capped, now joins the plan)
#   4. a configured feed with zero numeric versions fails closed with a message
#   5. a macOS entry with no forward pairing is matched by reverse lookup
#   6. the merge stamp is the committer date of HEAD in America/Chicago
#   7. a fixed --build is accepted only above this platform's max, so the
#      paired platform can reuse the planned value
#   8. the curl invocation is hardened and the max uses POSIX tools
#
# Everything here is offline: no network, no credentials, no App Store
# Connect, no xcodebuild.  curl and asc_client are stubbed, and the merge
# stamp comes from a temp git repo with a fixed committer date.
#
# Usage: bash scripts/ios-fleet/test-shared-build.sh
#
# ASCII-only (Apple bash 3.2 safe).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SHIP="${SCRIPT_DIR}/ship-testflight.sh"
[[ -f "$SHIP" ]] || { echo "missing $SHIP"; exit 1; }

PASS=0
FAIL=0
check() {
  if [[ "$2" == "$3" ]]; then
    echo "  ok  : $1"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $1 (expected '$2', got '$3')"
    FAIL=$((FAIL + 1))
  fi
}
contains() {
  if [[ "$3" == *"$2"* ]]; then
    echo "  ok  : $1"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $1 (missing '$2' in: $3)"
    FAIL=$((FAIL + 1))
  fi
}
lacks() {
  if [[ "$3" != *"$2"* ]]; then
    echo "  ok  : $1"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $1 (unexpectedly contains '$2')"
    FAIL=$((FAIL + 1))
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Extract the helpers and their dependencies from the ship script, the way
# test-asc-credentials.sh does, so the test drives the real code.
FUNCS="${TMP}/funcs.sh"
{
  echo 'log() { echo "[ios-ship] $*"; }'
  echo 'logerr() { echo "[ios-ship] $*" >&2; }'
  echo "FLEET_DIR=\"${SCRIPT_DIR}\""
  echo 'ASC_NODE="node"'
  echo 'FLEET_SECRETS_BIN="/nonexistent-fleet-secrets"'
  awk '
    /^json_get\(\) \{/ || /^json_paired_reverse\(\) \{/ || /^asc_credential_available\(\) \{/ || /^asc_client\(\) \{/ || /^merge_stamp\(\) \{/ || /^build_num_gt\(\) \{/ || /^asc_next_shared_build\(\) \{/ || /^asc_this_platform_max\(\) \{/ { grab = 1 }
    grab { print }
    grab && /^\}/ { grab = 0 }
  ' "$SHIP"
} > "$FUNCS"
grep -q '^asc_next_shared_build()' "$FUNCS" || { echo "FAIL: asc_next_shared_build not found"; exit 1; }
grep -q '^asc_this_platform_max()' "$FUNCS" || { echo "FAIL: asc_this_platform_max not found"; exit 1; }
grep -q '^json_paired_reverse()' "$FUNCS" || { echo "FAIL: json_paired_reverse not found"; exit 1; }
grep -q '^merge_stamp()' "$FUNCS" || { echo "FAIL: merge_stamp not found"; exit 1; }
grep -q '^build_num_gt()' "$FUNCS" || { echo "FAIL: build_num_gt not found"; exit 1; }

# Fake curl: records its argv, prints the XML from $FAKE_FEED_XML, exits $FAKE_CURL_RC.
BIN="${TMP}/bin"
mkdir -p "$BIN"
cat > "${BIN}/curl" <<'FAKECURL'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_CURL_LOG}"
if [[ "${FAKE_CURL_RC:-0}" -ne 0 ]]; then
  exit "${FAKE_CURL_RC}"
fi
printf '%s' "${FAKE_FEED_XML:-}"
FAKECURL
chmod +x "${BIN}/curl"
export PATH="${BIN}:${PATH}"
export FAKE_CURL_LOG="${TMP}/curl.log"
: > "$FAKE_CURL_LOG"

# A temp git repo with a fixed committer date, so the merge stamp is
# deterministic: 2026-10-29 09:30 Chicago time is stamp 202610290930.
STAMP_REPO="${TMP}/stamp-repo"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
git init -q "$STAMP_REPO"
GIT_COMMITTER_DATE="2026-10-29T09:30:00-05:00" git -C "$STAMP_REPO" commit -q --allow-empty \
  --date="2026-10-29T09:30:00-05:00" -m seed
unset GIT_COMMITTER_DATE

# Run asc_next_shared_build with a stubbed credential check and ASC client.
# Args: <apps.json> <app_key> <bundle_id> <platform> ; stdout=build, stderr=log.
run_helper() {
  local apps_json="$1" app_key="$2" bundle_id="$3" platform="$4"
  local asc_log="${TMP}/asc_args.txt"
  rm -f "$asc_log"
  APPS_JSON="$apps_json" APP_KEY="$app_key" BUNDLE_ID="$bundle_id" PLATFORM="$platform" \
    REPO_ROOT="$STAMP_REPO" ASC_PLATFORM="" ASC_LOG="$asc_log" FUNCS_PATH="$FUNCS" bash -c '
    set -uo pipefail
    # shellcheck source=/dev/null
    source "$FUNCS_PATH"
    asc_credential_available() { return 0; }
    asc_client() {
      printf "%s\n" "$*" > "$ASC_LOG"
      printf "202610290935"
      return 0
    }
    asc_next_shared_build
  '
}

# Run asc_this_platform_max with a stubbed client that prints $STUB_MAX and
# exits $STUB_RC.  Args: <bundle_id> <asc_platform> ; stdout=max, stderr=log.
run_max_helper() {
  local bundle_id="$1" asc_platform="$2"
  local asc_log="${TMP}/max_args.txt"
  rm -f "$asc_log"
  BUNDLE_ID="$bundle_id" ASC_PLATFORM="$asc_platform" \
    ASC_LOG="$asc_log" FUNCS_PATH="$FUNCS" STUB_MAX="$STUB_MAX" STUB_RC="${STUB_RC:-0}" bash -c '
    set -uo pipefail
    # shellcheck source=/dev/null
    source "$FUNCS_PATH"
    asc_credential_available() { return 0; }
    asc_client() {
      printf "%s\n" "$*" > "$ASC_LOG"
      printf "%s" "$STUB_MAX"
      return "$STUB_RC"
    }
    asc_this_platform_max
  '
}

echo "== whitespace-padded sparkle versions join the plan =="
cat > "${TMP}/apps-ws.json" <<'JSON'
{"apps": {"wsapp": {"bundleId": "com.example.ws", "platform": "iOS", "pairedBuildFeed": "https://example.com/appcast.xml"}}}
JSON
export FAKE_FEED_XML='<rss><channel><item><sparkle:version>  1400  </sparkle:version></item><item><sparkle:version>	1502	</sparkle:version></item></channel></rss>'
export FAKE_CURL_RC=0
: > "$FAKE_CURL_LOG"
WS_ERR="${TMP}/ws.err"
WS_OUT="$(run_helper "${TMP}/apps-ws.json" wsapp com.example.ws iOS 2>"$WS_ERR")"
WS_RC=$?
check "whitespace feed returns the stub build" "202610290935" "$WS_OUT"
check "whitespace feed exits 0" "0" "$WS_RC"
WS_ASC="$(cat "${TMP}/asc_args.txt" 2>/dev/null || true)"
contains "whitespace max 1502 reaches the client as floor" "1502" "$WS_ASC"
contains "the merge stamp reaches the client" "--merge-stamp 202610290930" "$WS_ASC"
contains "the plan command is plan-release-build" "plan-release-build com.example.ws" "$WS_ASC"

echo "== non-https feed is refused before curl runs =="
cat > "${TMP}/apps-http.json" <<'JSON'
{"apps": {"httpapp": {"bundleId": "com.example.http", "platform": "iOS", "pairedBuildFeed": "http://example.com/appcast.xml"}}}
JSON
: > "$FAKE_CURL_LOG"
rm -f "${TMP}/asc_args.txt"
HTTP_ERR="${TMP}/http.err"
HTTP_OUT="$(run_helper "${TMP}/apps-http.json" httpapp com.example.http iOS 2>"$HTTP_ERR")"
HTTP_RC=$?
check "non-https feed exits 1" "1" "$HTTP_RC"
check "non-https feed prints no build" "" "$HTTP_OUT"
HTTP_LOG="$(cat "$HTTP_ERR")"
contains "non-https rejection names the URL" "http://example.com/appcast.xml" "$HTTP_LOG"
contains "non-https rejection says why" "non-https" "$HTTP_LOG"
if [[ -s "$FAKE_CURL_LOG" ]]; then
  echo "  FAIL: curl ran for a non-https feed ($(cat "$FAKE_CURL_LOG"))"
  FAIL=$((FAIL + 1))
else
  echo "  ok  : curl never ran for a non-https feed"
  PASS=$((PASS + 1))
fi
if [[ -f "${TMP}/asc_args.txt" ]]; then
  echo "  FAIL: ASC client ran for a non-https feed"
  FAIL=$((FAIL + 1))
else
  echo "  ok  : ASC client never ran for a non-https feed"
  PASS=$((PASS + 1))
fi

echo "== out-of-range floor fails closed, capped values now join =="
cat > "${TMP}/apps-range.json" <<'JSON'
{"apps": {"rangeapp": {"bundleId": "com.example.range", "platform": "iOS", "pairedBuildFeed": "https://example.com/range.xml"}}}
JSON
export FAKE_FEED_XML='<rss><channel><item><sparkle:version>1234567890123456789</sparkle:version></item></channel></rss>'
export FAKE_CURL_RC=0
rm -f "${TMP}/asc_args.txt"
RANGE_ERR="${TMP}/range.err"
RANGE_OUT="$(run_helper "${TMP}/apps-range.json" rangeapp com.example.range iOS 2>"$RANGE_ERR")"
RANGE_RC=$?
check "19-digit floor exits 1" "1" "$RANGE_RC"
check "19-digit floor prints no build" "" "$RANGE_OUT"
RANGE_LOG="$(cat "$RANGE_ERR")"
contains "range rejection names the URL" "https://example.com/range.xml" "$RANGE_LOG"
contains "range rejection names the range" "1..18 digit" "$RANGE_LOG"
if [[ -f "${TMP}/asc_args.txt" ]]; then
  echo "  FAIL: ASC client ran for an out-of-range floor"
  FAIL=$((FAIL + 1))
else
  echo "  ok  : ASC client never ran for an out-of-range floor"
  PASS=$((PASS + 1))
fi
export FAKE_FEED_XML='<rss><channel><item><sparkle:version>0</sparkle:version></item></channel></rss>'
ZERO_ERR="${TMP}/zero.err"
ZERO_OUT="$(run_helper "${TMP}/apps-range.json" rangeapp com.example.range iOS 2>"$ZERO_ERR")"
ZERO_RC=$?
check "zero floor exits 1" "1" "$ZERO_RC"
check "zero floor prints no build" "" "$ZERO_OUT"
contains "zero rejection names the range" "1..18 digit" "$(cat "$ZERO_ERR")"
# 9999 was refused under the old 1..9998 cap; now it joins the plan, as does
# a stamp-scale floor.
export FAKE_FEED_XML='<rss><channel><item><sparkle:version>9999</sparkle:version></item></channel></rss>'
OK9999_OUT="$(run_helper "${TMP}/apps-range.json" rangeapp com.example.range iOS 2>/dev/null)"
check "9999 floor returns the stub build" "202610290935" "$OK9999_OUT"
contains "9999 reaches the client as floor" "9999" "$(cat "${TMP}/asc_args.txt" 2>/dev/null || true)"
export FAKE_FEED_XML='<rss><channel><item><sparkle:version>202610290940</sparkle:version></item></channel></rss>'
STAMPFLOOR_OUT="$(run_helper "${TMP}/apps-range.json" rangeapp com.example.range iOS 2>/dev/null)"
check "stamp-scale floor returns the stub build" "202610290935" "$STAMPFLOOR_OUT"
contains "stamp-scale floor reaches the client" "202610290940" "$(cat "${TMP}/asc_args.txt" 2>/dev/null || true)"

echo "== empty feed fails closed with a message =="
cat > "${TMP}/apps-empty.json" <<'JSON'
{"apps": {"emptyapp": {"bundleId": "com.example.empty", "platform": "iOS", "pairedBuildFeed": "https://example.com/empty.xml"}}}
JSON
export FAKE_FEED_XML='<rss><channel><item><title>no versions here</title></item></channel></rss>'
export FAKE_CURL_RC=0
rm -f "${TMP}/asc_args.txt"
EMPTY_ERR="${TMP}/empty.err"
EMPTY_OUT="$(run_helper "${TMP}/apps-empty.json" emptyapp com.example.empty iOS 2>"$EMPTY_ERR")"
EMPTY_RC=$?
check "empty feed exits 1" "1" "$EMPTY_RC"
check "empty feed prints no build" "" "$EMPTY_OUT"
EMPTY_LOG="$(cat "$EMPTY_ERR")"
contains "empty feed names the URL" "https://example.com/empty.xml" "$EMPTY_LOG"
contains "empty feed says no numeric versions" "no numeric" "$EMPTY_LOG"
contains "empty feed names the tag" "<sparkle:version>" "$EMPTY_LOG"
if [[ -f "${TMP}/asc_args.txt" ]]; then
  echo "  FAIL: ASC client ran for an empty feed (must stay fail-closed)"
  FAIL=$((FAIL + 1))
else
  echo "  ok  : ASC client never ran for an empty feed"
  PASS=$((PASS + 1))
fi

echo "== macOS reverse lookup pairs the iOS peer =="
cat > "${TMP}/apps-pair.json" <<'JSON'
{"apps": {
  "iosapp": {"bundleId": "com.example.ios", "platform": "iOS", "macBundleId": "com.example.mac"},
  "macapp": {"bundleId": "com.example.mac", "platform": "macOS"}
}}
JSON
export FAKE_FEED_XML=''
export FAKE_CURL_RC=0
MAC_ERR="${TMP}/mac.err"
MAC_OUT="$(run_helper "${TMP}/apps-pair.json" macapp com.example.mac macOS 2>"$MAC_ERR")"
MAC_RC=$?
check "mac entry returns the stub build" "202610290935" "$MAC_OUT"
check "mac entry exits 0" "0" "$MAC_RC"
MAC_ASC="$(cat "${TMP}/asc_args.txt" 2>/dev/null || true)"
contains "reverse lookup passes the iOS bundle id" "com.example.ios" "$MAC_ASC"
# The forward direction still works: the iOS entry passes the Mac bundle id.
IOS_ERR="${TMP}/ios.err"
IOS_OUT="$(run_helper "${TMP}/apps-pair.json" iosapp com.example.ios iOS 2>"$IOS_ERR")"
IOS_RC=$?
check "ios entry returns the stub build" "202610290935" "$IOS_OUT"
IOS_ASC="$(cat "${TMP}/asc_args.txt" 2>/dev/null || true)"
contains "forward pairing passes the Mac bundle id" "com.example.mac" "$IOS_ASC"

echo "== the merge stamp is the committer date of HEAD in Chicago =="
STAMP_OUT="$(REPO_ROOT="$STAMP_REPO" FUNCS_PATH="$FUNCS" bash -c '
  set -uo pipefail
  # shellcheck source=/dev/null
  source "$FUNCS_PATH"
  merge_stamp
')"
check "fixed committer date stamps 202610290930" "202610290930" "$STAMP_OUT"
NOTREPO_OUT="$(REPO_ROOT="$TMP" FUNCS_PATH="$FUNCS" bash -c '
  set -uo pipefail
  # shellcheck source=/dev/null
  source "$FUNCS_PATH"
  merge_stamp
' 2>/dev/null)"
NOTREPO_RC=$?
check "a non-repo exits 1" "1" "$NOTREPO_RC"
check "a non-repo prints no stamp" "" "$NOTREPO_OUT"

echo "== build_num_gt compares digit strings numerically =="
GT_OUT="$(FUNCS_PATH="$FUNCS" bash -c '
  set -uo pipefail
  # shellcheck source=/dev/null
  source "$FUNCS_PATH"
  out=""
  build_num_gt 202610290931 202610290930 && out="${out}T" || out="${out}F"
  build_num_gt 202610290930 202610290930 && out="${out}T" || out="${out}F"
  build_num_gt 202610290929 202610290930 && out="${out}T" || out="${out}F"
  build_num_gt 202610290930 999 && out="${out}T" || out="${out}F"
  build_num_gt 999 202610290930 && out="${out}T" || out="${out}F"
  build_num_gt 202610290930 0 && out="${out}T" || out="${out}F"
  build_num_gt 202610290930 abc && out="${out}T" || out="${out}F"
  build_num_gt 000202610290931 202610290930 && out="${out}T" || out="${out}F"
  printf "%s" "$out"
')"
check "above/equal/below/short-wide/zero/non-numeric/zero-padded" "TFFTFTFT" "$GT_OUT"

echo "== this-platform max queries one app record on one platform =="
export STUB_MAX="202610290930" STUB_RC=0
MAX_OUT="$(run_max_helper com.example.ws IOS 2>/dev/null)"
MAX_RC=$?
check "max returns the stub max" "202610290930" "$MAX_OUT"
check "max exits 0" "0" "$MAX_RC"
MAX_ASC="$(cat "${TMP}/max_args.txt" 2>/dev/null || true)"
contains "max queries max-platform-build" "max-platform-build com.example.ws IOS" "$MAX_ASC"
export STUB_MAX="0" STUB_RC=0
ZERO_MAX_OUT="$(run_max_helper com.example.ws MAC_OS 2>/dev/null)"
check "an empty platform reports 0" "0" "$ZERO_MAX_OUT"
contains "the platform travels to the client" "MAC_OS" "$(cat "${TMP}/max_args.txt" 2>/dev/null || true)"
export STUB_MAX="202610290930" STUB_RC=3
BADRC_OUT="$(run_max_helper com.example.ws IOS 2>/dev/null)"
BADRC_RC=$?
check "a failing client exits 1" "1" "$BADRC_RC"
check "a failing client prints no max" "" "$BADRC_OUT"
export STUB_MAX="1.2.x" STUB_RC=0
BADVAL_OUT="$(run_max_helper com.example.ws IOS 2>/dev/null)"
BADVAL_RC=$?
check "a non-numeric max exits 1" "1" "$BADVAL_RC"
check "a non-numeric max prints nothing" "" "$BADVAL_OUT"

echo "== fixed --build is checked against this platform only =="
# The paired platform holds the planned value already; this platform holds
# only build 100.  The planned value is above this platform's max, so it is
# accepted for this platform even though it equals the paired platform's.
FIXED_OUT="$(FUNCS_PATH="$FUNCS" bash -c '
  set -uo pipefail
  # shellcheck source=/dev/null
  source "$FUNCS_PATH"
  out=""
  build_num_gt 202610290930 100 && out="${out}T" || out="${out}F"
  build_num_gt 202610290930 202610290930 && out="${out}T" || out="${out}F"
  build_num_gt 202610290929 202610290930 && out="${out}T" || out="${out}F"
  printf "%s" "$out"
')"
check "above-accepts/equal-rejects/below-rejects" "TFF" "$FIXED_OUT"
SHIP_TEXT="$(cat "$SHIP")"
contains "fixed --build requires a 12-digit stamp" '[[ "$FORCE_BUILD" =~ ^[1-9][0-9]{11}$ ]]' "$SHIP_TEXT"
contains "fixed --build reads this platform max" '_this_max="$(asc_this_platform_max)"' "$SHIP_TEXT"
contains "fixed --build compares numerically" 'build_num_gt "$FORCE_BUILD" "$_this_max"' "$SHIP_TEXT"
contains "fixed --build names the blocking max" 'is at or below the highest existing build' "$SHIP_TEXT"

echo "== curl is hardened and the max uses POSIX tools =="
contains "curl pins https for proto" "--proto =https" "$SHIP_TEXT"
contains "curl pins https for redirects" "--proto-redir =https" "$SHIP_TEXT"
contains "curl has a connect timeout" "--connect-timeout 10" "$SHIP_TEXT"
contains "curl has a total timeout" "--max-time 30" "$SHIP_TEXT"
contains "curl caps the download" "--max-filesize 5000000" "$SHIP_TEXT"
contains "scrape tolerates whitespace" "<sparkle:version>[[:space:]]*[0-9]+[[:space:]]*</sparkle:version>" "$SHIP_TEXT"
HELPER_TEXT="$(awk '/^asc_next_shared_build\(\) \{/ { grab = 1 } grab { print } grab && /^\}/ { grab = 0 }' "$SHIP")"
lacks "the max never calls a hardcoded python" "/usr/bin/python3" "$HELPER_TEXT"
contains "the max uses sort -n" "sort -n" "$HELPER_TEXT"
contains "the max uses tail -n 1" "tail -n 1" "$HELPER_TEXT"

echo
echo "passed: ${PASS}  failed: ${FAIL}"
[[ $FAIL -eq 0 ]] || exit 1
exit 0

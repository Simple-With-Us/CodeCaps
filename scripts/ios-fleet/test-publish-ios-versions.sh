#!/usr/bin/env bash
# Tests for publish-ios-versions.sh (CC-202) with a stubbed GitHub API.
# Run: bash scripts/ios-fleet/test-publish-ios-versions.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT_SRC="${ROOT}/scripts/ios-fleet/publish-ios-versions.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-publish-ios.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "${TMP}/fleet" "${TMP}/bin" "${TMP}/state"
cp "$SCRIPT_SRC" "${TMP}/fleet/publish-ios-versions.sh"

# Fixture remote manifest with another app's row that must survive the merge.
python3 - "${TMP}/state/remote.json" <<'PY'
import base64, json, sys
data = {"schemaVersion": 1, "updatedAt": "2026-10-18T02:20:00Z",
        "apps": {"trade.congress.ios": {"marketingVersion": "1.0.236", "build": "202610180036", "appleId": 6798076688, "displayName": "Congress.Trade"}}}
open(sys.argv[1], "w").write(json.dumps(data))
PY

cat > "${TMP}/bin/curl" <<'STUB'
#!/usr/bin/env bash
# Stub curl: understands -o FILE -w FMT -X METHOD --data @FILE URL and -K FILE.
out=""; method="GET"; data=""; url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w) shift 2 ;;
    -X) method="$2"; shift 2 ;;
    --data) data="$2"; shift 2 ;;
    -K|-H) shift 2 ;;
    -sS) shift ;;
    *) url="$1"; shift ;;
  esac
done
state="${STUB_STATE_DIR:?}"
printf '%s %s\n' "$method" "$url" >> "${state}/calls.log"
if [[ -n "$data" && "$data" == @* ]]; then
  cp "${data#@}" "${state}/last-${method}.json" 2>/dev/null || true
fi
body='{}'; status=200
case "$method $url" in
  "GET "*"/contents/"*"?ref=main")
    content="$(base64 < "${state}/remote.json" | tr -d '\n')"
    body="{\"sha\":\"remote-sha\",\"content\":\"${content}\"}"
    ;;
  "GET "*"/git/ref/heads/main")
    body='{"object":{"sha":"main-sha"}}'
    ;;
  "POST "*"/git/refs")
    status=201; body='{"ref":"refs/heads/stub"}'
    ;;
  "GET "*"/contents/"*"?ref=ios-versions/"*)
    status=404; body='{"message":"Not Found"}'
    ;;
  "PUT "*"/contents/"*)
    if [[ "${STUB_FAIL_PUT:-}" == "1" ]]; then
      status=403; body='{"message":"Resource not accessible by integration"}'
    else
      status=201; body='{"content":{"sha":"new-sha"}}'
      cp "${state}/last-PUT.json" "${state}/put.json" 2>/dev/null || true
    fi
    ;;
  "POST "*"/pulls")
    status=201; body='{"html_url":"https://github.example/pull/7","number":7}'
    ;;
  "GET "*"/pulls/7")
    body='{"node_id":"PR_node_7","number":7}'
    ;;
  "POST "*"/graphql")
    body='{"data":{}}'
    ;;
  *)
    status=500; body='{"message":"unstubbed call"}'
    ;;
esac
printf '%s' "$body" > "$out"
printf '%s' "$status"
STUB
chmod +x "${TMP}/bin/curl"

run_publish() {
  STUB_STATE_DIR="${TMP}/state" PATH="${TMP}/bin:/usr/bin:/bin" \
  IOS_VERSIONS_API_BASE="https://api.github.example" \
  IOS_VERSIONS_PUBLISH_TOKEN="stub-token-for-tests" \
    bash "${TMP}/fleet/publish-ios-versions.sh" \
      --bundle-id com.simplewithus.codecaps.ios --version 1.0.264 \
      --build 283 --apple-id 6814623846 --display-name "CodeCaps Companion"
}

# Happy path: branch + PR, other apps preserved, row written.
out="$(run_publish 2>"${TMP}/happy.err")"
grep -q "remote-manifest-pr-opened" <<<"$out"
grep -q "PR #7" <<<"$out"
python3 - "${TMP}/state/put.json" <<'PY'
import base64, json, sys
put = json.load(open(sys.argv[1]))
assert put["branch"].startswith("ios-versions/"), put["branch"]
assert put["branch"] != "main"
merged = json.loads(base64.b64decode(put["content"]))
row = merged["apps"]["com.simplewithus.codecaps.ios"]
assert row == {"marketingVersion": "1.0.264", "build": "283", "appleId": 6814623846, "displayName": "CodeCaps Companion"}, row
assert merged["apps"]["trade.congress.ios"]["marketingVersion"] == "1.0.236", "other app row must survive"
PY
if grep -q "PUT .*contents.*ref=main" "${TMP}/state/calls.log"; then
  echo "FAIL: publisher PUT to main" >&2; exit 1
fi

# A refused write names its HTTP status and fails (the ship stays non-fatal
# because ship-testflight.sh only warns on this exit).
: > "${TMP}/state/calls.log"
if STUB_FAIL_PUT=1 run_publish >"${TMP}/fail.out" 2>"${TMP}/fail.err"; then
  echo "FAIL: a 403 PUT must make the publisher exit non-zero" >&2; exit 1
fi
grep -q "HTTP 403" "${TMP}/fail.err"
grep -q "Resource not accessible" "${TMP}/fail.err"

# No credential: the cause is printed, including why the ship token cannot work.
if PATH="/usr/bin:/bin" HOME="${TMP}" bash "${TMP}/fleet/publish-ios-versions.sh" \
    --bundle-id com.simplewithus.codecaps.ios --version 1.0.264 >"${TMP}/notoken.out" 2>"${TMP}/notoken.err"; then
  echo "FAIL: no-credential publish must exit non-zero so the ship log warns" >&2; exit 1
fi
grep -q "no IOS_VERSIONS_PUBLISH_TOKEN" "${TMP}/notoken.err"
grep -q "contents:read" "${TMP}/notoken.err"

# A non-numeric apple id is a named failure, not a bare traceback.
if bash "${TMP}/fleet/publish-ios-versions.sh" --bundle-id com.simplewithus.codecaps.ios \
    --version 1.0.264 --apple-id notanumber >"${TMP}/badid.out" 2>"${TMP}/badid.err"; then
  echo "FAIL: a non-numeric --apple-id must exit non-zero" >&2; exit 1
fi
grep -q "remote-manifest-publish-failed: --apple-id must be a number" "${TMP}/badid.err"
if grep -q Traceback "${TMP}/badid.err"; then echo "FAIL: traceback leaked" >&2; exit 1; fi

echo "test-publish-ios-versions: all tests passed"

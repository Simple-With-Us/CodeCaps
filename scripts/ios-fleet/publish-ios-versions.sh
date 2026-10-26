#!/usr/bin/env bash
# publish-ios-versions.sh - update the public fleet iOS version manifest.
#
# Called by ship-testflight.sh after a successful upload.  Also safe to run
# by hand.  Never prints secret values.  Failure is non-fatal for ships:
# the caller keeps this step best-effort and prints whatever this script
# prints, including the HTTP status of a refused remote write (CC-202).
#
# Usage:
#   bash publish-ios-versions.sh \
#     --bundle-id com.simplewithus.codecaps.ios \
#     --version 1.0.264 \
#     [--build 283] \
#     [--apple-id 6814623846] \
#     [--display-name "CodeCaps Companion"]
#
# The marketing version and the build number are independent (AFC-517), so
# both are passed separately and neither is derived from the other.
#
# Writes:
#   <this script's folder>/ios-app-versions.json   (local record)
#   Simple-With-Us/ai-fleet-coordinator site/ios-versions.json, through a
#   pull request.  That repository's main branch requires a pull request
#   (org and repo rulesets, no bypass actors), so a direct Contents PUT to
#   main is refused even for a credential that can write the repository.
#   The ship job's own GITHUB_TOKEN is also contents:read on the shipping
#   repository and cannot write the other repository at all.  The remote
#   leg therefore needs IOS_VERSIONS_PUBLISH_TOKEN (in CI: the org GH_PAT
#   secret, wired in ios-ship.yml) and opens or reuses a branch and pull
#   request instead of PUTting to main.  Without that token the remote leg
#   is skipped out loud and this script exits 1; the ship stays non-fatal
#   because ship-testflight.sh only warns on a non-zero exit here.

set -euo pipefail

FLEET_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_JSON="${FLEET_DIR}/ios-app-versions.json"
REPO="${IOS_VERSIONS_REPO:-Simple-With-Us/ai-fleet-coordinator}"
REMOTE_PATH="${IOS_VERSIONS_REMOTE_PATH:-site/ios-versions.json}"
API_BASE="${IOS_VERSIONS_API_BASE:-https://api.github.com}"

BUNDLE_ID=""
VERSION=""
BUILD=""
APPLE_ID=""
DISPLAY_NAME=""

usage() {
  sed -n '1,20p' "$0"
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --build) BUILD="$2"; shift 2 ;;
    --apple-id) APPLE_ID="$2"; shift 2 ;;
    --display-name) DISPLAY_NAME="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$BUNDLE_ID" && -n "$VERSION" ]] || { echo "need --bundle-id and --version" >&2; exit 2; }

python3 - "$LOCAL_JSON" "$BUNDLE_ID" "$VERSION" "$BUILD" "$APPLE_ID" "$DISPLAY_NAME" <<'PY'
import json, sys, datetime
path, bundle, version, build, apple_id, display = sys.argv[1:7]
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except FileNotFoundError:
    data = {"schemaVersion": 1, "apps": {}}
apps = data.setdefault("apps", {})
entry = apps.get(bundle, {})
entry["marketingVersion"] = version
if build:
    entry["build"] = build
if apple_id:
    entry["appleId"] = int(apple_id)
if display:
    entry["displayName"] = display
apps[bundle] = entry
data["schemaVersion"] = 1
data["updatedAt"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
print("local-manifest-updated", bundle, version)
PY

# The dedicated publishing credential.  GH_TOKEN is honoured as a fallback
# for a hand run; GITHUB_TOKEN is deliberately not used, because in CI it
# is the shipping repository's contents:read token and a remote write
# attempted with it only ever produced a swallowed 403.
TOKEN="${IOS_VERSIONS_PUBLISH_TOKEN:-${GH_TOKEN:-}}"
if [[ -z "$TOKEN" ]] && command -v gh >/dev/null 2>&1; then
  TOKEN="$(gh auth token 2>/dev/null || true)"
fi
if [[ -z "$TOKEN" ]]; then
  echo "remote-manifest-publish-skipped: no IOS_VERSIONS_PUBLISH_TOKEN credential; the ship job GITHUB_TOKEN is contents:read on this repository and cannot write ${REPO}, so ${REMOTE_PATH} was not updated" >&2
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "remote-manifest-publish-failed: curl not installed; cannot call the GitHub API for ${REPO}/${REMOTE_PATH}" >&2
  exit 1
fi

WORK_DIR="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/publish-ios-versions.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
API_BODY="${WORK_DIR}/api-body.json"
API_STATUS=""
# The credential travels in a private curl config inside the work directory,
# never in a command argument or a log line.
CURL_CONFIG="${WORK_DIR}/curl-config"
printf 'header = "Authorization: %s %s"\n' "Bearer" "$TOKEN" > "$CURL_CONFIG"
chmod 600 "$CURL_CONFIG"

# api_request METHOD PATH [JSON_FILE]
# Body lands in $API_BODY and the HTTP status in $API_STATUS.
api_request() {
  local method="$1" path="$2" data_file="${3:-}"
  local -a args
  args=(-sS -K "$CURL_CONFIG" -o "$API_BODY" -w '%{http_code}' -X "$method"
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28")
  if [[ -n "$data_file" ]]; then
    args+=(-H "Content-Type: application/json" --data "@${data_file}")
  fi
  API_STATUS="$(curl "${args[@]}" "${API_BASE}/${path}")"
}

api_message() {
  python3 - "$API_BODY" <<'PY' 2>/dev/null || echo "no response message"
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    print("no response message"); raise SystemExit
msg = data.get("message") if isinstance(data, dict) else None
print(msg if msg else "no response message")
PY
}

api_fail() {
  local what="$1"
  echo "remote-manifest-publish-failed: ${what} HTTP ${API_STATUS}: $(api_message)" >&2
  exit 1
}

json_field() {
  python3 - "$1" "$2" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
cur = data
for part in sys.argv[2].split("."):
    if isinstance(cur, dict):
        cur = cur.get(part, "")
    elif isinstance(cur, list) and part.isdigit() and int(part) < len(cur):
        cur = cur[int(part)]
    else:
        cur = ""
        break
print("" if cur is None else cur)
PY
}

# 1. Read the live manifest and merge this app's row into it.  Merging into
# the remote file matters: the local record only knows this app, so
# uploading it whole would delete every other app's row.
api_request GET "repos/${REPO}/contents/${REMOTE_PATH}?ref=main"
[[ "$API_STATUS" == "200" ]] || api_fail "GET repos/${REPO}/contents/${REMOTE_PATH}?ref=main"
json_field "$API_BODY" "content" | tr -d '\n' | base64 -d > "${WORK_DIR}/remote.json" 2>/dev/null \
  || { echo "remote-manifest-publish-failed: could not decode the live ${REMOTE_PATH} (HTTP 200 with an unreadable body)" >&2; exit 1; }

ALREADY_CURRENT="$(python3 - "${WORK_DIR}/remote.json" "$BUNDLE_ID" "$VERSION" "$BUILD" "$APPLE_ID" "$DISPLAY_NAME" <<'PY'
import json, sys
path, bundle, version, build, apple_id, display = sys.argv[1:7]
data = json.load(open(path, encoding="utf-8"))
entry = data.get("apps", {}).get(bundle, {})
ok = entry.get("marketingVersion") == version
if build:
    ok = ok and str(entry.get("build", "")) == build
if apple_id:
    ok = ok and entry.get("appleId") == int(apple_id)
if display:
    ok = ok and entry.get("displayName") == display
print("1" if ok else "0")
PY
)"
if [[ "$ALREADY_CURRENT" == "1" ]]; then
  echo "remote-manifest-already-current ${REPO}/${REMOTE_PATH} ${BUNDLE_ID} ${VERSION}"
  exit 0
fi

python3 - "${WORK_DIR}/remote.json" "${WORK_DIR}/merged.json" "$BUNDLE_ID" "$VERSION" "$BUILD" "$APPLE_ID" "$DISPLAY_NAME" <<'PY'
import json, sys, datetime
src, dst, bundle, version, build, apple_id, display = sys.argv[1:8]
data = json.load(open(src, encoding="utf-8"))
apps = data.setdefault("apps", {})
entry = apps.get(bundle, {})
entry["marketingVersion"] = version
if build:
    entry["build"] = build
if apple_id:
    entry["appleId"] = int(apple_id)
if display:
    entry["displayName"] = display
apps[bundle] = entry
data["schemaVersion"] = 1
data["updatedAt"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
with open(dst, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY

# 2. Branch off main.  The branch name is stable for one app version, so a
# re-run reuses the same branch and pull request instead of opening a
# duplicate.
BRANCH="ios-versions/$(printf '%s-%s' "$BUNDLE_ID" "$VERSION" | tr -c 'A-Za-z0-9._-' '-')"
api_request GET "repos/${REPO}/git/ref/heads/main"
[[ "$API_STATUS" == "200" ]] || api_fail "GET repos/${REPO}/git/ref/heads/main"
MAIN_SHA="$(json_field "$API_BODY" "object.sha")"
[[ -n "$MAIN_SHA" ]] || { echo "remote-manifest-publish-failed: GET main ref returned no sha (HTTP ${API_STATUS})" >&2; exit 1; }

python3 - "${WORK_DIR}/create-ref.json" "refs/heads/${BRANCH}" "$MAIN_SHA" <<'PY'
import json, sys
json.dump({"ref": sys.argv[2], "sha": sys.argv[3]}, open(sys.argv[1], "w", encoding="utf-8"))
PY
api_request POST "repos/${REPO}/git/refs" "${WORK_DIR}/create-ref.json"
if [[ "$API_STATUS" == "422" ]]; then
  api_request GET "repos/${REPO}/git/ref/heads/${BRANCH}"
  [[ "$API_STATUS" == "200" ]] || api_fail "POST repos/${REPO}/git/refs (branch ${BRANCH} may already exist)"
elif [[ "$API_STATUS" != "201" ]]; then
  api_fail "POST repos/${REPO}/git/refs"
fi

# 3. Put the merged manifest on the branch, never on main.
api_request GET "repos/${REPO}/contents/${REMOTE_PATH}?ref=${BRANCH}"
BRANCH_FILE_SHA=""
if [[ "$API_STATUS" == "200" ]]; then
  BRANCH_FILE_SHA="$(json_field "$API_BODY" "sha")"
elif [[ "$API_STATUS" != "404" ]]; then
  api_fail "GET repos/${REPO}/contents/${REMOTE_PATH}?ref=${BRANCH}"
fi

python3 - "${WORK_DIR}/merged.json" "${WORK_DIR}/put.json" "$BUNDLE_ID" "$VERSION" "$BRANCH" "$BRANCH_FILE_SHA" <<'PY'
import base64, json, sys
src, dst, bundle, version, branch, sha = sys.argv[1:7]
payload = {
    "message": f"chore: {bundle} {version}",
    "content": base64.b64encode(open(src, "rb").read()).decode(),
    "branch": branch,
}
if sha:
    payload["sha"] = sha
json.dump(payload, open(dst, "w", encoding="utf-8"))
PY
api_request PUT "repos/${REPO}/contents/${REMOTE_PATH}" "${WORK_DIR}/put.json"
[[ "$API_STATUS" == "200" || "$API_STATUS" == "201" ]] || api_fail "PUT repos/${REPO}/contents/${REMOTE_PATH} (branch ${BRANCH})"

# 4. Open the pull request, or reuse the one a previous run opened.
python3 - "${WORK_DIR}/pr.json" "$BUNDLE_ID" "$VERSION" "$BRANCH" <<'PY'
import json, sys
dst, bundle, version, branch = sys.argv[1:5]
body = (
    f"Records {bundle} {version} in the public iOS version manifest.  "
    "This branch was written by publish-ios-versions.sh after a TestFlight upload.  "
    "Main requires a pull request, so the publisher opens one instead of PUTting to main."
)
json.dump({"title": f"chore: {bundle} {version}", "head": branch, "base": "main", "body": body},
          open(dst, "w", encoding="utf-8"))
PY
api_request POST "repos/${REPO}/pulls" "${WORK_DIR}/pr.json"
PR_URL=""
PR_NUMBER=""
if [[ "$API_STATUS" == "201" ]]; then
  PR_URL="$(json_field "$API_BODY" "html_url")"
  PR_NUMBER="$(json_field "$API_BODY" "number")"
elif [[ "$API_STATUS" == "422" ]]; then
  OWNER="${REPO%%/*}"
  api_request GET "repos/${REPO}/pulls?state=open&head=${OWNER}:${BRANCH}"
  if [[ "$API_STATUS" == "200" ]]; then
    PR_URL="$(json_field "$API_BODY" "0.html_url")"
    PR_NUMBER="$(json_field "$API_BODY" "0.number")"
  fi
  [[ -n "$PR_URL" ]] || api_fail "POST repos/${REPO}/pulls"
else
  api_fail "POST repos/${REPO}/pulls"
fi

echo "remote-manifest-pr-opened ${REPO}/${REMOTE_PATH} ${BUNDLE_ID} ${VERSION} PR #${PR_NUMBER} ${PR_URL}"

# 5. Best effort: arm auto-merge so the row lands once the required checks
# pass.  A refusal here is printed, not hidden, and the pull request above
# is still the written row, so this leg alone does not fail the publish.
if [[ -n "$PR_NUMBER" ]]; then
  api_request GET "repos/${REPO}/pulls/${PR_NUMBER}"
  PR_NODE_ID=""
  if [[ "$API_STATUS" == "200" ]]; then
    PR_NODE_ID="$(json_field "$API_BODY" "node_id")"
  fi
  if [[ -n "$PR_NODE_ID" ]]; then
    python3 - "${WORK_DIR}/graphql.json" "$PR_NODE_ID" <<'PY'
import json, sys
query = "mutation($id:ID!){enablePullRequestAutoMerge(input:{pullRequestId:$id,mergeMethod:SQUASH}){pullRequest{number}}}"
json.dump({"query": query, "variables": {"id": sys.argv[2]}}, open(sys.argv[1], "w", encoding="utf-8"))
PY
    api_request POST "graphql" "${WORK_DIR}/graphql.json"
    if [[ "$API_STATUS" == "200" ]] && ! grep -q '"errors"' "$API_BODY"; then
      echo "remote-manifest-pr-auto-merge-armed PR #${PR_NUMBER}"
    else
      echo "remote-manifest-pr-auto-merge-not-armed: POST graphql HTTP ${API_STATUS}: $(api_message); PR #${PR_NUMBER} is open and lands once its required checks pass and it is merged" >&2
    fi
  fi
fi

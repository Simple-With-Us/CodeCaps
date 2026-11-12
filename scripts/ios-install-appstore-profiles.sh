#!/usr/bin/env bash
# Download the CodeCaps App Store profiles and install them for manual signing.
# Prints names and bundle ids only.  Never prints profile bytes.
set +o xtrace
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAP="${ROOT}/ios/CodeCapsCompanion/appstore-profiles.json"
CLIENT="${ROOT}/scripts/ios-fleet/asc-api.mjs"
DEST="${HOME}/Library/MobileDevice/Provisioning Profiles"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/cc-profiles.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT
mkdir -p "$DEST"
chmod 700 "$DEST"

[[ -f "$MAP" && -f "$CLIENT" ]] || {
  echo "error: profile map or App Store Connect client is missing" >&2
  exit 1
}

# The client takes the key from the environment, because a path on disk is not
# an approved secret source (Kody rule 42).  The only approved sources are
# process.env.ASC_KEY_P8 and `fleet-secrets get ASC_KEY_P8`, and the client
# resolves both on its own.  A named ASC_KEY_PATH is not a credential source
# at all and is not read here, so a stale or foreign path can never decide
# which credential signs the request.
#
# The key never reaches a command line, a log, the environment file, or a
# temporary file.  A run that resolves no credential at all is a hard stop,
# and it names the variables that could not be resolved, so the operator is
# told which one to set instead of being left with a permission message that
# points at nothing.
run_client() {
  local rc=0 err="$WORKDIR/client.stderr"
  node "$CLIENT" "$@" 2>"$err" || rc=$?
  show_client_stderr "$err"
  name_missing_credential "$err"
  return "$rc"
}

# Prints what the client said, so nothing it reported is lost when its
# stderr is captured.
show_client_stderr() {
  local err="$1"
  if [[ -s "$err" ]]; then
    cat "$err" >&2
  fi
}

# Names the variables that could not be resolved when the client found no
# credential.  The client says which sources it tried;  this says which
# variables to set, so the failure is actionable instead of a permission
# message that points at nothing.
name_missing_credential() {
  local err="$1"
  if grep -q "no App Store Connect credential found" "$err" 2>/dev/null; then
    echo "error: no App Store Connect credential resolved: set ASC_KEY_P8 with ASC_KEY_ID and ASC_ISSUER_ID, or let fleet-secrets answer for Fleet-OPS prod /asc" >&2
  fi
}

run_client GET '/v1/profiles?filter[profileType]=IOS_APP_STORE&limit=200&include=bundleId' \
  >"$WORKDIR/profiles.json"
python3 - "$MAP" "$DEST" "$WORKDIR/profiles.json" <<'PY'
import base64, json, os, plistlib, subprocess, sys

want = json.load(open(sys.argv[1], encoding="utf-8"))
dest = sys.argv[2]
data = json.load(open(sys.argv[3], encoding="utf-8"))
if data.get("errors"):
    err = data["errors"][0]
    raise SystemExit("error: profile list failed: %s" % (err.get("code") or err.get("title") or "unknown"))

bundles = {}
for inc in data.get("included") or []:
    if inc.get("type") == "bundleIds":
        bundles[inc["id"]] = (inc.get("attributes") or {}).get("identifier")

found = {}
for row in data.get("data") or []:
    rel = ((row.get("relationships") or {}).get("bundleId") or {}).get("data") or {}
    bid = bundles.get(rel.get("id"))
    attrs = row.get("attributes") or {}
    if bid in want and attrs.get("name") == want[bid] and attrs.get("profileState") == "ACTIVE":
        found[bid] = row

missing = [bid for bid in want if bid not in found]
if missing:
    raise SystemExit("error: missing ACTIVE App Store profile for %s" % ", ".join(missing))

for bid, row in found.items():
    attrs = row.get("attributes") or {}
    blob = base64.b64decode(attrs.get("profileContent") or "")
    raw_path = os.path.join(os.path.dirname(sys.argv[3]), bid + ".mobileprovision")
    with open(raw_path, "wb") as handle:
        handle.write(blob)
    os.chmod(raw_path, 0o600)
    plist = plistlib.loads(subprocess.check_output(["security", "cms", "-D", "-i", raw_path]))
    ents = plist.get("Entitlements") or {}
    app_id = ents.get("application-identifier") or ""
    if not str(app_id).endswith(bid):
        raise SystemExit("error: profile %s is for %s" % (attrs.get("name"), app_id))
    if ents.get("get-task-allow") is not False:
        raise SystemExit("error: profile %s is not a distribution profile" % attrs.get("name"))
    uuid = plist.get("UUID")
    if not uuid:
        raise SystemExit("error: profile %s has no UUID" % attrs.get("name"))
    final = os.path.join(dest, uuid + ".mobileprovision")
    os.replace(raw_path, final)
    os.chmod(final, 0o644)
    print("installed %s name=%s uuid=%s" % (bid, attrs.get("name"), uuid))
PY

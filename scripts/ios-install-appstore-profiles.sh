#!/usr/bin/env bash
# Download the CodeCaps App Store profiles and install them for manual signing.
# Prints names and bundle ids only.  Never prints profile bytes.
set +o xtrace
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAP="${ROOT}/ios/CodeCapsCompanion/appstore-profiles.json"
CLIENT="${ROOT}/scripts/ios-fleet/asc-api.mjs"
KEY_READER="${ROOT}/scripts/ios-fleet/asc-key.mjs"
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
# an approved secret source (Kody rule 42).  The hosted runner stages the key
# to a mode-600 file and publishes only its path, so the staged key is read
# here, with the hardened reader, and handed to the child in the child's
# environment.  The key never reaches a command line, a log, the environment
# file, or a temporary file.
#
# A path that names nothing is not a credential:  the run falls through and the
# client resolves the credential the way it does today, from an exported
# ASC_KEY_P8 or from fleet-secrets.
staged_key=""
if [[ -n "${ASC_KEY_PATH:-}" ]]; then
  read_rc=0
  staged_key="$(node "$KEY_READER" read "$ASC_KEY_PATH")" || read_rc=$?
  if [[ "$read_rc" -ne 0 ]]; then
    staged_key=""
  fi
fi

run_client() {
  if [[ -n "$staged_key" ]]; then
    ASC_KEY_P8="$staged_key" node "$CLIENT" "$@"
  else
    node "$CLIENT" "$@"
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

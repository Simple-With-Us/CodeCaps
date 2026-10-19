#!/usr/bin/env bash
# Prepare a GitHub-hosted macOS runner to archive CodeCaps for Mac for TestFlight.
# Writes ASC credentials, imports Apple Distribution (IOS_DIST_*) and
# 3rd Party Mac Developer Installer (MAC_INSTALLER_*).  Never prints secret values.
set +o xtrace
set -euo pipefail
umask 077

die() { echo "error: $*" >&2; exit 1; }
log() { echo "[mac-gm] $*"; }

os=$(sw_vers -productVersion)
build=$(sw_vers -buildVersion)
log "macOS ${os} (${build})"
if echo "$build" | grep -Eq '[0-9][a-z]$'; then
  die "beta macOS host ${os} (${build}).  App Store review rejects these as INVALID_BINARY.  Use GitHub-hosted macos-latest (GM)."
fi

: "${ASC_KEY_ID:?ASC_KEY_ID required}"
: "${ASC_ISSUER_ID:?ASC_ISSUER_ID required}"
# Current CI passes ASC_KEY_PATH (a mode-600 file staged by
# scripts/ios-stage-asc-key.sh);  retain ASC_KEY_P8 for local legacy callers.
if [[ -z "${ASC_KEY_PATH:-}" ]]; then
  : "${ASC_KEY_P8:?ASC_KEY_P8 or ASC_KEY_PATH required}"
fi
: "${IOS_DIST_P12_BASE64:?IOS_DIST_P12_BASE64 required}"
: "${IOS_DIST_P12_PASSWORD:?IOS_DIST_P12_PASSWORD required}"
: "${MAC_INSTALLER_P12_BASE64:?MAC_INSTALLER_P12_BASE64 required}"
: "${MAC_INSTALLER_P12_PASSWORD:?MAC_INSTALLER_P12_PASSWORD required}"

# AFC-359: nothing is written under the old secrets folder.  Scratch files live in a
# private temp dir that is removed on exit.  The ship step reads ASC_KEY_ID /
# ASC_ISSUER_ID / ASC_KEY_PATH from the job environment (GITHUB_ENV), not from a file.
KC_DIR="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
WORK_DIR="$(mktemp -d "${KC_DIR%/}/gm-prepare.XXXXXX")"
chmod 700 "$WORK_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT

KEY_PATH="${ASC_KEY_PATH:-${KC_DIR%/}/asc-gm-AuthKey.p8}"
if [[ -n "${ASC_KEY_PATH:-}" ]]; then
  [[ -s "$KEY_PATH" ]] || die "ASC_KEY_PATH has no key file"
else
  # Legacy local path:  the caller passed the key itself, not a staged file.
  printf '%s\n' "$ASC_KEY_P8" > "$KEY_PATH"
  [[ -z "${GITHUB_ENV:-}" ]] || printf 'ASC_KEY_PATH=%s\n' "$KEY_PATH" >> "$GITHUB_ENV"
fi
chmod 600 "$KEY_PATH"

DIST_P12="${WORK_DIR}/ios-distribution.p12"
printf '%s' "$IOS_DIST_P12_BASE64" | base64 --decode > "$DIST_P12"
chmod 600 "$DIST_P12"

INST_P12="${WORK_DIR}/mac-installer.p12"
printf '%s' "$MAC_INSTALLER_P12_BASE64" | base64 --decode > "$INST_P12"
chmod 600 "$INST_P12"

KC_DIR="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
KC_PATH="${KC_DIR}/app-signing.keychain-db"
KC_PASS_FILE="${KC_DIR}/app-signing-kc-pass"
openssl rand -base64 24 > "$KC_PASS_FILE"
chmod 600 "$KC_PASS_FILE"
KC_PASS=$(cat "$KC_PASS_FILE")

security delete-keychain "$KC_PATH" >/dev/null 2>&1 || true
security create-keychain -p "$KC_PASS" "$KC_PATH"
security set-keychain-settings -lut 21600 "$KC_PATH"
security unlock-keychain -p "$KC_PASS" "$KC_PATH"
# -A: allow all apps (required for non-interactive productsign on hosted runners;
# -T alone still prompts/hangs for the Installer identity).
security import "$DIST_P12" -k "$KC_PATH" -P "$IOS_DIST_P12_PASSWORD" -A >/dev/null
security import "$INST_P12" -k "$KC_PATH" -P "$MAC_INSTALLER_P12_PASSWORD" -A >/dev/null
# The keychain holds the identities now;  do not leave the p12 files on disk.
rm -f "$DIST_P12" "$INST_P12"
# productsign (Mac pkg) needs the same partition list as codesign; without it
# xcodebuild -exportArchive can hang on a keychain ACL prompt on hosted runners.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KC_PATH" >/dev/null
security unlock-keychain -p "$KC_PASS" "$KC_PATH"
security list-keychain -d user -s "$KC_PATH" login.keychain-db
# Persist pass path for later ship steps if the keychain relocks.
printf '%s
' "$KC_PATH" > "${KC_DIR}/app-signing-kc-path"
chmod 600 "${KC_DIR}/app-signing-kc-path"

if ! security find-identity -v -p codesigning "$KC_PATH" | grep -q 'Apple Distribution'; then
  die "imported keychain has no Apple Distribution identity"
fi
if ! security find-identity -v "$KC_PATH" | grep -q '3rd Party Mac Developer Installer'; then
  die "imported keychain has no 3rd Party Mac Developer Installer identity"
fi
log "Apple Distribution + Mac Installer identities imported"
log "ASC credentials come from the job environment (key id length ${#ASC_KEY_ID})"

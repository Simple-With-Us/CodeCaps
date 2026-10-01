#!/usr/bin/env bash
# Prepare a GitHub-hosted macOS runner to archive CodeCaps for Mac for TestFlight.
# Writes ASC credentials, imports Apple Distribution (IOS_DIST_*) and
# 3rd Party Mac Developer Installer (MAC_INSTALLER_*). Never prints secret values.
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
log() { echo "[mac-gm] $*"; }

os=$(sw_vers -productVersion)
build=$(sw_vers -buildVersion)
log "macOS ${os} (${build})"
if echo "$build" | grep -Eq '[0-9][a-z]$'; then
  die "beta macOS host ${os} (${build}). App Store review rejects these as INVALID_BINARY. Use GitHub-hosted macos-latest (GM)."
fi

: "${ASC_KEY_ID:?ASC_KEY_ID required}"
: "${ASC_ISSUER_ID:?ASC_ISSUER_ID required}"
: "${ASC_KEY_P8:?ASC_KEY_P8 required}"
: "${IOS_DIST_P12_BASE64:?IOS_DIST_P12_BASE64 required}"
: "${IOS_DIST_P12_PASSWORD:?IOS_DIST_P12_PASSWORD required}"
: "${MAC_INSTALLER_P12_BASE64:?MAC_INSTALLER_P12_BASE64 required}"
: "${MAC_INSTALLER_P12_PASSWORD:?MAC_INSTALLER_P12_PASSWORD required}"

SECRETS_DIR="${HOME}/.secrets"
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

KEY_PATH="${SECRETS_DIR}/AuthKey.p8"
printf '%s\n' "$ASC_KEY_P8" > "$KEY_PATH"
chmod 600 "$KEY_PATH"

ENV_PATH="${SECRETS_DIR}/appstore-connect.env"
{
  printf 'ASC_KEY_ID=%s\n' "$ASC_KEY_ID"
  printf 'ASC_ISSUER_ID=%s\n' "$ASC_ISSUER_ID"
  printf 'ASC_KEY_PATH=%s\n' "$KEY_PATH"
} > "$ENV_PATH"
chmod 600 "$ENV_PATH"

DIST_P12="${SECRETS_DIR}/ios-distribution.p12"
printf '%s' "$IOS_DIST_P12_BASE64" | base64 --decode > "$DIST_P12"
chmod 600 "$DIST_P12"

INST_P12="${SECRETS_DIR}/mac-installer.p12"
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
log "ASC env written (key id length ${#ASC_KEY_ID})"

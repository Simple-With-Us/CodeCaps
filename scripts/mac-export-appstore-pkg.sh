#!/usr/bin/env bash
# Build a Mac App Store .pkg from an .xcarchive without xcodebuild -exportArchive
# (hosted runners have hung on exportArchive/productsign for CodeCaps).
# Usage: mac-export-appstore-pkg.sh <archive.xcarchive> <out-dir>
set +o xtrace
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
log() { echo "[mac-pkg] $*"; }

ARCHIVE="${1:-}"
OUT_DIR="${2:-}"
[[ -d "$ARCHIVE" ]] || die "archive missing: $ARCHIVE"
[[ -n "$OUT_DIR" ]] || die "out dir required"
mkdir -p "$OUT_DIR"

APP="$(find "$ARCHIVE/Products" -maxdepth 3 -name '*.app' -type d | head -1 || true)"
[[ -n "$APP" && -d "$APP" ]] || die "no .app under $ARCHIVE/Products"
APP_NAME="$(basename "$APP" .app)"
log "app=$APP"

# Prefer explicit installer identity; fall back to short name.
INSTALLER_ID="${MAC_INSTALLER_IDENTITY:-3rd Party Mac Developer Installer: Jay Wedgeworth, LLC (CC8UTF7ATG)}"
if ! security find-identity -v 2>/dev/null | grep -Fq "$INSTALLER_ID"; then
  INSTALLER_ID="3rd Party Mac Developer Installer"
fi
log "installer identity ready (name length ${#INSTALLER_ID})"

# Re-unlock throwaway keychain if the prepare step left one (hosted CI).
if [[ -n "${RUNNER_TEMP:-}" && -f "${RUNNER_TEMP}/app-signing-kc-pass" && -f "${RUNNER_TEMP}/app-signing.keychain-db" ]]; then
  KC_PASS="$(cat "${RUNNER_TEMP}/app-signing-kc-pass")"
  security unlock-keychain -p "$KC_PASS" "${RUNNER_TEMP}/app-signing.keychain-db" >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "${RUNNER_TEMP}/app-signing.keychain-db" >/dev/null || true
fi

# Ensure Info.plist carries LSMinimumSystemVersion for the product definition
# (ASC 90264: product min version must equal LSMinimumSystemVersion).
INFO="$APP/Contents/Info.plist"
if ! /usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c 'Add :LSMinimumSystemVersion string 14.0' "$INFO"
fi
MIN_VER="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO")"
MARKETING="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO" 2>/dev/null || echo 0.1.0)"
log "LSMinimumSystemVersion=$MIN_VER marketing=$MARKETING"

PKG_PATH="${OUT_DIR}/${APP_NAME}.pkg"
# --component + --product copies min-system-version into the product definition.
productbuild \
  --component "$APP" /Applications \
  --product "$INFO" \
  --sign "$INSTALLER_ID" \
  --identifier "com.simplewithus.codecaps.macos" \
  --version "$MARKETING" \
  "$PKG_PATH"

[[ -f "$PKG_PATH" ]] || die "pkg not produced"
log "pkg=$PKG_PATH size=$(wc -c < "$PKG_PATH") bytes"
printf '%s\n' "$PKG_PATH"

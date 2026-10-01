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

PKG_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mac-pkgroot.XXXXXX")"
trap 'rm -rf "$PKG_ROOT"' EXIT
mkdir -p "$PKG_ROOT/Applications"
ditto "$APP" "$PKG_ROOT/Applications/${APP_NAME}.app"

PKG_PATH="${OUT_DIR}/${APP_NAME}.pkg"
# productbuild --root packages the tree; component installs under /Applications.
# --synthesize + analyze is more complex; --root is what fleet Mac App Store needs.
productbuild \
  --root "$PKG_ROOT" \
  / \
  --sign "$INSTALLER_ID" \
  --identifier "com.simplewithus.codecaps.macos" \
  --version "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 0.1.0)" \
  "$PKG_PATH"

[[ -f "$PKG_PATH" ]] || die "pkg not produced"
log "pkg=$PKG_PATH size=$(wc -c < "$PKG_PATH") bytes"
printf '%s\n' "$PKG_PATH"

#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR"
DIST_DIR="$PACKAGE_DIR/dist"
APP_NAME="CodeCaps"
PRODUCT_NAME="CodeCaps"
RELEASE_BUNDLE_ID="com.jays.agent-bar.mac"
DEV_BUNDLE_ID="com.jays.agent-bar.mac.dev"
BUNDLE_ID="${CODECAPS_BUNDLE_ID:-${AGENTBAR_BUNDLE_ID:-$RELEASE_BUNDLE_ID}}"
CONFIGURATION="debug"
MIN_SYSTEM_VERSION="14.0"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_PLUGINS="$APP_CONTENTS/PlugIns"
APP_EXECUTABLE="$APP_MACOS/$PRODUCT_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
MAC_WIDGET_ENTITLEMENTS="$ROOT_DIR/ios/CodeCapsCompanion/Generated/CodeCapsWidgetsMac.entitlements"
HOST_ENTITLEMENTS="$DIST_DIR/CodeCapsHost.entitlements"
ICON_MASTER="$ROOT_DIR/assets/icon-1024.png"
ICON_FALLBACK="$ROOT_DIR/assets/icon-512.png"
ICON_MAKER="$ROOT_DIR/script/make_icon.swift"
ICON_FILE="AppIcon.icns"
INSTALL_DIR="$HOME/Applications"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"
VERSION_FILE="$ROOT_DIR/VERSION"
ZIP_FILE="$DIST_DIR/$APP_NAME.zip"
DMG_FILE="$DIST_DIR/$APP_NAME.dmg"
NOTARY_PROFILE="${CODECAPS_NOTARY_PROFILE:-${AGENTBAR_NOTARY_PROFILE:-agentbar-notary}}"

# --- Auto-update (Sparkle 2) -------------------------------------------------
# docs/AUTO-UPDATE.md is the whole pattern: keys, hosting, CI, rollback, and how
# to copy it to another app.  CI publishes a signed release for every merge to
# main that changes the app, and this feed always names the newest one.  The
# public key is not a secret; its private half is the SPARKLE_ED_PRIVATE_KEY
# repository secret, backed up in the owner's login Keychain (account
# "codecaps") and in the secrets handoff folder.
SPARKLE_FEED_URL_DEFAULT="https://github.com/Simple-With-Us/CodeCaps/releases/latest/download/appcast.xml"
SPARKLE_PUBLIC_ED_KEY="${CODECAPS_SPARKLE_PUBLIC_KEY:-Ou2J0syHZawPSY3JLTLVyhbOylmtyr0QnZPbq7acETQ=}"
SPARKLE_CHECK_INTERVAL="${CODECAPS_SPARKLE_CHECK_INTERVAL:-3600}"

# notarytool signs in with an App Store Connect API key when all three of
# NOTARY_KEY_PATH, NOTARY_KEY_ID and NOTARY_ISSUER_ID are set (that is how CI
# does it), and with the keychain profile above otherwise.
NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
if [[ -n "${NOTARY_KEY_PATH:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" ]]; then
  NOTARY_AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
fi
# Release artifacts are universal.  A build that only runs on the machine that
# made it is not a release, and an Intel Mac has no Rosetta for arm64 code.
UNIVERSAL_ARCHS=(arm64 x86_64)
UNIVERSAL=0
KEEP_STAGED_APP=0

# Where a stray copy of the app tends to end up.  Only these are searched, so a
# bundle inside another checkout is never a candidate for pruning.
PRUNE_ROOTS=(
  "/Applications"
  "$HOME/Applications"
  "$HOME/Desktop"
  "$HOME/Downloads"
  "/Users/jay/Library/Mobile Documents/com~apple~CloudDocs/Downloads"
  "$DIST_DIR"
)

usage() {
  cat >&2 <<'USAGE'
usage: script/build_and_run.sh [mode]

  run            (default) build, install to ~/Applications, relaunch it, then
                 delete the dist staging bundle and Trash every other copy
  --install      the same without relaunching
  --dev          build with the .dev bundle identifier into dist/ and launch it
                 beside the installed app, leaving the installed copy alone
  --dev-stop     quit only this checkout's dev process and delete dist/
  --package      build a universal Release, zip it into dist/ with its SHA-256,
                 and remove the staged .app afterwards
  --release      --package, then notarize and staple the app, rebuild the zip
                 from the stapled bundle, and build, sign, notarize and staple
                 dist/CodeCaps.dmg.  Both artifacts get a .sha256 beside them.
                 Notarization uses the keychain profile named by
                 $AGENTBAR_NOTARY_PROFILE, default "agentbar-notary", or an
                 App Store Connect API key when NOTARY_KEY_PATH, NOTARY_KEY_ID
                 and NOTARY_ISSUER_ID are all set
  --build-only   stage dist/CodeCaps.app and stop
  --debug        stage and run under lldb
  --logs         stage, launch, and stream the process log
  --telemetry    stage, launch, and stream this bundle identifier's log
  --verify       stage, launch, and confirm the process is running

  There is exactly one installed copy, at ~/Applications/CodeCaps.app.  Every
  mode that installs also prunes: any other bundle whose CFBundleIdentifier is
  com.jays.agent-bar.mac, under /Applications, ~/Applications, ~/Desktop,
  ~/Downloads, iCloud Downloads or this checkout's dist/, is moved to the Trash
  and printed.  Bundles with another identifier, and bundles inside another
  checkout, are never touched.  Set CODECAPS_PRUNE_DRY_RUN=1 (or
  AGENTBAR_PRUNE_DRY_RUN=1) to print what the prune would Trash without moving
  anything.

  Signing: $CODECAPS_CODESIGN_IDENTITY or $AGENTBAR_CODESIGN_IDENTITY when set,
  otherwise the first "Developer ID Application:" identity in the codesigning
  keychain.  A Developer ID signature is required for the team-authorized Mac
  widget app group; builds fail closed when no matching identity is available.
  A stable identity also lets saved Read and Ingest tokens survive rebuilds.
  CODECAPS_ALLOW_ADHOC_VALIDATION=1 is allowed only with --build-only; it
  verifies bundle structure but reports App Group access as UNVERIFIED.
  --package also signs with the hardened runtime and a secure timestamp and
  prints the notarytool command; --release is the mode that actually notarizes.

  Versions: CFBundleShortVersionString is the VERSION file at the repo root, so
  cutting a release is one edit.  CFBundleVersion is `git rev-list --count
  HEAD`, which only ever goes up.

  Auto-update: Sparkle.framework is embedded in Contents/Frameworks and signed
  inside-out.  A build with the release identifier carries the update feed and
  key, so it updates itself from the signed releases CI publishes; a build with
  any other identifier does not, unless CODECAPS_SPARKLE_FEED_URL names a feed
  explicitly (that is how an update is rehearsed locally, see
  docs/AUTO-UPDATE.md).  CODECAPS_SPARKLE_FEED_URL= (set but empty) turns it
  off for any build.
USAGE
}

kill_owned_process() {
  local target="$1"
  local pid command
  while read -r pid command; do
    [[ -n "${pid:-}" && "$command" == "$target" ]] || continue
    kill "$pid" >/dev/null 2>&1 || true
  done < <(/bin/ps -axo pid=,command=)
}

kill_owned_app() {
  kill_owned_process "$APP_EXECUTABLE"
}

kill_installed_app() {
  kill_owned_process "$INSTALLED_APP/Contents/MacOS/$PRODUCT_NAME"
}

# A release-identifier build updates itself from the published feed.  Any other
# identifier gets no feed unless one is named explicitly, so a --dev copy never
# replaces itself with the release build.  Set-but-empty turns updates off.
sparkle_feed_url() {
  if [[ -n "${CODECAPS_SPARKLE_FEED_URL+set}" ]]; then
    printf '%s\n' "$CODECAPS_SPARKLE_FEED_URL"
  elif [[ "$BUNDLE_ID" == "$RELEASE_BUNDLE_ID" ]]; then
    printf '%s\n' "$SPARKLE_FEED_URL_DEFAULT"
  fi
}

# Info.plist entries for Sparkle.  Updates are checked hourly, then downloaded
# and installed without asking (AppUpdater installs the moment CodeCaps is not
# frontmost).  An archive must pass its EdDSA check before it is even
# unpacked.  No feed, no entries: AutoUpdateAvailability then keeps Sparkle
# switched off rather than letting it raise a launch-time alert.
sparkle_plist_entries() {
  local feed
  feed="$(sparkle_feed_url)"
  [[ -n "$feed" ]] || return 0
  cat <<ENTRIES
  <key>SUFeedURL</key>
  <string>$feed</string>
  <key>SUPublicEDKey</key>
  <string>$SPARKLE_PUBLIC_ED_KEY</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
  <key>SUAutomaticallyUpdate</key>
  <true/>
  <key>SUAllowsAutomaticUpdates</key>
  <true/>
  <key>SUScheduledCheckInterval</key>
  <integer>$SPARKLE_CHECK_INTERVAL</integer>
  <key>SUVerifyUpdateBeforeExtraction</key>
  <true/>
ENTRIES
  # A rehearsal feed on this Mac is plain HTTP, which App Transport Security
  # refuses unless local networking is allowed.  Release feeds are HTTPS and
  # never get this key.
  if [[ "$feed" == http://127.0.0.1* || "$feed" == http://localhost* ]]; then
    cat <<ENTRIES
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
  </dict>
ENTRIES
  fi
}

# SwiftPM puts a binary-target framework (Sparkle) beside the executable, where
# the executable's @loader_path rpath finds it.  In the bundle it lives in
# Contents/Frameworks, so that rpath is added as well.  ditto keeps the
# framework's Versions symlinks, which codesign requires.
embed_frameworks() {
  local bin_dir="$1" framework
  rm -rf "$APP_FRAMEWORKS"
  for framework in "$bin_dir"/*.framework; do
    [[ -d "$framework" ]] || continue
    mkdir -p "$APP_FRAMEWORKS"
    /usr/bin/ditto "$framework" "$APP_FRAMEWORKS/$(basename "$framework")"
    echo "embedded $(basename "$framework")"
  done
  if [[ ! -d "$APP_FRAMEWORKS/Sparkle.framework" ]]; then
    echo "error: Sparkle.framework was not found in $bin_dir." >&2
    echo "error: refusing to stage an app that would crash at launch looking for it." >&2
    exit 1
  fi
  if ! /usr/bin/otool -l "$APP_EXECUTABLE" | /usr/bin/grep -q '@executable_path/../Frameworks'; then
    /usr/bin/install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_EXECUTABLE"
  fi
}

embed_plugins() {
  local xcode_proj="$ROOT_DIR/ios/CodeCapsCompanion/CodeCapsCompanion.xcodeproj"
  if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen is required to generate the Mac widget app-group entitlements." >&2
    exit 1
  fi
  if ! (cd "$ROOT_DIR/ios/CodeCapsCompanion" && xcodegen generate); then
    echo "error: XcodeGen could not regenerate the companion project." >&2
    exit 1
  fi
  if [[ ! -d "$xcode_proj" ]]; then
    echo "error: Xcode companion project not found at $xcode_proj." >&2
    echo "error: refusing to stage CodeCaps without its widget extension." >&2
    exit 1
  fi
  if [[ ! -f "$MAC_WIDGET_ENTITLEMENTS" ]]; then
    echo "error: XcodeGen did not produce $MAC_WIDGET_ENTITLEMENTS." >&2
    exit 1
  fi
  local widget_symroot="$ROOT_DIR/ios/CodeCapsCompanion/build"
  echo "building macOS widget extension (CodeCapsWidgetsMac)..."
  if xcodebuild -project "$xcode_proj" -scheme CodeCapsCompanionMac -configuration Release -jobs "${CODECAPS_BUILD_JOBS:-2}" \
      -derivedDataPath "$widget_symroot/DerivedData" \
      CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
      SYMROOT="$widget_symroot" build; then
    local appex_src="$widget_symroot/Release/CodeCapsWidgets.appex"
    if [[ ! -d "$appex_src" ]]; then
      echo "error: CodeCapsWidgets.appex was not found in $widget_symroot/Release." >&2
      echo "error: refusing to stage a CodeCaps build without its widget extension." >&2
      exit 1
    fi
    mkdir -p "$APP_PLUGINS"
    rm -rf "$APP_PLUGINS/CodeCapsWidgets.appex"
    cp -R "$appex_src" "$APP_PLUGINS/"
    echo "embedded $(basename "$appex_src")"
  else
    echo "error: building CodeCapsWidgetsMac failed; see xcodebuild diagnostics above." >&2
    exit 1
  fi
}

# --- Signing -----------------------------------------------------------------
# Ad-hoc signing (`codesign --sign -`) gives every build a brand new code
# identity, and the login Keychain grants access per identity.  Items saved by
# build N were therefore unreadable by build N+1, which is why the saved Read
# Token and Ingest Token had to be pasted again after every rebuild.  Signing
# with a real identity keeps the designated requirement stable — it names the
# bundle identifier and the team rather than a per-build cdhash — so one
# authorization survives every later build.
SIGN_OPTIONS=()

resolve_codesign_identity() {
  if [[ -n "${CODECAPS_CODESIGN_IDENTITY:-${AGENTBAR_CODESIGN_IDENTITY:-}}" ]]; then
    printf '%s\n' "${CODECAPS_CODESIGN_IDENTITY:-$AGENTBAR_CODESIGN_IDENTITY}"
    return 0
  fi
  /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
    | /usr/bin/sed -n 's/^.*"\(Developer ID Application:[^"]*\)".*$/\1/p' \
    | /usr/bin/head -n 1
}

# codesign blocks on a Keychain key-access panel when this shell has never been
# authorized to use the signing key, and a build must never hang behind a panel
# nobody is watching.  Thirty seconds, then ad-hoc.  A killed process reports
# 128 plus its signal, and `alarm` raises SIGALRM (14).
WATCHDOG_STATUS=142
codesign_bounded() {
  /usr/bin/perl -e 'alarm 30; exec @ARGV' /usr/bin/codesign "$@"
}

# Nested code is signed before the bundle that contains it.  That is what
# replaces --deep, which re-signs everything inside with the outer bundle's
# options and which Apple has deprecated for exactly that reason.
nested_code_paths() {
  find "$APP_CONTENTS" \
    \( -name '*.framework' -o -name '*.bundle' -o -name '*.appex' -o -name '*.dylib' \) \
    -prune -print 2>/dev/null | sort -r
}

# Helpers that live inside a framework (Sparkle's Installer.xpc and
# Downloader.xpc, Updater.app, and the bare Autoupdate executable) are signed
# before the framework that holds them, which is the order Sparkle's own
# code-signing guide gives.  Entitlements are preserved because Downloader.xpc
# carries its own.
framework_helper_paths() {
  local framework name
  for framework in "$APP_FRAMEWORKS"/*.framework; do
    [[ -d "$framework" ]] || continue
    name="$(basename "$framework" .framework)"
    find "$framework/Versions" -mindepth 3 -maxdepth 3 -path '*/XPCServices/*.xpc' -type d 2>/dev/null
    find "$framework/Versions" -mindepth 2 -maxdepth 2 -name '*.app' -type d 2>/dev/null
    find "$framework/Versions" -mindepth 2 -maxdepth 2 -type f -perm -u+x ! -name "$name" 2>/dev/null
  done
}

sign_with_identity() {
  local identity="$1" target status
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    if [[ "$target" == *.appex ]]; then
      codesign_bounded --force ${SIGN_OPTIONS[@]+"${SIGN_OPTIONS[@]}"} \
        --entitlements "$MAC_WIDGET_ENTITLEMENTS" --sign "$identity" "$target" || return 1
    else
      codesign_bounded --force ${SIGN_OPTIONS[@]+"${SIGN_OPTIONS[@]}"} --preserve-metadata=entitlements --sign "$identity" "$target" || return 1
    fi
  done < <(framework_helper_paths)
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    if [[ "$target" == *.appex ]]; then
      if ! codesign_bounded --force ${SIGN_OPTIONS[@]+"${SIGN_OPTIONS[@]}"} \
        --entitlements "$MAC_WIDGET_ENTITLEMENTS" --sign "$identity" "$target"; then
        echo "error: could not sign required widget extension: $target" >&2
        return 1
      fi
      continue
    fi
    codesign_bounded --force ${SIGN_OPTIONS[@]+"${SIGN_OPTIONS[@]}"} --sign "$identity" "$target" && continue
    status=$?
    # A SwiftPM resource bundle carries no Info.plist, so codesign calls it an
    # unsuitable bundle format.  That is expected and harmless — the app's own
    # signature seals it as a resource either way — so it is noted and skipped
    # rather than dragging the whole build down to ad-hoc.  A watchdog kill is
    # the one nested failure that is fatal, because it means codesign is
    # sitting on a key-access panel and the app would only hang too.
    [[ "$status" != "$WATCHDOG_STATUS" ]] || return 1
    echo "note: not separately signable, sealed as a resource instead: $target"
  done < <(nested_code_paths)
  codesign_bounded --force ${SIGN_OPTIONS[@]+"${SIGN_OPTIONS[@]}"} \
    --entitlements "$HOST_ENTITLEMENTS" --sign "$identity" "$APP_BUNDLE" || return 1
}

prepare_signing_entitlements() {
  if [[ ! -f "$MAC_WIDGET_ENTITLEMENTS" ]]; then
    echo "error: missing generated Mac widget entitlements: $MAC_WIDGET_ENTITLEMENTS" >&2
    exit 1
  fi
  local group_id
  group_id="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$MAC_WIDGET_ENTITLEMENTS" 2>/dev/null)" || {
    echo "error: Mac widget entitlements do not declare an app group." >&2
    exit 1
  }
  [[ "$group_id" == "CC8UTF7ATG.codecaps" ]] || {
    echo "error: unexpected Mac widget app group '$group_id'." >&2
    exit 1
  }
  cp "$MAC_WIDGET_ENTITLEMENTS" "$HOST_ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c 'Delete :com.apple.security.app-sandbox' "$HOST_ENTITLEMENTS"
  if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$HOST_ENTITLEMENTS" >/dev/null 2>&1; then
    echo "error: the standalone CodeCaps host must remain unsandboxed." >&2
    exit 1
  fi
}

verify_group_entitlement() {
  local bundle="$1" label="$2" actual team
  local entitlements_file
  entitlements_file="$(mktemp "${TMPDIR:-/tmp}/codecaps-entitlements.XXXXXX")"
  if ! /usr/bin/codesign -d --entitlements :- "$bundle" >"$entitlements_file" 2>/dev/null; then
    rm -f "$entitlements_file"
    actual=""
  else
    actual="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$entitlements_file" 2>/dev/null)" || actual=""
    rm -f "$entitlements_file"
  fi
  team="$(/usr/bin/codesign -dv --verbose=4 "$bundle" 2>&1 \
    | /usr/bin/sed -n 's/^TeamIdentifier=//p' | /usr/bin/head -n 1)"
  local validation_only="${3:-false}"
  if [[ "$actual" != "CC8UTF7ATG.codecaps" || ( "$validation_only" != "true" && "$team" != "CC8UTF7ATG" ) ]]; then
    echo "error: $label signature lacks the expected team-authorized CodeCaps app group." >&2
    echo "error: expected group CC8UTF7ATG.codecaps and TeamIdentifier CC8UTF7ATG; found group '${actual:-none}' and team '${team:-none}'." >&2
    exit 1
  fi
}

# The designated requirement is the proof.  Signed stably it names the
# identifier and the team; ad-hoc it pins this one build's cdhash.
describe_signature() {
  /usr/bin/codesign -dv --verbose=2 "$APP_BUNDLE" 2>&1 | /usr/bin/sed 's/^/  /'
  /usr/bin/codesign -d -r- "$APP_BUNDLE" 2>&1 | /usr/bin/sed 's/^/  /'
}

# The check notarization makes of the nesting: every helper signed, every seal
# intact, nothing unsealed.  A bundle that fails it is never installed.
verify_app_signature() {
  if ! /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"; then
    echo "error: codesign --verify --deep --strict failed for $APP_BUNDLE" >&2
    exit 1
  fi
}

sign_app_bundle() {
  local identity
  prepare_signing_entitlements
  identity="$(resolve_codesign_identity)"
  if [[ -n "$identity" ]]; then
    if sign_with_identity "$identity"; then
      echo "signed with $identity"
      describe_signature
      verify_app_signature
      verify_group_entitlement "$APP_PLUGINS/CodeCapsWidgets.appex" "CodeCaps widget extension"
      verify_group_entitlement "$APP_BUNDLE" "CodeCaps host app"
      return 0
    fi
    echo "error: signing with '$identity' failed or timed out." >&2
    exit 1
  else
    if [[ "$MODE" == "--build-only" && "${CODECAPS_ALLOW_ADHOC_VALIDATION:-}" == "1" ]]; then
      if sign_with_identity "-"; then
        echo "signed ad-hoc for build-only structural validation"
        describe_signature
        verify_app_signature
        verify_group_entitlement "$APP_PLUGINS/CodeCapsWidgets.appex" "CodeCaps widget extension" true
        verify_group_entitlement "$APP_BUNDLE" "CodeCaps host app" true
        echo "App Group runtime access: UNVERIFIED (ad-hoc signature has no Developer Team ID)."
        return 0
      fi
      echo "error: ad-hoc structural validation signing failed." >&2
      exit 1
    fi
    echo "error: no Developer ID Application identity is available; team-authorized widget app-group signing is required." >&2
    exit 1
  fi
}

# The marketing version lives in one file so a release is a one-line edit, and
# the build number is the commit count so it is monotonic without bookkeeping.
short_version() {
  local version=""
  [[ ! -f "$VERSION_FILE" ]] || version="$(/usr/bin/sed -e 's/[[:space:]]//g' -e '/^$/d' "$VERSION_FILE" | /usr/bin/head -n 1)"
  printf '%s\n' "${version:-0.0.0}"
}

bundle_version() {
  local count=""
  count="$(/usr/bin/git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || true)"
  printf '%s\n' "${count:-1}"
}

bundle_identifier() {
  /usr/bin/plutil -extract CFBundleIdentifier raw -o - "$1/Contents/Info.plist" 2>/dev/null || true
}

# macOS before 26 draws an app icon exactly as given, so a full-bleed square
# master looks like a sticker in the Dock.  The master stays square — that is
# the fleet rule and every other surface wants it — and the macOS shape is
# derived here, at build time, into a throwaway file.
stage_icon() {
  if [[ -f "$ROOT_DIR/assets/AppIcon.icns" ]]; then
    cp "$ROOT_DIR/assets/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"
    ICON_FILE="AppIcon.icns"
    echo "icon: using canonical assets/AppIcon.icns"
    return 0
  fi

  local master="$ICON_MASTER"
  [[ -f "$master" ]] || master="$ICON_FALLBACK"
  [[ -f "$master" ]] || { echo "warning: no icon master found, shipping without an icon" >&2; return 0; }

  local workdir shaped
  workdir="$(mktemp -d "${TMPDIR:-/tmp}/agentbar-icon.XXXXXX")"
  shaped="$workdir/shaped.png"
  if [[ -f "$ICON_MAKER" ]] && swift "$ICON_MAKER" "$master" "$shaped" >/dev/null 2>&1; then
    echo "icon: derived the macOS icon shape from $(basename "$master")"
  else
    echo "warning: could not derive the macOS icon shape; using the square master as-is" >&2
    shaped="$master"
  fi

  if command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
    local iconset="$workdir/AppIcon.iconset"
    mkdir -p "$iconset"
    local spec size name
    for spec in "16:icon_16x16" "32:icon_16x16@2x" "32:icon_32x32" "64:icon_32x32@2x" \
                "128:icon_128x128" "256:icon_128x128@2x" "256:icon_256x256" \
                "512:icon_256x256@2x" "512:icon_512x512" "1024:icon_512x512@2x"; do
      size="${spec%%:*}"
      name="${spec#*:}"
      sips -z "$size" "$size" "$shaped" --out "$iconset/$name.png" >/dev/null
    done
    iconutil -c icns "$iconset" -o "$APP_RESOURCES/AppIcon.icns"
    ICON_FILE="AppIcon.icns"
  else
    cp "$shaped" "$APP_RESOURCES/AppIcon.png"
    ICON_FILE="AppIcon.png"
  fi
  rm -rf "$workdir"
}

# The resource bundle has to sit under Contents/Resources, which is the only
# place codesign seals it -- a copy at the .app root makes signing fail with
# "unsealed contents present in the bundle root".  `ResourceBundle` in
# Sources/CodeCaps/PlatformLogo.swift is what looks there, because the generated
# `Bundle.module` accessor does not.
assert_resource_bundle_reachable() {
  local resource_name="$1" target="$APP_RESOURCES/$1"
  if [[ ! -d "$target" ]]; then
    echo "error: the staged app cannot reach its resource bundle: $target is missing." >&2
    echo "error: refusing to sign and install an app whose brand marks cannot be found." >&2
    exit 1
  fi
  echo "resource bundle reachable at Contents/Resources: $resource_name"
}

build_and_stage() {
  local arch_flags=()
  if [[ "$UNIVERSAL" == "1" ]]; then
    local arch
    for arch in "${UNIVERSAL_ARCHS[@]}"; do arch_flags+=(--arch "$arch"); done
    if ! swift build --package-path "$PACKAGE_DIR" --configuration "$CONFIGURATION" --jobs "${CODECAPS_BUILD_JOBS:-2}" "${arch_flags[@]}"; then
      echo "warning: the universal build failed; falling back to this machine's architecture only." >&2
      echo "warning: the resulting artifact will not run on every supported Mac." >&2
      UNIVERSAL=0
      arch_flags=()
    fi
  fi
  if [[ "$UNIVERSAL" != "1" ]]; then
    swift build --package-path "$PACKAGE_DIR" --configuration "$CONFIGURATION" --jobs "${CODECAPS_BUILD_JOBS:-2}"
  fi
  local build_bin_dir build_binary build_resources
  build_bin_dir="$(swift build --package-path "$PACKAGE_DIR" --configuration "$CONFIGURATION" ${arch_flags[@]+"${arch_flags[@]}"} --show-bin-path)"
  build_binary="$build_bin_dir/$PRODUCT_NAME"
  [[ -x "$build_binary" ]] || { echo "built executable not found: $build_binary" >&2; exit 1; }

  [[ ! -L "$DIST_DIR" ]] || { echo "refusing symlink dist directory: $DIST_DIR" >&2; exit 1; }
  [[ ! -L "$APP_BUNDLE" ]] || { echo "refusing symlink app bundle: $APP_BUNDLE" >&2; exit 1; }
  rm -rf "$APP_BUNDLE"
  mkdir -p "$APP_MACOS" "$APP_RESOURCES"
  cp "$build_binary" "$APP_EXECUTABLE"
  chmod +x "$APP_EXECUTABLE"
  embed_frameworks "$build_bin_dir"
  embed_plugins
  if [[ "$UNIVERSAL" == "1" ]]; then
    local archs
    archs="$(/usr/bin/lipo -archs "$APP_EXECUTABLE" 2>/dev/null || true)"
    echo "architectures: $archs"
    local wanted
    for wanted in "${UNIVERSAL_ARCHS[@]}"; do
      [[ " $archs " == *" $wanted "* ]] || { echo "universal build is missing $wanted: $archs" >&2; exit 1; }
    done
  fi
  build_resources="$(find "$build_bin_dir" -maxdepth 1 -type d \( -name "*_"$PRODUCT_NAME.bundle -o -name "*_"$PRODUCT_NAME.resources \) -print -quit)"
  # A staged app with no resource bundle is a staged app with no brand marks, and
  # `PlatformLogoImage` resolves the bundle by hand because `Bundle.module` calls
  # fatalError instead of returning nil.  Fail the build here rather than hand
  # over a bundle whose icons quietly never appear.
  if [[ -z "$build_resources" ]]; then
    echo "error: no SwiftPM resource bundle for $PRODUCT_NAME in $build_bin_dir." >&2
    echo "error: $APP_NAME needs its brand marks; refusing to stage an app without them." >&2
    exit 1
  fi
  cp -R "$build_resources" "$APP_RESOURCES/"
  assert_resource_bundle_reachable "$(basename "$build_resources")"
  stage_icon

  /usr/bin/tee "$INFO_PLIST" >/dev/null <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleExecutable</key>
  <string>$PRODUCT_NAME</string>
  <key>CFBundleIconFile</key>
  <string>$ICON_FILE</string>
  <key>CFBundleShortVersionString</key>
  <string>$(short_version)</string>
  <key>CFBundleVersion</key>
  <string>$(bundle_version)</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
$(sparkle_plist_entries)
</dict>
</plist>
PLIST

  sign_app_bundle
}

install_owned_app() {
  local destination="$INSTALLED_APP"
  local staging="$INSTALL_DIR/$APP_NAME.app.installing.$$"
  local backup="$INSTALL_DIR/$APP_NAME.app.previous.$$"
  mkdir -p "$INSTALL_DIR"
  [[ ! -L "$INSTALL_DIR" ]] || { echo "refusing symlink Applications directory: $INSTALL_DIR" >&2; exit 1; }
  [[ ! -e "$staging" && ! -L "$staging" ]] || { echo "temporary install path already exists: $staging" >&2; exit 1; }
  [[ ! -e "$backup" && ! -L "$backup" ]] || { echo "temporary rollback path already exists: $backup" >&2; exit 1; }
  if [[ -e "$destination" || -L "$destination" ]]; then
    [[ ! -L "$destination" && -d "$destination" ]] || { echo "refusing symlink or non-bundle destination: $destination" >&2; exit 1; }
    local existing_id
    existing_id="$(bundle_identifier "$destination")"
    if [[ -n "$existing_id" && "$existing_id" != "$BUNDLE_ID" ]]; then
      echo "overwriting bundle with identifier '$existing_id': $destination"
    fi
    # The copy being replaced has to stop running, and it is addressed by its
    # exact executable path so no other app named CodeCaps is ever signalled.
    kill_installed_app
  fi
  cp -R "$APP_BUNDLE" "$staging"
  /usr/bin/plutil -lint "$staging/Contents/Info.plist" >/dev/null
  if [[ -e "$destination" ]]; then
    mv "$destination" "$backup"
  fi
  if ! mv "$staging" "$destination"; then
    if [[ -e "$backup" ]]; then mv "$backup" "$destination"; fi
    rm -rf "$staging"
    exit 1
  fi
  rm -rf "$backup"
  echo "installed $destination"
}

# Moves a bundle to the Trash rather than deleting it, so a mistake is
# recoverable.  `rm -rf` on an app bundle is not.
trash_path() {
  local path="$1"
  if [[ "${CODECAPS_PRUNE_DRY_RUN:-${AGENTBAR_PRUNE_DRY_RUN:-0}}" == "1" ]]; then
    echo "would trash $path"
    return 0
  fi
  if /usr/bin/osascript - "$path" >/dev/null 2>&1 <<'APPLESCRIPT'; then
on run argv
  tell application "Finder" to delete (POSIX file (item 1 of argv))
end run
APPLESCRIPT
    echo "trashed $path"
  else
    echo "could not Trash (left in place): $path" >&2
  fi
}

# Exactly one installed copy.  Anything else carrying this app's release bundle
# identifier, in one of the usual places, goes to the Trash — and nothing else
# does: a different identifier is skipped, and no other checkout is searched.
prune_other_copies() {
  local keep="$1"
  local root candidate identifier executable
  for root in "${PRUNE_ROOTS[@]}"; do
    [[ -d "$root" ]] || continue
    while IFS= read -r candidate; do
      [[ -n "$candidate" ]] || continue
      [[ "$candidate" != "$keep" ]] || continue
      identifier="$(bundle_identifier "$candidate")"
      [[ "$identifier" == "$RELEASE_BUNDLE_ID" ]] || continue
      executable="$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$candidate/Contents/Info.plist" 2>/dev/null || true)"
      if [[ -n "$executable" ]]; then
        kill_owned_process "$candidate/Contents/MacOS/$executable"
      fi
      trash_path "$candidate"
    done < <(find "$root" -maxdepth 3 \( -name "$APP_NAME.app" -o -name "AgentBar.app" \) -type d 2>/dev/null)
  done
}

package_dist() {
  CONFIGURATION="release"
  UNIVERSAL=1
  # A distributed build needs the hardened runtime and a secure timestamp, or
  # notarization rejects it.  --package stops here; --release goes on to
  # notarize what this produced.
  SIGN_OPTIONS=(--options runtime --timestamp)
  build_and_stage
  write_zip
  echo "Packaged: $ZIP_FILE"
  echo "SHA-256:  $(sha_of "$ZIP_FILE")"
  if [[ "$KEEP_STAGED_APP" != "1" ]]; then
    # The zip is the artifact; leaving the staged bundle behind is how a second
    # copy of the app ends up on disk in the first place.
    rm -rf "$APP_BUNDLE"
    echo "Notarize and staple with:"
    echo "  script/build_and_run.sh --release"
  fi
}

sha_of() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

write_sha_file() {
  local file="$1" sha
  sha="$(sha_of "$file")"
  echo "$sha  $(basename "$file")" > "$file.sha256"
  echo "$sha"
}

# ditto is what Apple's own notarization documentation uses.  It keeps the
# bundle's symlinks and extended attributes, which a plain zip does not, and a
# mangled bundle is rejected before it is even examined.
write_zip() {
  rm -f "$ZIP_FILE"
  /usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_FILE"
  write_sha_file "$ZIP_FILE" >/dev/null
}

# Submits one file and refuses to continue unless Apple accepted it.  A
# rejection is printed in full, because the log is the only thing that says
# which of the hundred notarization rules was broken.
notarize_file() {
  local file="$1"
  local response submission status
  echo "Submitting $(basename "$file") to Apple for notarization.  This takes a few minutes."
  if ! response="$(xcrun notarytool submit "$file" "${NOTARY_AUTH[@]}" --wait --output-format json 2>/dev/null)"; then
    echo "notarization could not be submitted for $(basename "$file")." >&2
    if [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
      echo "check NOTARY_KEY_PATH, NOTARY_KEY_ID and NOTARY_ISSUER_ID (an App Store Connect API key)." >&2
    else
      echo "check that the keychain profile '$NOTARY_PROFILE' exists (xcrun notarytool store-credentials)." >&2
    fi
    exit 1
  fi
  submission="$(printf '%s' "$response" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')"
  status="$(printf '%s' "$response" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))')"
  echo "notarization id:     $submission"
  echo "notarization status: $status"
  if [[ "$status" != "Accepted" ]]; then
    echo "notarization was not accepted for $(basename "$file").  Apple's log follows." >&2
    xcrun notarytool log "$submission" "${NOTARY_AUTH[@]}" >&2 || true
    exit 1
  fi
}

# A dmg is what a person who is handed a link expects to double-click, and the
# Applications symlink beside the app is the drag-to-install gesture everyone
# already knows.
build_dmg() {
  local staging="$DIST_DIR/dmg-staging"
  rm -rf "$staging"
  mkdir -p "$staging"
  cp -R "$APP_BUNDLE" "$staging/$APP_NAME.app"
  ln -s /Applications "$staging/Applications"
  rm -f "$DMG_FILE"
  /usr/bin/hdiutil create -volname "$APP_NAME" -srcfolder "$staging" -ov -format UDZO "$DMG_FILE"
  rm -rf "$staging"

  local identity
  identity="$(resolve_codesign_identity)"
  if [[ -n "$identity" ]]; then
    codesign_bounded --force --timestamp --sign "$identity" "$DMG_FILE"
    echo "signed $DMG_FILE with $identity"
  else
    echo "no Developer ID Application identity is available to sign the disk image." >&2
    exit 1
  fi
}

release_dist() {
  KEEP_STAGED_APP=1
  package_dist

  notarize_file "$ZIP_FILE"
  # Stapling writes Apple's ticket into the bundle, which is what lets a Mac
  # that is offline, or behind a firewall, still open it without a warning.
  /usr/bin/xcrun stapler staple "$APP_BUNDLE"
  # What a downloaded copy will face: Gatekeeper must accept the stapled app.
  /usr/sbin/spctl --assess --type execute -vv "$APP_BUNDLE"
  # The zip that was submitted holds the unstapled bundle, so it is rebuilt
  # from the stapled one.  Whoever downloads the zip gets the ticket too.
  write_zip

  build_dmg
  notarize_file "$DMG_FILE"
  /usr/bin/xcrun stapler staple "$DMG_FILE"
  /usr/sbin/spctl --assess --type open --context context:primary-signature -vv "$DMG_FILE"

  local zip_sha dmg_sha
  zip_sha="$(write_sha_file "$ZIP_FILE")"
  dmg_sha="$(write_sha_file "$DMG_FILE")"

  echo
  echo "Release artifacts in $DIST_DIR"
  echo "  $APP_NAME.zip  $zip_sha"
  echo "  $APP_NAME.dmg  $dmg_sha"
  echo "  version $(short_version) (build $(bundle_version))"
}

case "$MODE" in
  --build-only|build-only)
    build_and_stage
    ;;
  run)
    build_and_stage
    install_owned_app
    /usr/bin/open -n "$INSTALLED_APP"
    rm -rf "$APP_BUNDLE"
    prune_other_copies "$INSTALLED_APP"
    ;;
  --install|install)
    build_and_stage
    install_owned_app
    rm -rf "$APP_BUNDLE"
    prune_other_copies "$INSTALLED_APP"
    ;;
  --dev|dev)
    BUNDLE_ID="$DEV_BUNDLE_ID"
    kill_owned_app
    build_and_stage
    # Launched from dist/, beside the installed copy, which is left running.
    /usr/bin/open -n "$APP_BUNDLE"
    echo "dev instance running from $APP_BUNDLE"
    ;;
  --dev-stop|dev-stop)
    kill_owned_app
    rm -rf "$DIST_DIR"
    echo "dev instance stopped and $DIST_DIR removed"
    ;;
  --package|package)
    package_dist
    ;;
  --release|release)
    release_dist
    ;;
  --debug|debug)
    kill_owned_app
    build_and_stage
    lldb -- "$APP_EXECUTABLE"
    ;;
  --logs|logs)
    kill_owned_app
    build_and_stage
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate "process == \"$PRODUCT_NAME\""
    ;;
  --telemetry|telemetry)
    kill_owned_app
    build_and_stage
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    kill_owned_app
    build_and_stage
    /usr/bin/open -n "$APP_BUNDLE"
    sleep 1
    /usr/bin/pgrep -f -x "$APP_EXECUTABLE" >/dev/null
    ;;
  --help|-h|help)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac

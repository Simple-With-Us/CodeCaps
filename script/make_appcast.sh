#!/usr/bin/env bash
# Writes the Sparkle appcast for one signed, notarized update archive.
#
#   script/make_appcast.sh <archive.zip> <download-url-prefix> <output-dir> [release-notes.md]
#
# The appcast has exactly one item: the archive, at <download-url-prefix><archive
# name>, with its EdDSA signature and length.  Sparkle only ever needs the newest
# item, and every release carries its own appcast, so there is no history to
# merge.  generate_appcast reads the version, minimum macOS and architectures
# from the app inside the archive, and refuses an archive whose SUPublicEDKey
# does not match the signing key, so a key mix-up fails here and not on a Mac.
#
# The EdDSA private key is read from $SPARKLE_ED_PRIVATE_KEY when it is set (CI
# passes it on standard input, never as an argument), and otherwise from the
# login Keychain account named by $SPARKLE_KEY_ACCOUNT (default "codecaps"),
# which is where Sparkle's generate_keys put it.  See docs/AUTO-UPDATE.md.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPARKLE_BIN="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin"
APP_LINK="${SPARKLE_APP_LINK:-https://codecaps.simplewithus.com/}"

usage() {
  echo "usage: script/make_appcast.sh <archive.zip> <download-url-prefix> <output-dir> [release-notes.md]" >&2
  exit 2
}

[[ $# -ge 3 && $# -le 4 ]] || usage
ARCHIVE="$1"
PREFIX="$2"
OUT_DIR="$3"
NOTES="${4:-}"
[[ -f "$ARCHIVE" ]] || { echo "error: no archive at $ARCHIVE" >&2; exit 1; }
[[ "$PREFIX" == */ ]] || PREFIX="$PREFIX/"

# The tools ship inside the SwiftPM binary artifact, so a resolve is all it
# takes to have them.
if [[ ! -x "$SPARKLE_BIN/generate_appcast" ]]; then
  swift package --package-path "$ROOT_DIR" resolve >/dev/null
fi
[[ -x "$SPARKLE_BIN/generate_appcast" ]] || { echo "error: generate_appcast not found under $SPARKLE_BIN" >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/appcast.XXXXXX")"
trap 'rm -rf "$work"' EXIT
cp "$ARCHIVE" "$work/"
archive_name="$(basename "$ARCHIVE")"
# generate_appcast pairs release notes with an archive by file name.
if [[ -n "$NOTES" ]]; then
  cp "$NOTES" "$work/${archive_name%.*}.md"
fi

args=(--download-url-prefix "$PREFIX" --link "$APP_LINK" --embed-release-notes -o "$work/appcast.xml")
if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
  printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$SPARKLE_BIN/generate_appcast" --ed-key-file - "${args[@]}" "$work"
else
  "$SPARKLE_BIN/generate_appcast" --account "${SPARKLE_KEY_ACCOUNT:-codecaps}" "${args[@]}" "$work"
fi

feed="$work/appcast.xml"
items="$(/usr/bin/grep -c '<item>' "$feed" || true)"
[[ "$items" == "1" ]] || { echo "error: expected one appcast item, found $items" >&2; exit 1; }
/usr/bin/grep -q 'sparkle:edSignature=' "$feed" || { echo "error: the appcast item carries no EdDSA signature" >&2; exit 1; }
/usr/bin/grep -q "url=\"$PREFIX$archive_name\"" "$feed" || { echo "error: the appcast does not point at $PREFIX$archive_name" >&2; exit 1; }

mkdir -p "$OUT_DIR"
cp "$feed" "$OUT_DIR/appcast.xml"
version="$(/usr/bin/sed -n 's:.*<sparkle\:version>\(.*\)</sparkle\:version>.*:\1:p' "$feed" | /usr/bin/head -n 1)"
short="$(/usr/bin/sed -n 's:.*<sparkle\:shortVersionString>\(.*\)</sparkle\:shortVersionString>.*:\1:p' "$feed" | /usr/bin/head -n 1)"
echo "appcast: $OUT_DIR/appcast.xml"
echo "  item:  version $short (build $version)"
echo "  url:   $PREFIX$archive_name"

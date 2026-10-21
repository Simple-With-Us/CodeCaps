#!/usr/bin/env bash
# Load the staged App Store Connect private key into ASC_KEY_P8.
#
# Source this file from a workflow step that starts an App Store Connect
# client:
#
#   source scripts/ios-load-asc-key.sh
#   node scripts/ios-fleet/asc-api.mjs ensure-standing-testers "$appleid"
#
# The workflow stages the key once, to a mode-600 file, and this helper reads
# that file back into the calling shell as ASC_KEY_P8.  The credential then
# travels to the client as the environment variable the client reads, so it
# never enters $GITHUB_ENV, never becomes a command argument and never
# reaches a log line.  It exists only in the environment of the step that
# sourced it and in the environment of the clients that step starts.
#
# The clients refuse a path as a credential source (Kody rule 42), so the
# staged file stays what it is:  a staging detail for the Apple tools that
# need a key on disk, and the carrier between two steps of the same job.
# Nothing here is a second way for a client to resolve a credential; it is
# the shell layer that owns the credential handing it over.
#
# This file is meant to be sourced, not executed.  It sets no shell options,
# because a sourced file that did would change the caller's shell.

# Reads the staged key and exports it as ASC_KEY_P8.
#
# The checks are the ones a credential deserves on the way in:  the path must
# be set, the file must exist, its mode must be 600 so that nothing else on
# the runner can read it, and it must hold something.  Each failure names
# what is wrong and returns non-zero, and none of them prints the value.
asc_load_asc_key() {
  local path="${ASC_KEY_PATH:-}"
  if [ -z "$path" ]; then
    echo "error: ASC_KEY_PATH is not set; the ASC key was never staged." >&2
    return 1
  fi
  if [ ! -f "$path" ]; then
    echo "error: the staged ASC key file is missing." >&2
    return 1
  fi

  # The file holds a credential, so only its owner may read it.  The mode is
  # the last chance to notice, so a file that is group or world readable is
  # refused rather than loaded.  BSD and GNU stat disagree on the flag, so
  # both are tried and a mode that cannot be read at all is a refusal too.
  local mode
  mode="$(stat -f '%Lp' "$path" 2>/dev/null || stat -c '%a' "$path" 2>/dev/null || true)"
  case "$mode" in
    600) ;;
    '')
      echo "error: could not read the mode of the staged ASC key file; refusing to load it." >&2
      return 1
      ;;
    *)
      echo "error: the staged ASC key file is mode ${mode}, not 600; refusing to load it." >&2
      return 1
      ;;
  esac

  local pem
  pem="$(cat "$path")"
  if [ -z "${pem//[[:space:]]/}" ]; then
    echo "error: the staged ASC key file holds no key material." >&2
    return 1
  fi

  ASC_KEY_P8="$pem"
  export ASC_KEY_P8
  unset pem
  return 0
}

asc_load_asc_key

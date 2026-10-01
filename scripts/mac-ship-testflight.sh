#!/usr/bin/env bash
# Thin wrapper: ship CodeCaps for Mac to TestFlight (no Xcode UI / no Mac seat).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IN_REPO="${ROOT}/scripts/ios-fleet/ship-testflight.sh"
MAC="/Users/jay/apps/ios-fleet/ship-testflight.sh"
if [[ -f "$IN_REPO" ]]; then
  exec bash "$IN_REPO" codecaps-mac --repo-root "$ROOT" "$@"
fi
if [[ -f "$MAC" ]]; then
  exec bash "$MAC" codecaps-mac --repo-root "$ROOT" "$@"
fi
echo "error: ios-fleet ship-testflight.sh not found at ${IN_REPO} or ${MAC}" >&2
exit 1

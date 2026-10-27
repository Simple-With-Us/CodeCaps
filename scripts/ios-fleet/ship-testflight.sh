#!/usr/bin/env bash
# ship-testflight.sh - Archive + upload an iOS app to TestFlight without Xcode UI.
#
# Usage:
#   bash /Users/jay/apps/ios-fleet/ship-testflight.sh <socratic|congress|usage|usage-local|dealdex|autorotate|autorotate-mac|contactlogo|contactlogo-mac|botfleet|botfleet-mac|MiniMax> [options]
#
# Options:
#   --repo-root PATH   Repo root (default: cwd)
#   --build N          Force CURRENT_PROJECT_VERSION (exact; default: the repo
#                      commit count, raised above the App Store Connect floor)
#   --version X.Y.Z    Force MARKETING_VERSION (exact; default: the next patch
#                      on the app's train)
#   --export-only      Build IPA only; do not upload
#   --upload-only IPA  Skip archive; upload an existing IPA via ASC API key
#   --dry-run          Print plan and exit
#   --skip-xcodegen    Do not regenerate .xcodeproj
#   --allow-dirty      Allow shipping from a dirty git worktree
#   --force-ship       Bypass min-interval + same-HEAD skip (emergency / owner)
#   --sync-project-version  Write the resolved version into project.pbxproj
#   --allow-unverified-seq  Ship even if App Store Connect cannot be consulted
#                           (dangerous: the marketing version and the build
#                           number are then planned from unverified state)
#
# Version numbering (owner directive 2026-10-24, AFC-517; replaces the
# 1.0.<commit_count> scheme unified fleet-wide on 2026-10-18, fleet PR #2801):
#   MARKETING_VERSION       = <prefix>.<P+1>
#       <prefix> is the train from marketingVersionDefault (1.0).  P is the
#       highest patch already used on that train in App Store Connect, counting
#       BOTH the App Store versions (appStoreVersions.versionString) AND the
#       TestFlight trains (preReleaseVersions.version) for the app's platform.
#       A TestFlight train that holds a build named after its own patch (the
#       "1.0.2358 (2358)" drift trains) is IGNORED, so those uploads no longer
#       push the version forward.  App Store versions are never ignored.
#       When P+1 is itself already held by an App Store version or a TestFlight
#       train (a drift train included), the patch moves up to the next one nothing holds, so the
#       shipped version is always new (nextMarketingPatch in version-plan.mjs).
#   CURRENT_PROJECT_VERSION = the repo commit count (git rev-list --count
#       HEAD), raised when needed so that it is strictly greater than every
#       build already in the TARGET marketing train (old 12-digit UTC stamps
#       included:  Apple requires build numbers to grow inside one train) and
#       than the app's highest plain-integer build below 1000000000 on that
#       platform.  On macOS EVERY build counts, because macOS build numbers
#       have to grow across all trains.
#   The two numbers are INDEPENDENT:  the build number never names the
#   marketing version, and the marketing version never names the build.  The
#   only coupling is a safety rule:  a ship must never look like "1.0.N (N)",
#   so a build that happens to equal the patch number moves one up.
#   --version X.Y.Z is an exact marketing override and --build N an exact build
#   override.  With --version only the build is still automatic (the commit
#   count, floored against that train);  with --build only the marketing
#   version is still the automatic next patch.
#   App Store Connect renders "<marketing> (<build>)", e.g. "1.0.237 (2360)".
#   Unified across macOS and iOS; timestamps permanently retired.
#
# ---------------------------------------------------------------------------
# WHAT IS HOLDING BACK AUTOMATIC SHIPPING: THE MIN-INTERVAL RATE LIMIT
# ---------------------------------------------------------------------------
# Applies to uploads only (--export-only and --dry-run are free):
#   DEFAULT MINIMUM INTERVAL BETWEEN SUCCESSFUL TESTFLIGHT SHIPS, PER APP:
#       DEFAULT_MIN_INTERVAL_SEC=3600  (3600 seconds = 1 hour)
#   That constant is defined a few dozen lines below and is the main reason a
#   merge to main does not become a TestFlight build. .github/workflows/
#   ios-ship.yml fires on every push to main touching clients/ios/**, and this
#   gate turns most of those runs into a no-op skip (exit 0).
#   Override for one run:  IOS_TF_MIN_INTERVAL_SEC=7200 (2h)  or  --force-ship
#   Change the default:    edit DEFAULT_MIN_INTERVAL_SEC below (owner's call).
#
#   Also skips when git HEAD matches the last successful ship (no new commits).
#   Skip exits 0 ("nothing to do") so agent loops stay quiet, and a skipped run
#   does NOT resolve or consume a version (see the ship-gate ordering note
#   at the call site).
#   State: ~/.cache/ios-fleet/last-ship-<app>.txt  (unix_ts + space + git_sha)
#
# ---------------------------------------------------------------------------
# POST-UPLOAD: ensure-tf-ready AND TESTFLIGHT RELEASE NOTES (2026-08-13)
# ---------------------------------------------------------------------------
# ensure_tf_ready now passes BUILD_NUM (CFBundleVersion) to asc-api.mjs, which
# polls App Store Connect until THAT EXACT BUILD appears and only then declares
# export compliance on it. Before this it took "the newest build", which for the
# first minutes after an upload is the PREVIOUS ship -- so compliance was
# declared on the wrong build and the "testers can install this" line described
# a build it had never looked at.
#   IOS_TF_READY_TIMEOUT_SEC   discovery + readiness budget (default 900s)
#   exit 4 from asc-api.mjs    uploaded build never surfaced; warn, do NOT fail
#                              (record_successful_ship must still run or the rate
#                              gate never advances)
#
# It also renders the mandatory FLEET-PROTOCOL "What to Test" release note from the
# commit range since the last successful ship. THIS IS OPT-IN, because it writes
# copy every TestFlight tester reads:
#   IOS_TF_RELEASE_NOTES=1     publish to App Store Connect
#   IOS_TF_RELEASE_NOTES=0     off entirely
#   unset (DEFAULT)            dry render into the ship log; nothing is written
# Owner binding 2026-09-08 (Jay): production ships MUST publish What to Test
# (IOS_TF_RELEASE_NOTES=1). Body = 1-2 change/fix/upgrade types, or the other
# reason for the build if not a product change. Empty/placeholder/agent names ban.
# No --force-ship.
#   IOS_TF_RELEASE_TITLE=...   override the "<App> Update" title
# CI needs `fetch-depth: 0` on actions/checkout or the runner workspace holds a
# single commit and the range is uncomputable (verified 2026-08-13 on all three
# fleet runners).
#
# Secrets (never printed):
#   ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8  (env first, e.g. CI; else Infisical via
#   `fleet-secrets get` from Fleet-OPS /asc: ASC_KEY_ID, ASC_ISSUER_ID and the .p8 in ASC_KEY_P8,
#   written to a 0600 temp file and deleted on exit)
#   A named ASC_KEY_PATH is not a credential source at all:  it is ignored, so
#   a stale or foreign path in an operator's shell can never decide which
#   credential signs a request.  The credential comes from the environment or
#   from Infisical, and the key is handed to the node client in the client's
#   environment (see asc_client).  altool and Xcode are given the path of the
#   staged copy this script writes for them.
#   or Xcode-signed-in session for destination=upload export
#   SENTRY_AUTH_TOKEN_FULLSCOPE
#                        (the Sentry API token for the dSYM + Size Analysis
#                        upload; env or `fleet-secrets get`).  This is the only
#                        credential sentry-cli accepts.  SENTRY_AUTH_TOKEN on
#                        some repos holds the DSN instead, and a DSN is not an
#                        API token, so sentry-cli refuses it in about seventy
#                        milliseconds and the upload never happens.
#   SENTRY_AUTH_TOKEN  (legacy token slot; used only when it is not a DSN)
#   SENTRY_DSN         (injected into xcodebuild so Cocoa plist $(SENTRY_DSN) is set)
#
# Sentry after a successful archive (2026-09-01):
#   debug-files upload of the xcarchive dSYMs, then `sentry-cli build upload`
#   for Size Analysis.  The upload goes to the project the DSN names AND to the
#   app's own project, because the DSN is one shared fleet key and it moves.
#   Failures WARN and do not fail the TestFlight ship, but they are also
#   reported as ::error:: annotations and recorded, so the run shows red
#   instead of one warning line inside a green job (CC-200).
#   Quota: 100 size-analysis builds/month on the sponsored plan.  No LaunchAgent.
#
# ASCII-only (Apple bash 3.2 safe). Team: CC8UTF7ATG.

set -euo pipefail

# LaunchAgents inherit a tiny PATH (no Homebrew).  Node is required for
# ensure-tf-ready.  Keep Homebrew available, but prefer Apple's rsync: Xcode's
# exportArchive passes --extended-attributes to its rsync child, which Homebrew
# rsync 3.x rejects with "unknown option" and aborts the export.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:${PATH}"
# The node that runs asc-api.mjs.  IOS_FLEET_NODE lets an offline test answer
# App Store Connect from a stub;  a real ship leaves it unset and uses node
# from PATH.
ASC_NODE="${IOS_FLEET_NODE:-node}"

FLEET_DIR="$(cd "$(dirname "$0")" && pwd)"
APPS_JSON="${FLEET_DIR}/apps.json"
TEAM_ID="CC8UTF7ATG"
# AFC-359: App Store Connect credentials come from the environment (CI sets them) or
# Infisical Fleet-OPS via fleet-secrets.  Nothing is read from the old secrets folder.
FLEET_SECRETS_BIN="${FLEET_SECRETS:-${HOME}/.local/bin/fleet-secrets}"
ASC_TMP_DIR=""
cleanup_asc_tmp() {
  # The redirects are on every path:  a bare `rm` can be a wrapper that prints
  # to stdout, and this function runs inside the helpers whose stdout IS the
  # value the caller reads.
  if [[ -n "${ASC_TMP_DIR:-}" ]]; then
    rm -rf "$ASC_TMP_DIR" >/dev/null 2>&1 || true
  fi
  ASC_TMP_DIR=""
  # The rejected-key label goes with it:  only the private directory this
  # run created, never a path read from the environment.
  if [[ -n "${_rejected_key_dir:-}" ]]; then
    rm -rf "$_rejected_key_dir" >/dev/null 2>&1 || true
  fi
  _rejected_key_dir=""
  _rejected_key_path=""
}
# The file the nonsecret label (key id and source) of a refused App Store
# Connect key travels through.
#
# Both helpers that can meet a rejection are only ever called through a
# command substitution, so they run in a subshell:  a global they assign
# dies with the subshell and never reaches the parent, and the fatal
# message would always read "rejected key unknown".  The label therefore
# travels through a file.  The parent creates it once, inside a private
# directory of its own (mode 0700, from mktemp -d), before any subshell
# runs;  a subshell inherits the path through these script-owned
# variables.  Nothing about the path comes from the environment, so a
# stale or hostile value can never pick what is written, read or removed.
_rejected_key_dir=""
_rejected_key_path=""
init_rejected_key_file() {
  _rejected_key_dir="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/ios-fleet-rejected-key.XXXXXX")" || {
    _rejected_key_dir=""
    _rejected_key_path=""
    return 1
  }
  _rejected_key_path="${_rejected_key_dir}/label"
}
rejected_key_file() {
  printf '%s' "${_rejected_key_path:-}"
}
# Expand only a leading "~/" (not "~user/") so a typo is never merged with $HOME.
expand_tilde() {
  case "$1" in
    "~/"*) printf '%s' "${HOME}/${1#\~/}" ;;
    *) printf '%s' "$1" ;;
  esac
}
trap cleanup_asc_tmp EXIT
init_rejected_key_file || echo "ship-testflight: could not create a private directory for the rejected-key label; a rejection will read \"rejected key unknown\"" >&2
# 1 hour — owner 2026-08-14: ship unbuilt iOS updates as often as once per hour.
# Not Apple compute; local/process hygiene. Cron ticks twice an hour so a
# trailing merge inside the window is picked up on the next eligible tick.
DEFAULT_MIN_INTERVAL_SEC=3600
# Overridable so the sequence/rate-limit state can be pointed at a scratch dir
# for testing without touching real ship history.
STATE_DIR="${IOS_FLEET_STATE_DIR:-${HOME}/.cache/ios-fleet}"

APP_KEY=""
REPO_ROOT=""
FORCE_BUILD=""
FORCE_VERSION=""
EXPORT_ONLY=0
UPLOAD_ONLY_IPA=""
DRY_RUN=0
SKIP_XCODEGEN=0
ALLOW_DIRTY=0
FORCE_SHIP=0
ALLOW_UNVERIFIED_SEQ=0
SYNC_PROJECT_VERSION=0

die() { echo "error: $*" >&2; exit 1; }
log() { echo "[ios-ship] $*"; }
# Same prefix, but on stderr — for use inside $(...) helpers whose stdout is
# the return value and must stay clean.
logerr() { echo "[ios-ship] $*" >&2; }

usage() {
  # Print the header comment block: everything before the first non-comment line.
  sed -n '2,${/^[^#]/q;p;}' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

json_get() {
  # json_get <app_key> <field>
  /usr/bin/python3 - "$APPS_JSON" "$1" "$2" <<'PY'
import json, sys
path, app, field = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.load(open(path))
apps = data["apps"]
if app not in apps:
    print("", end="")
    sys.exit(0)
val = apps[app].get(field)
if val is None:
    print("", end="")
elif isinstance(val, list):
    print(",".join(val), end="")
else:
    print(val, end="")
PY
}

resolve_project() {
  local root="$1" rel="$2" alt="$3"
  if [[ -n "$rel" && -e "${root}/${rel}" ]]; then
    echo "${root}/${rel}"
    return 0
  fi
  if [[ -n "$alt" && -e "${root}/${alt}" ]]; then
    echo "${root}/${alt}"
    return 0
  fi
  return 1
}

# fs_get NAME FOLDER -> value on stdout (never logged); non-zero when absent.
fs_get() {
  local v bin="$FLEET_SECRETS_BIN"
  [[ -x "$bin" ]] || bin="$(command -v fleet-secrets 2>/dev/null || true)"
  [[ -n "$bin" && -x "$bin" ]] || return 1
  v="$("$bin" get "$1" --path "$2" 2>/dev/null </dev/null)" || return 1
  [[ -n "$v" ]] || return 1
  printf '%s' "$v"
}

# Load ASC credentials into the CURRENT shell (must not run inside $(...) or the
# exported ASC_* vars are discarded with the subshell). Sets AUTH_MODE to
# "api_key" or "none". Never prints secret values.
#
# WHY THE KEY IS HANDED OVER IN THE ENVIRONMENT (2026-10-21, Kody rule 42):
# The private key is a secret, and the approved secret sources are the process
# environment, a captured `fleet-secrets get NAME` and bootstrap-only Keychain
# credentials.  A caller-supplied file is not one of them, so the node client
# never reads a key file.  This shell layer already owns the credential for
# altool and Xcode, so it hands the key to the client in the environment,
# which is where the client looks for it.
#
# THE CREDENTIAL IS RESOLVED FROM TWO PLACES (2026-10-21, Kody rule 42 on
# PR #271):
#   1. ASC_KEY_P8, when it holds a PEM private key and comes with its key id
#   2. Infisical Fleet-OPS /asc (or /authkey-<id>-p8)
# A disk credential is not a source at all:  a named ASC_KEY_PATH is ignored,
# so a stale or foreign path in an operator's shell can never sign the
# upload with the wrong key, and App Store Connect would answer 401 without
# saying which input was wrong.  The key material never enters a command
# argument and never reaches a log line.
load_secrets() {
  AUTH_MODE="none"
  local kid="${ASC_KEY_ID:-}" iss="${ASC_ISSUER_ID:-}" p8="" fkid="" lower
  local key_pem="" key_path="" rc=0
  #  A named ASC_KEY_PATH is not a credential source.  It is remembered only
  #  so the run can say that it ignored it.
  local named_path="${ASC_KEY_PATH:-}"

  # 1. An ambient ASC_KEY_P8.  It is only usable when it really is a PEM
  #    private key and comes with the key id and issuer it belongs to.  It is
  #    resolved first, so nothing can override it.
  if [[ -n "${ASC_KEY_P8:-}" ]]; then
    if [[ -z "$kid" || -z "$iss" ]]; then
      log "ASC_KEY_P8 is set without ASC_KEY_ID and ASC_ISSUER_ID; ignoring it"
      unset ASC_KEY_P8
    else
      rc=0
      node "${FLEET_DIR}/asc-key.mjs" validate >/dev/null 2>&1 <<< "$ASC_KEY_P8" || rc=$?
      if [[ "$rc" -ne 0 ]]; then
        log "ASC_KEY_P8 is set but does not hold a PEM private key; ignoring it"
        unset ASC_KEY_P8
      else
        key_pem="$ASC_KEY_P8"
      fi
    fi
  fi

  # 2. The key id, issuer and private key must belong together:  with nothing named in the
  # environment all three come from /asc;  an env key id that is not the /asc one gets its
  # own .p8 from /authkey-<id>-p8, never the /asc key.
  if [[ -z "$key_pem" ]]; then
    fkid="$(fs_get ASC_KEY_ID /asc)" || fkid=""
    if [[ -z "$kid" ]]; then
      kid="$fkid"
      iss="$(fs_get ASC_ISSUER_ID /asc)" || iss=""
    elif [[ -z "$iss" && "$kid" == "$fkid" ]]; then
      # env named the /asc key itself:  its issuer is the /asc one
      iss="$(fs_get ASC_ISSUER_ID /asc)" || iss=""
    fi
    if [[ -z "$kid" || -z "$iss" ]]; then
      log "ASC credentials missing: set ASC_KEY_ID/ASC_ISSUER_ID/ASC_KEY_P8 or add ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_P8 to Infisical /asc"
      return 0
    fi
    if [[ "$kid" == "$fkid" ]]; then
      p8="$(fs_get ASC_KEY_P8 /asc)" || p8=""
    else
      lower="$(printf '%s' "$kid" | tr 'A-Z' 'a-z')"
      p8="$(fs_get "AUTHKEY_${kid}" "/authkey-${lower}-p8")" || p8=""
    fi
    if [[ -z "$p8" ]]; then
      log "missing the .p8 for key ${kid}: Infisical /asc ASC_KEY_P8 (the /asc key) or /authkey-<id>-p8 AUTHKEY_<id>"
      return 0
    fi
    key_pem="$p8"
    p8=""
  fi

  # The key has to be in a mode-600 file for altool and Xcode, and in the
  # environment for the node client, which never reads a file.  The file is
  # written from the credential that was just resolved, so it is never read
  # back as a credential.
  if [[ -z "$ASC_TMP_DIR" ]]; then
    ASC_TMP_DIR="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/asc-key.XXXXXX")"
  fi
  key_path="${ASC_TMP_DIR}/AuthKey_${kid}.p8"
  if ! node "${FLEET_DIR}/asc-key.mjs" write "$key_path" <<< "$key_pem"; then
    log "could not write the ASC key file; the credential is not usable"
    return 0
  fi
  # altool searches API_PRIVATE_KEYS_DIR first, so no symlink into ~/.appstoreconnect is needed.
  export API_PRIVATE_KEYS_DIR="$ASC_TMP_DIR"
  export ASC_KEY_ID="$kid" ASC_ISSUER_ID="$iss" ASC_KEY_PATH="$key_path"
  # The client takes the key from the environment:  a path is not an approved
  # secret source, so it never reads one.
  export ASC_KEY_P8="$key_pem"
  key_pem=""
  if [[ -n "$named_path" && "$named_path" != "$key_path" ]]; then
    log "ASC_KEY_PATH is not a credential source; the credential came from the environment or from Infisical"
  fi
  AUTH_MODE="api_key"
  return 0
}

# Run the App Store Connect client.
#
# The client takes the key from its environment and never reads a file (Kody
# rule 42).  The key is never an argument, never on this script's stdout, and
# never in a log line.
#
# Every call goes through here so the node binary is picked in exactly one
# place:  a real ship uses the node from PATH, and an offline test points
# IOS_FLEET_NODE at a stub.
asc_client() {
  "$ASC_NODE" "${FLEET_DIR}/asc-api.mjs" "$@"
}

# The credential sources the client can name in a rejection, and the ONLY
# sources this script reads out of a client's diagnostic.
#
# ONE list, on purpose.  The parser below matches a source against it, and
# the test asserts that every source asc-api.mjs can emit is on it, so the
# shell and the client cannot drift apart and leave a real rejection unnamed.
# The strings are the ones the client hands to its rejectedKeyLabel()
# (asc-api.mjs exports them as REJECTED_KEY_SOURCES).
asc_rejected_key_sources() {
  printf '%s\n' \
    "APPLE_API_* environment (base64 p8)" \
    "ASC_KEY_P8 environment" \
    "Infisical /asc"
}

# The nonsecret label of the key App Store Connect refused.
#
# The client resolves the credential itself (this script resolves it later,
# and only for altool and Xcode), so the client is the only layer that knows
# which key was in play.  It names it in its own diagnostic by the key id and
# the source it was resolved from:  "key id <id>, key source <source>".
# Nothing derived from the private key is read, kept, written or printed
# here.
#
# The label is read as ONE phrase out of ONE line:  the line has to carry
# both markers, so the id and the source can never come from two different
# diagnostics, and the source is taken only when it is one of the client's
# known source names (asc_rejected_key_sources).  Only a key id of the
# expected shape is taken as well, so any other text on that line --
# including a key fragment from an older client -- never reaches the label,
# the hand-off file or a fatal message.
#
# WHAT THE LABEL SAYS:
#   key id <id>, source <source>            the client named both
#   key id (unrecognized), source <source>  the client named no usable id
#   key id <id>, source (not named)         the client named no usable source
#   key id unknown, source unknown          the client named neither
# "unknown" is said only when NEITHER part is available.  A source that IS
# known is always named, even when the id is not:  the client already said
# which credential it used, and dropping that would send the operator after
# the wrong key.
#
# $1: the file the client's stderr was captured into.
ASC_LAST_REJECTED_KEY=""
asc_rejected_key_label() {
  local errf="${1:-}" label_line="" rest="" id_part="" src_part=""
  local key_id="" key_source="" source="" label=""
  if [[ -n "$errf" && -s "$errf" ]]; then
    # The one line that carries the whole label.  The client's own "asc-auth:
    # using <source> (key id length N)" line names no source, so it is not
    # the line to read.
    while IFS= read -r label_line || [[ -n "$label_line" ]]; do
      case "$label_line" in
        *"key id "*", key source "*) break ;;
        *) label_line="" ;;
      esac
    done < "$errf"
  fi
  if [[ -n "$label_line" ]]; then
    rest="${label_line#*key id }"
    id_part="${rest%%, key source *}"
    src_part="${rest#*, key source }"
    # The id:  only a key id of the shape the client accepts is taken, and
    # the client's own "(unrecognized)" is not an id.
    if [[ "$id_part" == "(unrecognized)" ]]; then
      key_id=""
    elif [[ "$id_part" =~ ^[A-Za-z0-9]{1,40}$ ]]; then
      key_id="$id_part"
    fi
    # The source:  only a known source name is taken, matched literally, so
    # a source that merely starts like one of them cannot smuggle anything
    # else into the label.
    while IFS= read -r source; do
      [[ -n "$source" ]] || continue
      case "$src_part" in
        "$source"*) key_source="$source"; break ;;
      esac
    done < <(asc_rejected_key_sources)
  fi
  if [[ -n "$key_id" && -n "$key_source" ]]; then
    label="key id ${key_id}, source ${key_source}"
  elif [[ -n "$key_source" ]]; then
    label="key id (unrecognized), source ${key_source}"
  elif [[ -n "$key_id" ]]; then
    label="key id ${key_id}, source (not named)"
  else
    label="key id unknown, source unknown"
  fi
  # Hand the label to the parent through the file:  the caller runs this
  # inside a command substitution, so a global it assigned would never get
  # there.  Only the label built above is written.
  local file
  file="$(rejected_key_file)"
  if [[ -n "$file" && -d "${file%/*}" && ! -L "$file" ]]; then
    (umask 077; printf '%s' "$label" >"$file") 2>/dev/null || true
  fi
  printf '%s' "$label"
}
# The label as the parent sees it, after a helper ran in a subshell.
rejected_key_label() {
  local label="" file
  file="$(rejected_key_file)"
  if [[ -n "$file" && -f "$file" && ! -L "$file" ]]; then
    label="$(cat "$file" 2>/dev/null || true)"
  fi
  printf '%s' "${label:-unknown}"
}

# Map ship APP_KEY to Sentry project slug in org simple-with-us.
sentry_project_for_app() {
  case "${APP_KEY}" in
    socratic) echo "socratic-trade" ;;
    congress) echo "congress-trade" ;;
    usage|usage-local) echo "usage-monitor" ;;
    dealdex) echo "dealdex" ;;
    autorotate|autorotate-mac) echo "autorotate" ;;
    contactlogo|contactlogo-mac) echo "contactlogo" ;;
    botfleet|botfleet-mac) echo "botfleet" ;;
    codecaps|codecaps-mac) echo "codecaps" ;;
    MiniMax) echo "" ;;
    *) echo "" ;;
  esac
}

# The Sentry API token, resolved once.  SENTRY_AUTH_TOKEN_FULLSCOPE is the only
# credential sentry-cli accepts.  SENTRY_AUTH_TOKEN holds the DSN on some repos,
# and a DSN is not an API token, so sentry-cli refuses it in about seventy
# milliseconds and the upload never happens.  The token stays a shell variable
# and is handed to sentry-cli one invocation at a time.
SENTRY_API_TOKEN=""
SENTRY_TOKEN_REASON=""
SENTRY_UPLOAD_FAILED=0

# The file that records a failed Sentry upload, so the workflow can turn it
# into a red run instead of one warning line inside a green job (CC-200).
sentry_failure_marker() {
  printf '%s' "${GITHUB_WORKSPACE:-$PWD}/.ios-ship-sentry-failed"
}

# Resolve the Sentry API token into SENTRY_API_TOKEN.  The reason for an empty
# token is kept in SENTRY_TOKEN_REASON, so the caller can name the cause
# instead of saying "no token".
#
# The return status is the signal:  0 when the token resolved, nonzero when it
# did not.  A credential that cannot be resolved is not the same thing as a
# credential that is absent, and the reader has to be told which one it is:  a
# fleet-secrets outage is not a missing secret, and a missing secret is not a
# DSN in the token slot.  The caller reads the failure through
# SENTRY_TOKEN_REASON and never lets it abort the TestFlight ship.
load_sentry_auth() {
  SENTRY_API_TOKEN=""
  SENTRY_TOKEN_REASON=""
  local token="" raw=""
  if [[ -n "${SENTRY_AUTH_TOKEN_FULLSCOPE:-}" ]]; then
    token="$SENTRY_AUTH_TOKEN_FULLSCOPE"
  elif command -v fleet-secrets &>/dev/null; then
    # The reader's exit status is captured on its own:  in a pipeline the
    # status would be the one of the last stage, so a failed read would look
    # like a successful read of an empty secret.
    if ! raw="$(fleet-secrets get SENTRY_AUTH_TOKEN_FULLSCOPE 2>/dev/null)"; then
      SENTRY_TOKEN_REASON="SENTRY_AUTH_TOKEN_FULLSCOPE could not be read from fleet-secrets"
      return 1
    fi
    token="$(printf '%s' "$raw" | tr -d '\r')"
  fi
  if [[ -z "$token" && -n "${SENTRY_AUTH_TOKEN:-}" ]]; then
    # The legacy slot is a fallback only, and only when it holds a real token.
    token="$SENTRY_AUTH_TOKEN"
  fi
  case "$token" in
    "")
      SENTRY_TOKEN_REASON="SENTRY_AUTH_TOKEN_FULLSCOPE is unset"
      return 1
      ;;
    *://*|*@*)
      # A DSN in the token slot is exactly the defect this lane had:  the
      # upload is refused in milliseconds and the job stays green.
      SENTRY_TOKEN_REASON="the token looks like a DSN, not an API token"
      return 1
      ;;
  esac
  SENTRY_API_TOKEN="$token"
  return 0
}

# Record a Sentry failure.  The ship itself is never blocked:  the TestFlight
# upload has already succeeded by the time this runs.  What changes is that the
# failure is an ::error:: annotation and a marker file, so the run shows red
# and nobody has to read a warning line to find it.
sentry_report_failure() {
  local message="$1"
  log "warning: sentry: ${message}"
  SENTRY_UPLOAD_FAILED=1
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::error title=Sentry upload::${message}"
    mkdir -p "$(dirname "$(sentry_failure_marker)")" 2>/dev/null || true
    # The marker is bookkeeping:  a failed write must not abort the ship under
    # set -e, because that would destroy a release that has not happened yet.
    # The ::error:: annotation above is the trace either way.
    printf '%s\n' "${message}" >>"$(sentry_failure_marker)" 2>/dev/null \
      || log "warning: sentry: could not write the failure marker; the ::error:: annotation is the only trace"
  fi
}

# The project the events land in is the one in the DSN, because SENTRY_DSN is
# one shared fleet key and it moves between projects.  A standard DSN ends in
# a numeric project id and sentry-cli needs the slug, so an id is resolved
# through the Sentry API.  A slug is used as it stands.
#
# The org comes from the DSN's own host (o<org id>.ingest.sentry.io), so a
# DSN minted in another org resolves too;  the fleet slug is the fallback for a
# host that carries no numeric org id.
#
# A resolution that fails is REPORTED through SENTRY_DSN_PROJECT_ERROR:  a
# silent empty result drops the DSN project from the upload list, which is
# exactly the "the dSYM landed in the wrong project" defect this lane exists to
# fix (CC-200), and it would leave the run green.
SENTRY_DSN_PROJECT_ERROR=""
sentry_dsn_project() {
  local raw="${SENTRY_DSN:-}"
  SENTRY_DSN_PROJECT_ERROR=""
  : >"${LOG_DIR}/sentry-dsn-project.error"
  [[ -n "$raw" ]] || return 0
  local last="${raw##*/}"
  [[ "$last" != "$raw" ]] || return 0
  case "$last" in
    *[!0-9]*)
      printf '%s' "$last"
      return 0
      ;;
  esac
  # Numeric:  ask the API for the slug.  The token never enters the command
  # line:  it is handed to curl on stdin, so a process listing cannot read it.
  local host org slug body
  host="$(printf '%s' "$raw" | sed -E 's#^https?://[^@/]+@##; s#/.*$##')"
  if [[ -z "$host" ]]; then
    SENTRY_DSN_PROJECT_ERROR="the host could not be read from the DSN"
    printf '%s' "$SENTRY_DSN_PROJECT_ERROR" >"${LOG_DIR}/sentry-dsn-project.error"
    return 1
  fi
  local org_id=""
  if [[ "$host" =~ ^o([0-9]+)\. ]]; then
    org_id="${BASH_REMATCH[1]}"
  fi
  for org in "$org_id" "simple-with-us"; do
    [[ -n "$org" ]] || continue
    body="$(curl -fsS -H @- "https://${host}/api/0/organizations/${org}/projects/${last}/" \
      <<<"Authorization: Bearer ${SENTRY_API_TOKEN}" 2>/dev/null)" || body=""
    slug="$(printf '%s' "$body" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("slug",""))
except Exception:
    print("")' 2>/dev/null)" || slug=""
    if [[ -n "$slug" ]]; then
      printf '%s' "$slug"
      return 0
    fi
  done
  SENTRY_DSN_PROJECT_ERROR="the project id ${last} in the DSN could not be resolved to a Sentry project slug"
  printf '%s' "$SENTRY_DSN_PROJECT_ERROR" >"${LOG_DIR}/sentry-dsn-project.error"
  return 1
}

# The projects the dSYM and the Size Analysis build go to.  The DSN's project
# first, then the app's own project, and never the same project twice.
sentry_project_list() {
  local app_project="$1" dsn_project="$2"
  if [[ -n "$dsn_project" && "$dsn_project" != "$app_project" ]]; then
    printf '%s\n' "$dsn_project"
  fi
  printf '%s\n' "$app_project"
}

# After a successful archive: upload dSYMs and Size Analysis.  Never fail the
# TestFlight ship if Sentry is missing or the upload errors, but every miss is
# reported as an ::error:: so the run shows red (CC-200).
upload_sentry_artifacts() {
  local project archive
  project="$(sentry_project_for_app)"
  archive="${ARCHIVE_PATH:-}"
  if [[ -z "$project" ]]; then
    log "sentry: no project mapping for app=${APP_KEY}; skipping artifact upload"
    return 0
  fi
  if [[ -z "$archive" || ! -d "$archive" ]]; then
    log "sentry: archive missing; skipping artifact upload"
    return 0
  fi
  if ! load_sentry_auth; then
    sentry_report_failure "no Sentry API token, so no dSYM and no Size Analysis build was uploaded:  ${SENTRY_TOKEN_REASON}.  Set SENTRY_AUTH_TOKEN_FULLSCOPE (the API token, not the DSN)."
    return 0
  fi
  if ! command -v sentry-cli >/dev/null 2>&1; then
    log "sentry: sentry-cli not on PATH; trying official installer"
    if ! curl -sL https://sentry.io/get-cli/ | SENTRY_CLI_VERSION="" bash >"${LOG_DIR}/sentry-cli-install.log" 2>&1; then
      sentry_report_failure "sentry-cli could not be installed, so no dSYM and no Size Analysis build was uploaded; see ${LOG_DIR}/sentry-cli-install.log"
      return 0
    fi
    export PATH="${HOME}/.sentry-cli:${PATH}:/opt/homebrew/bin"
  fi
  if ! command -v sentry-cli >/dev/null 2>&1; then
    sentry_report_failure "sentry-cli is missing, so no dSYM and no Size Analysis build was uploaded"
    return 0
  fi
  local dsn_project projects p
  if ! dsn_project="$(sentry_dsn_project)"; then
    # Without the DSN project the dSYM lands in the app's own project only,
    # which is the defect this lane exists to fix, so the run goes red rather
    # than going quietly wrong.
    # Command substitution runs in a subshell, so the function persists the
    # reason in LOG_DIR rather than in the parent shell's variable.
    if [[ -s "${LOG_DIR}/sentry-dsn-project.error" ]]; then
      SENTRY_DSN_PROJECT_ERROR="$(cat "${LOG_DIR}/sentry-dsn-project.error")"
    fi
    sentry_report_failure "the Sentry project named by the DSN could not be resolved, so the dSYM and the Size Analysis build can only go to ${project}:  ${SENTRY_DSN_PROJECT_ERROR}"
    dsn_project=""
  fi
  projects="$(sentry_project_list "$project" "$dsn_project")"
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    log "sentry: uploading debug files for project=${p}"
    set +e
    # Source bundles are a PER-PROJECT artifact:  uploading them to the DSN
    # project gives the app's own project no source context for a minified
    # stack, so every project in the list gets them.
    SENTRY_ORG=simple-with-us SENTRY_PROJECT="$p" SENTRY_AUTH_TOKEN="$SENTRY_API_TOKEN" \
      sentry-cli debug-files upload --include-sources "$archive" \
      >"${LOG_DIR}/sentry-debug-files-${p}.log" 2>&1
    local dif_rc=$?
    set -e
    if [[ $dif_rc -eq 0 ]]; then
      log "sentry: debug-files upload ok for project=${p}"
    else
      sentry_report_failure "sentry debug-files upload failed for project=${p} (rc=${dif_rc}); see ${LOG_DIR}/sentry-debug-files-${p}.log"
    fi
    if [[ -z "$dsn_project" || "$p" == "$dsn_project" ]]; then
      # The Size Analysis quota is 100 builds a month on the sponsored plan and
      # every build upload spends one of them.  The events land in the DSN
      # project, so that is the project that needs the Size Analysis build;
      # the app's own project gets the dSYMs only.
      log "sentry: Size Analysis build upload for project=${p}"
      set +e
      SENTRY_ORG=simple-with-us SENTRY_PROJECT="$p" SENTRY_AUTH_TOKEN="$SENTRY_API_TOKEN" \
        sentry-cli build upload "$archive" \
        >"${LOG_DIR}/sentry-build-upload-${p}.log" 2>&1
      local build_rc=$?
      set -e
      if [[ $build_rc -eq 0 ]]; then
        log "sentry: build upload ok for project=${p}"
      else
        sentry_report_failure "sentry build upload failed for project=${p} (rc=${build_rc}); see ${LOG_DIR}/sentry-build-upload-${p}.log"
      fi
    else
      log "sentry: skipping the Size Analysis build upload for project=${p}; the DSN project (${dsn_project}) holds the events and the quota is 100 builds a month"
    fi
  done <<<"$projects"
  return 0
}

link_private_key() {
  # altool / iTMSTransporter look for AuthKey_<id>.p8 in standard dirs.  When
  # load_secrets wrote a temp key it also set API_PRIVATE_KEYS_DIR, so there is
  # nothing to link (and a symlink to a deleted temp file would dangle).
  local key_path="$1" key_id="$2"
  if [[ -n "${ASC_TMP_DIR:-}" && "$key_path" == "${ASC_TMP_DIR}/"* ]]; then
    return 0
  fi
  local dest_dir="${HOME}/.appstoreconnect/private_keys"
  mkdir -p "$dest_dir"
  chmod 700 "$dest_dir"
  local dest="${dest_dir}/AuthKey_${key_id}.p8"
  if [[ -L "$dest" && ! -e "$dest" ]]; then
    rm -f "$dest"
  fi
  if [[ ! -e "$dest" ]]; then
    ln -sf "$key_path" "$dest"
  fi
  chmod 600 "$key_path" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# THE VERSION NUMBERS (owner directive 2026-10-24, AFC-517)
# ---------------------------------------------------------------------------
# The rule itself is in the header comment above; this is where it is applied.
# The readable, unit-tested copy of it is scripts/ios-fleet/version-plan.mjs.
#
# MARKETING_VERSION (CFBundleShortVersionString) is <prefix>.<P+1>:
#   <prefix> is the train from marketingVersionDefault, and P is the highest
#   patch App Store Connect already holds on that train (App Store versions
#   AND TestFlight trains, drift trains ignored).  The marketing version is
#   the next patch, so it never collides with an existing one.
#
# CURRENT_PROJECT_VERSION (CFBundleVersion) is the repo commit count:
#   - it names the EXACT commit a build came from, so a TestFlight or Sparkle
#     build can be traced to source without a second lookup
#   - it is monotonic by construction, so it can never regress
#   - it is raised above the App Store Connect floor when it has to be (a
#     shallow checkout understates the count, and the retired UTC stamps are
#     still higher than a fresh commit count)
#
# The two numbers are independent.  The build number is NEVER derived from
# the marketing version, and the marketing version is never derived from the
# build number:  that is what stopped App Store Connect from showing
# "1.0.2358 (2358)".
#
# App Store Connect is the only record that shipping advances, so it is the
# only record that can answer "which patches does this train hold?" and
# "which build numbers are taken?".  The local build-seq counter
# (~/.cache/ios-fleet/build-seq-<app>.txt) and the MARKETING_VERSION in
# project.pbxproj are NOT sources any more:  the counter is never written,
# and the project file is only read to print the agreement NOTICE.

# Highest N in MARKETING_VERSION = <prefix>.N across the project's build
# configurations. 0 when the file is unreadable or holds no on-train value.
#
# NOT A SEQUENCING INPUT.  project.pbxproj does not feed the marketing
# version or the build number any more (AFC-517); this only backs the
# agreement NOTICE below, so a stale value in the project file is visible
# instead of silently steering a ship.
project_marketing_seq() {
  local proj_file="$1" prefix="$2" quiet="${3:-}" best=0 v n off_train=""
  if [[ ! -f "$proj_file" ]]; then
    printf '0'
    return 0
  fi
  while IFS= read -r v; do
    [[ -n "$v" ]] || continue
    n="${v#${prefix}.}"
    if [[ "$n" =~ ^[0-9]+$ && "$n" != "$v" ]]; then
      [[ "$n" -gt "$best" ]] && best="$n"
    else
      off_train="$v"
    fi
  done < <(grep -o 'MARKETING_VERSION = [^;]*;' "$proj_file" \
             | sed 's/MARKETING_VERSION = //; s/;$//' | sort -u)
  if [[ -n "$off_train" && -z "$quiet" ]]; then
    logerr "WARNING: project.pbxproj has MARKETING_VERSION=${off_train}, which is not on the ${prefix}.N train."
    logerr "WARNING: that value is ignored for sequencing. If you meant to start a new train,"
    logerr "WARNING: update marketingVersionDefault for '${APP_KEY}' in ${APPS_JSON}."
  fi
  printf '%s' "$best"
}

# The highest patch already used on the <prefix> train in App Store Connect
# (App Store versions AND TestFlight trains, drift trains ignored).
# Prints the integer on stdout.  Returns 1 (and prints nothing) when ASC
# cannot be consulted -- the caller must distinguish "no patch yet" (0) from
# "unknown" (failure).
asc_latest_marketing_patch() {
  local prefix="$1" plat="${2:-}" out rc
  if ! command -v "$ASC_NODE" >/dev/null 2>&1; then
    logerr "asc-patch: node not on PATH; cannot verify against App Store Connect"
    return 1
  fi
  if [[ -z "${ASC_KEY_ID:-}" && -z "${APPLE_API_KEY_ID:-}" && ! -x "$FLEET_SECRETS_BIN" ]] && ! command -v fleet-secrets >/dev/null 2>&1; then
    logerr "asc-patch: no ASC_* in env and no fleet-secrets; cannot verify against App Store Connect"
    return 1
  fi
  set +e
  # Capture stderr to a temp file rather than sending it to /dev/null: the
  # latest-marketing-patch: lines carry Apple's HTTP status and error code,
  # which is the only thing that explains a failed patch lookup.  Clean up with
  # the redirect on every path -- a bare `rm` can be a wrapper that prints to
  # stdout, and this function's stdout IS the patch number.
  local errf rc
  errf="$(mktemp "${TMPDIR:-/tmp}/asc-patch-err.XXXXXX")"
  out=$(asc_client latest-marketing-patch "$BUNDLE_ID" "$prefix" "$plat" 2>"$errf")
  rc=$?
  if [[ $rc -eq 4 ]]; then
    set -e
    # The client's diagnostic names the key that was refused by key id and
    # source;  the shell quotes that label so the rejection says which
    # credential it was and not only that a credential was rejected.
    ASC_LAST_REJECTED_KEY="$(asc_rejected_key_label "$errf")"
    logerr "asc-patch: App Store Connect rejected the credential (HTTP 401/403; rejected key ${ASC_LAST_REJECTED_KEY})"
    # Forward the client's own lines first:  they carry Apple's status and code.
    if [[ -s "$errf" ]]; then
      while IFS= read -r _pl; do
        case "$_pl" in latest-marketing-patch:*|latest-build-seq:*) logerr "asc-patch: ${_pl}" ;; esac
      done <"$errf"
    fi
    rm -f "$errf" >/dev/null 2>&1 || true
    return 4
  fi
  set -e
  if [[ -s "$errf" ]]; then
    while IFS= read -r line; do
      case "$line" in
        latest-marketing-patch:*) logerr "asc-patch: ${line}" ;;
      esac
    done <"$errf"
  fi
  rm -f "$errf" >/dev/null 2>&1 || true
  if [[ $rc -ne 0 || ! "$out" =~ ^[0-9]+$ ]]; then
    logerr "asc-patch: query failed (rc=${rc}); cannot verify against App Store Connect"
    return 1
  fi
  printf '%s' "$out"
}

# The build floor for one marketing train:  every build already in that train
# (Apple requires build numbers to grow inside one train, so the retired UTC
# stamps still hold the floor up) plus the app's plain-integer builds below
# 1000000000 (EVERY build on macOS, where build numbers grow across trains).
#
# Prints "<floor> <train> <app>" on stdout -- the three numbers the version
# plan log line names.  Returns 1 (and prints nothing) when ASC cannot be
# consulted.
asc_build_floor() {
  local version="$1" plat="${2:-}" out rc err train app errfile
  if ! command -v "$ASC_NODE" >/dev/null 2>&1; then
    logerr "asc-floor: node not on PATH; cannot verify against App Store Connect"
    return 1
  fi
  if [[ -z "${ASC_KEY_ID:-}" && -z "${APPLE_API_KEY_ID:-}" && ! -x "$FLEET_SECRETS_BIN" ]] && ! command -v fleet-secrets >/dev/null 2>&1; then
    logerr "asc-floor: no ASC_* in env and no fleet-secrets; cannot verify against App Store Connect"
    return 1
  fi
  errfile="$(mktemp "${TMPDIR:-/tmp}/ios-fleet-floor.XXXXXX" 2>/dev/null || printf '')"
  set +e
  out=$(asc_client build-floor "$BUNDLE_ID" "$version" "$plat" 2>"$errfile")
  rc=$?
  # Keep the client's build-floor lines:  they carry Apple's HTTP status,
  # which the fatal message below tells the operator to look for.
  if [[ -s "$errfile" ]]; then
    while IFS= read -r _fl; do
      case "$_fl" in build-floor:*|latest-build-seq:*) logerr "asc-floor: ${_fl}" ;; esac
    done <"$errfile"
  fi
  if [[ $rc -eq 4 ]]; then
    set -e
    # The client's diagnostic names the key that was refused by key id and
    # source;  the shell quotes that label so the rejection says which
    # credential it was and not only that a credential was rejected.
    ASC_LAST_REJECTED_KEY="$(asc_rejected_key_label "$errfile")"
    logerr "asc-floor: App Store Connect rejected the credential (HTTP 401/403; rejected key ${ASC_LAST_REJECTED_KEY})"
    rm -f "$errfile" >/dev/null 2>&1 || true
    return 4
  fi
  set -e
  err="$(cat "$errfile" 2>/dev/null || true)"
  rm -f "$errfile" 2>/dev/null || true
  if [[ $rc -ne 0 || ! "$out" =~ ^[0-9]+$ ]]; then
    logerr "asc-floor: query failed (rc=${rc}); cannot verify against App Store Connect"
    return 1
  fi
  # The client prints the two parts of the floor on stderr, so the log line
  # can name them; fall back to the combined floor when they are missing.
  train="$(printf '%s' "$err" | sed -n 's/.*[^a-z]train=\([0-9][0-9]*\).*/\1/p' | tail -n 1)"
  app="$(printf '%s' "$err" | sed -n 's/.*[^a-z]app=\([0-9][0-9]*\).*/\1/p' | tail -n 1)"
  # The client's build-floor lines were already forwarded once, above.
  printf '%s %s %s' "$out" "${train:-$out}" "${app:-$out}"
}

# The major.minor train a marketing version belongs to: "2.0.123" -> "2.0",
# "3" -> "3.0".  The floor is per-train, so the train has to come from the
# version actually being shipped rather than always from the default.
version_prefix() {
  printf '%s' "${1:-1.0}" | awk -F. '{ if (NF >= 2) print $1"."$2; else print $1".0" }'
}

marketing_prefix() {
  # "1.0" from marketingVersionDefault (1.0 or 1.0.x both yield 1.0).
  version_prefix "${DEFAULT_MARKETING:-1.0}"
}

ship_state_path() {
  echo "${STATE_DIR}/last-ship-${APP_KEY}.txt"
}

repo_head_sha() {
  git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown"
}

# Decide whether this run may upload: rate limit + "no new commits since the
# last successful ship". Does not apply to --export-only (local IPA only) or
# --force-ship.
#
# This function DECIDES and LOGS; it does not exit. That separation is the fix
# for the ordering bug observed live on 2026-08-12: the gate used to be
# evaluated after the build counter had already committed floor+1,
# so a rate-limited attempt still burned a build number. The sequence advanced
# 5 -> 6 while the run skipped, leaving 1.0.6 existing nowhere and the local
# counter drifting further from App Store Connect. The caller now evaluates the
# gate BEFORE any version is resolved.
#
# Sets SHIP_GATE_DECISION to "proceed" or "skip".
SHIP_GATE_DECISION="proceed"
evaluate_ship_gate() {
  SHIP_GATE_DECISION="proceed"
  if [[ "$FORCE_SHIP" -eq 1 ]]; then
    log "force-ship: bypassing min-interval / same-HEAD gate"
    return 0
  fi
  if [[ "$EXPORT_ONLY" -eq 1 ]]; then
    return 0
  fi

  local min_sec min_src path last_ts last_sha now elapsed head_sha
  # Report which source the number came from, so the log answers "why did this
  # not ship" without anyone reading the script. Non-numeric / empty -> default,
  # and say so rather than crediting the env var for a value it did not supply.
  if [[ -n "${IOS_TF_MIN_INTERVAL_SEC:-}" && "${IOS_TF_MIN_INTERVAL_SEC}" =~ ^[0-9]+$ ]]; then
    min_sec="$IOS_TF_MIN_INTERVAL_SEC"
    min_src="IOS_TF_MIN_INTERVAL_SEC"
  else
    min_sec="$DEFAULT_MIN_INTERVAL_SEC"
    min_src="DEFAULT_MIN_INTERVAL_SEC in $(basename "$0")"
    if [[ -n "${IOS_TF_MIN_INTERVAL_SEC:-}" ]]; then
      log "ship-gate: IOS_TF_MIN_INTERVAL_SEC is not a number; using the default"
    fi
  fi
  path="$(ship_state_path)"
  head_sha="$(repo_head_sha)"
  now="$(date +%s)"

  if [[ ! -f "$path" ]]; then
    log "ship-gate: no prior ship for ${APP_KEY}; proceeding"
    return 0
  fi

  # Format: "<unix_ts> <git_sha>"
  read -r last_ts last_sha <"$path" || true
  if ! [[ "${last_ts:-}" =~ ^[0-9]+$ ]]; then
    log "ship-gate: bad state file; proceeding"
    return 0
  fi

  if [[ -n "${last_sha:-}" && "$last_sha" != "unknown" && "$head_sha" == "$last_sha" ]]; then
    log "ship-gate: skip — HEAD ${head_sha:0:10} already shipped for ${APP_KEY} (no new commits)"
    log "ship-gate: use --force-ship to upload the same HEAD again"
    SHIP_GATE_DECISION="skip"
    return 0
  fi

  elapsed=$((now - last_ts))
  if [[ "$elapsed" -lt "$min_sec" ]]; then
    local remain=$((min_sec - elapsed))
    local remain_m=$(( (remain + 59) / 60 ))
    local min_m=$(( min_sec / 60 ))
    log "ship-gate: skip — last ${APP_KEY} ship ${elapsed}s ago; min interval ${min_sec}s (~${remain_m}m left)"
    log "ship-gate: that ${min_sec}s (${min_m}m) limit comes from ${min_src}."
    log "ship-gate: it is THE throttle on automatic shipping — .github/workflows/ios-ship.yml"
    log "ship-gate: runs on every push to main touching clients/ios/**, and most runs skip here."
    log "ship-gate: override this run with IOS_TF_MIN_INTERVAL_SEC=<seconds> or --force-ship;"
    log "ship-gate: change the standing limit by editing DEFAULT_MIN_INTERVAL_SEC (owner's call)."
    SHIP_GATE_DECISION="skip"
    return 0
  fi

  log "ship-gate: ok — ${elapsed}s since last ship (min ${min_sec}s from ${min_src}); HEAD ${head_sha:0:10}"
}

record_successful_ship() {
  local path head_sha now
  path="$(ship_state_path)"
  head_sha="$(repo_head_sha)"
  now="$(date +%s)"
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR" 2>/dev/null || true
  printf '%s %s\n' "$now" "$head_sha" >"$path"
  chmod 600 "$path" 2>/dev/null || true
  log "ship-gate: recorded success ts=${now} sha=${head_sha:0:10} -> ${path}"
  # Public version manifest for the in-app update prompt.  Best-effort —
  # a publish miss must never fail a ship that already uploaded.
  if [[ -n "${BUNDLE_ID:-}" && -n "${MARKETING:-}" ]]; then
    local apple_id display
    local -a pub_args
    apple_id="$(json_get "$APP_KEY" appleId || true)"
    display="$(json_get "$APP_KEY" displayName || true)"
    pub_args=(--bundle-id "$BUNDLE_ID" --version "$MARKETING")
    [[ -n "${BUILD_NUM:-}" ]] && pub_args+=(--build "$BUILD_NUM")
    [[ -n "${apple_id:-}" ]] && pub_args+=(--apple-id "$apple_id")
    [[ -n "${display:-}" ]] && pub_args+=(--display-name "$display")
    if bash "${FLEET_DIR}/publish-ios-versions.sh" "${pub_args[@]}" >/dev/null 2>&1; then
      log "version-manifest: published ${BUNDLE_ID} ${MARKETING}"
    else
      log "warning: version-manifest publish failed (non-fatal)"
    fi
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root) REPO_ROOT="$2"; shift 2 ;;
    --build) FORCE_BUILD="$2"; shift 2 ;;
    --version) FORCE_VERSION="$2"; shift 2 ;;
    --export-only) EXPORT_ONLY=1; shift ;;
    --upload-only) UPLOAD_ONLY_IPA="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --skip-xcodegen) SKIP_XCODEGEN=1; shift ;;
    --allow-dirty) ALLOW_DIRTY=1; shift ;;
    --force-ship) FORCE_SHIP=1; shift ;;
    --allow-unverified-seq) ALLOW_UNVERIFIED_SEQ=1; shift ;;
    --sync-project-version) SYNC_PROJECT_VERSION=1; shift ;;
    -h|--help) usage ;;
    -*) die "unknown option: $1 (try --help)" ;;
    *)
      if [[ -z "$APP_KEY" ]]; then
        APP_KEY="$1"; shift
      else
        die "unexpected arg: $1"
      fi
      ;;
  esac
done

[[ -n "$APP_KEY" ]] || die "app key required (e.g. socratic, congress, usage, usage-local, dealdex, autorotate, autorotate-mac, contactlogo, contactlogo-mac, botfleet, botfleet-mac, MiniMax)"
[[ -f "$APPS_JSON" ]] || die "missing apps registry: $APPS_JSON"

# Validate APP_KEY against apps.json before requiring Xcode tools so --help-adjacent
# and CI unit tests can reject unknown keys on Linux runners without xcodebuild.
_EARLY_BUNDLE="$(json_get "$APP_KEY" bundleId)"
_EARLY_SCHEME="$(json_get "$APP_KEY" scheme)"
_EARLY_PROJECT="$(json_get "$APP_KEY" projectRel)"
[[ -n "$_EARLY_BUNDLE" && -n "$_EARLY_SCHEME" && -n "$_EARLY_PROJECT" ]] || die "unknown app key or incomplete registry: $APP_KEY"

# Prefer stable Xcode.app over Xcode-beta for TestFlight / ASC compatibility.
# Beta toolchains + beta macOS stamp BuildMachineOSBuild that App Store review
# rejects as INVALID_BINARY even when TestFlight accepts the same IPA.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  elif [[ -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
    echo "[ios-ship] warning: only Xcode-beta present; ASC Invalid Binary risk" >&2
    export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
  fi
fi
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
  echo "[ios-ship] DEVELOPER_DIR=${DEVELOPER_DIR}"
fi

need_cmd xcodebuild
need_cmd /usr/bin/python3

# Owner 2026-08-11: always use stable Xcode.app for archive/export/upload.
# Xcode-beta breaks TestFlight / App Store Connect tooling compatibility.
# Override only if DEVELOPER_DIR is already set to a non-beta path.
if [[ -z "${DEVELOPER_DIR:-}" || "$DEVELOPER_DIR" == *Xcode-beta* ]]; then
  if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  fi
fi
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
  log "using DEVELOPER_DIR=${DEVELOPER_DIR}"
  xcodebuild -version || die "xcodebuild broken under DEVELOPER_DIR=${DEVELOPER_DIR}"
fi


if [[ -z "$REPO_ROOT" ]]; then
  hint="$(json_get "$APP_KEY" worktreeHint || true)"
  hint="${hint/#\~/$HOME}"
  if [[ -n "$hint" && -d "$hint" ]]; then
    REPO_ROOT="$hint"
  else
    REPO_ROOT="$(pwd)"
  fi
fi
if [[ ! -d "$REPO_ROOT" ]]; then
  die "repo root does not exist: $REPO_ROOT"
fi
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"

DISPLAY_NAME="$(json_get "$APP_KEY" displayName)"
BUNDLE_ID="$(json_get "$APP_KEY" bundleId)"
PLATFORM="$(json_get "$APP_KEY" platform)"
SCHEME="$(json_get "$APP_KEY" scheme)"
PROJECT_REL="$(json_get "$APP_KEY" projectRel)"
PROJECT_REL_ALT="$(json_get "$APP_KEY" projectRelAlt)"
XCODEGEN_DIR="$(json_get "$APP_KEY" xcodegenDir)"
DEFAULT_MARKETING="$(json_get "$APP_KEY" marketingVersionDefault)"

if [[ -z "$PLATFORM" ]]; then
  if [[ "$APP_KEY" == *-mac || "$SCHEME" == *[Mm]ac* ]]; then
    PLATFORM="macOS"
  else
    PLATFORM="iOS"
  fi
fi

[[ -n "$BUNDLE_ID" && -n "$SCHEME" && -n "$PROJECT_REL" ]] || die "unknown app key or incomplete registry: $APP_KEY"
if [[ "$BUNDLE_ID" == "me.grok.dealdex" ]]; then
  die "refusing to upload me.grok.dealdex"
fi
if [[ "$APP_KEY" == "dealdex" && "$BUNDLE_ID" != "net.dealdex" ]]; then
  die "DealDex live bundle is net.dealdex, not ${BUNDLE_ID}"
fi

if [[ -z "$UPLOAD_ONLY_IPA" && "$DRY_RUN" -eq 0 ]]; then
  if [[ "$ALLOW_DIRTY" -eq 0 ]]; then
    if ! git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      die "not a git repo: $REPO_ROOT (pass --allow-dirty to override)"
    fi
    if [[ -n "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)" ]]; then
      die "dirty worktree at $REPO_ROOT (commit first, or pass --allow-dirty)"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# SHIP GATE FIRST, THEN THE VERSION NUMBERS.
# ---------------------------------------------------------------------------
# Ordering matters and used to be wrong. The gate was evaluated ~60 lines below
# the point where the build counter committed floor+1, so every
# rate-limited attempt burned a version that never shipped (observed live
# 2026-08-12: skipped at 4392s of a 9000s interval, sequence still went 5 -> 6).
#
# Everything the gate needs is already resolved above: APP_KEY, REPO_ROOT (for
# HEAD), EXPORT_ONLY, FORCE_SHIP, STATE_DIR. Nothing between here and the old
# call site set up anything it reads, so moving it earlier drops no step. What
# it now runs BEFORE is: PBXPROJ resolution, the App Store Connect queries
# (the marketing patch and the build floor), the project-version agreement
# check, --sync-project-version, load_secrets, and the output dirs.  No
# number is consumed from a local cache any more:  App Store Connect is the
# only record that shipping advances.
# The dirty-worktree check stays ahead of the gate so a dirty tree still fails
# loudly rather than being masked by a quiet rate-limit skip.
#
# --force-ship and --export-only still bypass the gate exactly as before, and
# --dry-run still reports the gate outcome alongside the version plan (it peeks
# at the version without shipping it, so evaluating early changes nothing for
# it beyond ordering the log lines).
evaluate_ship_gate

# Capture the previously-shipped sha for the TestFlight release notes BEFORE
# anything can rewrite the state file. record_successful_ship() overwrites it
# after ensure_tf_ready, so reading it later happens to work today -- capturing
# it here makes the notes immune to a future reordering, which is exactly the
# class of bug the ship-gate comment above documents.
PREV_SHIP_SHA=""
if [[ -f "$(ship_state_path)" ]]; then
  read -r _prev_ts PREV_SHIP_SHA <"$(ship_state_path)" || true
  [[ "${PREV_SHIP_SHA:-}" != "unknown" ]] || PREV_SHIP_SHA=""
fi
# Which subtree is "this app's iOS code" -- used only as the tie-break when the
# commit range exceeds the release-notes bullet cap.
IOS_PATH_PREFIX="$(dirname "$PROJECT_REL")"

if [[ "$SHIP_GATE_DECISION" == "skip" && "$DRY_RUN" -eq 0 ]]; then
  log "ship-gate: exiting 0 before any version is resolved (nothing consumed)"
  exit 0
fi

# Where the version the project itself declares lives. Best-effort: for
# XcodeGen apps the .xcodeproj may not exist until it is generated below, in
# which case the project contributes 0 to the floor and says so.
PBXPROJ=""
if _proj_dir="$(resolve_project "$REPO_ROOT" "$PROJECT_REL" "$PROJECT_REL_ALT" 2>/dev/null)"; then
  PBXPROJ="${_proj_dir}/project.pbxproj"
fi

MARKETING_PREFIX="$(marketing_prefix)"

# The App Store Connect platform key.  "macOS" in apps.json is MAC_OS there.
ASC_PLATFORM="IOS"
if [[ "$PLATFORM" == "macOS" ]]; then
  ASC_PLATFORM="MAC_OS"
fi

# What the version plan is built from.  Printed in the "version plan:" log
# line so the log answers "where did that build number come from?" without
# anyone reading the script.
PLAN_ASC_PATCH="n/a"
PLAN_TARGET_PATCH=""
PLAN_FLOOR="n/a"
PLAN_TRAIN_FLOOR="n/a"
PLAN_APP_FLOOR="n/a"
PLAN_COMMIT_COUNT="n/a"
PLAN_READY=0

if [[ -n "$UPLOAD_ONLY_IPA" ]]; then
  # The IPA already carries the versions it was built with. Resolving -- let
  # alone consuming -- a version here would burn a marketing version on a run
  # that cannot possibly use it, which is the same defect as the gate-ordering
  # bug above. It would also drag in the App Store Connect queries' hard
  # failure when ASC is unreachable, blocking a legitimate retry of an
  # already-built IPA.
  MARKETING="(from IPA)"
  BUILD_NUM="(from IPA)"
  log "version: taken from the existing IPA (--upload-only); no version resolved, nothing consumed"
else
  PLAN_READY=1

  # The repo commit count:  the build number names the exact commit a build
  # came from, so it is the starting point for CFBundleVersion.  It is not
  # enough on its own -- the App Store Connect floor below raises it when it
  # has to be -- but it is never invented:  a checkout with no readable git
  # history cannot be numbered at all.
  COMMIT_COUNT="$(git -C "$REPO_ROOT" rev-list --count HEAD 2>/dev/null || true)"
  if [[ "$COMMIT_COUNT" =~ ^[0-9]+$ ]]; then
    PLAN_COMMIT_COUNT="$COMMIT_COUNT"
  fi

  # ---- the marketing version ---------------------------------------------
  # --version is an exact override.  Otherwise the version is the next patch
  # on the default train, and P comes from App Store Connect.
  if [[ -n "$FORCE_VERSION" ]]; then
    MARKETING="$FORCE_VERSION"
    # The patch the operator pinned, on its own train ("2.0.5" -> 5).
    _pinned="${FORCE_VERSION##*.}"
    if [[ "$_pinned" =~ ^[0-9]+$ ]]; then
      PLAN_ASC_PATCH="pinned"
      PLAN_TARGET_PATCH="$_pinned"
    fi
  else
    set +e
    _patch="$(asc_latest_marketing_patch "$MARKETING_PREFIX" "$ASC_PLATFORM")"
    _rc=$?
    if [[ $_rc -eq 4 ]]; then
      die "App Store Connect rejected the API key (HTTP 401/403; rejected key $(rejected_key_label)) while reading the next marketing version.
  Fix the key (ASC_* in env or Infisical /asc; fleet-secrets doctor) and re-run.
  --allow-unverified-seq does not cover a rejected credential:  the upload would fail with it too."
    fi
    set -e
    if [[ $_rc -ne 0 || ! "$_patch" =~ ^[0-9]+$ ]]; then
      if [[ "$ALLOW_UNVERIFIED_SEQ" -eq 0 ]]; then
        die "cannot determine the next marketing version.
  App Store Connect could not be consulted.  The marketing version is the next
  patch on the ${MARKETING_PREFIX} train, and App Store Connect is the only
  record of which patches that train already holds:  guessing would ship a
  version that already exists (or skip one that does not).
  Fix one of these, then re-run:
    1) restore ASC access: check ASC_* in env or Infisical /asc (fleet-secrets doctor) and that 'node' is on PATH, then
       run: node ${FLEET_DIR}/asc-api.mjs latest-marketing-patch ${BUNDLE_ID} ${MARKETING_PREFIX} ${ASC_PLATFORM}
     2) or pin the version explicitly:  --version <X.Y.Z>
        --version is honoured exactly, so the marketing version no longer needs
        App Store Connect.  The build number is still automatic:  the repo
        commit count, raised above the floor of that train.
    3) or, only if you are certain, re-run with --allow-unverified-seq"
      fi
      logerr "WARNING: --allow-unverified-seq set; the marketing version is planned from an UNVERIFIED patch (P=0)"
      _patch=0
    fi
    PLAN_ASC_PATCH="$_patch"
    PLAN_TARGET_PATCH="$((_patch + 1))"
    MARKETING="${MARKETING_PREFIX}.${PLAN_TARGET_PATCH}"
  fi

  # ---- the build number ---------------------------------------------------
  if [[ -n "$FORCE_BUILD" ]]; then
    # An explicit --build is honoured exactly, and it does NOT move the
    # marketing version:  the two numbers are independent.
    BUILD_NUM="$FORCE_BUILD"
    # An explicit --build is honoured exactly, but never as the retired
    # "1.0.N (N)" pair (AFC-517):  refuse rather than silently change it.
    # Compared as numbers, so "--build 0236" is caught for 1.0.236 too.
    if [[ -n "$PLAN_TARGET_PATCH" && "$BUILD_NUM" =~ ^[0-9]+$ ]] && (( 10#$BUILD_NUM == 10#$PLAN_TARGET_PATCH )); then
      die "--build ${BUILD_NUM} equals the patch of ${MARKETING}, which would ship ${MARKETING} (${BUILD_NUM}): the 1.0.N (N) form the owner retired (AFC-517).  Pass a different --build."
    fi
    log "version: operator override (--build/--version); the local build-seq counter is not consulted"
  else
    [[ "$PLAN_COMMIT_COUNT" =~ ^[0-9]+$ ]] || die "could not read the commit count from ${REPO_ROOT}; CFBundleVersion is the repo commit count and UTC timestamps are retired"

    # The floor:  every build already in the TARGET train, plus the app's own
    # plain-integer builds.  It is per-train, so it is read from the train
    # this run actually ships to -- reading 1.0's floor for a 2.0 ship is what
    # produced stale builds like "2.0 (build 202510190002)".
    set +e
    _floor_line="$(asc_build_floor "$MARKETING" "$ASC_PLATFORM")"
    _rc=$?
    if [[ $_rc -eq 4 ]]; then
      die "App Store Connect rejected the API key (HTTP 401/403; rejected key $(rejected_key_label)) while reading the build floor.
  Fix the key (ASC_* in env or Infisical /asc; fleet-secrets doctor) and re-run.
  --allow-unverified-seq does not cover a rejected credential:  the upload would fail with it too."
    fi
    set -e
    if [[ $_rc -ne 0 || -z "$_floor_line" ]]; then
      if [[ "$ALLOW_UNVERIFIED_SEQ" -eq 0 ]]; then
        die "cannot determine the build floor for ${MARKETING}.
  App Store Connect could not be consulted.  The build number must be greater
  than every build already in that train and greater than the app's own
  builds, and App Store Connect is the only record of them:  a build number
  that is not greater is rejected as a duplicate.
  Fix one of these, then re-run:
    1) restore ASC access: check ASC_* in env or Infisical /asc (fleet-secrets doctor) and that 'node' is on PATH, then
       run: node ${FLEET_DIR}/asc-api.mjs build-floor ${BUNDLE_ID} ${MARKETING} ${ASC_PLATFORM}
     2) or pass the build number explicitly:  --build <N>
        --build is honoured exactly:  CFBundleVersion becomes N.  It must be
        greater than every build already in that train.  --build does NOT move
        the marketing version any more:  the two numbers are independent.
     3) or, only if you are certain this train is empty, re-run with --allow-unverified-seq"
      fi
      logerr "WARNING: --allow-unverified-seq set; the build floor is UNVERIFIED (0)"
      _floor_line="0 0 0"
    fi
    # "<floor> <train> <app>":  the two parts of the floor, and the result.
    PLAN_FLOOR="$(printf '%s' "$_floor_line" | awk '{print $1}')"
    PLAN_TRAIN_FLOOR="$(printf '%s' "$_floor_line" | awk '{print $2}')"
    PLAN_APP_FLOOR="$(printf '%s' "$_floor_line" | awk '{print $3}')"
    [[ "$PLAN_FLOOR" =~ ^[0-9]+$ ]] || PLAN_FLOOR=0
    [[ "$PLAN_TRAIN_FLOOR" =~ ^[0-9]+$ ]] || PLAN_TRAIN_FLOOR=0
    [[ "$PLAN_APP_FLOOR" =~ ^[0-9]+$ ]] || PLAN_APP_FLOOR=0

    # Strictly-increasing guard:  ASC rejects a repeated (version, build)
    # pair, so never ship at or below the known floor.  The guard fires when
    # the floor is at or above the commit count -- because App Store Connect
    # already holds it, or because a shallow checkout understates the commit
    # count -- so the log line names the floor rather than asserting the
    # commit count was shipped.
    BUILD_NUM="$PLAN_COMMIT_COUNT"
    if [[ "$BUILD_NUM" -le "$PLAN_FLOOR" ]]; then
      BUILD_NUM="$((PLAN_FLOOR + 1))"
      log "build: floor ${PLAN_FLOOR} is at or above the commit count ${PLAN_COMMIT_COUNT}; using ${BUILD_NUM} instead"
    fi
    # A ship must never look like "1.0.N (N)":  if the build number happens
    # to be the patch number of the marketing version, move it one up.
    if [[ -n "$PLAN_TARGET_PATCH" && "$BUILD_NUM" -eq "$PLAN_TARGET_PATCH" ]]; then
      _bumped="$((BUILD_NUM + 1))"
      log "build: ${BUILD_NUM} equals the patch number; using ${_bumped} so the ship does not read ${MARKETING} (${BUILD_NUM})"
      BUILD_NUM="$_bumped"
    fi
  fi
fi

# The project file and the shipped version must never disagree silently. The
# version above is passed on the xcodebuild command line and overrides whatever
# project.pbxproj says, so a stale value there is invisible without this check.
# The project file is NOT a sequencing input any more (AFC-517):  this only
# reports the disagreement.
PROJECT_SEQ_NOW="$(project_marketing_seq "$PBXPROJ" "$MARKETING_PREFIX" quiet)"
if [[ -n "$UPLOAD_ONLY_IPA" ]]; then
  : # no version was resolved for --upload-only; nothing to compare against
elif [[ -z "$PBXPROJ" ]]; then
  log "project version: .xcodeproj not resolvable yet; skipping agreement check"
elif [[ "${MARKETING_PREFIX}.${PROJECT_SEQ_NOW}" != "$MARKETING" ]]; then
  log "NOTICE: project.pbxproj says MARKETING_VERSION=${MARKETING_PREFIX}.${PROJECT_SEQ_NOW}, shipping ${MARKETING}."
  log "NOTICE: the shipped value wins (passed to xcodebuild). To record it in the repo,"
  log "NOTICE: add --sync-project-version to the next REAL ship, then commit"
  log "NOTICE: clients/ios/*.xcodeproj/project.pbxproj. Syncing from a --dry-run would"
  log "NOTICE: write a number the next real ship then exceeds, re-creating this gap."
fi

# Write the resolved version into project.pbxproj so the repo records what
# shipped. Opt-in: it dirties the worktree, and the ship path itself requires a
# clean one.
if [[ "$SYNC_PROJECT_VERSION" -eq 1 ]]; then
  # A dry-run only peeks; nothing is consumed, so the next real ship
  # would exceed whatever we wrote here and the file would be stale again.
  [[ "$DRY_RUN" -eq 0 ]] || die "--sync-project-version cannot be combined with --dry-run.
  A dry-run does not ship anything, so writing ${MARKETING} now would be
  superseded by the next real ship. Pass --sync-project-version on the real ship instead."
  [[ -z "$UPLOAD_ONLY_IPA" ]] || die "--sync-project-version cannot be combined with --upload-only.
  An upload-only run resolves no version of its own — the IPA already carries one — so
  there is nothing to write back. Pass it on the run that builds the archive."
  [[ -n "$PBXPROJ" && -f "$PBXPROJ" ]] || die "--sync-project-version: project.pbxproj not found under $REPO_ROOT"
  /usr/bin/sed -i '' \
    -e "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = ${MARKETING};/g" \
    -e "s/CURRENT_PROJECT_VERSION = [^;]*;/CURRENT_PROJECT_VERSION = ${BUILD_NUM};/g" \
    "$PBXPROJ"
  log "synced project.pbxproj -> MARKETING_VERSION=${MARKETING} CURRENT_PROJECT_VERSION=${BUILD_NUM}"
  log "commit that change; it is the repo's record of this version"
fi
AUTH_MODE="none"
load_secrets

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_ROOT="${TMPDIR:-/tmp}/ios-ship-${APP_KEY}-${STAMP}"
ARCHIVE_PATH="${OUT_ROOT}/${SCHEME}.xcarchive"
EXPORT_DIR="${OUT_ROOT}/export"
LOG_DIR="${OUT_ROOT}/logs"
mkdir -p "$LOG_DIR"

log "app=${DISPLAY_NAME} key=${APP_KEY}"
log "bundleId=${BUNDLE_ID}"
log "scheme=${SCHEME}"
log "repo=${REPO_ROOT}"
if [[ "$PLAN_READY" -eq 1 ]]; then
  log "version plan: asc_patch=${PLAN_ASC_PATCH} -> marketing=${MARKETING}; build floors: train=${PLAN_TRAIN_FLOOR} app=${PLAN_APP_FLOOR} commit_count=${PLAN_COMMIT_COUNT} -> build=${BUILD_NUM}"
fi
log "marketing=${MARKETING} build=${BUILD_NUM}"
log "App Store Connect will show this as: ${MARKETING} (${BUILD_NUM})"
log "auth=${AUTH_MODE} export_only=${EXPORT_ONLY} force_ship=${FORCE_SHIP}"
log "out=${OUT_ROOT}"

# The gate already ran, before any version was resolved. A real run that
# was told to skip exited there; only --dry-run reaches this point still
# holding a "skip" decision, and it reports it as part of the plan.
if [[ "$DRY_RUN" -eq 1 ]]; then
  if [[ "$SHIP_GATE_DECISION" == "skip" ]]; then
    log "dry-run: ship-gate would SKIP this run; no version would be consumed"
  else
    log "dry-run: would archive + ship; exiting"
  fi
  exit 0
fi

if [[ -n "$UPLOAD_ONLY_IPA" ]]; then
  [[ -f "$UPLOAD_ONLY_IPA" ]] || die "package not found: $UPLOAD_ONLY_IPA"
  [[ "$AUTH_MODE" == "api_key" ]] || die "upload-only requires ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_P8 (env) or Infisical /asc (ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8)"
  link_private_key "$ASC_KEY_PATH" "$ASC_KEY_ID"
  log "uploading existing package via altool (api key)"
  set +e
  xcrun altool --upload-package "$UPLOAD_ONLY_IPA" \
    --apiKey "$ASC_KEY_ID" \
    --apiIssuer "$ASC_ISSUER_ID" \
    2>&1 | tee "${LOG_DIR}/upload.log"
  UPLOAD_RC=${PIPESTATUS[0]}
  set -e
  [[ $UPLOAD_RC -eq 0 ]] || die "altool upload failed (rc=$UPLOAD_RC); see ${LOG_DIR}/upload.log"
  record_successful_ship
  log "upload submitted; watch TestFlight processing in App Store Connect"
  exit 0
fi

# Optional XcodeGen regenerate
if [[ -n "$XCODEGEN_DIR" && "$XCODEGEN_DIR" != "null" && "$SKIP_XCODEGEN" -eq 0 ]]; then
  if command -v xcodegen >/dev/null 2>&1; then
    log "xcodegen generate in ${REPO_ROOT}/${XCODEGEN_DIR}"
    (cd "${REPO_ROOT}/${XCODEGEN_DIR}" && xcodegen generate) 2>&1 | tee "${LOG_DIR}/xcodegen.log"
  else
    log "xcodegen not installed; using checked-in .xcodeproj"
  fi
fi

PROJECT_PATH="$(resolve_project "$REPO_ROOT" "$PROJECT_REL" "$PROJECT_REL_ALT")" \
  || die "project not found under $REPO_ROOT ($PROJECT_REL / $PROJECT_REL_ALT)"

log "project=${PROJECT_PATH}"

# Archive (device, not simulator). -allowProvisioningUpdates lets Xcode
# download/create App Store distribution profiles for team CC8UTF7ATG.
# Xcode's saved account session can be rejected (observed 2026-08-09:
# "Unable to log in with account ... login details were rejected"), which fails
# automatic signing even when an ASC API key is available. Passing the key
# straight to xcodebuild removes the dependency on the Xcode UI session.
#
# IOS_MANUAL_SIGN=1 skips that portal call.  Xcode 26's provisioning service
# rejects this API key (developerservices2 401), so CodeCaps Release is signed
# with the App Store profiles already installed by name.  One specifier cannot
# cover two bundles; the XcodeGen Release configs carry each profile.
ASC_AUTH_FLAGS=()
if [[ -n "${ASC_KEY_PATH:-}" && -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]]; then
  _asc_key_expanded="$(expand_tilde "$ASC_KEY_PATH")"
  if [[ -f "$_asc_key_expanded" ]]; then
    ASC_AUTH_FLAGS=(-authenticationKeyPath "$_asc_key_expanded" \
      -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
    log "signing auth: ASC API key"
  fi
fi

# One Mac hosts three Actions runners. Serialize archive/export so two
# xcodebuild archives cannot thrash DerivedData / codesign at once.
ARCHIVE_LOCK_DIR="${STATE_DIR}/archive.lockdir"
acquire_archive_lock() {
  mkdir -p "$STATE_DIR"
  local tries=0
  until mkdir "$ARCHIVE_LOCK_DIR" 2>/dev/null; do
    tries=$((tries + 1))
    if [[ "$tries" -gt 180 ]]; then
      die "archive lock timeout (${ARCHIVE_LOCK_DIR})"
    fi
    log "archive lock busy; waiting (${tries})"
    sleep 10
  done
  # shellcheck disable=SC2064
  trap "rmdir '$ARCHIVE_LOCK_DIR' 2>/dev/null || true; cleanup_asc_tmp" EXIT
}
release_archive_lock() {
  rmdir "$ARCHIVE_LOCK_DIR" 2>/dev/null || true
}

# What each ensure-tf-ready exit code means.  Kept in its own file so the
# wording is testable without an App Store Connect round trip, and so the rc=5
# branch can name the real cause (no internal tester group) instead of the
# export-compliance wording that never applied to it.
#
# The helper is loaded here, in the ship body, and not at the top of the
# script:  the prelude of this script is cut and sourced on its own by the
# credential tests, and the prelude carries only safe top-level shapes.
load_tf_ready_outcome() {
  local helper="${FLEET_DIR}/tf-ready-outcome.sh"
  if [[ ! -f "$helper" ]]; then
    echo "missing ${helper}" >&2
    return 1
  fi
  # shellcheck source=scripts/ios-fleet/tf-ready-outcome.sh
  source "$helper"
}

# After a successful upload, declare export compliance if the IPA omitted
# ITSAppUsesNonExemptEncryption. Otherwise TestFlight stays
# MISSING_EXPORT_COMPLIANCE and the phone never sees the build (ST 1.0.1/2
# on 2026-08-12).
ensure_tf_ready() {
  log "verifying TestFlight ready-to-install for ${BUNDLE_ID} build ${BUILD_NUM}"
  set +e
  # BUILD_NUM (CFBundleVersion) is REQUIRED. Without it asc-api.mjs would have to
  # guess "the newest build", which for the first minutes after an upload is the
  # PREVIOUS ship -- so compliance got declared on the wrong build and readiness
  # was reported for a build never inspected (2026-08-13). MARKETING is a second
  # predicate, not a substitute: it identifies a train, not a build.
  IOS_TF_NOTES_REPO="$REPO_ROOT" \
  IOS_TF_NOTES_PREV_SHA="$PREV_SHIP_SHA" \
  IOS_TF_NOTES_APP="$DISPLAY_NAME" \
  IOS_TF_NOTES_IOS_PREFIX="$IOS_PATH_PREFIX" \
  asc_client ensure-tf-ready "$BUNDLE_ID" "$BUILD_NUM" "$MARKETING" \
    >"${LOG_DIR}/ensure-tf-ready.json" 2>"${LOG_DIR}/ensure-tf-ready.err"
  local rc=$?
  set -e
  if [[ -s "${LOG_DIR}/ensure-tf-ready.err" ]]; then
    while IFS= read -r line; do log "tf-ready: $line"; done <"${LOG_DIR}/ensure-tf-ready.err"
  fi
  if [[ $rc -eq 0 ]]; then
    log "TestFlight internal testers can install this build"
    return 0
  fi
  if [[ $rc -eq 3 ]]; then
    log "warning: upload succeeded but ASC has not reached IN_BETA_TESTING yet; watch TestFlight"
    return 0
  fi
  if [[ $rc -eq 4 ]]; then
    # The upload itself succeeded; ASC simply never surfaced the build in time.
    # Warn loudly but do NOT fail: the caller must still record_successful_ship,
    # or the rate gate never advances and the next scheduled run re-ships the
    # same HEAD. A red job after a successful upload also mislabels the outcome.
    log "warning: ASC never surfaced build ${BUILD_NUM}; export compliance NOT declared on it"
    log "warning: if the phone never gets this build, declare compliance by hand in App Store Connect"
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
      echo "::warning::ensure-tf-ready could not find uploaded build ${BUILD_NUM} for ${BUNDLE_ID}; export compliance not declared"
    fi
    return 0
  fi
  if [[ $rc -eq 5 || $rc -eq 6 ]]; then
    # rc=5 is READ AND ZERO ON THE INTERNAL PATH: the build was found, Apple
    # finished processing it, and export compliance WAS declared (the compliance
    # PATCH lands before the readiness poll, so the poll's enc=false is the
    # answered state).  The count behind the code is the count of INTERNAL
    # TestFlight testers in internal groups with access to all builds, so rc=5
    # means this app has no internal group and zero internal testers can install
    # the build.  rc=6 is the same situation with the count unreadable, so
    # installability on the internal path is unverified rather than known-zero.
    #
    # It says nothing about external testers: a build assigned to an external
    # group reaches that group, subject to Apple's beta review of the build.
    # CodeCaps iOS 1.0.263 / build 281 was in exactly that state on
    # 2026-10-25: no internal group, and at the same time assigned to the
    # existing Public Beta external group.
    #
    # The generic export-compliance wording never applied to either code, and
    # it is why 14 green ships reached nobody (GH #1018) and why CodeCaps iOS
    # 1.0.263 / build 281 shipped with a green job on 2026-10-25 and a
    # warning about the wrong thing.
    if ! load_tf_ready_outcome; then
      log "warning: the ensure-tf-ready outcome helper is missing, so exit code ${rc} has no wording"
      return 0
    fi
    while IFS= read -r line; do
      [[ -n "$line" ]] && log "$line"
    done <<< "$(tf_ready_outcome_lines "$rc")"
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
      echo "::warning::$(tf_ready_outcome_annotation "$rc" "$BUNDLE_ID" "$BUILD_NUM")"
    fi
    return 0
  fi
  # rc=2 is a usage error or an ASC API error. Compliance was NOT declared, so
  # this deserves the same CI annotation rc=4 gets -- otherwise the only trace
  # is one log line inside a green job, which is how ST 1.0.1/2 stayed
  # VALID-but-uninstallable without anyone noticing.
  log "warning: ensure-tf-ready failed (rc=$rc); build may be stuck on export compliance"
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::warning::ensure-tf-ready failed (rc=${rc}) for ${BUNDLE_ID} build ${BUILD_NUM}; export compliance not declared"
  fi
  return 0
}

write_manual_export_plists() {
  local map="$1"
  [[ -f "$map" ]] || die "manual signing profile map missing: $map"
  EXPORT_PLIST_UPLOAD="${LOG_DIR}/ExportOptions-manual-upload.plist"
  EXPORT_PLIST_IPA="${LOG_DIR}/ExportOptions-manual-ipa.plist"
  # Mac App Store pkgs need Apple Distribution for the app and a separate
  # installerSigningCertificate for productsign.  Putting the Installer
  # identity in signingCertificate makes codesign reject it.
  python3 - "$map" "$TEAM_ID" "$PLATFORM" "$EXPORT_PLIST_UPLOAD" "$EXPORT_PLIST_IPA" <<'PY'
import json, plistlib, sys
profiles = json.load(open(sys.argv[1], encoding="utf-8"))
team = sys.argv[2]
platform = sys.argv[3]
common = {
    "method": "app-store-connect",
    "teamID": team,
    "signingStyle": "manual",
    "signingCertificate": "Apple Distribution",
    "provisioningProfiles": profiles,
    "uploadSymbols": True,
    "manageAppVersionAndBuildNumber": False,
    "stripSwiftSymbols": True,
}
if platform == "macOS":
    common["installerSigningCertificate"] = "3rd Party Mac Developer Installer"
upload = dict(common)
upload["destination"] = "upload"
ipa = dict(common)
ipa["destination"] = "export"
with open(sys.argv[4], "wb") as handle:
    plistlib.dump(upload, handle, fmt=plistlib.FMT_XML)
with open(sys.argv[5], "wb") as handle:
    plistlib.dump(ipa, handle, fmt=plistlib.FMT_XML)
PY
  log "manual export plists written ($map platform=$PLATFORM)"
}

MANUAL_SIGN=0
PROVISION_UPDATE_FLAGS=(-allowProvisioningUpdates)
# CodeCaps iOS defaults to manual signing.  IOS_MANUAL_SIGN=0 forces the
# automatic portal path after the App Group is actually on the profiles.
# CodeCaps Mac uses MAC_MANUAL_SIGN (default on for codecaps-mac).
if [[ "$PLATFORM" == "macOS" ]]; then
  if [[ "${MAC_MANUAL_SIGN:-}" == "1" || ( "$APP_KEY" == "codecaps-mac" && "${MAC_MANUAL_SIGN:-}" != "0" ) ]]; then
    MANUAL_SIGN=1
  fi
elif [[ "${IOS_MANUAL_SIGN:-}" == "1" || ( "$APP_KEY" == "codecaps" && "${IOS_MANUAL_SIGN:-}" != "0" ) ]]; then
  MANUAL_SIGN=1
fi
if [[ "$MANUAL_SIGN" -eq 1 ]]; then
  PROVISION_UPDATE_FLAGS=()
  log "manual App Store signing: skipping Xcode provisioning portal"
  if [[ "$PLATFORM" == "macOS" ]]; then
    bash "${REPO_ROOT}/scripts/mac-install-appstore-profiles.sh"
    write_manual_export_plists "${REPO_ROOT}/ios/CodeCapsCompanion/mac-appstore-profiles.json"
    # Keep ASC API auth for destination=upload; Mac export still needs the
    # App Store Connect session even when profiles are pre-installed.
  else
    bash "${REPO_ROOT}/scripts/ios-install-appstore-profiles.sh"
    write_manual_export_plists "${REPO_ROOT}/ios/CodeCapsCompanion/appstore-profiles.json"
    ASC_AUTH_FLAGS=()
  fi
fi

acquire_archive_lock
log "archiving..."
set +e
if [[ "$PLATFORM" == "macOS" ]]; then
  ARCHIVE_PLATFORM_FLAGS=(-destination "generic/platform=macOS")
else
  ARCHIVE_PLATFORM_FLAGS=(-destination "generic/platform=iOS")
fi

SENTRY_DSN_FLAGS=()
if [[ -n "${SENTRY_DSN:-}" ]]; then
  SENTRY_DSN_FLAGS+=(SENTRY_DSN="$SENTRY_DSN")
  log "SENTRY_DSN present for archive (length ${#SENTRY_DSN})"
else
  log "SENTRY_DSN unset; Cocoa no-ops when the plist value is empty"
fi

if [[ "$MANUAL_SIGN" -eq 1 ]]; then
  xcodebuild archive \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration Release \
    "${ARCHIVE_PLATFORM_FLAGS[@]}" \
    -archivePath "$ARCHIVE_PATH" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    MARKETING_VERSION="$MARKETING" \
    CURRENT_PROJECT_VERSION="$BUILD_NUM" \
    ${SENTRY_DSN_FLAGS[@]:+"${SENTRY_DSN_FLAGS[@]}"} \
    2>&1 | tee "${LOG_DIR}/archive.log"
else
  xcodebuild archive \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration Release \
    "${ARCHIVE_PLATFORM_FLAGS[@]}" \
    -archivePath "$ARCHIVE_PATH" \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    ${ASC_AUTH_FLAGS[@]:+"${ASC_AUTH_FLAGS[@]}"} \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Automatic \
    MARKETING_VERSION="$MARKETING" \
    CURRENT_PROJECT_VERSION="$BUILD_NUM" \
    ${SENTRY_DSN_FLAGS[@]:+"${SENTRY_DSN_FLAGS[@]}"} \
    2>&1 | tee "${LOG_DIR}/archive.log"
fi
ARCHIVE_RC="${PIPESTATUS[0]:-$?}"
set -e
[[ $ARCHIVE_RC -eq 0 ]] || die "archive failed (rc=$ARCHIVE_RC); see ${LOG_DIR}/archive.log"
upload_sentry_artifacts

if [[ "$MANUAL_SIGN" -eq 0 ]]; then
  EXPORT_PLIST_UPLOAD="${FLEET_DIR}/ExportOptions-appstore.plist"
  EXPORT_PLIST_IPA="${FLEET_DIR}/ExportOptions-export-ipa.plist"
fi

if [[ "$EXPORT_ONLY" -eq 1 ]]; then
  log "exporting package only..."
  mkdir -p "$EXPORT_DIR"
  set +e
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_PLIST_IPA" \
    ${PROVISION_UPDATE_FLAGS[@]:+"${PROVISION_UPDATE_FLAGS[@]}"} \
    ${ASC_AUTH_FLAGS[@]:+"${ASC_AUTH_FLAGS[@]}"} \
    2>&1 | tee "${LOG_DIR}/export.log"
  EXPORT_RC=${PIPESTATUS[0]}
  set -e
  [[ $EXPORT_RC -eq 0 ]] || die "export failed (rc=$EXPORT_RC); see ${LOG_DIR}/export.log"
  PACKAGE="$(ls -1 "$EXPORT_DIR"/*.ipa "$EXPORT_DIR"/*.pkg 2>/dev/null | head -1 || true)"
  [[ -n "$PACKAGE" ]] || die "no IPA or PKG produced in $EXPORT_DIR"
  log "Package ready: $PACKAGE"
  log "Upload later: bash $0 $APP_KEY --upload-only \"$PACKAGE\""
  exit 0
fi

# Prefer: export with destination=upload (uses Xcode session OR ASC if configured in Xcode)
# Mac manual ships: hosted xcodebuild -exportArchive has hung on productsign.
# Build the .pkg with productbuild from the xcarchive, then altool upload.
if [[ "$PLATFORM" == "macOS" && "$MANUAL_SIGN" -eq 1 ]]; then
  log "macOS manual ship: productbuild pkg from xcarchive (skip xcodebuild -exportArchive)"
  mkdir -p "$EXPORT_DIR"
  PACKAGE="$(bash "${REPO_ROOT}/scripts/mac-export-appstore-pkg.sh" "$ARCHIVE_PATH" "$EXPORT_DIR" | tail -1)"
  [[ -n "$PACKAGE" && -f "$PACKAGE" ]] || die "mac-export-appstore-pkg.sh failed"
  log "Package ready: $PACKAGE"
else
  log "exporting + uploading to App Store Connect..."
  mkdir -p "$EXPORT_DIR"
  set +e
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_PLIST_UPLOAD" \
    ${PROVISION_UPDATE_FLAGS[@]:+"${PROVISION_UPDATE_FLAGS[@]}"} \
    ${ASC_AUTH_FLAGS[@]:+"${ASC_AUTH_FLAGS[@]}"} \
    2>&1 | tee "${LOG_DIR}/export-upload.log"
  EXPORT_RC=${PIPESTATUS[0]}
  set -e

  if [[ $EXPORT_RC -eq 0 ]]; then
    log "upload path succeeded via xcodebuild export (destination=upload)"
    log "build ${MARKETING} (${BUILD_NUM}) submitted for ${BUNDLE_ID}"
    release_archive_lock
    ensure_tf_ready
    record_successful_ship
    log "logs: ${LOG_DIR}"
    exit 0
  fi

  log "xcodebuild upload export failed (rc=$EXPORT_RC); trying local export + altool"

  mkdir -p "$EXPORT_DIR"
  set +e
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_PLIST_IPA" \
    ${PROVISION_UPDATE_FLAGS[@]:+"${PROVISION_UPDATE_FLAGS[@]}"} \
    ${ASC_AUTH_FLAGS[@]:+"${ASC_AUTH_FLAGS[@]}"} \
    2>&1 | tee "${LOG_DIR}/export-ipa.log"
  EXPORT_RC=${PIPESTATUS[0]}
  set -e
  [[ $EXPORT_RC -eq 0 ]] || die "export failed (rc=$EXPORT_RC); see ${LOG_DIR}/export-ipa.log and ${LOG_DIR}/export-upload.log"

  PACKAGE="$(ls -1 "$EXPORT_DIR"/*.ipa "$EXPORT_DIR"/*.pkg 2>/dev/null | head -1 || true)"
  [[ -n "$PACKAGE" ]] || die "no IPA or PKG produced in $EXPORT_DIR"
fi

# Re-load secrets before altool: long xcodebuild sessions can leave ASC_*
# unset under `set -u` even when AUTH_MODE was api_key at plan time.
load_secrets
if [[ "$AUTH_MODE" != "api_key" ]]; then
  log "Package ready at: $PACKAGE"
  log "Upload blocked: no App Store Connect API key."
  log "Owner handoff:"
  log "  1) Create ASC API key (App Manager+) in App Store Connect"
  log "  2) Store ASC_KEY_ID and ASC_ISSUER_ID in Infisical Fleet-OPS /asc"
  log "  3) Store the .p8 contents as ASC_KEY_P8 in the same Infisical folder"
  log "  4) Or export ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_P8 for this run"
  log "  5) Re-run: bash $0 $APP_KEY --upload-only \"$PACKAGE\""
  log "Also ensure App Store Connect has an app record for ${BUNDLE_ID}."
  exit 3
fi

link_private_key "${ASC_KEY_PATH}" "${ASC_KEY_ID}"
log "uploading package via altool (api key)"
set +e
xcrun altool --upload-package "$PACKAGE" \
  --apiKey "${ASC_KEY_ID}" \
  --apiIssuer "${ASC_ISSUER_ID}" \
  2>&1 | tee "${LOG_DIR}/upload.log"
UPLOAD_RC=${PIPESTATUS[0]}
set -e
if [[ $UPLOAD_RC -ne 0 ]]; then
  log "altool failed (rc=$UPLOAD_RC). Common cause: no App Store Connect app for ${BUNDLE_ID}."
  log "Create the app in ASC (My Apps → +) with this exact bundle id, then:"
  log "  bash $0 $APP_KEY --upload-only \"$PACKAGE\""
  die "altool upload failed (rc=$UPLOAD_RC); see ${LOG_DIR}/upload.log"
fi

release_archive_lock
ensure_tf_ready
record_successful_ship
log "upload submitted; watch TestFlight processing for ${BUNDLE_ID} build ${BUILD_NUM}"
log "logs: ${LOG_DIR}"
exit 0

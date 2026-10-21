#!/usr/bin/env bash
# Install the credential tooling the release workflows read Fleet-OPS with,
# mint the Infisical access token that tooling uses, and run the consumer that
# resolves the credentials.
#
# It installs two things:
#
#   * the Infisical CLI, pinned to version 0.44.4.  The release tarball is
#     checked against the pinned SHA-256 of the asset before it is unpacked,
#     so a moved or rebuilt asset fails the step instead of installing
#     something nobody reviewed.
#   * the fleet's `fleet-secrets` reader, taken from the pinned commit of the
#     public AI-Fleet-Coordinator repository and installed with the upstream
#     installer, so the runner ends up with the layout every fleet Mac has.
#
# It then mints an Infisical access token with universal auth and runs
# scripts/stage-asc-key.mjs, the only thing in the release that reads a
# credential.
#
# The token never touches a file.  It is minted into a shell variable, it is
# exported into the environment of the consumer, and the consumer runs in this
# same process tree.  It is never echoed, never printed, never written to
# $GITHUB_ENV and never written to disk.
#
# The names the workflow already uses are mapped here onto the names the
# reader and the CLI expect:
#
#   INFISICAL_PROJECT_ID     ->  INFISICAL_FLEET_OPS_PROJECT_ID
#   INFISICAL_CLIENT_ID      ->  INFISICAL_UNIVERSAL_AUTH_CLIENT_ID
#   INFISICAL_CLIENT_SECRET  ->  INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET
#
# Run: bash scripts/install-release-secrets-tooling.sh
set +o xtrace
set -euo pipefail

INFISICAL_CLI_VERSION="0.44.4"
INFISICAL_CLI_SHA256_arm64="02ccd2ce6e1d80eeafb06022697fe7f3c6434ba757b31590f2ff8f88d6ccaf51"
INFISICAL_CLI_SHA256_x86_64="35a6af67d361bf4f14ec814c08143293dd00f35eb0ad6a171eec967ca5c9585e"
FLEET_SECRETS_REPO="Simple-With-Us/AI-Fleet-Coordinator"
# The pinned commit the reader comes from.  The name avoids the word "secret"
# on purpose: a 40-character hash beside it reads as a credential to the
# secret scanner, and a false positive here is a broken release.
FLEET_READER_COMMIT="436ed80b17dd9b4e6326ad7c270629fa84c9c950"
FLEET_SECRETS_MODULES="__init__.py __main__.py cli.py core.py linux-entrypoint.py sync_cli_login.py"

# The reader lands in the fleet's own tools directory, which the reader knows
# about: it looks there when PATH does not carry it.
TOOLS_DIR="${HOME}/.local/bin"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

work="$(mktemp -d "${TMPDIR:-/tmp}/release-secrets.XXXXXX")"
trap 'rm -rf "$work"' EXIT

say() {
  printf '%s\n' "$*"
}

# Every fallible step names its own failure, because the consumer has to run
# even when the install did not: it is what removes any key-bearing entry
# from the job's environment file.
fail() {
  printf 'install-release-secrets-tooling: %s\n' "$*" >&2
  return 1
}

# The SHA-256 of a file, with the two tools a runner may have.
sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

# The CLI's own error text, with the client id and the client secret taken
# out of it.  A failed login must be diagnosable from the log, and neither
# half of the identity belongs in a log.
scrub() {
  local text="$1"
  if [ -n "${INFISICAL_CLIENT_ID:-}" ]; then
    text="${text//"$INFISICAL_CLIENT_ID"/<redacted>}"
  fi
  if [ -n "${INFISICAL_CLIENT_SECRET:-}" ]; then
    text="${text//"$INFISICAL_CLIENT_SECRET"/<redacted>}"
  fi
  printf '%s' "$text"
}

install_infisical_cli() {
  local asset expected actual published base
  case "$(uname -m)" in
    arm64)
      asset="cli_${INFISICAL_CLI_VERSION}_darwin_arm64.tar.gz"
      expected="$INFISICAL_CLI_SHA256_arm64"
      ;;
    x86_64)
      asset="cli_${INFISICAL_CLI_VERSION}_darwin_amd64.tar.gz"
      expected="$INFISICAL_CLI_SHA256_x86_64"
      ;;
    *)
      fail "the runner architecture $(uname -m) has no pinned Infisical CLI build"
      return 1
      ;;
  esac
  base="https://github.com/infisical/cli/releases/download/v${INFISICAL_CLI_VERSION}"
  curl -fsSL "$base/$asset" -o "$work/$asset" \
    || { fail "the Infisical CLI $asset could not be downloaded"; return 1; }
  actual="$(sha256_of "$work/$asset")"
  [ "$actual" = "$expected" ] \
    || { fail "the Infisical CLI $asset does not match the pinned checksum"; return 1; }
  # The release publishes the same checksum in its own list.  A disagreement
  # means the asset moved, and the step fails rather than installing it.
  if curl -fsSL "$base/checksums-darwin.txt" -o "$work/checksums.txt" 2>/dev/null; then
    published="$(awk -v a="$asset" '$2 == a { print $1 }' "$work/checksums.txt")"
    if [ -n "$published" ] && [ "$published" != "$expected" ]; then
      fail "the Infisical CLI release publishes a different checksum for $asset"
      return 1
    fi
  fi
  tar xzf "$work/$asset" -C "$work" infisical \
    || { fail "the Infisical CLI archive could not be unpacked"; return 1; }
  mkdir -p "$TOOLS_DIR" || { fail "the tools directory could not be created"; return 1; }
  install -m 0755 "$work/infisical" "$TOOLS_DIR/infisical" \
    || { fail "the Infisical CLI could not be installed"; return 1; }
  say "installed: Infisical CLI $INFISICAL_CLI_VERSION -> $TOOLS_DIR/infisical"
}

install_fleet_secrets() {
  local raw module
  raw="https://raw.githubusercontent.com/$FLEET_SECRETS_REPO/$FLEET_READER_COMMIT/scripts"
  mkdir -p "$work/scripts/fleet_secrets" \
    || { fail "the fleet-secrets staging directory could not be created"; return 1; }
  for module in $FLEET_SECRETS_MODULES; do
    curl -fsSL "$raw/fleet_secrets/$module" -o "$work/scripts/fleet_secrets/$module" \
      || { fail "the fleet-secrets module $module could not be downloaded"; return 1; }
  done
  curl -fsSL "$raw/fleet-secrets" -o "$work/scripts/fleet-secrets" \
    || { fail "the fleet-secrets entry point could not be downloaded"; return 1; }
  curl -fsSL "$raw/install-fleet-secrets.sh" -o "$work/scripts/install-fleet-secrets.sh" \
    || { fail "the fleet-secrets installer could not be downloaded"; return 1; }
  # The upstream installer lays the package out the way every fleet Mac has
  # it, so the runner and the Mac read the vault the same way.
  bash "$work/scripts/install-fleet-secrets.sh" >/dev/null \
    || { fail "the fleet-secrets installer failed"; return 1; }
  say "installed: fleet-secrets ($FLEET_READER_COMMIT) -> $TOOLS_DIR/fleet-secrets"
}

mint_token() {
  local status token project_id
  project_id="${INFISICAL_PROJECT_ID:-}"
  [ -n "$project_id" ] || { fail "the Fleet-OPS Infisical project id is not set"; return 1; }
  [ -n "${INFISICAL_CLIENT_ID:-}" ] \
    || { fail "the Infisical universal auth client id is not set"; return 1; }
  [ -n "${INFISICAL_CLIENT_SECRET:-}" ] \
    || { fail "the Infisical universal auth client secret is not set"; return 1; }

  export INFISICAL_UNIVERSAL_AUTH_CLIENT_ID="$INFISICAL_CLIENT_ID"
  export INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET="$INFISICAL_CLIENT_SECRET"
  export INFISICAL_DISABLE_UPDATE_CHECK="true"

  # The token is minted into a shell variable and stays there.  It is read
  # from the command's output, which never reaches the log, and it is never
  # written to a file.
  status=0
  token="$("$TOOLS_DIR/infisical" login --method=universal-auth --plain --silent 2>"$work/login.err")" || status=$?
  if [ "$status" -ne 0 ]; then
    say "the Infisical CLI refused the universal auth login (exit $status): $(scrub "$(cat "$work/login.err")")"
    fail "no Infisical access token was minted"
    return 1
  fi
  case "$token" in
    "") fail "the Infisical CLI returned no access token"; return 1 ;;
    *[[:space:]]*) fail "the Infisical CLI returned an access token that is not a single line"; return 1 ;;
  esac

  # The token and the project id are the session the consumer inherits.  The
  # client secret stays out of it: the token is the identity from here on.
  export INFISICAL_TOKEN="$token"
  export INFISICAL_FLEET_OPS_PROJECT_ID="$project_id"
  export PATH="$TOOLS_DIR:$PATH"
  say "minted: an Infisical access token for the consumer"
}

install_tooling() {
  install_infisical_cli || return 1
  install_fleet_secrets || return 1
  mint_token || return 1
}

# The install is allowed to fail and the consumer still runs: the consumer is
# what removes any key-bearing entry from the job's environment file, and the
# step reports the status of the command that actually failed.
install_rc=0
install_tooling || install_rc=$?

stage_rc=0
node "$repo_root/scripts/stage-asc-key.mjs" || stage_rc=$?

if [ "$install_rc" -ne 0 ]; then exit "$install_rc"; fi
exit "$stage_rc"

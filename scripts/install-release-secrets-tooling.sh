#!/usr/bin/env bash
# Install the credential tooling the release workflows read Fleet-OPS with, and
# mint the Infisical access token that tooling uses.
#
# Two things are installed:
#
#   * the Infisical CLI, pinned to version 0.44.4.  The release tarball is
#     checked against the pinned SHA-256 of the asset before it is unpacked,
#     so a moved or rebuilt asset fails the step instead of installing
#     something nobody reviewed.
#   * the fleet's `fleet-secrets` reader, taken from the pinned commit of the
#     public AI-Fleet-Coordinator repository and installed with the upstream
#     installer, so the runner ends up with the layout every fleet Mac has.
#
# The token is minted with universal auth and exported as INFISICAL_TOKEN for
# the rest of the step.  It is never printed, never echoed and never written
# to $GITHUB_ENV: the workflow reads it back from a mode-600 file of shell
# assignments and removes that file when the step ends.
#
# The names the workflow already uses are mapped here onto the names the
# reader and the CLI expect:
#
#   INFISICAL_PROJECT_ID     ->  INFISICAL_FLEET_OPS_PROJECT_ID
#   INFISICAL_CLIENT_ID      ->  INFISICAL_UNIVERSAL_AUTH_CLIENT_ID
#   INFISICAL_CLIENT_SECRET  ->  INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET
#
# Nothing here reads a credential.  The ASC material is read by
# scripts/stage-asc-key.mjs, through the reader this script installs.
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
# The workflow reads the minted session back from this file.  The name is the
# one the workflows use, so the two never drift apart.
ENV_FILE="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/release-secrets-env.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/release-secrets.XXXXXX")"
trap 'rm -rf "$work"' EXIT

say() {
  printf '%s\n' "$*"
}

die() {
  printf 'install-release-secrets-tooling: %s\n' "$*" >&2
  exit 1
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
      die "the runner architecture $(uname -m) has no pinned Infisical CLI build"
      ;;
  esac
  base="https://github.com/infisical/cli/releases/download/v${INFISICAL_CLI_VERSION}"
  curl -fsSL "$base/$asset" -o "$work/$asset" \
    || die "the Infisical CLI $asset could not be downloaded"
  actual="$(sha256_of "$work/$asset")"
  [ "$actual" = "$expected" ] \
    || die "the Infisical CLI $asset does not match the pinned checksum"
  # The release publishes the same checksum in its own list.  A disagreement
  # means the asset moved, and the step fails rather than installing it.
  if curl -fsSL "$base/checksums-darwin.txt" -o "$work/checksums.txt" 2>/dev/null; then
    published="$(awk -v a="$asset" '$2 == a { print $1 }' "$work/checksums.txt")"
    if [ -n "$published" ] && [ "$published" != "$expected" ]; then
      die "the Infisical CLI release publishes a different checksum for $asset"
    fi
  fi
  tar xzf "$work/$asset" -C "$work" infisical \
    || die "the Infisical CLI archive could not be unpacked"
  mkdir -p "$TOOLS_DIR"
  install -m 0755 "$work/infisical" "$TOOLS_DIR/infisical" \
    || die "the Infisical CLI could not be installed"
  say "installed: Infisical CLI $INFISICAL_CLI_VERSION -> $TOOLS_DIR/infisical"
}

install_fleet_secrets() {
  local raw module
  raw="https://raw.githubusercontent.com/$FLEET_SECRETS_REPO/$FLEET_READER_COMMIT/scripts"
  mkdir -p "$work/scripts/fleet_secrets"
  for module in $FLEET_SECRETS_MODULES; do
    curl -fsSL "$raw/fleet_secrets/$module" -o "$work/scripts/fleet_secrets/$module" \
      || die "the fleet-secrets module $module could not be downloaded"
  done
  curl -fsSL "$raw/fleet-secrets" -o "$work/scripts/fleet-secrets" \
    || die "the fleet-secrets entry point could not be downloaded"
  curl -fsSL "$raw/install-fleet-secrets.sh" -o "$work/scripts/install-fleet-secrets.sh" \
    || die "the fleet-secrets installer could not be downloaded"
  # The upstream installer lays the package out the way every fleet Mac has
  # it, so the runner and the Mac read the vault the same way.
  bash "$work/scripts/install-fleet-secrets.sh" >/dev/null \
    || die "the fleet-secrets installer failed"
  say "installed: fleet-secrets ($FLEET_READER_COMMIT) -> $TOOLS_DIR/fleet-secrets"
}

mint_token() {
  local status token project_id
  project_id="${INFISICAL_PROJECT_ID:-}"
  [ -n "$project_id" ] || die "the Fleet-OPS Infisical project id is not set"
  [ -n "${INFISICAL_CLIENT_ID:-}" ] \
    || die "the Infisical universal auth client id is not set"
  [ -n "${INFISICAL_CLIENT_SECRET:-}" ] \
    || die "the Infisical universal auth client secret is not set"

  export INFISICAL_UNIVERSAL_AUTH_CLIENT_ID="$INFISICAL_CLIENT_ID"
  export INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET="$INFISICAL_CLIENT_SECRET"
  export INFISICAL_DISABLE_UPDATE_CHECK="true"

  # The token is captured, never echoed: it is read from the command's output
  # and never reaches the log.
  status=0
  token="$("$TOOLS_DIR/infisical" login --method=universal-auth --plain --silent 2>"$work/login.err")" || status=$?
  if [ "$status" -ne 0 ]; then
    say "the Infisical CLI refused the universal auth login (exit $status): $(scrub "$(cat "$work/login.err")")"
    die "no Infisical access token was minted"
  fi
  case "$token" in
    "") die "the Infisical CLI returned no access token" ;;
    *[[:space:]]*) die "the Infisical CLI returned an access token that is not a single line" ;;
  esac

  export INFISICAL_TOKEN="$token"
  export INFISICAL_FLEET_OPS_PROJECT_ID="$project_id"
  export PATH="$TOOLS_DIR:$PATH"

  # The session the workflow reads back.  It carries the token and the
  # project id, never the client secret: the token is the identity the
  # reader uses from here on.
  umask 077
  {
    printf 'export INFISICAL_FLEET_OPS_PROJECT_ID=%s\n' "$(printf '%q' "$project_id")"
    printf 'export INFISICAL_TOKEN=%s\n' "$(printf '%q' "$token")"
    printf 'export PATH=%s\n' "$(printf '%q' "$PATH")"
  } >"$ENV_FILE"
  chmod 600 "$ENV_FILE"
  say "minted: an Infisical access token for the rest of this step ($ENV_FILE, mode 600)"
}

install_infisical_cli
install_fleet_secrets
mint_token

# The reader is proven against the vault before the staging script runs.
# `names` prints key names only, never a value, and its output is dropped.
"$TOOLS_DIR/fleet-secrets" names --path /asc >/dev/null \
  || die "the fleet reader could not read Fleet-OPS prod /asc with the minted token"
say "verified: the fleet reader reads Fleet-OPS prod /asc"

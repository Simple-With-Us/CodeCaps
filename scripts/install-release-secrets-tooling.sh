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
# It then mints an Infisical access token with universal auth, proves that the
# fleet's reader can use that token, and runs scripts/stage-asc-key.mjs, the
# only thing in the release that reads a credential.
#
# The token never touches a file.  It is minted into a shell variable, it is
# exported into the environment of the consumer, and the consumer runs in this
# same process tree.  It is never echoed, never printed, never written to
# $GITHUB_ENV and never written to disk.
#
# The reader is proven before the consumer runs, because the consumer cannot
# tell a broken reader from a missing credential: it reads a failed lookup as
# an empty value, so a broken tool and a rejected token both read as "the
# credential is missing", and the operator is sent to fix vault permissions
# when the fault is the tooling.  The proof is read-only: it lists the names
# in Fleet-OPS prod /asc and never a value.
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

# The replacement in a bash substitution is a pattern, and in bash 5.2 and
# later an ampersand in it expands to the text that matched, which here would
# be the credential itself.  The option is turned off where the shell has it,
# and the preview refuses a value that could put one in the replacement, so
# neither shell can expand one back into the secret.
if shopt -q patsub_replacement 2>/dev/null; then
  shopt -u patsub_replacement
fi

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

# A masked preview of a credential:  the first eight characters and the last
# four, with an ellipsis between them.  It is not reversible, because the
# ellipsis stands for the part that is not shown, and it names the value that
# was rejected so an operator can tell which one it was without being handed
# the value (rule 43).
#
# The preview is only a preview when the middle of the value is really hidden.
# The two slices cover twelve characters between them, so a value of twelve
# characters or fewer would be reconstructed in full by the two of them
# together; those are redacted outright instead.  The message that carries the
# preview names the credential, so an operator still knows which value was
# refused without any part of the value being shown.
#
# The preview also has to be an ordinary string.  The replacement in a bash
# substitution is a pattern, and in bash 5.2 and later an ampersand in it
# expands to the text that matched, which here would be the credential
# itself.  A value that could put one in the preview is refused, so the
# preview can only ever be text.
mask() {
  local value="$1"
  case "$value" in
    *[\&]*) printf '%s' "<redacted>"; return ;;
  esac
  if [ "${#value}" -le 12 ]; then
    printf '%s' "<redacted>"
    return
  fi
  printf '%s…%s' "${value:0:8}" "${value: -4}"
}

# A tool's own error text, with the client id, the client secret and the
# access token taken out of it.  A failed login or a failed read must be
# diagnosable from the log, and no part of the identity belongs in a log.
# The token is minted fresh for every job, so a slice of it would identify
# nothing an operator can act on; the diagnosis names the fault instead.
#
# The client id and the client secret are long lived and the runner masks
# them by value, so they are redacted whole:  a preview of either would
# defeat that masking and put twelve characters of a standing credential in
# a public log.  The access token is minted for one job, so it may carry a
# preview, and that preview is what tells the operator which value was
# refused.
scrub() {
  local text="$1" masked redacted
  redacted='<redacted>'
  if [ -n "${INFISICAL_CLIENT_ID:-}" ]; then
    text="${text//"$INFISICAL_CLIENT_ID"/${redacted}}"
  fi
  if [ -n "${INFISICAL_CLIENT_SECRET:-}" ]; then
    text="${text//"$INFISICAL_CLIENT_SECRET"/${redacted}}"
  fi
  if [ -n "${INFISICAL_TOKEN:-}" ]; then
    masked="$(mask "$INFISICAL_TOKEN")"
    text="${text//"$INFISICAL_TOKEN"/${masked}}"
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
    say "the Infisical CLI refused the universal auth login (exit $status); the client id or the client secret was refused: $(scrub "$(cat "$work/login.err")")"
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

# The reader is proven before the consumer runs.  The consumer reads a failed
# lookup as an empty value, so a missing reader, a broken install and a token
# the vault rejects would all read as "the credential is missing" and send the
# operator to fix vault permissions when the fault is the tooling.  This check
# names the fault instead.
#
# The proof is read-only and lists names, never values: `fleet-secrets names
# --path /asc` is the fleet's own reader, and it carries the minted token
# through INFISICAL_TOKEN.
#
# The reader's exit codes are its own: 2 is a refused configuration, 4 is a
# fetch or auth failure and 5 is an unresolved reference in the vault.  A
# reference is a credential fault, not a tooling fault, and the consumer names
# it precisely, so it does not fail this check.
check_reader() {
  local reader status detail name missing
  reader="${FLEET_SECRETS:-}"
  if [ -z "$reader" ]; then
    reader="$(command -v fleet-secrets || true)"
  fi
  if [ -z "$reader" ]; then
    fail "the fleet-secrets reader is not on PATH; the reader is at fault, not the vault permissions"
    return 1
  fi
  status=0
  "$reader" names --path /asc >"$work/names.out" 2>"$work/names.err" || status=$?
  if [ "$status" -eq 0 ]; then
    # The reader works, so a name the release needs that is not in the list
    # is a credential missing from the vault.  It is named here, because the
    # consumer cannot tell an absent name from an unreadable one and would
    # send the operator to fix the read permissions.
    missing=""
    for name in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8; do
      # A name the job's own environment already carries is resolved from
      # there first (stage-asc-key.mjs reads the environment before the
      # vault), so its absence from the vault is not a fault.  The consumer
      # trims a value before it uses it and refuses one that holds nothing
      # but whitespace, so a name the environment carries in that shape is
      # not resolved from there either and has to come from the vault.
      case "${!name:-}" in
        *[![:space:]]*) continue ;;
      esac
      grep -qx -- "$name" "$work/names.out" || missing="${missing:+$missing, }$name"
    done
    if [ -n "$missing" ]; then
      fail "the fleet-secrets reader can read Fleet-OPS prod /asc, but ${missing} is not there; the credential is missing from the vault, not unreadable"
      return 1
    fi
    say "checked: the fleet-secrets reader can read Fleet-OPS prod /asc"
    return 0
  fi
  if [ "$status" -eq 5 ]; then
    # The fetch reached the vault, so the reader and the token both work and
    # the fault is in the vault's content.  The consumer reports it:  it keeps
    # the reader's exit 5 and names the unresolved reference rather than a
    # missing credential.
    say "checked: the fleet-secrets reader reached Fleet-OPS prod /asc; a value there is an unresolved Infisical reference"
    return 0
  fi
  detail="$(scrub "$(cat "$work/names.err" 2>/dev/null || true)")"
  detail="${detail:-the reader reported no detail}"
  case "$status" in
    2)
      fail "the fleet-secrets reader refused to read Fleet-OPS prod /asc (exit 2); the reader or its configuration is at fault, not the vault permissions: ${detail}"
      ;;
    4)
      fail "the fleet-secrets reader could not read Fleet-OPS prod /asc (exit 4); the minted Infisical access token was rejected or the vault was unreachable: ${detail}"
      ;;
    *)
      fail "the fleet-secrets reader failed to list Fleet-OPS prod /asc (exit ${status}); the reader is at fault: ${detail}"
      ;;
  esac
  return 1
}

install_tooling() {
  install_infisical_cli || return 1
  install_fleet_secrets || return 1
  mint_token || return 1
  check_reader || return 1
}

# The reader can be proved on its own, with a token the caller already holds.
# An operator runs it to test a reader or a token without running a release
# step, and the contract test drives it with a stubbed reader:
#
#   INFISICAL_TOKEN=... INFISICAL_FLEET_OPS_PROJECT_ID=... \
#     bash scripts/install-release-secrets-tooling.sh check-reader
#
# Without an argument the script does the whole release job: install the
# tooling, mint the token, prove the reader and run the consumer.
if [ "${1:-}" = "check-reader" ]; then
  export PATH="$TOOLS_DIR:$PATH"
  # Without a token the reader falls back to sources a runner does not have
  # and fails the way a rejected token fails, so an absent token is named
  # before the reader is asked.
  if [ -z "${INFISICAL_TOKEN:-}" ]; then
    fail "no Infisical access token in the environment; export INFISICAL_TOKEN and INFISICAL_FLEET_OPS_PROJECT_ID before proving the reader"
    exit 1
  fi
  check_reader || exit 1
  exit 0
fi

# The install is allowed to fail and the consumer still runs: the consumer is
# what removes any key-bearing entry from the job's environment file, and the
# step reports the status of the command that actually failed.
install_rc=0
install_tooling || install_rc=$?

stage_rc=0
node "$repo_root/scripts/stage-asc-key.mjs" || stage_rc=$?

if [ "$install_rc" -ne 0 ]; then exit "$install_rc"; fi
exit "$stage_rc"

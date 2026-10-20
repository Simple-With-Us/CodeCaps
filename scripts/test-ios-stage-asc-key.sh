#!/usr/bin/env bash
# Offline test for the ASC key handoff in .github/workflows/ios-ship.yml:
# scripts/ios-stage-asc-key.sh itself, then the real fetch script driven by a
# stubbed Infisical.  No Apple or Infisical credential is used; every key
# below is a synthetic fixture.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/staging"
export ASC_STAGING_ROOT="$tmp_dir/staging"
export GITHUB_ENV="$tmp_dir/github-env"
: > "$GITHUB_ENV"

cat > "$tmp_dir/fixture" <<'KEY'
SYNTHETIC-HEADER
SYNTHETIC-MULTILINE-FIXTURE-DO-NOT-USE
SYNTHETIC-FOOTER
KEY

bash "$repo_root/scripts/ios-stage-asc-key.sh" < "$tmp_dir/fixture" > "$tmp_dir/stdout" 2> "$tmp_dir/stderr"
key_path="$(sed -n 's/^ASC_KEY_PATH=//p' "$GITHUB_ENV")"
[[ -f "$key_path" ]]
file_mode() {
  if [[ "$(uname -s)" == Darwin ]]; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}
[[ "$(file_mode "$key_path")" == 600 ]]
[[ "$(file_mode "$(dirname "$key_path")")" == 700 ]]
cmp "$tmp_dir/fixture" "$key_path"
[[ "$(cat "$GITHUB_ENV")" == "ASC_KEY_PATH=$key_path" ]]
[[ ! -s "$tmp_dir/stdout" && ! -s "$tmp_dir/stderr" ]]
if grep -Fq 'SYNTHETIC-MULTILINE-FIXTURE' "$GITHUB_ENV" "$tmp_dir/stdout" "$tmp_dir/stderr"; then
  echo 'key material reached environment or log output' >&2
  exit 1
fi

# Guard the workflow handoff itself, not only the staging script.
workflow="$repo_root/.github/workflows/ios-ship.yml"
if grep -Eq 'for name in .*ASC_KEY_P8' "$workflow"; then
  echo 'workflow still propagates the multiline key through an environment mask' >&2
  exit 1
fi
if ! grep -Fq 'scripts/ios-stage-asc-key.sh' "$workflow"; then
  echo 'workflow does not use the protected key-file handoff' >&2
  exit 1
fi

# A second handoff cannot overwrite the first key, including through aliases.
bash "$repo_root/scripts/ios-stage-asc-key.sh" < "$tmp_dir/fixture" > "$tmp_dir/stdout" 2> "$tmp_dir/stderr"
second_path="$(tail -n 1 "$GITHUB_ENV" | sed 's/^ASC_KEY_PATH=//')"
[[ "$key_path" != "$second_path" ]]
cmp "$tmp_dir/fixture" "$key_path"
cmp "$tmp_dir/fixture" "$second_path"

# Empty input must not publish a path or leave a partial key directory.
cp "$GITHUB_ENV" "$tmp_dir/before-empty-env"
if bash "$repo_root/scripts/ios-stage-asc-key.sh" < /dev/null > "$tmp_dir/stdout" 2> "$tmp_dir/stderr"; then
  echo 'empty key input was accepted' >&2
  exit 1
fi
cmp "$GITHUB_ENV" "$tmp_dir/before-empty-env"
[[ "$(find "$ASC_STAGING_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" == 2 ]]

# Guard the workflow handoff itself, not only the staging script.
workflow="$repo_root/.github/workflows/ios-ship.yml"
if grep -Eq 'for name in .*ASC_KEY_P8' "$workflow"; then
  echo 'workflow still propagates the multiline key through an environment mask' >&2
  exit 1
fi
if ! grep -Fq 'scripts/stage-asc-key.mjs' "$workflow"; then
  echo 'workflow does not use the protected key-file handoff' >&2
  exit 1
fi
if grep -Eq 'infisical secrets get|infisical/get-cli' "$workflow"; then
  echo 'workflow reads a secret through the bare Infisical CLI' >&2
  exit 1
fi
if grep -Fq '8dae6d03' "$workflow"; then
  echo 'workflow hard-codes the Infisical project id' >&2
  exit 1
fi
# No new code may talk to the vault directly: the values come from the
# approved composite action.
if grep -Eq 'listSecretsRaw|loginUniversalAuth' "$workflow"; then
  echo 'workflow reads the vault directly instead of through the approved action' >&2
  exit 1
fi
# The staging script is what hands the key to the protected handoff.
if ! grep -Fq 'ios-stage-asc-key.sh' "$repo_root/scripts/stage-asc-key.mjs"; then
  echo 'the fetch script does not hand the key to the staging script' >&2
  exit 1
fi

# The end-to-end handoff: a stubbed Infisical, the real fetch script and the
# real staging script.  The key is staged to a mode-600 file, only its path
# is published, and the value never reaches the environment or the log.
node --test "$repo_root/scripts/stage-asc-key.node-test.mjs" > /dev/null

echo 'ios-stage-asc-key: all tests passed'

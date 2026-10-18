#!/usr/bin/env bash
# Offline test for the ASC key handoff in .github/workflows/ios-ship.yml:
# scripts/ios-stage-asc-key.sh itself, then the real "Load ASC credentials"
# run block driven by a fake Infisical CLI.  No Apple or Infisical credential
# is used; every key below is a synthetic fixture.
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

# Exercise the actual workflow run block using a fake Infisical CLI.
python3 - "$workflow" "$tmp_dir/workflow-load.sh" <<'PYTHON'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
section = text.split('      - name: Load ASC credentials (Fleet-OPS prod /asc)\n', 1)[1]
section = section.split('\n      - name:', 1)[0]
run = section.split('        run: |\n', 1)[1]
pathlib.Path(sys.argv[2]).write_text('\n'.join(line[10:] for line in run.splitlines() if line.startswith('          ')) + '\n')
PYTHON
mkdir "$tmp_dir/bin" "$tmp_dir/workspace" "$tmp_dir/workspace/scripts"
ln -s "$repo_root/scripts/ios-stage-asc-key.sh" "$tmp_dir/workspace/scripts/ios-stage-asc-key.sh"
cat > "$tmp_dir/bin/infisical" <<'CLI'
#!/usr/bin/env bash
# Fake CLI.  Records the project and path of every read so the test can prove
# the ASC trio comes from Fleet-OPS /asc and nowhere else.
case "${1:-}" in
  login) printf '%s\n' synthetic-session-token ;;
  secrets)
    printf '%s\n' "$*" >> "$ASC_TEST_CALLS"
    if [[ -n "${ASC_TEST_EMPTY:-}" && "${3:-}" == "$ASC_TEST_EMPTY" ]]; then
      exit 0
    fi
    if [[ "${3:-}" == ASC_KEY_P8 ]]; then
      cat "$ASC_TEST_FIXTURE"
    else
      printf 'synthetic-%s\n' "${3:-value}"
    fi
    ;;
  *) exit 1 ;;
esac
CLI
chmod 700 "$tmp_dir/bin/infisical"
: > "$tmp_dir/workflow-env"
: > "$tmp_dir/calls"
env PATH="$tmp_dir/bin:$PATH" \
  GITHUB_WORKSPACE="$tmp_dir/workspace" GITHUB_ENV="$tmp_dir/workflow-env" \
  ASC_STAGING_ROOT="$tmp_dir/staging" \
  ASC_INFISICAL_PROJECT_ID=synthetic-fleet-project \
  INFISICAL_UNIVERSAL_AUTH_CLIENT_ID=synthetic-client \
  INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET=synthetic-secret \
  INFISICAL_CLIENT_ID= INFISICAL_CLIENT_SECRET= \
  ASC_TEST_FIXTURE="$tmp_dir/fixture" ASC_TEST_CALLS="$tmp_dir/calls" \
  bash "$tmp_dir/workflow-load.sh" > "$tmp_dir/workflow-stdout" 2> "$tmp_dir/workflow-stderr"
if grep -Fq -f "$tmp_dir/fixture" "$tmp_dir/workflow-env" "$tmp_dir/workflow-stdout" "$tmp_dir/workflow-stderr"; then
  echo 'workflow leaked multiline key material' >&2
  exit 1
fi
[[ "$(grep -c '^ASC_KEY_PATH=' "$tmp_dir/workflow-env")" == 1 ]]
grep -q '^ASC_KEY_ID=synthetic-ASC_KEY_ID$' "$tmp_dir/workflow-env"
grep -q '^ASC_ISSUER_ID=synthetic-ASC_ISSUER_ID$' "$tmp_dir/workflow-env"
if grep -q '^ASC_KEY_P8=' "$tmp_dir/workflow-env"; then
  echo 'the private key was exported through the environment' >&2
  exit 1
fi
workflow_key="$(sed -n 's/^ASC_KEY_PATH=//p' "$tmp_dir/workflow-env")"
cmp "$tmp_dir/fixture" "$workflow_key"
[[ "$(file_mode "$workflow_key")" == 600 ]]
[[ ! -s "$tmp_dir/workflow-stderr" ]]
# Exactly three reads, all from the Fleet-OPS project at /asc.
[[ "$(wc -l < "$tmp_dir/calls" | tr -d ' ')" == 3 ]]
if grep -v -e '--projectId=synthetic-fleet-project' "$tmp_dir/calls" | grep -q .; then
  echo 'an ASC value was read from a project other than Fleet-OPS' >&2
  exit 1
fi
if grep -v -e '--path=/asc' "$tmp_dir/calls" | grep -q .; then
  echo 'an ASC value was read from a path other than /asc' >&2
  exit 1
fi

# A missing value must fail the step and name Fleet-OPS /asc, not fall back.
for missing in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8; do
  : > "$tmp_dir/missing-env"
  if env PATH="$tmp_dir/bin:$PATH" \
    GITHUB_WORKSPACE="$tmp_dir/workspace" GITHUB_ENV="$tmp_dir/missing-env" \
    ASC_STAGING_ROOT="$tmp_dir/staging" \
    ASC_INFISICAL_PROJECT_ID=synthetic-fleet-project \
    INFISICAL_UNIVERSAL_AUTH_CLIENT_ID=synthetic-client \
    INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET=synthetic-secret \
    INFISICAL_CLIENT_ID= INFISICAL_CLIENT_SECRET= \
    ASC_TEST_FIXTURE="$tmp_dir/fixture" ASC_TEST_CALLS="$tmp_dir/calls" \
    ASC_TEST_EMPTY="$missing" bash "$tmp_dir/workflow-load.sh" \
    > "$tmp_dir/missing-stdout" 2> "$tmp_dir/missing-stderr"; then
    echo "missing $missing was accepted" >&2
    exit 1
  fi
  grep -q 'Fleet-OPS prod /asc' "$tmp_dir/missing-stdout" "$tmp_dir/missing-stderr"
done

echo 'ios-stage-asc-key: all tests passed'

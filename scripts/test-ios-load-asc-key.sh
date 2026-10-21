#!/usr/bin/env bash
# Offline test for the ASC key handoff in .github/workflows/ios-ship.yml:
# scripts/ios-load-asc-key.sh reads the staged key back into the step's
# environment so the App Store Connect clients receive it as ASC_KEY_P8.
# No Apple credential is used; every key below is a synthetic fixture.
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

# The loader refuses a path it cannot vouch for, and it says why without ever
# printing the value.  Each case is a separate refusal.
refuse() {
  local what="$1" needle="$2"
  if ( export ASC_KEY_PATH="$3"; source "$repo_root/scripts/ios-load-asc-key.sh" ) \
      > "$tmp_dir/out" 2> "$tmp_dir/err"; then
    echo "the loader accepted ${what}" >&2
    exit 1
  fi
  if ! grep -Fq "$needle" "$tmp_dir/err"; then
    echo "the loader refused ${what} without naming the reason" >&2
    cat "$tmp_dir/err" >&2
    exit 1
  fi
  if grep -Fq 'SYNTHETIC-MULTILINE-FIXTURE' "$tmp_dir/out" "$tmp_dir/err"; then
    echo 'key material reached the output of a refused load' >&2
    exit 1
  fi
}

# Stage the key the way the workflow does, so the loader is exercised against
# the file the real handoff produces.
bash "$repo_root/scripts/ios-stage-asc-key.sh" < "$tmp_dir/fixture" > "$tmp_dir/stdout" 2> "$tmp_dir/stderr"
key_path="$(sed -n 's/^ASC_KEY_PATH=//p' "$GITHUB_ENV")"
[[ -f "$key_path" ]]
expected="$(cat "$key_path")"
printf '%s\n' "$expected" > "$tmp_dir/expected"

# The happy path: the loader puts the staged key into the caller's
# environment, where the clients look for it.
(
  export ASC_KEY_PATH="$key_path"
  source "$repo_root/scripts/ios-load-asc-key.sh" > "$tmp_dir/load-stdout" 2> "$tmp_dir/load-stderr"
  [[ "$ASC_KEY_P8" == "$expected" ]]
)
[[ ! -s "$tmp_dir/load-stdout" ]]
[[ ! -s "$tmp_dir/load-stderr" ]]
if grep -Fq 'SYNTHETIC-MULTILINE-FIXTURE' "$tmp_dir/load-stdout" "$tmp_dir/load-stderr"; then
  echo 'key material reached the output of a successful load' >&2
  exit 1
fi

# The value must reach a child process as an environment variable, because
# that is the only way a client accepts a credential.
(
  export ASC_KEY_PATH="$key_path"
  source "$repo_root/scripts/ios-load-asc-key.sh" > /dev/null 2>&1
  node -e 'process.stdout.write((process.env.ASC_KEY_P8 || "") + "\n")' | cmp - "$tmp_dir/expected"
)

# The loader reads the file it was pointed at, so a different file yields a
# different value.  Without this a loader that returned a constant would pass
# every other case.
cp "$key_path" "$tmp_dir/other.p8"
printf 'SYNTHETIC-OTHER\n' > "$tmp_dir/other.p8"
chmod 600 "$tmp_dir/other.p8"
(
  export ASC_KEY_PATH="$tmp_dir/other.p8"
  source "$repo_root/scripts/ios-load-asc-key.sh" > /dev/null 2>&1
  [[ "$ASC_KEY_P8" == "SYNTHETIC-OTHER" ]]
)

# An unset path, a missing file, a file anyone can read and an empty file are
# all refused.
refuse 'an unset path' 'ASC_KEY_PATH is not set' ''
refuse 'a missing file' 'is missing' "$tmp_dir/no-such-file.p8"
cp "$key_path" "$tmp_dir/loose.p8"
chmod 644 "$tmp_dir/loose.p8"
refuse 'a world-readable key file' 'not 600' "$tmp_dir/loose.p8"
: > "$tmp_dir/empty.p8"
chmod 600 "$tmp_dir/empty.p8"
refuse 'an empty key file' 'no key material' "$tmp_dir/empty.p8"

# The loader must not put the key into the job's environment file:  that file
# feeds every later step, and the key belongs to one step at a time.  The
# check is on the write, not on the word, because the loader explains in a
# comment why it does not write there.
if grep -Eq '>> *"?\$\{?GITHUB_ENV' "$repo_root/scripts/ios-load-asc-key.sh"; then
  echo 'the loader writes to the job environment file' >&2
  exit 1
fi

# The workflow hands the credential to every client through the environment,
# and it never calls the removed asc-key.mjs exec subcommand.
workflow="$repo_root/.github/workflows/ios-ship.yml"
if grep -Eq 'asc-key\.mjs exec' "$workflow"; then
  echo 'the workflow calls the removed asc-key.mjs exec subcommand' >&2
  exit 1
fi
load_count="$(grep -c 'source scripts/ios-load-asc-key\.sh' "$workflow" || true)"
if [[ "$load_count" -lt 4 ]]; then
  echo "the workflow sources the loader in only ${load_count} steps; every client step needs it" >&2
  exit 1
fi

echo 'ios-load-asc-key: all tests passed'

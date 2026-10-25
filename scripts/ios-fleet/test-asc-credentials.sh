#!/usr/bin/env bash
# AFC-359: ship-testflight.sh resolves App Store Connect credentials from the
# environment first, then from Infisical through fleet-secrets, and never from
# the old secrets folder.
#
# 2026-10-21 (Kody rule 42 on PR #271): the private key is handed over in the
# environment, never as a path the node client reads.  The shell layer owns the
# credential, so this test drives load_secrets with a FAKE fleet-secrets binary
# and throwaway keys generated here at test time.  No network, no real
# secrets, and no committed key.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/ship-testflight.sh"
tmp="$(mktemp -d)"
# The throwaway HOME lives inside the temp dir, so the cleanup has to run with
# the real HOME in place:  a trash helper that protects the home directory
# refuses to remove a parent of it.
real_home="${HOME}"
trap 'HOME="$real_home" rm -rf "$tmp"' EXIT
export HOME="${tmp}/home"
export TMPDIR="${tmp}/tmp"
mkdir -p "$HOME" "$TMPDIR"

fail() { echo "FAIL: $*" >&2; exit 1; }

# A throwaway key pair, generated here and never committed.  The client parses
# a PEM before it accepts it, so a fake envelope is not a key.
gen_pem() {
  node -e 'process.stdout.write(require("crypto").generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey.export({ type: "pkcs8", format: "pem" }))'
}
gen_pem > "${tmp}/asc.p8"
gen_pem > "${tmp}/other.p8"
chmod 600 "${tmp}/asc.p8" "${tmp}/other.p8"

# Fake fleet-secrets: prints synthetic values, records the folders it was asked for.
cat > "${tmp}/fleet-secrets" <<'FAKE'
#!/usr/bin/env bash
[[ "$1" == get ]] || exit 2
name="$2"; folder="$4"
echo "${name} ${folder}" >> "${FAKE_LOG}"
case "${folder}:${name}" in
  /asc:ASC_KEY_ID) printf 'ABCDE12345\n' ;;
  /asc:ASC_ISSUER_ID) printf 'issuer-synthetic\n' ;;
  /asc:ASC_KEY_P8) cat "${FAKE_ASC_PEM}" ;;
  /authkey-otherkey01-p8:AUTHKEY_OTHERKEY01) cat "${FAKE_OTHER_PEM}" ;;
  *) exit 3 ;;
esac
FAKE
chmod +x "${tmp}/fleet-secrets"
export FAKE_LOG="${tmp}/fake.log"
export FAKE_ASC_PEM="${tmp}/asc.p8"
export FAKE_OTHER_PEM="${tmp}/other.p8"
: > "$FAKE_LOG"

extract() {
  awk '
    /^fs_get\(\) \{/ || /^load_secrets\(\) \{/ || /^cleanup_asc_tmp\(\) \{/ || /^expand_tilde\(\) \{/ || /^rejected_key_file\(\) \{/ || /^init_rejected_key_file\(\) \{/ || /^rejected_key_label\(\) \{/ || /^asc_rejected_key_label\(\) \{/ || /^asc_rejected_key_sources\(\) \{/ { grab = 1 }
    grab { print }
    grab && /^\}/ { grab = 0 }
  ' "$script"
}

# The comparison tool.  It answers through the exit code only, so a
# credential is never expanded into the shell, where a trace would show it.
#
#   same <file>          the value in VALUE_TO_COMPARE equals the file
#   different <file>      the value in VALUE_TO_COMPARE differs from the file
#   samefile <a> <b>     the two files hold the same key
#   differentfile <a> <b> the two files hold different keys
cat > "${tmp}/compare.cjs" <<'CJS'
const fs = require("fs");
const mode = process.argv[2];
const first = process.argv[3];
const second = process.argv[4];
const value = process.env.VALUE_TO_COMPARE || "";
const read = (path) => fs.readFileSync(path, "utf8").trim();
const equal = second ? read(first) === read(second) : value.trim() === read(first);
const wantsDifferent = mode === "different" || mode === "differentfile";
process.exit(wantsDifferent ? (equal ? 1 : 0) : (equal ? 0 : 1));
CJS

funcs="${tmp}/funcs.sh"
{
  echo 'log() { :; }'
  echo 'ASC_TMP_DIR=""'
  echo '_rejected_key_dir=""'
  echo '_rejected_key_path=""'
  echo "FLEET_SECRETS_BIN=\"${tmp}/fleet-secrets\""
  echo "FLEET_DIR=\"${here}\""
  echo "ASC_COMPARE_TOOL=\"${tmp}/compare.cjs\""
  cat <<'FUNCS'
same_as_file() {
  VALUE_TO_COMPARE="$1" node "$ASC_COMPARE_TOOL" same "$2"
}
different_from_file() {
  VALUE_TO_COMPARE="$1" node "$ASC_COMPARE_TOOL" different "$2"
}
same_file_as_file() {
  node "$ASC_COMPARE_TOOL" samefile "$1" "$2"
}
different_file_from_file() {
  node "$ASC_COMPARE_TOOL" differentfile "$1" "$2"
}
FUNCS
  extract
} > "$funcs"
grep -q '^load_secrets()' "$funcs" || fail "load_secrets not found in ship-testflight.sh"
grep -q '^fs_get()' "$funcs" || fail "fs_get not found in ship-testflight.sh"

# 1. Nothing in the environment:  credentials come from Infisical, the key is a 0600 temp file.
out="$(env -u ASC_KEY_ID -u ASC_ISSUER_ID -u ASC_KEY_PATH -u ASC_KEY_P8 bash -c '
  set -euo pipefail
  source "'"$funcs"'"
  load_secrets
  [[ "$AUTH_MODE" == api_key ]]
  [[ "$ASC_KEY_ID" == ABCDE12345 && "$ASC_ISSUER_ID" == issuer-synthetic ]]
  [[ -f "$ASC_KEY_PATH" ]]
  mode="$(stat -c %a "$ASC_KEY_PATH" 2>/dev/null || stat -f %Lp "$ASC_KEY_PATH")"
  [[ "$mode" == 600 ]]
  [[ "$API_PRIVATE_KEYS_DIR" == "$ASC_TMP_DIR" ]]
  # The staged file holds the /asc key, and the client takes the key from the
  # environment.  Neither comparison prints a value.
  same_file_as_file "$ASC_KEY_PATH" "'"$tmp"'/asc.p8"
  same_as_file "$ASC_KEY_P8" "'"$tmp"'/asc.p8"
  echo "$ASC_KEY_PATH"
  cleanup_asc_tmp
  [[ ! -e "$ASC_KEY_PATH" ]]
')" || fail "load_secrets from Infisical"
[[ ! -e "$out" ]] || fail "temp key file survived cleanup"
grep -q '^ASC_KEY_ID /asc$' "$FAKE_LOG" || fail "did not ask Infisical /asc for the key id"
grep -q '^ASC_KEY_P8 /asc$' "$FAKE_LOG" || fail "did not ask Infisical /asc for the key"

# 2. The environment wins over a named key file.  A disk credential never
# overrides the environment (Kody rule 42 on PR #271):  a stale or foreign
# value in an operator's shell would sign the upload with the wrong key.
: > "$FAKE_LOG"
cp "${tmp}/asc.p8" "${tmp}/named-key.p8"
chmod 600 "${tmp}/named-key.p8"
ASC_KEY_ID=ENVKEY0001 ASC_ISSUER_ID=env-issuer \
  ASC_KEY_P8="$(<"${tmp}/other.p8")" ASC_KEY_PATH="${tmp}/named-key.p8" bash -c '
  set -euo pipefail
  source "'"$funcs"'"
  load_secrets
  [[ "$AUTH_MODE" == api_key && "$ASC_KEY_ID" == ENVKEY0001 ]]
  # The environment key is the credential in play, and the named file is not.
  same_as_file "$ASC_KEY_P8" "'"$tmp"'/other.p8"
  different_from_file "$ASC_KEY_P8" "'"$tmp"'/named-key.p8"
' || fail "a named key file overrode the environment"
[[ ! -s "$FAKE_LOG" ]] || fail "fleet-secrets was called although the environment was complete"

# 2a. A named ASC_KEY_PATH is not a credential source at all:  it is ignored,
# and the credential comes from Infisical.  A file somebody names can never
# decide which key signs the upload (Kody rule 42 on PR #271).
: > "$FAKE_LOG"
cp "${tmp}/other.p8" "${tmp}/named-file.p8"
chmod 600 "${tmp}/named-file.p8"
env -u ASC_KEY_P8 ASC_KEY_ID=ABCDE12345 ASC_ISSUER_ID=issuer-synthetic ASC_KEY_PATH="${tmp}/named-file.p8" bash -c '
  set -euo pipefail
  source "'"$funcs"'"
  load_secrets
  [[ "$AUTH_MODE" == api_key && "$ASC_KEY_ID" == ABCDE12345 ]]
  # The credential is the /asc one from Infisical, never the named file.
  same_as_file "$ASC_KEY_P8" "'"$tmp"'/asc.p8"
  different_from_file "$ASC_KEY_P8" "'"$tmp"'/named-file.p8"
  cleanup_asc_tmp
' || fail "a named key file was used as the credential"
grep -q '^ASC_KEY_P8 /asc$' "$FAKE_LOG" || fail "fleet-secrets was not consulted for the credential"

# The scanner that finds a command substitution which runs the key reader.
#
# It walks the file and matches the closing parenthesis of every
# substitution, so a capture is found whatever shape it has:  with or without
# a `||` after it, written on one line or across several, and with a nested
# substitution inside it.  The scan is exact, so the script as it stands is
# not flagged by a shape it does not have.
cat > "${tmp}/find-key-capture.cjs" <<'SCAN'
const fs = require("fs");
const text = fs.readFileSync(process.argv[2], "utf8");
const offenders = [];
const lineOf = (index) => text.slice(0, index).split("\n").length;
let depth = 0;
let start = 0;
let quote = null;
for (let i = 0; i < text.length; i += 1) {
  const c = text[i];
  if (quote === "'") {
    //  Single quotes are literal in bash, so nothing inside them is a
    //  substitution.
    if (c === quote) quote = null;
    continue;
  }
  if (c === "\\") { i += 1; continue; }
  if (c === "`") {
    const end = text.indexOf("`", i + 1);
    if (end === -1) break;
    if (text.slice(i, end + 1).includes("asc-key.mjs")) offenders.push(lineOf(i));
    i = end;
    continue;
  }
  if (quote === "\"") {
    if (c === quote) { quote = null; continue; }
    if (c === "$" && text[i + 1] === "{") { const end = text.indexOf("}", i); if (end !== -1) { i = end; continue; } }
    if (c === "$" && text[i + 1] === "(") { depth += 1; if (depth === 1) start = i; i += 1; continue; }
    if (c === ")" && depth > 0) {
      depth -= 1;
      if (depth === 0 && text.slice(start, i + 1).includes("asc-key.mjs")) offenders.push(lineOf(start));
    }
    continue;
  }
  if (c === "$" && text[i + 1] === "{") { const end = text.indexOf("}", i); if (end !== -1) { i = end; continue; } }
  if (c === "#") {
    //  A comment runs to the end of the line, and an apostrophe in it is an
    //  apostrophe, not the start of a quoted string.
    const end = text.indexOf("\n", i);
    i = end === -1 ? text.length : end;
    continue;
  }
  if (c === "\"" || c === "'") { quote = c; continue; }
  if (c === "$" && text[i + 1] === "(") { depth += 1; if (depth === 1) start = i; i += 1; continue; }
  if (c === ")" && depth > 0) {
    depth -= 1;
    if (depth === 0 && text.slice(start, i + 1).includes("asc-key.mjs")) offenders.push(lineOf(start));
  }
}
if (offenders.length) {
  console.error("the key reader is captured into a variable at line(s) " + offenders.join(", "));
  process.exit(1);
}
SCAN

# 2b. A staged key file is never read into a variable:  the shell that owns it
# only ever holds its path.
if ! node "${tmp}/find-key-capture.cjs" "$script"; then
  fail "ship-testflight.sh reads the key material into a variable"
fi

# 2b. The guard has teeth:  a capture in every shape is caught, and the ship
# script as it stands is not flagged.
for shape in plain plain-with-or split-across-lines nested; do
  cp "$script" "${tmp}/mutated.sh"
  case "$shape" in
    plain)
      printf '%s\n' 'key="$(node "${FLEET_DIR}/asc-key.mjs" read "$ASC_KEY_PATH")"' >> "${tmp}/mutated.sh" ;;
    plain-with-or)
      printf '%s\n' 'key="$(node "${FLEET_DIR}/asc-key.mjs" read "$ASC_KEY_PATH")" || rc=$?' >> "${tmp}/mutated.sh" ;;
    split-across-lines)
      printf '%s\n%s\n' 'key="$(node "${FLEET_DIR}/asc-key.mjs" \' '  read "$ASC_KEY_PATH")"' >> "${tmp}/mutated.sh" ;;
    nested)
      printf '%s\n' 'key="$(cd "$(dirname "$0")"; node "${FLEET_DIR}/asc-key.mjs" read "$ASC_KEY_PATH")"' >> "${tmp}/mutated.sh" ;;
  esac
  if node "${tmp}/find-key-capture.cjs" "${tmp}/mutated.sh" >/dev/null 2>&1; then
    fail "the capture guard did not catch a ${shape} capture"
  fi
done

# 2b. An ambient ASC_KEY_P8 that is not a PEM private key is ignored, and the
# run fails closed rather than signing with something that is not a key.
: > "$FAKE_LOG"
ASC_KEY_ID=NOSUCHKEY0 ASC_ISSUER_ID=any-issuer ASC_KEY_P8="not a private key at all" bash -c '
  set -euo pipefail
  source "'"$funcs"'"
  load_secrets
  [[ "$AUTH_MODE" == none && -z "$ASC_TMP_DIR" ]]
  [[ -z "${ASC_KEY_P8:-}" ]]
' || fail "an ASC_KEY_P8 that is not a key was adopted"

# 2c. An ambient ASC_KEY_P8 without a key id is ignored:  the key id, the
# issuer and the key belong together.
: > "$FAKE_LOG"
ASC_KEY_ID="" ASC_ISSUER_ID="" ASC_KEY_P8="$(<"${tmp}/other.p8")" bash -c '
  set -euo pipefail
  source "'"$funcs"'"
  load_secrets
  [[ "$AUTH_MODE" == api_key && "$ASC_KEY_ID" == ABCDE12345 ]]
  same_as_file "$ASC_KEY_P8" "'"$tmp"'/asc.p8"
' || fail "an ASC_KEY_P8 without a key id was adopted"

# 2d. An env key id that is NOT the /asc one never gets the /asc key:  its own .p8 comes from
# /authkey-<id>-p8, and /asc ASC_KEY_P8 is not requested.
: > "$FAKE_LOG"
env -u ASC_KEY_PATH -u ASC_KEY_P8 ASC_KEY_ID=OTHERKEY01 ASC_ISSUER_ID=issuer-other bash -c '
  set -euo pipefail
  source "'"$funcs"'"
  load_secrets
  [[ "$AUTH_MODE" == api_key && "$ASC_KEY_ID" == OTHERKEY01 ]]
  [[ "$ASC_ISSUER_ID" == issuer-other ]]
  same_file_as_file "$ASC_KEY_PATH" "'"$tmp"'/other.p8"
  different_file_from_file "$ASC_KEY_PATH" "'"$tmp"'/asc.p8"
  cleanup_asc_tmp
' || fail "env key id different from /asc was not given its own key"
grep -q '^AUTHKEY_OTHERKEY01 /authkey-otherkey01-p8$' "$FAKE_LOG" || fail "did not ask the per-key folder"
if grep -q '^ASC_KEY_P8 ' "$FAKE_LOG"; then fail "mixed an env key id with the /asc key"; fi

# 2e. An env key id that is not the /asc one with NO env issuer fails closed:  the /asc issuer
# is never paired with another key's .p8.
: > "$FAKE_LOG"
env -u ASC_KEY_PATH -u ASC_ISSUER_ID -u ASC_KEY_P8 ASC_KEY_ID=OTHERKEY01 bash -c '
  set -euo pipefail
  source "'"$funcs"'"
  load_secrets
  [[ "$AUTH_MODE" == none && -z "$ASC_TMP_DIR" ]]
' || fail "mixed the /asc issuer with another key"
if grep -q '^ASC_ISSUER_ID ' "$FAKE_LOG"; then fail "asked /asc for an issuer for a different key id"; fi

# 2f. An env key id equal to the /asc one uses the /asc key.
: > "$FAKE_LOG"
env -u ASC_KEY_PATH -u ASC_ISSUER_ID -u ASC_KEY_P8 ASC_KEY_ID=ABCDE12345 bash -c '
  set -euo pipefail
  source "'"$funcs"'"
  load_secrets
  [[ "$AUTH_MODE" == api_key && "$ASC_KEY_ID" == ABCDE12345 ]]
  same_file_as_file "$ASC_KEY_PATH" "'"$tmp"'/asc.p8"
  cleanup_asc_tmp
' || fail "env key id equal to /asc was not served from /asc"
grep -q '^ASC_KEY_P8 /asc$' "$FAKE_LOG" || fail "did not ask /asc ASC_KEY_P8"

# 2g. An env key id with no key material anywhere fails closed (no api_key mode).
: > "$FAKE_LOG"
env -u ASC_KEY_PATH -u ASC_KEY_P8 ASC_KEY_ID=NOSUCHKEY0 ASC_ISSUER_ID=any-issuer bash -c '
  set -euo pipefail
  source "'"$funcs"'"
  load_secrets
  [[ "$AUTH_MODE" == none && -z "$ASC_TMP_DIR" ]]
' || fail "missing key material did not fail closed"

# 2h. A named ASC_KEY_PATH that names nothing is ignored the same way:  the
# credential comes from Infisical, and the named path is never read.
: > "$FAKE_LOG"
env -u ASC_KEY_P8 ASC_KEY_ID=ABCDE12345 ASC_ISSUER_ID=issuer-synthetic ASC_KEY_PATH="${tmp}/no-such-key.p8" bash -c '
  set -euo pipefail
  source "'"$funcs"'"
  load_secrets
  [[ "$AUTH_MODE" == api_key && "$ASC_KEY_ID" == ABCDE12345 ]]
  same_as_file "$ASC_KEY_P8" "'"$tmp"'/asc.p8"
  cleanup_asc_tmp
' || fail "a named key file that names nothing broke the run"
grep -q '^ASC_KEY_P8 /asc$' "$FAKE_LOG" || fail "fleet-secrets was not consulted for the credential"

# 2i. Only a leading "~/" is expanded:  "~user/x" must not be merged with $HOME.
env -u ASC_KEY_P8 ASC_KEY_ID=TILDE00001 ASC_ISSUER_ID=tilde-issuer bash -c '
  set -euo pipefail
  source "'"$funcs"'"
  [[ "$(expand_tilde "~/k.p8")" == "$HOME/k.p8" ]]
  [[ "$(expand_tilde "~other/k.p8")" == "~other/k.p8" ]]
  [[ "$(expand_tilde "/abs/k.p8")" == "/abs/k.p8" ]]
' || fail "expand_tilde"

# 3. The credential never travels in a command argument.  The secret reaches
# the child through the environment, so its own argv must not carry it.
argv="$(ASC_KEY_ID=ENVKEY0005 ASC_ISSUER_ID=env-issuer ASC_KEY_P8="$(<"${tmp}/other.p8")" bash -c '
  set -euo pipefail
  ps -o args= -p $$ 2>/dev/null || true
')"
pem="$(<"${tmp}/other.p8")"
[[ "$argv" != *"$pem"* ]] || fail "the credential reached the child in its command arguments"

# 4. Neither this test nor the ship script passes a credential to `env`, which
# would put it in the process arguments of every child.
for f in "$0" "$script"; do
  if grep -nE '(^|[[:space:]])env [^|]*ASC_KEY_P8=' "$f" >/dev/null; then
    fail "$(basename "$f") passes a credential through env arguments"
  fi
done

# 5. Nothing is created under the old secrets folder or ~/.appstoreconnect.
[[ ! -e "${HOME}/.secrets" ]] || fail "created the old secrets folder"
[[ ! -e "${HOME}/.appstoreconnect" ]] || fail "created ~/.appstoreconnect"

# 6. The script text itself no longer names the old folder as a source.
if grep -nE '(~|\$\{?HOME\}?)/\.secrets' "$script" >/dev/null; then
  fail "ship-testflight.sh still names the old secrets folder"
fi

# 7. A rejected credential is named only by nonsecret labels:  the key id
# and the source the client resolved it from.  Nothing derived from the
# private key is read out of the client's diagnostic, so even a line that
# carries a key fragment (an older client's "key in play" preview, here
# made of synthetic text) leaves no trace in the label, the hand-off file or
# the parent's fatal text.
synthetic_head="SYNTHHEAD"
synthetic_tail="TAIL"
cat > "${tmp}/client-err.txt" <<ERR
asc-auth: using ASC_KEY_P8 environment (key id length 15)
latest-marketing-patch: App Store Connect rejected the API key (HTTP 401; key id SYNTHETICKEYID1, key source ASC_KEY_P8 environment)
latest-build-seq: App Store Connect rejected the API key (HTTP 401; key id SYNTHETICKEYID1, key in play ${synthetic_head}…${synthetic_tail})
ERR
: > "${tmp}/client-err-empty.txt"
label="$(bash -c '
  set -euo pipefail
  source "'"$funcs"'"
  mkdir -p "'"${tmp}"'/td1"; TMPDIR="'"${tmp}"'/td1" init_rejected_key_file
  asc_rejected_key_label "'"$tmp"'/client-err.txt"
' 2>"${tmp}/label-stderr.txt")" || fail "asc_rejected_key_label"
[[ "$label" == "key id SYNTHETICKEYID1, source ASC_KEY_P8 environment" ]] || fail "the key id and source were not read from the client diagnostic: ${label}"
for out in "$label" "$(cat "${tmp}/label-stderr.txt")" "$(cat "${tmp}"/td1/ios-fleet-rejected-key.*/label)"; do
  [[ "$out" != *"$synthetic_head"* && "$out" != *"$synthetic_tail"* && "$out" != *"key in play"* ]] || fail "a key-body fragment survived into the label, stderr or the hand-off file: ${out}"
done
empty_label="$(bash -c '
  set -euo pipefail
  source "'"$funcs"'"
  mkdir -p "'"${tmp}"'/td2"; TMPDIR="'"${tmp}"'/td2" init_rejected_key_file
  asc_rejected_key_label "'"$tmp"'/client-err-empty.txt"
')" || fail "asc_rejected_key_label on an empty diagnostic"
[[ -n "$empty_label" ]] || fail "an empty diagnostic produced no text at all"
missing_label="$(bash -c '
  set -euo pipefail
  source "'"$funcs"'"
  mkdir -p "'"${tmp}"'/td3"; TMPDIR="'"${tmp}"'/td3" init_rejected_key_file
  asc_rejected_key_label
')" || fail "asc_rejected_key_label without a file"
[[ -n "$missing_label" ]] || fail "a missing diagnostic file produced no text at all"
# A line with only a key fragment and no key id yields no label from it.
printf '%s\n' "latest-marketing-patch: App Store Connect rejected the API key (HTTP 401; key in play ${synthetic_head}…${synthetic_tail})" > "${tmp}/client-err-legacy.txt"
legacy_label="$(bash -c '
  set -euo pipefail
  source "'"$funcs"'"
  mkdir -p "'"${tmp}"'/td4"; TMPDIR="'"${tmp}"'/td4" init_rejected_key_file
  asc_rejected_key_label "'"$tmp"'/client-err-legacy.txt"
')" || fail "asc_rejected_key_label on a legacy diagnostic"
[[ "$legacy_label" != *"$synthetic_head"* && "$legacy_label" != *"$synthetic_tail"* ]] || fail "a legacy key fragment reached the label: ${legacy_label}"
# The raw key must never appear in what the shell prints.
pem_material="$(sed -e 's/-----[^-]*-----//g' "${tmp}/asc.p8" | tr -d '[:space:]')"
[[ "$label" != *"${pem_material:0:8}"* ]] || fail "the label carries key material"
# The ship script no longer prints or transports a preview of the key.
if grep -nE 'key in play|rejected_key_preview' "$script" >/dev/null; then
  fail "ship-testflight.sh still handles a key preview"
fi

# 8. The label has to survive the command substitution the ship script
# uses.  Both helpers that can meet a rejection are only ever called
# through "$(...)", so they run in a subshell and a global they assign
# never reaches the parent -- the fatal message would name no key at all.
# The label therefore travels through a file, and the parent reads it back
# for its fatal text, which must carry the key id and source and no key
# fragment.
parent_fatal="$(bash -c '
  set -euo pipefail
  source "'"$funcs"'"
  mkdir -p "'"${tmp}"'/td5"; TMPDIR="'"${tmp}"'/td5" init_rejected_key_file
  _p="$(asc_rejected_key_label "'"$tmp"'/client-err.txt")"
  [[ "$_p" == "key id SYNTHETICKEYID1, source ASC_KEY_P8 environment" ]] || exit 1
  printf "App Store Connect rejected the API key (HTTP 401/403; rejected key %s) while reading the next marketing version." "$(rejected_key_label)"
')" || fail "the label inside a command substitution"
[[ "$parent_fatal" == *"rejected key key id SYNTHETICKEYID1, source ASC_KEY_P8 environment)"* ]] || fail "the label did not leave the command substitution: ${parent_fatal}"
[[ "$parent_fatal" != *"$synthetic_head"* && "$parent_fatal" != *"$synthetic_tail"* ]] || fail "a key-body fragment reached the parent fatal text: ${parent_fatal}"
hand_off_dir="$(ls -d "${tmp}"/td5/ios-fleet-rejected-key.*)"
[[ "$(stat -c %a "$hand_off_dir" 2>/dev/null || stat -f %Lp "$hand_off_dir")" == "700" ]] || fail "the hand-off directory is not private"
hand_off="$(cat "${hand_off_dir}/label")"
[[ "$hand_off" != *"$synthetic_head"* && "$hand_off" != *"$synthetic_tail"* ]] || fail "a key-body fragment reached the hand-off file: ${hand_off}"
# With no rejection there is no label, and the parent says so.
unknown_label="$(bash -c '
  set -euo pipefail
  source "'"$funcs"'"
  mkdir -p "'"${tmp}"'/td6"; TMPDIR="'"${tmp}"'/td6" init_rejected_key_file
  rejected_key_label
')" || fail "rejected_key_label without a label"
[[ "$unknown_label" == "unknown" ]] || fail "a missing label should read unknown: ${unknown_label}"

# 9. The hand-off path belongs to this run alone.  A stale or hostile
# environment cannot choose what is written, read or removed, a symlink
# planted at the old predictable name is never followed, and cleanup
# removes only the private directory this run created.
mkdir -p "${tmp}/td9"
printf 'SENTINEL-ENV\n' > "${tmp}/sentinel-env"
printf 'SENTINEL-LINK\n' > "${tmp}/sentinel-link"
printf 'SENTINEL-DIR\n' > "${tmp}/sentinel-dir"
env_out="$(REJECTED_KEY_FILE="${tmp}/sentinel-env" _rejected_key_path="${tmp}/sentinel-env" _rejected_key_dir="${tmp}/sentinel-dir" TMPDIR="${tmp}/td9" bash -c '
  set -euo pipefail
  source "'"$funcs"'"
  ln -s "'"$tmp"'/sentinel-link" "${TMPDIR}/ios-fleet-rejected-key.$$"
  init_rejected_key_file
  _p="$(asc_rejected_key_label "'"$tmp"'/client-err.txt")"
  printf "%s|%s\n" "$_p" "$(rejected_key_label)"
  own="$_rejected_key_dir"
  cleanup_asc_tmp
  [[ ! -e "$own" ]] || { echo "own dir survived cleanup"; exit 1; }
')" || fail "the run-owned hand-off path: ${env_out}"
[[ "$env_out" == "key id SYNTHETICKEYID1, source ASC_KEY_P8 environment|key id SYNTHETICKEYID1, source ASC_KEY_P8 environment" ]] || fail "the label did not round-trip through the run-owned file: ${env_out}"
[[ "$(cat "${tmp}/sentinel-env")" == "SENTINEL-ENV" ]] || fail "an environment-selected file was overwritten"
[[ "$(cat "${tmp}/sentinel-link")" == "SENTINEL-LINK" ]] || fail "a symlink at the predictable name was followed"
[[ -f "${tmp}/sentinel-dir" && "$(cat "${tmp}/sentinel-dir")" == "SENTINEL-DIR" ]] || fail "cleanup removed an environment-selected path"
# Cleanup that never created a directory removes nothing, whatever the environment says.
_rejected_key_dir="${tmp}/sentinel-dir" bash -c '
  source "'"$funcs"'"
  _rejected_key_dir=""
  cleanup_asc_tmp
'
[[ -f "${tmp}/sentinel-dir" ]] || fail "cleanup without a run-owned directory deleted a file"
# The ship script itself takes no hand-off path from the environment.
if grep -nE 'REJECTED_KEY_FILE|ios-fleet-rejected-key\.\$\$' "$script" >/dev/null; then
  fail "ship-testflight.sh still derives the hand-off path from the environment or a predictable name"
fi

# 10. The REAL client diagnostic, read by the shell parser.
#
# The parser has to understand the label the client actually prints, not a
# hand-written copy of it:  a copy can drift away from the client, and then
# a real rejection is named wrongly -- or not named at all.  So the client
# itself is run against a local server that answers 401, with a synthetic
# key, and its own stderr is what the parser reads.
cat > "${tmp}/real-401.mjs" <<'CJS'
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const [script, outDir, pemPath] = process.argv.slice(2);
const pem = readFileSync(pemPath, "utf8");

// A server that refuses every request, the way App Store Connect refuses a
// key it will not accept.
const server = createServer((req, res) => {
  res.writeHead(401, { "Content-Type": "text/plain" });
  res.end("unauthorized");
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const base = `http://127.0.0.1:${server.address().port}`;

function run(env) {
  return new Promise((resolve) => {
    const child = spawn("node", [script, "latest-build-seq", "com.example.nothing", "1.0"], {
      env: {
        PATH: process.env.PATH,
        HOME: process.env.HOME,
        ASC_API_BASE: base,
        // Every other credential source is cleared, so the scenario below is
        // the one that decides which credential the client uses.
        ASC_KEY_ID: "",
        ASC_ISSUER_ID: "",
        ASC_KEY_P8: "",
        ASC_KEY_PATH: "",
        APPLE_API_KEY_ID: "",
        APPLE_API_ISSUER_ID: "",
        APPLE_API_KEY_P8_BASE64: "",
        FLEET_SECRETS_BIN: "/nonexistent/fleet-secrets",
        FLEET_SECRETS: "/nonexistent/fleet-secrets",
        ...env
      },
      stdio: ["ignore", "pipe", "pipe"]
    });
    let stderr = "";
    child.stderr.on("data", (d) => { stderr += d; });
    child.on("close", () => resolve(stderr));
  });
}

const scenarios = {
  // A key id and a source the client can name.
  "asc-env": {
    ASC_KEY_ID: "SYNTHETICKEYID1",
    ASC_ISSUER_ID: "synthetic-issuer",
    ASC_KEY_P8: pem
  },
  // The other environment source.
  "apple-env": {
    APPLE_API_KEY_ID: "SYNTHETICKEYID2",
    APPLE_API_ISSUER_ID: "synthetic-issuer-2",
    APPLE_API_KEY_P8_BASE64: Buffer.from(pem).toString("base64")
  },
  // A key id that is not shaped like a key id:  the client says the id was
  // unrecognized, and the source is still known.
  "unrecognized-id": {
    ASC_KEY_ID: "not a key id",
    ASC_ISSUER_ID: "synthetic-issuer",
    ASC_KEY_P8: pem
  }
};

for (const [name, env] of Object.entries(scenarios)) {
  writeFileSync(join(outDir, `${name}.err`), await run(env));
}
server.close();
CJS
node "${tmp}/real-401.mjs" "${here}/asc-api.mjs" "${tmp}" "${tmp}/asc.p8" || fail "the mock 401 run"

# The label the client printed, in the client's own words:  the assertions
# below are about the shell reading THAT, not about a copy of it.
grep -q 'key id SYNTHETICKEYID1, key source ASC_KEY_P8 environment' "${tmp}/asc-env.err" \
  || fail "the client did not print the expected label: $(cat "${tmp}/asc-env.err")"
grep -q 'key id SYNTHETICKEYID2, key source APPLE_API_\* environment (base64 p8)' "${tmp}/apple-env.err" \
  || fail "the client did not name the APPLE_API_* source: $(cat "${tmp}/apple-env.err")"
grep -q 'key id (unrecognized), key source ASC_KEY_P8 environment' "${tmp}/unrecognized-id.err" \
  || fail "the client did not report the id as unrecognized: $(cat "${tmp}/unrecognized-id.err")"

# The shell parser, fed the real diagnostic.
parse_label() {
  local errf="$1" td="$2"
  bash -c '
    set -euo pipefail
    source "'"$funcs"'"
    mkdir -p "'"$td"'"; TMPDIR="'"$td"'" init_rejected_key_file
    asc_rejected_key_label "'"$errf"'"
  '
}
mkdir -p "${tmp}/td10"
real_label="$(parse_label "${tmp}/asc-env.err" "${tmp}/td10")" || fail "the parser on the real client diagnostic"
[[ "$real_label" == "key id SYNTHETICKEYID1, source ASC_KEY_P8 environment" ]] \
  || fail "the real client diagnostic lost the key id or the source: ${real_label}"
apple_label="$(parse_label "${tmp}/apple-env.err" "${tmp}/td10")" || fail "the parser on the APPLE_API_* diagnostic"
[[ "$apple_label" == "key id SYNTHETICKEYID2, source APPLE_API_* environment (base64 p8)" ]] \
  || fail "the real client diagnostic lost the APPLE_API_* source: ${apple_label}"
# The case the review found:  the client named the source but not a usable
# id, and the label has to say so AND name the source.  Dropping the source
# would send the operator after the wrong credential.
unrecognized_label="$(parse_label "${tmp}/unrecognized-id.err" "${tmp}/td10")" || fail "the parser on the unrecognized-id diagnostic"
[[ "$unrecognized_label" == "key id (unrecognized), source ASC_KEY_P8 environment" ]] \
  || fail "an unrecognized key id dropped the known source: ${unrecognized_label}"
# The word "unknown" is only for the case where the client named neither.
[[ "$unrecognized_label" != *"unknown"* ]] || fail "the label said unknown although the source was known: ${unrecognized_label}"

# 11. ONE accepted source list.  The parser takes a source only when it is
# on that list, so the list has to hold every source the client can emit:  a
# real rejection whose source is missing from it would be named as if the
# client had said nothing at all.
cat > "${tmp}/list-sources.mjs" <<CJS
import { REJECTED_KEY_SOURCES } from "file://${here}/asc-api.mjs";
for (const source of REJECTED_KEY_SOURCES) console.log(source);
CJS
client_sources="$(node "${tmp}/list-sources.mjs")" || fail "the client's source list"
shell_sources="$(bash -c 'set -euo pipefail; source "'"$funcs"'"; asc_rejected_key_sources')" || fail "the shell's source list"
[[ -n "$client_sources" && -n "$shell_sources" ]] || fail "a source list is empty"
while IFS= read -r src; do
  [[ -n "$src" ]] || continue
  printf '%s\n' "$shell_sources" | grep -Fxq "$src" \
    || fail "the client can name the source '${src}' and the shell does not accept it"
done <<< "$client_sources"
while IFS= read -r src; do
  [[ -n "$src" ]] || continue
  printf '%s\n' "$client_sources" | grep -Fxq "$src" \
    || fail "the shell accepts the source '${src}' and the client cannot emit it"
done <<< "$shell_sources"

# 12. Loading the ship script creates the run-owned hand-off path.  The init
# runs when the script is loaded, so every run has a private place to put
# the label before any subshell exists, and a refusal is never written
# somewhere a stale value could pick.
#
# The prelude is cut from the top of the ship script down to the load-time
# init call.  The cut is checked before anything is sourced, and the checks
# keep this order:  it must stop strictly before the end of the file, its
# last line must be the init call, the function definition must be in it on
# its own line, and every column-0 line before that last one must be a
# top-level shape the shell can carry into the prelude.  A missing or
# reformatted call marker fails here, and so does a ship-body command the
# cut swallowed, so the ship body is never sourced.
extract_ship_prelude() {
  local src="$1" dest="$2" total kept offender
  sed -n '1,/^init_rejected_key_file ||/p' "$src" > "$dest"
  total="$(wc -l < "$src")"
  kept="$(wc -l < "$dest")"
  (( kept < total )) || { echo "the prelude cut did not stop before the end of the ship script"; return 1; }
  tail -n 1 "$dest" | grep -q '^init_rejected_key_file || ' \
    || { echo "the prelude cut did not stop at the load-time hand-off init call"; return 1; }
  grep -q '^init_rejected_key_file() {$' "$dest" \
    || { echo "the hand-off init function definition is not in the prelude"; return 1; }
  # The positional guard.  A line that starts with whitespace is a function
  # body and is ignored.  A line at column 0 has to be a shape that belongs
  # to the prelude itself:  a comment, a blank line, set -euo pipefail, an
  # allowlisted assignment, a function opener, a lone closing brace, or a
  # trap.  Any other command at column 0 is ship-body code the cut took
  # with it, and the prelude would run it when it is sourced.
  #
  # An assignment is accepted only when it is one the real prelude makes:
  # export PATH=, and a plain assignment to ASC_NODE, FLEET_DIR, APPS_JSON,
  # TEAM_ID, FLEET_SECRETS_BIN, ASC_TMP_DIR, _rejected_key_dir or
  # _rejected_key_path.  A name that is not on that list is refused even
  # when it only assigns a value, so no column-0 name= prefix can smuggle
  # a command into the prelude.
  #
  # An allowlisted name is still refused when its value chains a command
  # after it, and two rules refuse that between them.  A quoted value must
  # be the whole remainder of the line:  nothing may follow its closing
  # quote, so a line like TEAM_ID="x" && rm -rf ... is refused.  An
  # unquoted value must be a single word, with no whitespace, ;, & or | in
  # it, so a line like TEAM_ID=x&&rm -rf ... is refused as well.  The &&
  # inside FLEET_DIR="$(cd "$(dirname "$0")" && pwd)" is inside the quoted
  # value, so that line stays one assignment and is accepted.
  offender="$(awk '
    BEGIN {
      SQ = sprintf("%c", 39)
      # The names the real prelude sets at column 0, and nothing else.
      allowed["ASC_NODE"] = 1
      allowed["FLEET_DIR"] = 1
      allowed["APPS_JSON"] = 1
      allowed["TEAM_ID"] = 1
      allowed["FLEET_SECRETS_BIN"] = 1
      allowed["ASC_TMP_DIR"] = 1
      allowed["_rejected_key_dir"] = 1
      allowed["_rejected_key_path"] = 1
    }
    { lines[NR] = $0 }
    END {
      for (i = 1; i < NR; i++) {
        l = lines[i]
        if (l ~ /^[[:space:]]*$/) continue
        if (l ~ /^[[:space:]]/) continue
        if (l ~ /^#/) continue
        if (l == "set -euo pipefail") continue
        if (assignment_ok(l)) continue
        if (l ~ /^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*[{][[:space:]]*$/) continue
        if (l ~ /^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*[{].*[}]$/) continue
        if (l ~ /^[}][[:space:]]*$/) continue
        if (l ~ /^trap[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+EXIT[[:space:]]*$/) continue
        print i ": " l
        exit
      }
    }
    # Strip the quoted text and the command substitutions from a line and
    # return what is left.  The shell reads no chain inside a quoted string
    # and no chain inside a ( ) substitution, so those parts are dropped:
    # the && in FLEET_DIR="$(cd "$(dirname "$0")" && pwd)" is part of the
    # value, and that line stays a single assignment.
    function strip_literal(s,   out, i, c, len, st, top) {
      out = ""
      st = ""
      len = length(s)
      i = 1
      while (i <= len) {
        c = substr(s, i, 1)
        top = (st == "") ? "" : substr(st, length(st), 1)
        if (top == "s") {
          if (c == SQ) st = substr(st, 1, length(st) - 1)
          i++
          continue
        }
        if (top == "d") {
          if (c == "\"") { st = substr(st, 1, length(st) - 1); i++; continue }
          if (c == "$" && substr(s, i + 1, 1) == "(") { st = st "("; i += 2; continue }
          i++
          continue
        }
        if (top == "(") {
          if (c == "\"") { st = st "d"; i++; continue }
          if (c == SQ) { st = st "s"; i++; continue }
          if (c == "$" && substr(s, i + 1, 1) == "(") { st = st "("; i += 2; continue }
          if (c == ")") { st = substr(st, 1, length(st) - 1); i++; continue }
          i++
          continue
        }
        if (c == "\"") { st = st "d"; i++; continue }
        if (c == SQ) { st = st "s"; i++; continue }
        if (c == "$" && substr(s, i + 1, 1) == "(") { st = st "("; i += 2; continue }
        out = out c
        i++
      }
      return out
    }
    # The position of the closing quote of the quoted value that starts a
    # line, or 0 when that value is not closed.  A command substitution
    # inside the value is parsed in its own context, so the quotes inside
    # it do not close the value.
    function quoted_value_end(v,   i, c, len, st, top) {
      len = length(v)
      st = ""
      c = substr(v, 1, 1)
      if (c == "\"") st = "d"
      else if (c == SQ) st = "s"
      else return 0
      i = 2
      while (i <= len) {
        c = substr(v, i, 1)
        top = substr(st, length(st), 1)
        if (top == "s") {
          if (c == SQ) { st = substr(st, 1, length(st) - 1); if (st == "") return i }
          i++
          continue
        }
        if (top == "d") {
          if (c == "\"") { st = substr(st, 1, length(st) - 1); if (st == "") return i; i++; continue }
          if (c == "$" && substr(v, i + 1, 1) == "(") { st = st "("; i += 2; continue }
          i++
          continue
        }
        if (c == "\"") { st = st "d"; i++; continue }
        if (c == SQ) { st = st "s"; i++; continue }
        if (c == "$" && substr(v, i + 1, 1) == "(") { st = st "("; i += 2; continue }
        if (c == ")") { st = substr(st, 1, length(st) - 1); if (st == "") return i; i++; continue }
        i++
      }
      return 0
    }
    # An assignment is accepted only when it is one the real prelude makes,
    # and only when the value does not chain a command after it.
    function assignment_ok(l,   name, value, first, stripped, rest, qend) {
      if (match(l, /^export[[:space:]]+PATH=/)) {
        value = substr(l, RSTART + RLENGTH)
      } else if (match(l, /^[A-Za-z_][A-Za-z0-9_]*=/)) {
        name = substr(l, 1, RLENGTH - 1)
        if (!(name in allowed)) return 0
        value = substr(l, RLENGTH + 1)
      } else {
        return 0
      }
      first = substr(value, 1, 1)
      stripped = strip_literal(l)
      rest = substr(stripped, index(stripped, "=") + 1)
      # The chain refusal.  A value that runs a command after it is
      # refused by the two rules below.  A quoted value must be the whole
      # remainder of the line:  nothing may follow its closing quote.  An
      # unquoted value must be a single word, with no whitespace, ;, & or
      # | in it.  The && inside FLEET_DIR="$(cd "$(dirname "$0")" && pwd)"
      # is inside the quoted value, so that line stays one assignment and
      # is accepted.
      if (first == "\"" || first == SQ) {
        # A quoted value is the whole remainder of the line:  nothing may
        # follow the closing quote.
        qend = quoted_value_end(value)
        if (qend == 0) return 0
        if (substr(value, qend + 1) ~ /[^[:space:]]/) return 0
      }
      if (first != "\"" && first != SQ) {
        # An unquoted value is a single word.
        if (rest ~ /[[:space:];&|]/) return 0
      }
      return 1
    }
  ' "$dest")"
  if [[ -n "$offender" ]]; then
    echo "the prelude cut holds a positional command at line ${offender}"
    return 1
  fi
}

# 12a. Synthetic ship scripts whose call marker is missing, reformatted,
# moved or too tight are refused before sourcing.  Each variant has to be
# refused by the check it is meant to trip:  a cut that never stops and a
# cut that stops at the wrong line must not pass for one another, so every
# variant asserts the words of its own refusal.
for variant in missing reformatted moved nodef tight assignchain assignchainbare assignother; do
  synth="${tmp}/synth-ship-${variant}.sh"
  sentinel="${tmp}/synth-sentinel-${variant}"
  {
    echo '#!/bin/bash'
    if [[ "$variant" != nodef ]]; then
      echo 'init_rejected_key_file() {'
      echo '  _rejected_key_dir="$(mktemp -d)"'
      echo '}'
    else
      echo 'init_rejected_key_file_renamed() { :; }'
    fi
    case "$variant" in
      missing)     ;;
      reformatted) echo 'init_rejected_key_file|| echo "could not init" >&2' ;;
      moved)       echo 'echo "arg parsing"'
                   echo 'init_rejected_key_file || echo "could not init" >&2' ;;
      nodef)       echo 'init_rejected_key_file || echo "could not init" >&2' ;;
      tight)       echo 'init_rejected_key_file ||echo "could not init" >&2' ;;
      # An allowlisted name whose quoted value chains a command after it:
      # the quoted-value rule has to refuse it, not the allowlist -- nothing
      # may follow the closing quote of the value.
      assignchain) echo "TEAM_ID=\"x\" && printf 'SHIP-BODY-RAN\\n' > '${sentinel}'"
                   echo 'init_rejected_key_file || echo "could not init" >&2' ;;
      # The same chain with an unquoted value:  the unquoted single-word
      # rule has to refuse it, not the allowlist.
      assignchainbare) echo "TEAM_ID=x&&printf 'SHIP-BODY-RAN\\n' > '${sentinel}'"
                       echo 'init_rejected_key_file || echo "could not init" >&2' ;;
      # A name the real prelude never sets:  the allowlist has to refuse
      # it, even though it only assigns a value.
      assignother) echo 'OTHER_NAME=1'
                   echo 'init_rejected_key_file || echo "could not init" >&2' ;;
    esac
    echo "printf 'SHIP-BODY-RAN\\n' > '${sentinel}'"
    echo 'exit 0'
  } > "$synth"
  if synth_out="$(extract_ship_prelude "$synth" "${tmp}/synth-prelude-${variant}.sh")"; then
    fail "a ${variant} call marker was accepted as a prelude"
  fi
  [[ -n "$synth_out" ]] || fail "the ${variant} call marker was refused without a reason"
  case "$variant" in
    missing)     expect="did not stop before the end" ;;
    reformatted) expect="did not stop before the end" ;;
    moved)       expect="positional" ;;
    nodef)       expect="function definition" ;;
    tight)       expect="did not stop at the load-time hand-off init call" ;;
    assignchain) expect="positional" ;;
    assignchainbare) expect="positional" ;;
    assignother) expect="positional" ;;
    *)           fail "an unknown variant ${variant} reached the refusal check" ;;
  esac
  [[ "$synth_out" == *"$expect"* ]] \
    || fail "the ${variant} variant was refused by the wrong check: ${synth_out}"
done

# 12a-bis. The positive control:  a prelude that stops exactly at the init
# call is accepted, and the ship body after that call is never sourced, so
# the body never runs.  The sentinel is then fired on purpose by the full
# script, which proves the sentinel can fire at all:  an absence that was
# never shown to be able to become a presence proves nothing.
kept_synth="${tmp}/synth-ship-kept.sh"
kept_sentinel="${tmp}/synth-sentinel-kept"
kept_prelude="${tmp}/synth-prelude-kept.sh"
rm -f "$kept_sentinel"
{
  echo '#!/bin/bash'
  echo 'init_rejected_key_file() {'
  echo '  _rejected_key_dir="$(mktemp -d)"'
  echo '}'
  echo 'init_rejected_key_file || echo "could not init" >&2'
  echo "printf 'SHIP-BODY-RAN\\n' > '${kept_sentinel}'"
  echo 'exit 0'
} > "$kept_synth"
if ! kept_out="$(extract_ship_prelude "$kept_synth" "$kept_prelude")"; then
  fail "a prelude that stops at the init call was refused: ${kept_out}"
fi
TMPDIR="$tmp" bash -c 'set -euo pipefail; source "'"$kept_prelude"'"' \
  || fail "the accepted prelude did not load"
[[ ! -e "$kept_sentinel" ]] \
  || fail "the accepted prelude ran the ship body after the init call"
TMPDIR="$tmp" bash "$kept_synth" || fail "the kept ship body did not run"
[[ -e "$kept_sentinel" ]] \
  || fail "the sentinel never fired, so its absence would prove nothing"
rm -f "$kept_sentinel"

# 12b. The real ship script passes the same checks, and only then is its
# prelude sourced.
prelude_err="$(extract_ship_prelude "$script" "${tmp}/ship-prelude.sh")" || fail "$prelude_err"
load_out="$(bash -c '
  set -euo pipefail
  source "'"$tmp"'/ship-prelude.sh"
  [[ -n "${_rejected_key_path:-}" ]] || { echo "no hand-off path"; exit 1; }
  [[ -n "${_rejected_key_dir:-}" ]] || { echo "no hand-off directory"; exit 1; }
  [[ -d "$_rejected_key_dir" ]] || { echo "no hand-off directory on disk"; exit 1; }
  printf "%s\n%s\n%s\n" "$_rejected_key_path" "$_rejected_key_dir" "$(stat -c %a "$_rejected_key_dir" 2>/dev/null || stat -f %Lp "$_rejected_key_dir")"
')" || fail "loading the ship script did not create the run-owned hand-off path: ${load_out}"
load_path="$(printf '%s\n' "$load_out" | sed -n 1p)"
load_dir="$(printf '%s\n' "$load_out" | sed -n 2p)"
load_mode="$(printf '%s\n' "$load_out" | sed -n 3p)"
[[ "$load_path" == "${load_dir}/label" ]] || fail "the hand-off path is not the label file inside the run-owned directory: ${load_path}"
[[ "$load_mode" == "700" ]] || fail "the run-owned hand-off directory is not private: ${load_mode}"
[[ "$load_dir" == "${TMPDIR:-/tmp}"/* ]] || fail "the hand-off directory is not inside the run's own temporary directory: ${load_dir}"

# 13. Without the run-owned hand-off file the parent says the rejected key
# is unknown:  it does not crash, and it does not read a hand-off path from
# the environment.
printf 'SENTINEL-BYPASS\n' > "${tmp}/sentinel-bypass"
bypass_out="$(REJECTED_KEY_FILE="${tmp}/sentinel-bypass" _rejected_key_path="${tmp}/sentinel-bypass" bash -c '
  set -euo pipefail
  source "'"$funcs"'"
  # init_rejected_key_file is deliberately NOT called.
  _rejected_key_path=""
  _rejected_key_dir=""
  printf "%s|%s\n" "$(rejected_key_label)" "$(asc_rejected_key_label "'"$tmp"'/asc-env.err")"
')" || fail "the bypass case crashed: ${bypass_out}"
[[ "${bypass_out%%|*}" == "unknown" ]] || fail "the parent did not report the rejected key as unknown: ${bypass_out}"
[[ "$bypass_out" == *"key id SYNTHETICKEYID1, source ASC_KEY_P8 environment" ]] \
  || fail "the parser lost the label without the hand-off file: ${bypass_out}"
[[ "$(cat "${tmp}/sentinel-bypass")" == "SENTINEL-BYPASS" ]] || fail "the hand-off path was taken from the environment"

echo "ok: ASC credential resolution (environment first, then Infisical, a named path ignored, temp key removed)"
echo "ok: the rejected-key label is parsed from the real client diagnostic, and the run-owned hand-off path is created at load"

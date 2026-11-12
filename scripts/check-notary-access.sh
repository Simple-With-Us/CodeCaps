#!/usr/bin/env bash
# Read-only authentication preflight. Never print Apple's raw diagnostic text:
# it can contain account identifiers or request details. No credential storage.
set +o xtrace
set -euo pipefail
for name in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH; do
  if [[ -z "${!name:-}" ]]; then
    echo "error: missing $name from Fleet-OPS prod /asc" >&2
    exit 1
  fi
done
if [[ ! -s "$ASC_KEY_PATH" ]]; then
  echo 'error: staged ASC key file is missing or empty' >&2
  exit 1
fi
umask 077
diagnostic="$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/notary-access.XXXXXX")"
trap 'rm -f -- "$diagnostic"' EXIT
if xcrun notarytool history --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" \
    --issuer "$ASC_ISSUER_ID" --output-format json > /dev/null 2> "$diagnostic"; then
  echo 'Notarization service authentication succeeded; artifact acceptance remains a separate release gate.'
else
  status=$?
  category='unclassified service or client failure'
  if grep -Eiq '(^|[^0-9])401([^0-9]|$)|unauthorized|authentication' "$diagnostic"; then
    category='authentication rejected; verify the existing Fleet-OPS /asc key'
  elif grep -Eiq '(^|[^0-9])403([^0-9]|$)|forbidden|agreement|permission' "$diagnostic"; then
    category='service access rejected; verify key permissions and account agreements'
  elif grep -Eiq 'timed out|timeout|network|resolve host|connection' "$diagnostic"; then
    category='network or service connectivity failure'
  elif grep -Eiq 'private key|key format|parse.*key|issuer' "$diagnostic"; then
    category='key format or issuer configuration failure'
  fi
  printf 'error: notarization preflight failed (exit %s): %s. Raw response withheld.\n' "$status" "$category" >&2
  exit 1
fi

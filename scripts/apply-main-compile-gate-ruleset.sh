#!/usr/bin/env bash
set -euo pipefail

repo="${1:-Simple-With-Us/CodeCaps}"
ruleset_id="${2:-24433457}"
config="${3:-$(cd "$(dirname "$0")/.." && pwd)/.github/rulesets/default-main-protection.json}"

if [[ ! -f "$config" ]]; then
  echo "ruleset config not found: $config" >&2
  exit 1
fi

gh api "repos/${repo}/rulesets/${ruleset_id}" -X PUT --input "$config"
echo "Updated ruleset ${ruleset_id} on ${repo} (required: Swift CI / compile (macOS))."

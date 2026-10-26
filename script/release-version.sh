#!/usr/bin/env bash
# Canonical CodeCaps release number shared by Mac and iOS build entrypoints.
# Callers must use a full-history checkout; never invent a fallback version.
codecaps_commit_count() {
  local repo_root="$1" shallow count
  shallow="$(git -C "$repo_root" rev-parse --is-shallow-repository 2>/dev/null)" || {
    echo "release-version: cannot inspect git history at $repo_root; refusing to guess a CodeCaps release number" >&2
    return 1
  }
  if [[ "$shallow" != "false" ]]; then
    echo "release-version: shallow git history at $repo_root; fetch full history before building CodeCaps" >&2
    return 1
  fi
  count="$(git -C "$repo_root" rev-list --count HEAD 2>/dev/null)" || {
    echo "release-version: cannot count git commits at $repo_root; refusing to guess a CodeCaps release number" >&2
    return 1
  }
  if [[ ! "$count" =~ ^[1-9][0-9]*$ ]]; then
    echo "release-version: no positive full-history commit count at $repo_root; refusing to guess a CodeCaps release number" >&2
    return 1
  fi
  printf '%s\n' "$count"
}

codecaps_short_version() {
  local repo_root="$1" version_file="$2" version prefix count
  version=""
  if [[ -f "$version_file" ]]; then
    version="$(sed -e 's/[[:space:]]//g' -e '/^$/d' "$version_file" | head -n 1)"
  fi
  prefix="${version:-1.0}"
  prefix="$(printf '%s' "$prefix" | awk -F. '{ if (NF >= 2) print $1"."$2; else print $1".0" }')"
  if [[ "$prefix" != "1.0" ]]; then
    echo "release-version: CodeCaps releases must use the canonical 1.0.N marketing train (found ${prefix})" >&2
    return 1
  fi
  count="$(codecaps_commit_count "$repo_root")" || return 1
  printf '1.0.%s\n' "$count"
}

#!/usr/bin/env bash
# Validate REPOSITORIES (newline-separated `owner/name[@branch]`) and emit what the token step needs.
# Outputs (GITHUB_OUTPUT): owner, names (newline-separated repository names, branches stripped)
set -euo pipefail

owner=""
names=""
while IFS= read -r line; do
  line=${line//[[:space:]]/}
  [ -n "$line" ] || continue
  spec=${line%%@*}
  [[ $spec =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "publish-homebrew-formula: '$line' is not owner/name[@branch]" >&2; exit 1; }
  this_owner=${spec%%/*}
  [ -z "$owner" ] || [ "$owner" = "$this_owner" ] || { echo "publish-homebrew-formula: repositories must share one owner ('$owner' vs '$this_owner')" >&2; exit 1; }
  owner=$this_owner
  names+="${spec#*/}"$'\n'
done <<<"${REPOSITORIES:?REPOSITORIES required}"

[ -n "$owner" ] || { echo "publish-homebrew-formula: no repositories given" >&2; exit 1; }
{
  echo "owner=$owner"
  echo "names<<EOF"
  printf '%s' "$names"
  echo "EOF"
} >> "${GITHUB_OUTPUT:-/dev/stdout}"

#!/usr/bin/env bash
# Copy FILES into each tap repository and push, retrying a push that loses a race.
#   TOKEN           installation (or fallback) token                          (required)
#   REPOSITORIES    newline-separated owner/name[@branch]                     (required)
#   FILES           newline-separated SOURCE:DEST                             (required)
#   COMMIT_MESSAGE  commit message                                            (required)
#   APP_OUTCOME     outcome of the token step; 'failure' with a TOKEN means the fallback is in use
#   URL_BASE        https://github.com by default; a file:// base is used by the tests
#   ATTEMPTS        push attempts per repository (default 4)
set -euo pipefail

: "${REPOSITORIES:?REPOSITORIES required}" "${FILES:?FILES required}" "${COMMIT_MESSAGE:?COMMIT_MESSAGE required}"
url_base=${URL_BASE:-https://github.com}
attempts=${ATTEMPTS:-4}

if [ -z "${TOKEN:-}" ] && [[ $url_base == https://* ]]; then
  echo "::error::no token: the GitHub App token could not be created (check HOMEBREW_TAP_APP_CLIENT_ID / HOMEBREW_TAP_APP_PRIVATE_KEY and that the App is installed on the tap) and no fallback-token was given" >&2
  exit 1
fi
if [ "${APP_OUTCOME:-success}" = failure ]; then
  echo "::warning::GitHub App token step failed; publishing with the fallback token"
fi

pairs=()
while IFS= read -r line; do
  [ -n "${line//[[:space:]]/}" ] || continue
  src=${line%%:*}
  dest=${line#*:}
  [ "$src" != "$line" ] && [ -n "$src" ] && [ -n "$dest" ] || { echo "publish-homebrew-formula: '$line' is not SOURCE:DEST" >&2; exit 1; }
  [ -f "$src" ] || { echo "publish-homebrew-formula: source file '$src' does not exist" >&2; exit 1; }
  case $dest in /* | ../* | *..*) echo "publish-homebrew-formula: DEST '$dest' must be a relative path without '..'" >&2; exit 1 ;; esac
  pairs+=("$(realpath "$src")|$dest")
done <<<"$FILES"
[ ${#pairs[@]} -gt 0 ] || { echo "publish-homebrew-formula: no files given" >&2; exit 1; }

remote_for() { # owner/name -> clone URL (token embedded only for https)
  if [[ $url_base == https://* && -n ${TOKEN:-} ]]; then
    echo "https://x-access-token:${TOKEN}@${url_base#https://}/$1.git"
  else
    echo "$url_base/$1.git"
  fi
}

push_with_retry() { # branch
  local branch=$1 n
  for ((n = 1; n <= attempts; n++)); do
    git push -q origin "HEAD:$branch" 2>/dev/null && return 0
    echo "push attempt $n/$attempts lost a race or failed; rebasing and retrying"
    git pull -q --rebase origin "$branch" 2>/dev/null || { git rebase --abort 2>/dev/null || true; }
  done
  return 1
}

publish_repo() { # spec
  local spec=$1 branch="" dir pair src dest
  [[ $spec == *@* ]] && { branch=${spec#*@}; spec=${spec%%@*}; }
  dir=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$dir'" RETURN
  git clone -q --depth 1 ${branch:+--branch "$branch"} "$(remote_for "$spec")" "$dir" 2>/dev/null \
    || { echo "publish-homebrew-formula: cannot clone $spec (is the App installed on it?)" >&2; return 1; }
  cd "$dir" || return 1
  branch=${branch:-$(git rev-parse --abbrev-ref HEAD)}
  for pair in "${pairs[@]}"; do
    src=${pair%%|*}
    dest=${pair#*|}
    # Explicit `|| return 1`: errexit is suppressed in a function called from `||`/`if`.
    mkdir -p "$(dirname "$dest")" || return 1
    cp "$src" "$dest" || return 1
    git add -- "$dest" || return 1
  done
  if git diff --cached --quiet; then
    echo "$spec: already up to date"
    return 0
  fi
  git -c user.name="${GIT_USER_NAME:-github-actions[bot]}" \
    -c user.email="${GIT_USER_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}" \
    commit -q -m "$COMMIT_MESSAGE" || return 1
  push_with_retry "$branch" || { echo "publish-homebrew-formula: could not push to $spec after $attempts attempts" >&2; return 1; }
  echo "$spec: published"
}

failed=0
while IFS= read -r spec; do
  spec=${spec//[[:space:]]/}
  [ -n "$spec" ] || continue
  (publish_repo "$spec") || failed=1
done <<<"$REPOSITORIES"
exit $failed

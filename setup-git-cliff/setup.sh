#!/usr/bin/env bash
# Install a pinned git-cliff release and put it on PATH.
#   GIT_CLIFF_VERSION  e.g. 2.14.2 or v2.14.2                                  (required)
#   DOWNLOAD_BASE      release asset base URL; tests point it at file://
#   CHECKSUMS_FILE     checksum list (default checksums.txt next to this script); tests override it
#   DRY_RUN            '1' prints the download URL and exits                   (tests)
#   UNAME_S / UNAME_M  override `uname -s` / `uname -m`                        (tests)
# Outputs (GITHUB_OUTPUT): version, path
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
version=${GIT_CLIFF_VERSION:?GIT_CLIFF_VERSION required}
version=${version#v}
case "$version" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "setup-git-cliff: version must look like 2.14.2, got '$version' (there is no 'latest')" >&2; exit 1 ;;
esac

os=${UNAME_S:-$(uname -s)}
arch=${UNAME_M:-$(uname -m)}
case "$os/$arch" in
  Linux/x86_64)                  triple=x86_64-unknown-linux-gnu ;;
  Linux/aarch64 | Linux/arm64)   triple=aarch64-unknown-linux-gnu ;;
  Darwin/arm64 | Darwin/aarch64) triple=aarch64-apple-darwin ;;
  *) echo "setup-git-cliff: unsupported platform $os/$arch" >&2; exit 1 ;;
esac

asset="git-cliff-$version-$triple.tar.gz"
base=${DOWNLOAD_BASE:-https://github.com/orhun/git-cliff/releases/download/v$version}
if [ "${DRY_RUN:-}" = 1 ]; then
  echo "$base/$asset"
  exit 0
fi

sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
fetch() {
  local proto='=https'
  [[ $1 == file://* ]] && proto='=https,file'
  curl --proto "$proto" --tlsv1.2 --fail --silent --show-error --location --retry 5 --retry-connrefused -o "$2" "$1"
}

dest="${RUNNER_TOOL_CACHE:-$HOME/.cache}/git-cliff/$version/$triple"
if [ ! -x "$dest/git-cliff" ]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  fetch "$base/$asset" "$tmp/$asset"
  want=$(awk -v a="$asset" '$2 == a {print $1}' "${CHECKSUMS_FILE:-$here/checksums.txt}")
  [ -n "$want" ] || { echo "setup-git-cliff: no recorded checksum for $asset; add it to setup-git-cliff/checksums.txt" >&2; exit 1; }
  got=$(sha256_of "$tmp/$asset")
  [ "$got" = "$want" ] || { echo "setup-git-cliff: checksum mismatch for $asset: got $got, want $want" >&2; exit 1; }
  mkdir -p "$dest"
  tar -xzf "$tmp/$asset" -C "$tmp"
  install -m 0755 "$tmp/git-cliff-$version/git-cliff" "$dest/git-cliff"
fi

echo "$dest" >> "${GITHUB_PATH:-/dev/null}"
{ echo "version=$version"; echo "path=$dest"; } >> "${GITHUB_OUTPUT:-/dev/null}"
"$dest/git-cliff" --version

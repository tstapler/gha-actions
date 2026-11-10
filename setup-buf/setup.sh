#!/usr/bin/env bash
# Install a pinned buf release and put it on PATH.
#   BUF_VERSION  e.g. 1.50.0 or v1.50.0                  (required)
#   DRY_RUN      '1' prints the download URL and exits    (tests)
#   UNAME_S / UNAME_M  override `uname -s` / `uname -m`   (tests)
# Outputs (GITHUB_OUTPUT): version, path
set -euo pipefail

version=${BUF_VERSION:?BUF_VERSION required}
version=${version#v}
case "$version" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "setup-buf: version must look like 1.50.0, got '$version' (there is no 'latest')" >&2; exit 1 ;;
esac

os=${UNAME_S:-$(uname -s)}
arch=${UNAME_M:-$(uname -m)}
case "$os/$arch" in
  Linux/x86_64)                asset=buf-Linux-x86_64 ;;
  Linux/aarch64 | Linux/arm64) asset=buf-Linux-aarch64 ;;
  Darwin/x86_64)               asset=buf-Darwin-x86_64 ;;
  Darwin/arm64 | Darwin/aarch64) asset=buf-Darwin-arm64 ;;
  *) echo "setup-buf: unsupported platform $os/$arch" >&2; exit 1 ;;
esac

base="https://github.com/bufbuild/buf/releases/download/v${version}"
if [ "${DRY_RUN:-}" = 1 ]; then
  echo "$base/$asset"
  exit 0
fi

sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
fetch() { curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location --retry 5 --retry-connrefused -o "$2" "$1"; }

dest="${RUNNER_TOOL_CACHE:-$HOME/.cache}/buf/$version/$asset"
if [ ! -x "$dest/bin/buf" ]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  fetch "$base/$asset" "$tmp/buf"
  fetch "$base/sha256.txt" "$tmp/sha256.txt"
  want=$(awk -v a="$asset" '$2 == a {print $1}' "$tmp/sha256.txt")
  [ -n "$want" ] || { echo "setup-buf: $asset not listed in sha256.txt for v$version" >&2; exit 1; }
  got=$(sha256_of "$tmp/buf")
  [ "$got" = "$want" ] || { echo "setup-buf: checksum mismatch for $asset: got $got, want $want" >&2; exit 1; }
  mkdir -p "$dest/bin"
  install -m 0755 "$tmp/buf" "$dest/bin/buf"
fi

echo "$dest/bin" >> "${GITHUB_PATH:-/dev/null}"
{ echo "version=$version"; echo "path=$dest/bin"; } >> "${GITHUB_OUTPUT:-/dev/null}"
"$dest/bin/buf" --version

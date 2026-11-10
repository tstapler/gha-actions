#!/usr/bin/env bash
# Install a pinned protoc release and put it on PATH.
#   PROTOC_VERSION    e.g. 23.4 or v23.4                          (required)
#   REQUIRE_CHECKSUM  'true' (default) fails when checksums.txt has no entry for the asset
#   DRY_RUN           '1' prints the download URL and exits       (tests)
#   UNAME_S / UNAME_M override `uname -s` / `uname -m`            (tests)
# Outputs (GITHUB_OUTPUT): version, path
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
version=${PROTOC_VERSION:?PROTOC_VERSION required}
version=${version#v}
case "$version" in
  [0-9]*.[0-9]*) ;;
  *) echo "setup-protoc: version must look like 23.4, got '$version' (there is no 'latest')" >&2; exit 1 ;;
esac

os=${UNAME_S:-$(uname -s)}
arch=${UNAME_M:-$(uname -m)}
case "$os/$arch" in
  Linux/x86_64)                  plat=linux-x86_64 ;;
  Linux/aarch64 | Linux/arm64)   plat=linux-aarch_64 ;;
  Darwin/x86_64)                 plat=osx-x86_64 ;;
  Darwin/arm64 | Darwin/aarch64) plat=osx-aarch_64 ;;
  *) echo "setup-protoc: unsupported platform $os/$arch" >&2; exit 1 ;;
esac

asset="protoc-$version-$plat.zip"
url="https://github.com/protocolbuffers/protobuf/releases/download/v$version/$asset"
if [ "${DRY_RUN:-}" = 1 ]; then
  echo "$url"
  exit 0
fi

sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

dest="${RUNNER_TOOL_CACHE:-$HOME/.cache}/protoc/$version/$plat"
if [ ! -x "$dest/bin/protoc" ]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location --retry 5 --retry-connrefused -o "$tmp/$asset" "$url"
  want=$(awk -v a="$asset" '$2 == a {print $1}' "$here/checksums.txt")
  if [ -n "$want" ]; then
    got=$(sha256_of "$tmp/$asset")
    [ "$got" = "$want" ] || { echo "setup-protoc: checksum mismatch for $asset: got $got, want $want" >&2; exit 1; }
  elif [ "${REQUIRE_CHECKSUM:-true}" = true ]; then
    echo "setup-protoc: no recorded checksum for $asset; add it to setup-protoc/checksums.txt or set require-checksum: false" >&2
    exit 1
  else
    echo "::warning::setup-protoc: installing $asset without checksum verification"
  fi
  mkdir -p "$dest"
  unzip -q -o "$tmp/$asset" -d "$dest"
  chmod +x "$dest/bin/protoc"
fi

echo "$dest/bin" >> "${GITHUB_PATH:-/dev/null}"
{ echo "version=$version"; echo "path=$dest/bin"; } >> "${GITHUB_OUTPUT:-/dev/null}"
"$dest/bin/protoc" --version

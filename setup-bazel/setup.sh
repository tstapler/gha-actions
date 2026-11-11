#!/usr/bin/env bash
# Install a pinned bazelisk as `bazel`, select the Bazel version, and write a user bazelrc.
#   BAZELISK_VERSION  e.g. 1.30.0 or v1.30.0                                   (required)
#   WORKDIR           directory holding .bazelversion (default .)
#   BAZEL_VERSION     overrides .bazelversion; sets USE_BAZEL_VERSION
#   DISK_CACHE / REPO_CACHE   'true' adds --disk_cache / --repository_cache for the dirs below
#   CACHE_ROOT        parent of both cache dirs (default $HOME/.cache)
#   REMOTE_CACHE      remote cache endpoint, e.g. http://127.0.0.1:9090/cache
#   REMOTE_UPLOAD     'false' adds --remote_upload_local_results=false (default true)
#   BAZELRC           file the bazelrc lines are appended to (default $HOME/.bazelrc)
#   DOWNLOAD_BASE     release asset base URL; tests point it at file://
#   CHECKSUMS_FILE    checksum list (default checksums.txt next to this script); tests override it
#   DRY_RUN           '1' prints the download URL and exits                    (tests)
#   UNAME_S / UNAME_M override `uname -s` / `uname -m`                         (tests)
# Outputs (GITHUB_OUTPUT): version, path, bazel-version, disk-cache-dir, repository-cache-dir
# Exports (GITHUB_ENV): USE_BAZEL_VERSION when a version is found
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
version=${BAZELISK_VERSION:?BAZELISK_VERSION required}
version=${version#v}
case "$version" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "setup-bazel: bazelisk version must look like 1.30.0, got '$version' (there is no 'latest')" >&2; exit 1 ;;
esac

os=${UNAME_S:-$(uname -s)}
arch=${UNAME_M:-$(uname -m)}
case "$os/$arch" in
  Linux/x86_64)                  asset=bazelisk-linux-amd64 ;;
  Linux/aarch64 | Linux/arm64)   asset=bazelisk-linux-arm64 ;;
  Darwin/arm64 | Darwin/aarch64) asset=bazelisk-darwin-arm64 ;;
  *) echo "setup-bazel: unsupported platform $os/$arch (supported: linux amd64/arm64, macOS arm64)" >&2; exit 1 ;;
esac

base=${DOWNLOAD_BASE:-https://github.com/bazelbuild/bazelisk/releases/download/v$version}
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

dest="${RUNNER_TOOL_CACHE:-$HOME/.cache}/bazelisk/$version/$asset"
if [ ! -x "$dest/bin/bazel" ]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  fetch "$base/$asset" "$tmp/$asset"
  want=$(awk -v a="$asset" '$2 == a {print $1}' "${CHECKSUMS_FILE:-$here/checksums.txt}")
  [ -n "$want" ] || { echo "setup-bazel: no recorded checksum for $asset (bazelisk $version); add it to setup-bazel/checksums.txt" >&2; exit 1; }
  got=$(sha256_of "$tmp/$asset")
  [ "$got" = "$want" ] || { echo "setup-bazel: checksum mismatch for $asset: got $got, want $want" >&2; exit 1; }
  mkdir -p "$dest/bin"
  install -m 0755 "$tmp/$asset" "$dest/bin/bazel"
fi
echo "$dest/bin" >> "${GITHUB_PATH:-/dev/null}"

# Bazel version: explicit input, else the first non-comment line of .bazelversion.
bazel_version=${BAZEL_VERSION:-}
if [ -z "$bazel_version" ] && [ -f "${WORKDIR:-.}/.bazelversion" ]; then
  bazel_version=$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "${WORKDIR:-.}/.bazelversion" | awk 'NF {print; exit}')
fi
if [ -n "$bazel_version" ]; then
  case $bazel_version in *[!A-Za-z0-9._/-]*) echo "setup-bazel: refusing odd Bazel version '$bazel_version'" >&2; exit 1 ;; esac
  echo "USE_BAZEL_VERSION=$bazel_version" >> "${GITHUB_ENV:-/dev/null}"
fi

cache_root=${CACHE_ROOT:-$HOME/.cache}
disk_dir="$cache_root/bazel-disk-cache"
repo_dir="$cache_root/bazel-repository-cache"
rc=${BAZELRC:-$HOME/.bazelrc}
mkdir -p "$(dirname "$rc")"
{
  [ "${DISK_CACHE:-false}" = true ] && echo "build --disk_cache=$disk_dir"
  [ "${REPO_CACHE:-false}" = true ] && echo "common --repository_cache=$repo_dir"
  if [ -n "${REMOTE_CACHE:-}" ]; then
    echo "build --remote_cache=$REMOTE_CACHE"
    [ "${REMOTE_UPLOAD:-true}" = false ] && echo "build --remote_upload_local_results=false"
  fi
  true
} >> "$rc"

{
  echo "version=$version"
  echo "path=$dest/bin"
  echo "bazel-version=$bazel_version"
  echo "disk-cache-dir=$disk_dir"
  echo "repository-cache-dir=$repo_dir"
} >> "${GITHUB_OUTPUT:-/dev/null}"
echo "setup-bazel: bazelisk $version installed as bazel; Bazel ${bazel_version:-<bazelisk default>}"

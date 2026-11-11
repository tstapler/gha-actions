#!/usr/bin/env bash
# Build a Bazel Rust binary target and package it as <name>-<version>-<triple>.tar.gz plus .sha256.
#   TARGET        Bazel label of the rust_binary, e.g. //crates/cli:dunnage        (required)
#   BINARY_NAME   name of the executable inside the archive                        (required)
#   TARGET_TRIPLE e.g. aarch64-apple-darwin                                        (required)
#   VERSION       release version, with or without a leading v                     (required)
#   CONFIGS       whitespace/newline-separated names, each becomes --config=NAME
#   BAZEL_ARGS    newline-separated extra `bazel build` arguments
#   BAZEL         bazel executable (default bazel)
#   BINARY_PATH   skip the build and package this file (tests, prebuilt binaries)
#   EXTRA_FILES   newline-separated extra files to include, besides README*/LICENSE*/COPYING*
#   SOURCE_DIR    where README/LICENSE are looked up (default .)
#   OUTPUT_DIR    where the archive is written (default dist)
#   WORKDIR       directory to run in (default .); SOURCE_DIR and OUTPUT_DIR are relative to it
# Outputs (GITHUB_OUTPUT): archive-path, archive-name, sha256, sha256-path, version
set -euo pipefail

target=${TARGET:?TARGET required}
bin=${BINARY_NAME:?BINARY_NAME required}
triple=${TARGET_TRIPLE:?TARGET_TRIPLE required}
version=${VERSION:?VERSION required}
version=${version#v}
bazel=${BAZEL:-bazel}
out=${OUTPUT_DIR:-dist}
src=${SOURCE_DIR:-.}
cd "${WORKDIR:-.}" || { echo "bazel-rust-package: cannot enter '${WORKDIR:-.}'" >&2; exit 1; }

[[ $target =~ ^(@[A-Za-z0-9_.~+-]*)?//[A-Za-z0-9_./+@~-]*(:[A-Za-z0-9_./+@~=,-]+)?$ ]] \
  || { echo "bazel-rust-package: '$target' is not a Bazel label like //pkg:name" >&2; exit 1; }
[[ $bin =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "bazel-rust-package: binary name '$bin' has unsupported characters" >&2; exit 1; }
[[ $triple =~ ^[a-z0-9_]+-[a-z0-9_]+(-[a-z0-9_]+)+$ ]] || { echo "bazel-rust-package: '$triple' is not a target triple like x86_64-unknown-linux-gnu" >&2; exit 1; }
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]+)?$ ]] || { echo "bazel-rust-package: version '$version' is not semver (1.2.3 or 1.2.3-rc.1)" >&2; exit 1; }

flags=()
for c in ${CONFIGS:-}; do
  [[ $c =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "bazel-rust-package: config '$c' has unsupported characters" >&2; exit 1; }
  flags+=("--config=$c")
done
while IFS= read -r a; do
  [ -n "${a//[[:space:]]/}" ] && flags+=("$a")
done <<<"${BAZEL_ARGS:-}"

if [ -n "${BINARY_PATH:-}" ]; then
  built=$BINARY_PATH
else
  "$bazel" build ${flags[@]+"${flags[@]}"} -- "$target"
  # cquery with the same flags names the output file; resolve it against the execution root.
  rel=$("$bazel" cquery ${flags[@]+"${flags[@]}"} --output=files -- "$target" | awk 'NF {print; exit}')
  [ -n "$rel" ] || { echo "bazel-rust-package: cquery returned no output file for $target" >&2; exit 1; }
  case $rel in
    /*) built=$rel ;;
    *) built="$("$bazel" info ${flags[@]+"${flags[@]}"} execution_root)/$rel" ;;
  esac
fi
[ -f "$built" ] || { echo "bazel-rust-package: built binary '$built' does not exist" >&2; exit 1; }

name="$bin-$version-$triple"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/$name"
install -m 0755 "$built" "$stage/$name/$bin"
shopt -s nullglob
for f in "$src"/README* "$src"/LICENSE* "$src"/COPYING*; do
  [ -f "$f" ] && install -m 0644 "$f" "$stage/$name/$(basename "$f")"
done
while IFS= read -r f; do
  [ -n "${f//[[:space:]]/}" ] || continue
  [ -f "$f" ] || { echo "bazel-rust-package: extra file '$f' does not exist" >&2; exit 1; }
  install -m 0644 "$f" "$stage/$name/$(basename "$f")"
done <<<"${EXTRA_FILES:-}"

mkdir -p "$out"
out=$(cd "$out" && pwd)
archive="$name.tar.gz"
tar_opts=(--numeric-owner)
if tar --version 2>/dev/null | grep -q 'GNU tar'; then
  tar_opts+=(--sort=name --owner=0 --group=0 --mtime=@0)
else
  tar_opts+=(--uid 0 --gid 0)
fi
(cd "$stage" && tar "${tar_opts[@]}" -cf - "$name") | gzip -n > "$out/$archive"

sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
sum=$(sha256_of "$out/$archive")
printf '%s  %s\n' "$sum" "$archive" > "$out/$archive.sha256"

{
  echo "archive-path=$out/$archive"
  echo "archive-name=$archive"
  echo "sha256=$sum"
  echo "sha256-path=$out/$archive.sha256"
  echo "version=$version"
} >> "${GITHUB_OUTPUT:-/dev/null}"
echo "bazel-rust-package: $out/$archive sha256 $sum"

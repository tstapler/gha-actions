#!/usr/bin/env bash
# Write a bazelrc fragment that makes every `bazel build/test` in the job emit a JSON trace profile
# and a memory profile, plus whichever resource-collection flags this Bazel supports.
#   PROFILE_DIR   where profiles go                      (required)
#   BAZELRC_MODE  'user' appends to ~/.bazelrc (default), 'none' only writes the fragment
#   EXTRA_FLAGS   newline-separated extra `build` flags, appended verbatim
#   COLLECT       'true' (default) adds the optional --experimental_collect_* flags that this Bazel knows
#   BAZEL         bazel binary (default: bazel)
# Outputs (GITHUB_OUTPUT): profile-path, memory-profile-path, bazelrc-fragment
set -euo pipefail

dir=${PROFILE_DIR:?PROFILE_DIR required}
bazel=${BAZEL:-bazel}
mkdir -p "$dir"
frag="$dir/bazel-profile.bazelrc"
profile="$dir/command.profile.gz"
memprofile="$dir/memory.profile"

# Unknown flags abort a Bazel build, so only emit optional flags that `bazel help` lists.
known=""
if [ "${COLLECT:-true}" = true ] && command -v "$bazel" >/dev/null 2>&1; then
  known=$("$bazel" help build --long 2>/dev/null || true)
fi
has_flag() { printf '%s\n' "$known" | grep -q -- "--\[no\]$1 \|--$1 "; }

{
  echo "build --profile=$profile"
  echo "build --memory_profile=$memprofile"
  for f in experimental_collect_resource_estimation experimental_collect_pressure_stall_indicators \
           experimental_collect_load_average_in_profiler experimental_collect_system_network_usage \
           experimental_collect_worker_data_in_profiler; do
    if has_flag "$f"; then echo "build --$f"; fi
  done
  if [ -n "${EXTRA_FLAGS:-}" ]; then printf '%s\n' "$EXTRA_FLAGS"; fi
} > "$frag"

if [ "${BAZELRC_MODE:-user}" = user ]; then
  # ~/.bazelrc is read by every Bazel invocation of this user, with no edits to the repo's .bazelrc.
  cat "$frag" >> "$HOME/.bazelrc"
fi

echo "bazel-profile fragment ($frag):"
cat "$frag"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "profile-path=$profile"
    echo "memory-profile-path=$memprofile"
    echo "bazelrc-fragment=$frag"
  } >> "$GITHUB_OUTPUT"
fi

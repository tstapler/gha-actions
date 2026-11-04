#!/usr/bin/env bash
# Summarise a Bazel profile (critical path, slowest actions) into the step summary.
#   PROFILE_PATH   the .profile.gz written via --profile   (required)
#   TOP_N          lines of analyze-profile output to keep   (default 60)
#   BAZEL          bazel binary                              (default bazel)
# Never fails the job: a missing profile or analyze-profile error is reported and skipped.
set -uo pipefail

profile=${PROFILE_PATH:?PROFILE_PATH required}
bazel=${BAZEL:-bazel}
top=${TOP_N:-60}

if [ ! -s "$profile" ]; then
  echo "::notice title=bazel-profile::no profile at $profile (no bazel build ran, or --profile was overridden)"
  exit 0
fi

size_kb=$(( $(stat -c %s "$profile") / 1024 ))
report=$(mktemp)
if ! command -v "$bazel" >/dev/null 2>&1 || ! "$bazel" analyze-profile "$profile" > "$report" 2>&1; then
  echo "(analyze-profile unavailable or failed; profile is still uploaded)" > "$report"
fi

{
  echo "### Bazel profile (${size_kb} KB)"
  echo
  echo "Open the uploaded profile in https://ui.perfetto.dev or chrome://tracing for the timeline."
  echo
  echo '```'
  head -n "$top" "$report"
  echo '```'
} | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
exit 0

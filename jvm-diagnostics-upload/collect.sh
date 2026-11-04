#!/usr/bin/env bash
# Collect JVM crash/OOM evidence into one directory and print a size table.
#   SEARCH_DIRS          newline-separated roots to search (default: $GITHUB_WORKSPACE)
#   EXTRA_PATHS          newline-separated extra files/dirs/globs to copy verbatim
#   MAX_FILE_MB          files larger than this are listed but not copied (default 512)
#   MAX_TOTAL_MB         stop copying once this much has been collected  (default 1024)
#   INCLUDE_GRADLE_REPORTS  'true' to also copy build/reports trees (default true)
#   OUT_DIR              collection directory (required)
# Writes "count=<n>" and "bytes=<n>" to $GITHUB_OUTPUT when set. Never fails the job.
set -uo pipefail

out=${OUT_DIR:?OUT_DIR required}
max_file=$(( ${MAX_FILE_MB:-512} * 1048576 ))
max_total=$(( ${MAX_TOTAL_MB:-1024} * 1048576 ))
mkdir -p "$out"
total=0 count=0
rows=$(mktemp)

collect() { # <src> <relative-name>
  local src=$1 name=$2 size
  size=$(stat -c %s "$src" 2>/dev/null) || return 0
  if [ "$size" -gt "$max_file" ]; then
    printf '| %s | %s | skipped (over %s MB file cap) |\n' "$name" "$(( size / 1048576 )) MB" "${MAX_FILE_MB:-512}" >> "$rows"
    return 0
  fi
  if [ $(( total + size )) -gt "$max_total" ]; then
    printf '| %s | %s | skipped (over %s MB total cap) |\n' "$name" "$(( size / 1048576 )) MB" "${MAX_TOTAL_MB:-1024}" >> "$rows"
    return 0
  fi
  mkdir -p "$out/$(dirname "$name")"
  if cp "$src" "$out/$name"; then
    total=$(( total + size )); count=$(( count + 1 ))
    printf '| %s | %s | collected |\n' "$name" "$(( (size + 1023) / 1024 )) KB" >> "$rows"
  fi
}

roots=${SEARCH_DIRS:-${GITHUB_WORKSPACE:-.}}
while IFS= read -r root; do
  [ -d "$root" ] || continue
  tag=$(printf '%s' "$root" | tr -c 'A-Za-z0-9._-' '_')
  # -prune keeps find out of node_modules/.git, which can hold millions of files.
  while IFS= read -r f; do
    collect "$f" "$tag/${f#"$root"/}"
  done < <(find "$root" \( -name node_modules -o -name .git \) -prune -o -type f \
              \( -name 'hs_err_pid*.log' -o -name '*.hprof' -o -name '*gc*.log' -o -name 'replay_pid*.log' \) -print 2>/dev/null)
  if [ "${INCLUDE_GRADLE_REPORTS:-true}" = true ]; then
    while IFS= read -r f; do
      collect "$f" "$tag/${f#"$root"/}"
    done < <(find "$root" \( -name node_modules -o -name .git \) -prune -o -type f \
                \( -path '*/build/reports/*' -o -path '*/kotlin-build-reports/*' -o -path '*/build/reports/kotlin-build/*' \) -print 2>/dev/null)
  fi
done <<< "$roots"

if [ -n "${EXTRA_PATHS:-}" ]; then
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    # shellcheck disable=SC2086  # globs in EXTRA_PATHS are intentionally expanded
    for p in $pat; do
      if [ -d "$p" ]; then
        while IFS= read -r f; do collect "$f" "extra/${f#/}"; done < <(find "$p" -type f 2>/dev/null)
      elif [ -f "$p" ]; then collect "$p" "extra/${p#/}"; fi
    done
  done <<< "$EXTRA_PATHS"
fi

{
  echo "### JVM diagnostics collected: ${count} file(s), $(( total / 1048576 )) MB"
  if [ -s "$rows" ]; then
    echo
    echo "| file | size | status |"
    echo "|---|---|---|"
    sort "$rows" | head -n 200
  else
    echo
    echo "No hs_err, heap dump, GC log or Gradle report files found."
  fi
} | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  { echo "count=$count"; echo "bytes=$total"; } >> "$GITHUB_OUTPUT"
fi
exit 0

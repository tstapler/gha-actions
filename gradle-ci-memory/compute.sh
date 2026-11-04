#!/usr/bin/env bash
# Derive Gradle / Kotlin-daemon heap sizes and worker count from the machine's RAM and CPUs,
# and write them to a gradle.properties file. All sizes are integer MB.
#
# Every input comes from the environment (set by action.yml); unset/empty means "derive".
#   TOTAL_MB            override detected RAM (also lets tests simulate other runner sizes)
#   CPUS                override detected CPU count
#   GRADLE_HEAP_PCT     Gradle daemon heap as % of RAM            (default 16)
#   KOTLIN_HEAP_PCT     Kotlin compile daemon heap as % of RAM    (default 32)
#   GRADLE_HEAP_MB / KOTLIN_HEAP_MB / WORKERS_MAX   explicit values; skip derivation (and the cap)
#   GRADLE_HEAP_MAX_MB (4096) / KOTLIN_HEAP_MAX_MB (8192)        upper bounds on derived values
#   TEST_FORK_HEAP_MB   assumed heap of one test fork             (default 1024)
#   RESERVE_MB          RAM kept for OS, runner, native memory    (default 2048)
#   BUDGET_PCT          gradle+kotlin+forks+reserve may use this % of RAM (default 95)
#   KOTLIN_DIAG_FLAGS   extra Kotlin daemon JVM flags, space separated
#   KOTLIN_FALLBACK     'keep' | 'disable' (kotlin.daemon.useFallbackStrategy=false)
#   GRADLE_EXTRA_JVMARGS appended to org.gradle.jvmargs
#   KOTLIN_BUILD_REPORT_DIR  if set, enables kotlin.build.report.output=file into this dir
#   PROPS_FILE         file to append to (default ~/.gradle/gradle.properties)
#   GITHUB_OUTPUT       if set, gradle-heap-mb, kotlin-heap-mb, workers-max, total-mb are written
set -euo pipefail

floor_128() { echo $(( ($1 + 64) / 128 * 128 )); }  # nearest 128 MB (name kept for the cap math)

detect_total_mb() {
  local mem cg
  mem=$(free -m | awk '/Mem:/{print $2}')
  # A container/cgroup limit below host RAM is what the OOM killer actually enforces.
  for f in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory/memory.limit_in_bytes; do
    if [ -r "$f" ]; then
      cg=$(cat "$f")
      if [[ $cg =~ ^[0-9]+$ ]] && [ $(( cg / 1048576 )) -lt "$mem" ]; then mem=$(( cg / 1048576 )); fi
    fi
  done
  echo "$mem"
}

total=${TOTAL_MB:-$(detect_total_mb)}
cpus=${CPUS:-$(nproc)}
gradle_pct=${GRADLE_HEAP_PCT:-16}
kotlin_pct=${KOTLIN_HEAP_PCT:-32}
gradle_max=${GRADLE_HEAP_MAX_MB:-4096}
kotlin_max=${KOTLIN_HEAP_MAX_MB:-8192}
fork_heap=${TEST_FORK_HEAP_MB:-1024}
reserve=${RESERVE_MB:-2048}
budget_pct=${BUDGET_PCT:-95}

workers=${WORKERS_MAX:-}
if [ -z "$workers" ]; then
  # CPUs / 2, but never more forks than a quarter of RAM can hold.
  workers=$(( cpus / 2 )); mem_workers=$(( total / 4 / fork_heap ))
  [ "$workers" -le "$mem_workers" ] || workers=$mem_workers
  [ "$workers" -ge 1 ] || workers=1
fi

if [ -n "${GRADLE_HEAP_MB:-}" ] && [ -n "${KOTLIN_HEAP_MB:-}" ]; then
  gradle=$GRADLE_HEAP_MB; kotlin=$KOTLIN_HEAP_MB   # fully explicit: trust the caller
else
  gradle=${GRADLE_HEAP_MB:-$(floor_128 $(( total * gradle_pct / 100 )))}
  kotlin=${KOTLIN_HEAP_MB:-$(floor_128 $(( total * kotlin_pct / 100 )))}
  [ -n "${GRADLE_HEAP_MB:-}" ] || { [ "$gradle" -le "$gradle_max" ] || gradle=$gradle_max; }
  [ -n "${KOTLIN_HEAP_MB:-}" ] || { [ "$kotlin" -le "$kotlin_max" ] || kotlin=$kotlin_max; }

  # Safety cap: gradle + kotlin + test forks + reserve must fit in the budget.
  avail_for_heaps=$(( total * budget_pct / 100 - workers * fork_heap - reserve ))
  sum=$(( gradle + kotlin ))
  if [ "$sum" -gt "$avail_for_heaps" ]; then
    [ "$avail_for_heaps" -ge 1024 ] || avail_for_heaps=1024
    [ -n "${GRADLE_HEAP_MB:-}" ] || gradle=$(floor_128 $(( gradle * avail_for_heaps / sum )))
    [ -n "${KOTLIN_HEAP_MB:-}" ] || kotlin=$(floor_128 $(( kotlin * avail_for_heaps / sum )))
    [ "$gradle" -ge 512 ] || gradle=512
    [ "$kotlin" -ge 512 ] || kotlin=512
    echo "::notice title=gradle-ci-memory::capped heaps to fit ${total} MB RAM (budget ${budget_pct}%, ${workers} test fork(s) x ${fork_heap} MB, ${reserve} MB reserve)"
  fi
fi

kotlin_opts="-Xmx${kotlin}m"
[ -z "${KOTLIN_DIAG_FLAGS:-}" ] || kotlin_opts="$kotlin_opts ${KOTLIN_DIAG_FLAGS}"

props=${PROPS_FILE:-$HOME/.gradle/gradle.properties}
mkdir -p "$(dirname "$props")"
{
  echo "org.gradle.jvmargs=-Xms512m -Xmx${gradle}m -XX:MaxMetaspaceSize=512m -XX:ReservedCodeCacheSize=256m -XX:+HeapDumpOnOutOfMemoryError${GRADLE_EXTRA_JVMARGS:+ $GRADLE_EXTRA_JVMARGS}"
  echo "kotlin.daemon.jvmargs=${kotlin_opts}"
  echo "org.gradle.workers.max=${workers}"
  [ "${KOTLIN_FALLBACK:-keep}" != disable ] || echo "kotlin.daemon.useFallbackStrategy=false"
  if [ -n "${KOTLIN_BUILD_REPORT_DIR:-}" ]; then
    echo "kotlin.build.report.output=file"
    echo "kotlin.build.report.file.output_dir=${KOTLIN_BUILD_REPORT_DIR}"
  fi
} >> "$props"

echo "gradle-ci-memory: total=${total}MB cpus=${cpus} -> gradle=${gradle}MB kotlin=${kotlin}MB workers=${workers}"
echo "--- $props (appended) ---"
tail -n 7 "$props"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "gradle-heap-mb=$gradle"
    echo "kotlin-heap-mb=$kotlin"
    echo "workers-max=$workers"
    echo "total-mb=$total"
  } >> "$GITHUB_OUTPUT"
fi

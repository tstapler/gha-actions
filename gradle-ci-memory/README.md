# gradle-ci-memory

Writes `~/.gradle/gradle.properties` (which outranks the project's) with heaps derived from the runner's RAM and CPUs. Defaults: Gradle heap 16% of RAM (max 4096 MB), Kotlin daemon 32% (max 8192 MB), `org.gradle.workers.max` = CPUs/2 (and no more forks than a quarter of RAM holds). If gradle + kotlin + workers x 1024 MB + 2048 MB reserve exceeds 95% of RAM, both heaps are scaled down. A 16 GB / 4 CPU runner gets 2560 / 5120 MB / 2 workers.

```yaml
- uses: tstapler/gha-actions/gradle-ci-memory@v0
  id: mem
  with: { kotlin-gc-log: 'true', heap-dump-on-oom: 'true' }
# ... build ...
- if: always()
  uses: tstapler/gha-actions/gradle-ci-memory/effective-flags@v0
- if: always()
  uses: tstapler/gha-actions/jvm-diagnostics-upload@v0
  with: { extra-paths: "${{ steps.mem.outputs.diagnostics-dir }}" }
```

Inputs: `gradle-heap-percent`, `kotlin-heap-percent`, `gradle-heap-mb`, `kotlin-heap-mb`, `workers-max`, `*-max-mb`, `test-fork-heap-mb`, `reserve-mb`, `total-memory-mb`/`cpus` (override detection), `kotlin-gc-log`, `heap-dump-on-oom`, `kotlin-build-report`, `kotlin-fallback` (`disable` sets `kotlin.daemon.useFallbackStrategy=false`), `diagnostics-dir`. Outputs: `gradle-heap-mb`, `kotlin-heap-mb`, `workers-max`, `total-mb`, `diagnostics-dir`.

## Why `kotlin.daemon.jvmargs`, not `kotlin.daemon.jvm.options`

In a probe project (Kotlin 2.4.10, Gradle 9.3.1; `test/kotlin-daemon-probe.sh`), `kotlin.daemon.jvm.options=-Xmx703m` in gradle.properties (user or project) was ignored: the daemon started with the inherited `org.gradle.jvmargs` heap. `kotlin.daemon.jvmargs=-Xmx700m -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=...` (space separated) reached the daemon intact, as did `systemProp.kotlin.daemon.jvm.options` (comma separated). The self-test re-proves this on every run.

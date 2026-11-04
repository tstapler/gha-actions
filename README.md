# gha-actions

Reusable composite actions for CI observability. Pin by commit SHA (or `@v0`).

| Action | Purpose |
|---|---|
| [`mem-sampler`](mem-sampler/README.md) | Wrap a command; log machine and per-process memory; benchdiff metrics; PR comment |
| [`gradle-ci-memory`](gradle-ci-memory/README.md) | Size Gradle and Kotlin daemon heaps from the runner's RAM and CPUs; optional GC log and heap dump |
| [`jvm-diagnostics-upload`](jvm-diagnostics-upload/README.md) | Collect hs_err, heap dumps, GC logs and Gradle reports into one artifact |
| [`bazel-profile`](bazel-profile/README.md) | Profile and memory-profile every Bazel build; summarize and upload |
| `runner-monitor` | Thin wrapper over `step-security/workflow-telemetry-action` with safe defaults |
| `otel-trace` | Thin wrapper over `corentinmusard/otel-cicd-action`; off unless an endpoint is set |

`docs/buildbuddy-evaluation.md` covers hosted Bazel BES and cache options.

Development: `bash test/run.sh` (unit tests), `.github/workflows/selftest.yml` (real-runner tests).

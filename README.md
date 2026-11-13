# gha-actions

Reusable composite actions for CI observability. Pin by commit SHA (or `@v0`).

| Action | Purpose |
|---|---|
| [`mem-sampler`](mem-sampler/README.md) | Wrap a command; log machine and per-process memory; benchdiff metrics; PR comment |
| [`gradle-ci-memory`](gradle-ci-memory/README.md) | Size Gradle and Kotlin daemon heaps from the runner's RAM and CPUs; optional GC log and heap dump |
| [`jvm-diagnostics-upload`](jvm-diagnostics-upload/README.md) | Collect hs_err, heap dumps, GC logs and Gradle reports into one artifact |
| [`bazel-profile`](bazel-profile/README.md) | Profile and memory-profile every Bazel build; summarize and upload |
| [`go-diagnostics-upload`](go-diagnostics-upload/README.md) | Summarize `go test -json` (slowest packages/tests, per-package GC pressure) and upload it |
| [`setup-buf`](setup-buf/README.md) | Install a pinned `buf` release, checksum-verified; no GitHub API calls, so no unauthenticated rate limit |
| [`setup-protoc`](setup-protoc/README.md) | Install a pinned `protoc` release, checksum-verified; same properties |
| [`publish-homebrew-formula`](publish-homebrew-formula/README.md) | Push formula/cask files to one or more tap repos as a GitHub App (short-lived token, retry on a lost push race) |
| [`setup-bazel`](setup-bazel/README.md) | Install a pinned bazelisk (checksum-verified, no API calls), pick Bazel from `.bazelversion`, optional disk/repository caches and remote cache |
| [`setup-git-cliff`](setup-git-cliff/README.md) | Install a pinned `git-cliff` release, checksum-verified; same properties |
| [`bazel-rust-package`](bazel-rust-package/README.md) | Build a Bazel `rust_binary`, write `<name>-<version>-<triple>.tar.gz` and `.sha256`, upload them as an artifact |
| [`generate-homebrew-formula`](generate-homebrew-formula/README.md) | Render a Homebrew formula from release archives' URLs and sha256 values; feeds `publish-homebrew-formula` |
| `runner-monitor` | Thin wrapper over `step-security/workflow-telemetry-action` with safe defaults |
| `otel-trace` | Thin wrapper over `corentinmusard/otel-cicd-action`; off unless an endpoint is set |

Reusable workflow: [`rust-bazel-release.yml`](.github/workflows/rust-bazel-release.yml) builds a Bazel Rust binary on native runners, creates the GitHub Release with a git-cliff changelog, and updates a Homebrew tap. See [`docs/rust-bazel-publish.md`](docs/rust-bazel-publish.md).

`docs/buildbuddy-evaluation.md` covers hosted Bazel BES and cache options.

Development: `bash test/run.sh` (unit tests), `.github/workflows/selftest.yml` (real-runner tests).

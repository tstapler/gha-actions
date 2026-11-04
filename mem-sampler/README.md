# mem-sampler

Composite actions cannot wrap a later `run:` step, so the action only puts `mem-sampler` on PATH. You wrap the command yourself. Samples go to the job log, which survives a killed runner.

```yaml
- uses: tstapler/gha-actions/mem-sampler@v0
- run: mem-sampler --out ci-mem/metrics.json --label build -- ./gradlew build
- if: always()
  uses: tstapler/gha-actions/mem-sampler/report@v0   # needs pull-requests: write
  with: { metrics: ci-mem/metrics.json, title: CI memory (build), tag: ci-memory-build }
```

`mem-sampler` flags: `--out`, `--label`, `--interval` (30), `--top` (6), `--warn-avail-mb` (2000), `--no-summary`. The wrapped command's exit status is returned unchanged. Log lines: `[mem]` whole machine, `[mem-top]` largest processes with RSS, `-Xmx` and a name (kotlin-daemon, gradle-daemon, gradle-test-fork, bazel-server, bazel-worker, xvfb).

Output: benchdiff-format JSON (`peak_used` max, `min_available` min), a step-summary table, and a `::warning` when available memory falls below the threshold.

`report` inputs: `metrics`, `title`, `tag`, `baseline-cache` (default true: the default branch's metrics are saved with actions/cache and PRs diff against them), `baseline` (explicit file), `threshold`, `min-abs`, `comment`.

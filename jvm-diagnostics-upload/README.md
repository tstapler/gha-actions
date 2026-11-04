# jvm-diagnostics-upload

Collects `hs_err_pid*.log`, `*.hprof`, `*gc*.log` and `build/reports` trees (Gradle test reports, Kotlin build reports) from `search-dirs` (default: the workspace) plus any `extra-paths`, skips files over `max-file-mb` (listed in the summary, not uploaded), stops at `max-total-mb`, and uploads one artifact. It never fails the job.

```yaml
- if: always()
  uses: tstapler/gha-actions/jvm-diagnostics-upload@v0
  with: { name: diagnostics-${{ matrix.os }}, retention-days: 7 }
```

Outputs: `file-count`, `bytes`. Heap dumps can contain secrets from process memory; on a public repo keep retention short.

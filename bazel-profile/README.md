# bazel-profile

Writes a bazelrc fragment with `--profile`, `--memory_profile` and whichever of `--experimental_collect_resource_estimation`, `--experimental_collect_pressure_stall_indicators`, `--experimental_collect_load_average_in_profiler`, `--experimental_collect_system_network_usage`, `--experimental_collect_worker_data_in_profiler` the installed Bazel lists in `bazel help build` (unknown flags would abort the build). With the default `bazelrc-mode: user` the fragment is appended to `~/.bazelrc`.

```yaml
- uses: tstapler/gha-actions/bazel-profile@v0
  id: bp
- run: bazel build //...
- if: always()
  uses: tstapler/gha-actions/bazel-profile/report@v0
  with: { profile-path: "${{ steps.bp.outputs.profile-path }}" }
```

The report puts `bazel analyze-profile` output (critical path, slowest actions) in the step summary and uploads the profile; open it in https://ui.perfetto.dev. One profile file per job: a second `bazel` invocation overwrites it, so call the action again with a different `profile-dir` if a job runs several builds you want to keep. Flags verified present in Bazel 9.3.1; see `docs/buildbuddy-evaluation.md` for hosted storage.

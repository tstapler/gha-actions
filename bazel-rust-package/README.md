# bazel-rust-package

Builds a Bazel `rust_binary` and packages it for a release: `<binary>-<version>-<triple>.tar.gz` and `<...>.tar.gz.sha256`, uploaded as a workflow artifact.

```yaml
- uses: tstapler/gha-actions/setup-bazel@v0
- uses: tstapler/gha-actions/bazel-rust-package@v0
  id: pkg
  with:
    target: //crates/cli:dunnage
    binary-name: dunnage
    target-triple: aarch64-apple-darwin
    version: ${{ needs.prepare.outputs.version }}
    configs: release
```

The action runs `bazel build`, then `bazel cquery --output=files` with the same flags to find the output file (no guessing at `bazel-bin` paths), and copies it into a directory named like the archive, so the tarball has one top-level directory with the binary, plus any `README*`, `LICENSE*`, `COPYING*` found in `source-dir` and any `extra-files`. Homebrew strips a single top-level directory on extract, so `bin.install "dunnage"` works on it.

- The build is native: the triple names the archive, it does not cross-compile. Run it on the runner that matches the triple.
- `configs` become `--config=NAME`; `bazel-args` takes anything else (`--compilation_mode=opt`, `--stamp`). Both reach `build`, `cquery` and `info`, so the three agree on the configuration.
- The archive is deterministic where the tar allows it: names sorted, owner 0, mtime 0 and `gzip -n` with GNU tar (Linux); owner 0 only with macOS bsdtar, so a macOS archive's hash can change between runs on the same input.
- Binary name, label, triple and version are validated before use. Version is semver, `v` stripped.
- `working-directory` is where Bazel runs; `source-dir` and `output-dir` are relative to it, and the path outputs are absolute.
- `binary-path` packages a file you already have and skips the build.

Outputs: `archive-path`, `archive-name`, `sha256`, `sha256-path`, `artifact-name`. Needs `bazel` on `PATH` (see `setup-bazel`).

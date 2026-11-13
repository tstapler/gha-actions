# setup-bazel

Installs a pinned [bazelisk](https://github.com/bazelbuild/bazelisk/releases) as `bazel`, selects the Bazel version from `.bazelversion`, and can cache Bazel's disk and repository caches or point Bazel at a remote cache.

```yaml
- uses: tstapler/gha-actions/setup-bazel@v0
  with:
    disk-cache: 'true'
    cache-key: release-linux
    cache-save: ${{ github.event_name != 'pull_request' }}
- run: bazel build //...
```

- bazelisk comes straight from the release asset (no GitHub API call, no token) and is verified against `checksums.txt` in this action. The recorded sums are the sha256 of the v1.30.0 assets for linux-amd64, linux-arm64 and darwin-arm64, taken from a download of each (the darwin-arm64 one also matches the `digest` GitHub lists for the asset). A version with no recorded checksum, or a mismatch, fails. To add a version, download the assets and append their `sha256sum` lines.
- bazelisk then downloads Bazel itself at build time, from Bazel's own release host. That download is outside this action's checksum.
- The Bazel version is `bazel-version` if given, else the first non-comment line of `.bazelversion` in `working-directory`. It is exported as `USE_BAZEL_VERSION` to the rest of the job.
- Settings go in `~/.bazelrc` (user rc, so a repo's own `.bazelrc` still applies): `--disk_cache`, `--repository_cache`, and `--remote_cache` (plus `--remote_upload_local_results=false` with `remote-upload: 'false'`).
- `disk-cache` (default off) and `repository-cache` (default on) use `actions/cache`. The disk-cache key is per `cache-key`, OS and arch, and the commit, restoring the newest earlier one. The repository-cache key hashes `MODULE.bazel` and `MODULE.bazel.lock`. `cache-save: 'false'` restores without saving, so pull requests read caches the default branch wrote.
- `remote-cache` takes any endpoint Bazel accepts. For `tstapler/bazel-cache-proxy` (a local HTTP proxy in front of the GitHub Actions cache) start the proxy first and pass `http://127.0.0.1:9090/cache`; see `docs/rust-bazel-publish.md`.

Linux amd64/arm64 and macOS arm64. Inputs: `bazelisk-version` (default `1.30.0`), `working-directory`, `bazel-version`, `disk-cache`, `repository-cache`, `cache-key`, `cache-save`, `remote-cache`, `remote-upload`. Outputs: `version`, `path`, `bazel-version`, `disk-cache-dir`, `repository-cache-dir`.

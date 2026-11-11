# setup-git-cliff

Installs a pinned [`git-cliff`](https://github.com/orhun/git-cliff/releases) release and puts it on `PATH`.

```yaml
- uses: tstapler/gha-actions/setup-git-cliff@v0
  with:
    version: '2.14.2'
```

Same properties as `setup-buf`: the archive comes straight from the release assets (no GitHub API call, no token) and is checked against `checksums.txt` in this action; a version with no recorded checksum, or a mismatch, fails. The recorded sums for 2.14.2 are the sha256 of the release tarballs, each cross-checked against the `.sha512` file the release publishes. To add a version, download the three tarballs and append their `sha256sum` lines.

Linux amd64/arm64 and macOS arm64. Input: `version` (default `2.14.2`). Outputs: `version`, `path`.

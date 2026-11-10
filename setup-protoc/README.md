# setup-protoc

Installs a pinned [`protoc`](https://github.com/protocolbuffers/protobuf/releases) release and puts it on `PATH`.

```yaml
- uses: tstapler/gha-actions/setup-protoc@v0
  with:
    version: '23.4'
```

Downloads come straight from the release assets, so a pinned install makes no GitHub API call and needs no token. The zip is verified against `checksums.txt` in this action. protobuf publishes no checksum file, so those hashes were recorded from a download of each asset (trust on first use); they catch later tampering or corruption, not a bad original. A version with no recorded checksum fails unless `require-checksum: 'false'`. To add one, download the four assets and append their `sha256sum` lines to `checksums.txt`.

Linux and macOS, amd64 and arm64. Inputs: `version` (default `23.4`), `require-checksum` (default `true`). Outputs: `version`, `path`.

This is a fresh implementation. It replaces `arduino/setup-protoc`, which is GPL-3.0; no code is copied from it.

# setup-buf

Installs a pinned [`buf`](https://github.com/bufbuild/buf) release and puts it on `PATH`.

```yaml
- uses: tstapler/gha-actions/setup-buf@v0
  with:
    version: '1.50.0'
```

Why not `bufbuild/buf-setup-action`: it resolves the version through the GitHub API, and without a `github_token` that request counts against the runner's shared unauthenticated rate limit, which failed CI in tstapler/tymux#90. This action downloads the release asset directly from `github.com/.../releases/download`, which is not an API call, so a pinned install cannot be rate limited and needs no token.

The binary is checked against the `sha256.txt` published with the release and cached under `$RUNNER_TOOL_CACHE`. Linux and macOS, amd64 and arm64.

Inputs: `version` (default `1.50.0`; there is no `latest`, pin one). Outputs: `version`, `path`.

Attribution: the behavior mirrors `bufbuild/buf-setup-action` (Apache-2.0); no code is copied.

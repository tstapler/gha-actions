# Publishing a Rust project built with Bazel

Tag `v1.2.3`, and `rust-bazel-release.yml` builds the binary natively on each runner, creates the GitHub Release with a git-cliff changelog and the archives, and updates the Homebrew formula in your tap. Everything is pinned and checksummed, and no step calls the GitHub API with an unauthenticated token.

## The pieces

| Piece | What it does |
|---|---|
| [`setup-bazel`](../setup-bazel/README.md) | Pinned, checksum-verified bazelisk as `bazel`; Bazel version from `.bazelversion`; optional disk/repository caches and remote cache |
| [`bazel-rust-package`](../bazel-rust-package/README.md) | `bazel build` + collect + `<name>-<version>-<triple>.tar.gz` + `.sha256` + artifact upload |
| [`setup-git-cliff`](../setup-git-cliff/README.md) | Pinned, checksum-verified git-cliff |
| [`generate-homebrew-formula`](../generate-homebrew-formula/README.md) | Formula `.rb` from the archives' URLs and sha256 values |
| [`publish-homebrew-formula`](../publish-homebrew-formula/README.md) | Pushes the formula to the tap as a GitHub App |
| [`.github/workflows/rust-bazel-release.yml`](../.github/workflows/rust-bazel-release.yml) | Reusable workflow wiring all of the above |

## Flow

```
tag v1.2.3 pushed
  prepare   resolve version from the tag, validate names and the targets matrix
  build     one job per target, on its native runner: setup-bazel -> bazel-rust-package   (contents: read)
  assemble  download archives, SHA256SUMS, git-cliff changelog, render formula             (contents: read)
  release   gh release create <tag> with the archives, SHA256SUMS and the changelog        (contents: write)
  homebrew  publish-homebrew-formula pushes the formula to the tap                         (contents: read + App token)
```

`release` and `homebrew` run only for a tag push and never in a dry run. The jobs hand over through workflow artifacts (`package-<triple>`, then `release-assets`).

## Calling it

In the project (`.github/workflows/release.yml`):

```yaml
name: Release
on:
  push:
    tags: ['v[0-9]+.[0-9]+.[0-9]+*']
  workflow_dispatch:
    inputs:
      version: { description: 'Version to dry-run (no tag on a dispatch)', required: true }

permissions: {}

jobs:
  release:
    uses: tstapler/gha-actions/.github/workflows/rust-bazel-release.yml@<commit-sha>
    permissions:
      contents: write   # the reusable workflow's release job needs it; its other jobs ask for less
    with:
      package-name: dunnage
      bazel-target: //crates/dunnage-cli:dunnage
      description: Find and clean up disk space safely
      license: MIT OR Apache-2.0
      dry-run: ${{ github.event_name == 'workflow_dispatch' }}
      version: ${{ inputs.version }}
      homebrew-app-client-id: ${{ vars.HOMEBREW_TAP_APP_CLIENT_ID }}
    secrets:
      HOMEBREW_TAP_APP_PRIVATE_KEY: ${{ secrets.HOMEBREW_TAP_APP_PRIVATE_KEY }}
```

Inputs: `package-name`, `bazel-target`, `description`, `license` (required); `binary-name` (defaults to the package name), `targets` (JSON `[{"triple","runner"}]`, default x86_64-linux on `ubuntu-22.04`, aarch64-linux on `ubuntu-24.04-arm`, aarch64-macOS on `macos-15`), `working-directory`, `bazel-configs`, `bazel-args`, `remote-cache`, `homepage`, `tap-repository` (default `tstapler/homebrew-tap`), `formula-path` (default `Formula/<package>.rb`), `homebrew-app-client-id`, `publish-homebrew` (default true), `cliff-config` (default `cliff.toml`), `version`, `dry-run`.

GitHub-hosted runners are free for public repositories, including the `ubuntu-24.04-arm` and `macos-15` ones.

## Dry run first

Run the workflow with `workflow_dispatch` (or `dry-run: true`) before the first tag. It builds every target, packages, writes `SHA256SUMS`, renders the changelog and the formula into the job summary, and uploads the `release-assets` artifact. It creates no release and pushes nothing. Download `release-assets`, read `formula/<name>.rb`, and run `brew audit --strict --new` against it in a scratch tap if you want to be sure.

## Project layout the actions expect

- `MODULE.bazel` (bzlmod) with `bazel_dep(name = "rules_rust", ...)`; a `rust_binary` target for the CLI. For a Cargo workspace, `crate_universe` reads the Cargo manifests so one dependency list serves both builds:

  ```python
  crate = use_extension("@rules_rust//crate_universe:extensions.bzl", "crate")
  crate.from_cargo(
      name = "crates",
      cargo_lockfile = "//:Cargo.lock",
      manifests = ["//:Cargo.toml", "//crates/dunnage-cli:Cargo.toml"],
  )
  use_repo(crate, "crates")
  ```

- `.bazelversion` at the workspace root, for example `9.3.2`. `setup-bazel` exports it as `USE_BAZEL_VERSION`.
- A `release` config in `.bazelrc` if you want one (`build:release --compilation_mode=opt`), passed as `bazel-configs: release`.
- `cliff.toml` at the repository root (see `github-releases-git-cliff`).
- Tags of the form `vX.Y.Z` or `vX.Y.Z-rc.1` (a hyphen makes the GitHub Release a prerelease).

`test/fixtures/rust-bazel` is a minimal working example (rules_rust 0.75.0, Bazel 9.3.2).

## Required secrets and variables

| Name | Kind | Where | Purpose |
|---|---|---|---|
| `HOMEBREW_TAP_APP_CLIENT_ID` | variable | the project repository | GitHub App client ID; passed as the `homebrew-app-client-id` input |
| `HOMEBREW_TAP_APP_PRIVATE_KEY` | secret | the project repository | GitHub App private key; passed as the workflow secret |

The GitHub App is installed on the tap repository only, with Contents: read and write. `set-homebrew-tap-app-credentials` in the dotfiles repo sets both per repository (a personal account has no account-wide secrets). `GITHUB_TOKEN` is the only other credential, used by `gh release create`. Without the App credentials, pass `publish-homebrew: false`; the release still happens.

## Using bazel-cache-proxy as the remote cache

[`tstapler/bazel-cache-proxy`](https://github.com/tstapler/bazel-cache-proxy) is a local HTTP/gRPC cache server with a GitHub Actions cache backend, so Bazel can use the free Actions cache as a remote cache. The clone I read has no README; this section comes from its example configs (`crates/bazel-cache-proxy/examples/*.toml`) and from the working composite action in `stapler-squad` (`.github/actions/bazel-cache-proxy/{start,flush}`). Treat the flags below as that action's usage, not a spec.

The shape of a job:

1. Export the Actions cache credentials to `run:` steps (`crazy-max/ghaction-github-runtime`), because the proxy needs `ACTIONS_RESULTS_URL` and `ACTIONS_RUNTIME_TOKEN`.
2. Install the proxy (`cargo install --git https://github.com/tstapler/bazel-cache-proxy --rev <sha> --locked bazel-cache-proxy`, cached with `actions/cache`) and start it with a config:

   ```toml
   [backend]
   type = "gha"
   prefix = "release-linux-x64"   # distinct per job
   root = "/home/runner/work/_temp/bazel-cache-proxy/store"
   upload = true                  # false on pull requests
   ```

   `bazel-cache-proxy serve --config config.toml &`, then wait for `http://127.0.0.1:9090/healthz`.
3. Give `setup-bazel` the endpoint: `remote-cache: http://127.0.0.1:9090/cache` (add `remote-upload: 'false'` to make it read-only).
4. After the build, with `if: always()`, `POST http://127.0.0.1:9090/admin/flush` so new blobs are published to the Actions cache, then stop the proxy.

In the reusable workflow, the build job has no step to start the proxy, so `remote-cache` only helps if the endpoint is reachable from the job. To use the proxy there, copy the `build` job into your own workflow and add the start and flush steps, or set `disk-cache` only (the default in the workflow, and enough for a first release). The `stapler-squad` action pair is the one to copy.

## Publishing to crates.io (separate, optional)

The Bazel flow does not publish crates. Keep `cargo publish --workspace` in its own job that uses the Cargo manifests (the Cargo workspace stays the source of truth for versions and metadata):

```yaml
publish-crates:
  needs: release
  runs-on: ubuntu-latest
  permissions:
    contents: read
    id-token: write            # crates.io trusted publishing
  steps:
    - uses: actions/checkout@<sha>
      with: { persist-credentials: false }
    - uses: rust-lang/crates-io-auth-action@<sha>
      id: auth
    - run: cargo publish --workspace --locked
      env:
        CARGO_REGISTRY_TOKEN: ${{ steps.auth.outputs.token }}
```

Run it after `release` so a failed build never leaves a crate published without binaries, or before it if you would rather fail on crates.io problems first. A crates.io version cannot be unpublished, only yanked. This is not part of `rust-bazel-release.yml`, and nothing here requires it. The `cargo publish` step is sketched, not tested.

## Rollback

- Bad GitHub Release: `gh release delete vX.Y.Z --cleanup-tag`, fix, and push the tag again. Re-running on an existing release uploads the assets over it (`--clobber`) and replaces the notes.
- Bad formula: revert the commit in the tap (`git revert`), or fix forward by tagging a patch release. The formula points at release assets, so deleting a release breaks `brew install` until the formula is reverted.
- A crates.io release: `cargo yank --version X.Y.Z`.

## Security notes

- Workflow `permissions: {}` at the top; each job asks for its own: `contents: read` for build, assemble and homebrew, `contents: write` only for `release`. Nothing else gets a write scope.
- Triggered by a tag push. `release` and `homebrew` have `if: publish == 'true'`, which needs a tag ref, no dry run, and not `workflow_dispatch`. A pull request can never publish.
- The tap token is a GitHub App installation token, minted in the `homebrew` job, scoped to the tap repository with Contents: write, and expiring in an hour. There is no stored personal access token.
- Inputs reach shell steps through `env:`, never through `${{ }}` inside `run:`; names, labels, triples and versions are validated before use.
- Every third-party action is pinned by commit SHA. bazelisk and git-cliff are pinned releases checked against recorded sha256 values, with no GitHub API call. bazelisk downloads Bazel itself later, outside that check.
- Archives are checked again in `assemble` (`sha256sum --check`) before they are attached.
- `persist-credentials: false` on every checkout.
- `tstapler/gha-actions/*` is pinned to a commit of the branch that added these actions; move it to the merged or released commit.

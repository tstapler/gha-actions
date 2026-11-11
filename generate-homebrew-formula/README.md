# generate-homebrew-formula

Renders a Homebrew formula for prebuilt release archives. Its output is the input of `publish-homebrew-formula`.

```yaml
- uses: tstapler/gha-actions/generate-homebrew-formula@v0
  id: formula
  with:
    name: dunnage
    version: ${{ needs.prepare.outputs.version }}
    desc: Find and clean up disk space safely
    homepage: https://github.com/tstapler/dunnage
    license: MIT OR Apache-2.0
    sums-file: dist/SHA256SUMS
    url-base: https://github.com/tstapler/dunnage/releases/download/v${{ needs.prepare.outputs.version }}
- uses: tstapler/gha-actions/publish-homebrew-formula@v0
  with:
    client-id: ${{ vars.HOMEBREW_TAP_APP_CLIENT_ID }}
    private-key: ${{ secrets.HOMEBREW_TAP_APP_PRIVATE_KEY }}
    files: ${{ steps.formula.outputs.formula-path }}:Formula/dunnage.rb
```

Archives come from `archives` (`TRIPLE URL SHA256` per line) or from `sums-file` plus `url-base`, where every `<binary>-<version>-<triple>.tar.gz` line of a `sha256sum`-style file becomes one. Supported triples: `{aarch64,x86_64}-apple-darwin`, `{aarch64,x86_64}-unknown-linux-{gnu,musl}`.

What it writes: class name (CamelCase of the name), `desc`, `homepage`, `license`, an `on_macos` and an `on_linux` block each with `on_arm`/`on_intel` `url` + `sha256`, `bin.install "<binary>"`, and `test do` running `<binary> --version`.

- A `license` of `A OR B` becomes `any_of: ["A", "B"]` (`AND` becomes `all_of`), which is what `brew audit` wants.
- A plain `x.y.z` version is left for Homebrew to scan from the URL, because `brew audit --strict` rejects an explicit `version` there as redundant. A prerelease keeps an explicit `version`.
- An OS with a single CPU gets `depends_on arch:` so the other CPU fails with a clear message instead of a formula with no `url`.
- All URLs must be `https://`, sha256 values 64 lowercase hex. Strings are escaped for Ruby.

The generator is `generate.py` (stdlib only). `test/run.sh` checks it against `test/golden/dunnage.rb`. Inputs: `name`, `version`, `desc`, `homepage`, `license` (required); `archives`, `sums-file`, `url-base`, `binary-name`, `class-name`, `test-args`, `output`. Output: `formula-path`.

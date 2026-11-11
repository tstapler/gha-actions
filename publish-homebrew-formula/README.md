# publish-homebrew-formula

Pushes formula or cask files to one or more Homebrew tap repositories as a GitHub App, with a short-lived installation token instead of a stored personal access token.

```yaml
- uses: tstapler/gha-actions/publish-homebrew-formula@v0
  with:
    client-id: ${{ vars.HOMEBREW_TAP_APP_CLIENT_ID }}
    private-key: ${{ secrets.HOMEBREW_TAP_APP_PRIVATE_KEY }}
    files: |
      Formula/tool.rb:Formula/tool.rb
      Casks/tool.rb:Casks/tool.rb
    repositories: |
      tstapler/homebrew-tap
```

- `files`: `SOURCE:DEST` pairs. `DEST` is relative to the tap repository root, with no `..`.
- `repositories`: `owner/name[@branch]`, one per line, all with the same owner; the App must be installed on each with Contents read/write. Default `tstapler/homebrew-tap`.
- `commit-message`: default `update <repo> <ref>`.
- `fallback-token`: optional; used only when the App token cannot be minted (say, a legacy PAT during a rollout). Without it the step fails with a message naming the likely cause.

An unchanged file makes no commit. A push that loses a race with another publisher is rebased and retried (4 attempts). Set a `concurrency` group on the job if several releases may publish at once.

Credentials are set per repository (a personal account has no account-wide secrets) with `set-homebrew-tap-app-credentials` from the dotfiles repo.

The files are copied as given. Rendering a formula from release archives is up to the caller, for example `scripts/render-homebrew-formula.sh` in tstapler/tymux.

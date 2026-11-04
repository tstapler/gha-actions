# BuildBuddy evaluation (BES, remote cache, profile storage)

Question: should CI get a Build Event Service (BES), remote cache and profile storage from BuildBuddy, and if so self-hosted or cloud? This is a recommendation only. No BuildBuddy infrastructure is built here. `bazel-profile` already uploads the local profile as an artifact, which covers profile storage without a server.

## Options

| | Cloud free tier | Self-host OSS |
|---|---|---|
| What you get | Hosted BES UI, remote cache, remote execution | Same server binary you run yourself |
| Limits | 100 GB cache transfer, up to 80 remote cores, up to 10 users, unlimited builds, community support ([pricing](https://www.buildbuddy.io/pricing)) | Your own hardware and storage |
| Intended for | "small teams and open source projects" ([pricing](https://www.buildbuddy.io/pricing)) | Individuals / on-prem; MIT-licensed OSS version ([pricing](https://www.buildbuddy.io/pricing)) |
| Ops cost | None | Docker, Kubernetes or Helm; multi-replica needs MySQL plus storage ([on-prem docs](https://www.buildbuddy.io/docs/on-prem)) |
| Gaps | Page does not state BES invocation or cache retention limits for the free tier | Enterprise adds OIDC auth, API access and more; the docs page does not itemize the split ([on-prem docs](https://www.buildbuddy.io/docs/on-prem)) |

## Constraints for a public GitHub-hosted repo

- A cloud API key must reach the build as a secret. Fork PRs do not receive secrets, so fork builds would run without BES or cache. Use a read-only cache key for PRs and a write key for main (standard BuildBuddy practice; not verified here).
- Self-hosting needs a publicly reachable endpoint for GitHub-hosted runners (or self-hosted runners), which is real operational and security work for a personal setup.

## Recommendation

1. Now: keep `bazel-profile` artifacts (zero infrastructure, available today).
2. Next, if remote cache or a shared invocation UI is wanted: try the cloud free tier on the main branch only, with a write key as a repo secret. It is the cheapest experiment and reversible by removing three `.bazelrc` lines.
3. Self-hosting only if the free-tier limits are hit or data must stay on owned hardware.

Unverified: free-tier BES retention, real cache-transfer volume of the stelekit Bazel jobs (measure with the profile artifacts first), and the current stelekit cache setup (`--config=remote-cache` exists in its workflows; its backend was not inspected).

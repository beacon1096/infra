# TODO

## Multica upstream

- [ ] Prepare and submit the durable-webhook Issue deduplication fix upstream.
  - Rebase [`multica-webhook-issue-dedup.patch`](docs/ci-cd/patches/multica-webhook-issue-dedup.patch)
    onto the current Multica default branch.
  - Re-run the focused PostgreSQL-backed regression tests.
  - Write an upstream-facing issue or pull request description without Beacon
    deployment details or credentials.
  - Follow the upstream review and replace any temporary downstream build with
    an official fixed release.

- [ ] Decide whether to deploy a temporary patched Multica image before an
  upstream release. The currently deployed release still has the false
  duplicate behavior.

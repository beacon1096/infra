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

- [x] Build and validate a temporary patched Multica backend image for the
  durable-webhook deduplication fix.
  - Production smoke test on 2026-09-16 confirmed two distinct deliveries
    create two Issues while a retry of one delivery remains idempotent.
  - The reproducible `multica-backend-oci` flake output and Forgejo publish job
    carry `0.4.24-beacon.1` until an official fixed release replaces it.

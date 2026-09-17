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

## Automation ingress

- [ ] Move Forgejo, n8n, and Multica machine-to-machine webhooks onto
  self-hosted ingress or private service discovery.
  - Keep the public Cloudflare path as a compatibility layer while migration
    is incomplete.
  - Preserve scoped, single-use callback capabilities and fixed destination
    allowlists; private routing must not replace application-layer
    authorization.
  - Remove the callback-specific User-Agent workaround only after agents no
    longer traverse Cloudflare and the private path has equivalent
    observability and availability.

## Agent validation tools

- [ ] Prototype bounded n8n MCP tools for agent-requested validation.
  - Reuse existing Forgejo validation implementations; do not create a second
    set of test commands with different semantics.
  - Start with exact-SHA Nix evaluation and Helm rendering tools.
  - Allowlist repositories and targets, keep credentials inside n8n/runner,
    and return structured results plus immutable evidence URLs.
  - Test authorization, malicious inputs, replay, timeout, cancellation,
    unavailable capacity, and result-to-SHA binding.
  - Keep MCP validation separate from approval and merge authority.

## GitOps validation migration

- [ ] Replace the sunsetted `flux-local` workflow with `flate` validation.
  - Preserve the current test and rendered-diff coverage before changing the
    required status name.
  - Pin the executable or container by immutable digest and test Forgejo
    Actions compatibility.
  - Evaluate `konflate` separately as a read-only Forgejo PR review service;
    do not make a new service a prerequisite for the initial CLI migration.
  - Keep `flux-local` 8.4.0 only as a short-term compatibility bridge.

## Wanxiang cluster upgrade

- [ ] Execute the staged Talos/Kubernetes upgrade described in
  [`wanxiang/docs/cluster-upgrade.md`](wanxiang/docs/cluster-upgrade.md).
  - Do not close Renovate PR #36 while the control-plane upgrade is pending.
  - Do not merge its kubectl 1.37 pin while every API server remains on 1.35.
  - Re-evaluate the open Flux, Cilium, CoreDNS, Envoy Gateway, and related
    chart PRs against each target Kubernetes minor before approval.

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

## Renovate review continuation

- [ ] Add a first-class continuation path after a Renovate review returns
  `human_required`.
  - The signed review capability is single-use and is consumed by the
    `human_required` callback, so a later human approval currently cannot
    submit `approve` for the same PR head.
  - After an allowlisted human approves the exact reviewed SHA, mint a new
    short-lived capability bound to the same repository, PR, head SHA, review
    evidence, and Multica Issue instead of replaying the consumed capability.
  - Re-read Forgejo and the human approval at continuation time, reject stale
    or changed heads, and retain the existing merge-queue and branch-protection
    checks.
  - Add regression coverage for approve, reject, expiry, replay, concurrent
    head changes, and duplicate human-approval events.
  - Until implemented, refreshing the PR with a signed empty commit is an
    audited fail-closed workaround only when its Git tree is proven identical;
    it is not the intended steady-state workflow.

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

- [x] Complete the Talos 1.13.10 / Kubernetes 1.36 stage described in
  [`wanxiang/docs/cluster-upgrade.md`](wanxiang/docs/cluster-upgrade.md),
  including the Cilium, CloudNativePG, and Longhorn prerequisites, the 1.36.3
  minor transition, and the separate 1.36.4 patch update.
- [ ] After a stable 1.36 observation period, prepare the Talos/Kubernetes 1.37
  stage as a separate reviewed rollout.
  - Keep Renovate PR #36 (kubectl 1.37) and PR #37 (talosctl 1.14) open until
    the Stage 3 client/control-plane ordering is decided.
  - Keep the completed Kubernetes 1.36.4 patch separate from the 1.37 minor
    transition and retain its independent rollout evidence.
  - Re-evaluate the open Flux, Cilium, CoreDNS, Envoy Gateway, and related
    chart PRs against each target Kubernetes minor before approval.

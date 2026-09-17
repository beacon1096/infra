# Renovate and Multica merge gate

## Goal

Renovate discovers dependency updates and prepares pull requests. It is not the
authority that decides whether an update is operationally safe. Major updates
may require migrations, configuration changes, staged rollout instructions, or
other work that Renovate cannot infer.

A human or Multica agent reviews and, when necessary, updates the pull request.
Approval applies to one exact head commit. Any subsequent commit invalidates
that decision and starts review again.

## Flow model

```text
Renovate PR or updated head
        │
        ▼
policy/merge-gate = pending
        │ SHA-bound review task
        ▼
Multica / human analysis and required changes
        │ signed approve / reject / human_required
        ▼
n8n re-reads the current Forgejo PR
        ├─ mismatch/reject → policy/merge-gate = failure
        └─ approve        → policy/merge-gate = success
                                  │
                                  ▼
                         schedule protected merge
                                  │ required checks pass
                                  ▼
                            Forgejo merges PR
```

The merge request includes `head_commit_id`. Forgejo branch protection remains
the final enforcement point for required checks, rejected reviews, conflicts,
and outdated branches.

## Trust model

| Principal | Authority |
| --- | --- |
| `renovate` | Create and update dependency PRs; cannot merge `main` |
| Multica agent | Analyze one supplied PR revision and return a scoped decision; receives no Forgejo PAT |
| Authorized operator | Approve another author's PR with a Forgejo review, or confirm an own-author PR with a SHA-bound command; initial allowlist is `beacon1096` |
| `multica-gate` | Read the two infrastructure repositories and write `policy/merge-gate`; cannot merge |
| n8n | Validate review capabilities, write the policy result, and request a protected merge |
| `multica-merger` | Merge only through its isolated n8n credential and Forgejo's merge whitelist |
| Forgejo | Enforce protected-branch requirements and reject stale or unauthorized merges |
| GitOps, SOPS, cluster, and n8n administrators | Trusted control-plane operators with existing production impact |

## Why the executor stays in n8n

n8n already creates approved `infra-private` release tags and therefore is
already a production control-plane component. A custom merger service managed
by the same repository, SOPS recipients, Kubernetes administrators, and network
does not create an independent security boundary. It adds an image, API,
deployment, upgrade path, and tests while leaving the same operators trusted.

A separate service becomes worthwhile only if its secret recipients,
deployment authority, and administrators are separated from n8n. Without those
properties, a dedicated n8n workflow is the smaller and more auditable design.

## Security invariants

### Authenticate Forgejo events

The public Forgejo webhook must carry a dedicated authorization value. n8n
rejects unauthenticated events before they can update event state, start a
Multica task, write a commit status, or generate notifications. This prevents a
caller from impersonating a Renovate webhook to consume review capacity or
reset a gate to pending.

### Use a scoped review capability

n8n signs a short-lived capability containing the repository, PR number, exact
head SHA, issue time, expiry, and a random identifier. The Multica task receives
that capability, not the signing secret. The callback derives its scope only
from verified claims; caller-supplied repository and SHA fields are not trusted.

The capability is valid for at most 24 hours and is single-use. After signature
and field validation, n8n atomically inserts its random `jti` into a dedicated
PostgreSQL table whose primary key is `jti`. `INSERT ... ON CONFLICT DO NOTHING`
allows exactly one execution to continue; a concurrent or later replay returns
HTTP 409 before any Forgejo status or merge request is written.

Consumption is deliberately fail-closed and happens before the fresh PR lookup.
If a later Forgejo request fails, the same capability cannot be retried; a new
PR event must issue a new capability. Consumed rows are retained through expiry
and removed after a seven-day grace period. Reuse cannot authorize another PR
or commit, and a merge of a closed PR or request for a changed head is also
rejected by the fresh PR lookup and `head_commit_id` constraint.

### Separate judgment from enforcement

Multica classifies the operational risk and gathers evidence. The callback has
three outcomes:

- `approve` means the reviewed SHA contains the necessary upgrade work and has
  sufficient validation evidence;
- `reject` means a known incompatibility or required step is unresolved;
- `human_required` means the decision needs environmental, business, or human
  judgment and leaves the gate pending.

Major-version changes are not rejected mechanically, but schema or data
migrations, storage formats, authentication or authorization, network ingress
or routing, control-plane software such as Talos, Kubernetes, and Forgejo,
destructive operations, and insufficient evidence default to
`human_required`. Uncertainty must never be converted into approval merely to
finish a task.

The agent makes the contextual judgment; n8n and Forgejo enforce deterministic
facts such as identity, repository scope, current SHA, required checks, branch
freshness, and merge permission.

### Treat repository content as untrusted

PR titles, descriptions, diffs, release notes, and linked pages can contain
instructions intended to manipulate an agent. They are evidence, not control
messages. Only the review runbook defines the agent's task and callback
protocol. The agent never receives gate or merger Forgejo credentials.

### Bind approval and merge to current state

Before writing the policy result, n8n fetches the PR from a fixed Forgejo API
origin and requires all of the following:

- repository is `infrastructure/infra` or `infrastructure/infra-private`;
- PR is open and targets `main`;
- author is `renovate`;
- current head equals the SHA in the signed capability.

Only an approved result schedules merging. The URL is constructed from the
validated allowlist and integer PR number. The request supplies the reviewed
head as `head_commit_id` and does not force a merge. Forgejo waits for every
protected-branch requirement and rejects a changed or outdated head.

The existence of a successful status is not itself a merge trigger. Scheduling
happens only in the same n8n execution that validates the signed capability,
re-reads the PR, and writes the gate with the `multica-gate` credential. A
different repository writer therefore cannot trigger merging merely by posting
another status named `policy/merge-gate`; failure of n8n's status request stops
the execution before the merger credential is used.

### Isolate the merger credential

The `multica-merger` PAT belongs in n8n's encrypted credential store and is
attached only to the fixed merge request node. It must not be exposed as a Pod
environment variable, embedded in workflow JSON, sent to Multica, or reused by
Renovate. n8n administrators remain trusted; this isolation prevents webhook
data and agent tasks from reading the credential directly.

The separate `Review Capability PostgreSQL` n8n credential is generated during
Pod initialization from the existing CNPG application Secret and imported into
n8n's encrypted credential store. Its password is never embedded in workflow
JSON. The workflow accesses only its own
`multica_review_capability_consumptions` table and its query is parameterized.
This credential currently reuses the n8n application database role, so it does
not form an independent boundary from n8n administrators. A dedicated database
role may be added when database administration is separated from the n8n
control plane.

## Failure behavior

All validation failures are closed: no merge is scheduled. A rejected or stale
review writes or retains a failing gate. Forgejo API errors return an explicit
failure to the callback and remain visible in n8n execution history. Operational
dependency failures use HTTP 424 with a JSON error body: the public proxy
replaces upstream 5xx bodies with a generic error page, while 424 preserves the
machine-readable result and remains a non-success, fail-closed outcome. Updating
a PR produces a new SHA and a new pending gate; approval of the previous SHA has
no effect on it.

## Multica webhook Issue deduplication

The create-Issue autopilot currently applies two independent duplicate checks:

1. webhook ingress deduplicates retries using the delivery identity derived
   from `Idempotency-Key`; and
2. Issue creation suppresses a recent active Issue with the same autopilot,
   project, and normalized title.

The second check is useful as a coarse safety guard for manual and scheduled
runs, but it is not a valid identity for webhook events. This integration uses
a stable generic Issue title, so several distinct Forgejo pull-request events
can arrive with different idempotency keys while rendering the same title. The
title check then creates the first Issue and incorrectly marks the remaining
runs as `skipped` with `recent duplicate autopilot issue`.

The downstream patch in
[`patches/multica-webhook-issue-dedup.patch`](patches/multica-webhook-issue-dedup.patch)
makes the durable webhook delivery the authoritative boundary:

- a retry with the same delivery identity still reuses its existing run;
- distinct deliveries create distinct Issues even when their titles match;
- replay remains a new delivery and therefore performs the requested work;
- manual, scheduled, and legacy non-durable runs retain the recent-title
  safety guard.

The implementation checks `run.WebhookDeliveryID.Valid`, not the textual
`source` field. This ties the exception to a persisted delivery protected by
the database uniqueness constraint and avoids turning a mislabeled internal
call into a deduplication bypass. It requires no schema migration and no n8n
workflow change.

The patch includes a PostgreSQL-backed regression test that sends two webhook
requests with different `Idempotency-Key` values through one create-Issue
autopilot and verifies that their runs reference two different Issues. It was
also checked against the existing test that verifies recent-title suppression
for ordinary dispatch. Both tests passed after applying all upstream database
migrations in a disposable PostgreSQL instance.

The fix was also smoke-tested against the production database on 2026-09-16.
Two deliveries with the same rendered Issue title and distinct idempotency keys
created separate runs and Issues; retrying the first key returned `duplicate`
and reused its delivery. The official `v0.4.24` image was restored immediately
after the test.

The temporary downstream image is built reproducibly by the
`multica-backend-oci` flake output. It fetches the pinned upstream `v0.4.24`
source, applies the patch above, builds the static Go binaries, and produces an
OCI archive tagged `0.4.24-beacon.1`. The Forgejo build workflow publishes that
immutable version tag to
`forgejo.beaco.works/infrastructure/nix-fleet/multica-backend`. Deployment is a
separate change to the Multica HelmRelease, made only after the registry tag is
available anonymously. This ordering prevents Flux from reconciling a manifest
whose image has not been published yet.

The publish job logs in through a temporary `skopeo` auth file populated from
standard input. Registry credentials must not be passed with `--dest-creds`:
command arguments are visible in the runner's process table. The auth file is
removed by an exit trap, and the registry PAT is rotated if process-table
exposure is observed.

Upstream contribution and eventual removal of the downstream image remain
tracked in [`TODO.md`](../../TODO.md).

## Pull request validation

The credential-free `Nix Validation` Forgejo workflow evaluates all flake
outputs and runs the n8n policy regression test for every pull request. It does
not receive Attic, registry, SOPS, gate, or merger credentials. Full fleet
builds remain in the post-merge and release workflows; Multica may require an
additional targeted build as evidence when a dependency update affects a
specific host or deployment artifact.

## Non-Renovate pull requests

The protected `policy/merge-gate` context applies to every pull request.
Opening, reopening, or updating an ordinary PR sets the gate on its current SHA
to pending. When the operator is not the PR author, approval uses Forgejo's
normal review UI. Forgejo intentionally prevents authors from approving their
own PRs, so an allowlisted author instead comments exactly
`/approve <full-40-character-head-SHA>` on the PR.

The review or comment webhook is only a wake-up signal. n8n does not trust its
claimed reviewer, command, or verdict. It re-reads the open PR and either its
reviews or the specific comment through the fixed Forgejo API origin, then
requires all of the following:

- repository is one of the two infrastructure repositories and base is `main`;
- PR author is not `renovate`;
- webhook PR head and current PR head are equal;
- for a review, its `commit_id` is the current head and it is neither stale nor
  dismissed;
- for an author confirmation, the re-read comment ID matches the webhook, the
  body contains only `/approve` plus the complete current head SHA, and no
  abbreviated SHA is accepted;
- reviewer or confirming author is in the explicit operator allowlist,
  initially `beacon1096`.

Only then does `multica-gate` mark that SHA successful and the isolated
`multica-merger` credential request a protected merge with the same
`head_commit_id`. A replay for an older review cannot approve a changed head.
Multica decisions continue to use their separate signed-capability path; an
agent cannot manufacture either event from PR-controlled content.

An author confirmation is a second action bound to the post-validation
revision, not independent four-eyes review. This is an explicit single-operator
exception: an agent currently authorized to operate as `beacon1096` is the same
Forgejo principal and cannot be distinguished from the human by this gate.
Agent-specific Forgejo identities remain the long-term way to recover that
separation; until then, the audit record proves which exact revision the shared
principal confirmed, not whether a human or delegated agent clicked it.

## Renovate merge queue

An approved Renovate PR enters a PostgreSQL-backed FIFO queue instead of
merging in the callback execution. This prevents every merge into `main` from
forcing all other approved dependency PRs through another agent review.

At approval time n8n reads the recursive Git trees for the PR's merge base and
reviewed head. It computes a canonical, path-sorted delta containing each
changed leaf's path, type, mode, base blob ID, and head blob ID, then stores its
SHA-256 digest with the repository, PR, exact approved head, Multica capability
JTI, and a 24-hour expiry. A truncated, unreadable, or oversized tree fails
closed. `git patch-id` is deliberately not used because its whitespace
normalization is weaker than the required byte-level tree identity.

The `Renovate Merge Queue` n8n workflow leases one active item at a time. It
re-reads the PR and requires it to remain open, authored by `renovate`, and
targeted at `main`. If the PR merge base is behind the current base head, the
isolated merger credential asks Forgejo to update the PR branch and releases
the lease. The resulting synchronize webhook leaves `policy/merge-gate`
pending but suppresses a duplicate Multica dispatch while that queue record is
active.

Once the PR contains the current base, the worker recomputes the tree delta.
Only an exact digest and changed-path count match carries approval to the new
head. Changes elsewhere on `main` therefore do not require another review, but
any change to the approved path/blob/mode/type set blocks the queue item. A
blocked item is sent back through the authenticated infra-ci webhook as a new
`synchronize` event. This event is only a wake-up signal: infra-ci creates a
new capability for the updated head, and the callback still re-reads Forgejo
before accepting a decision. Approval is never inferred from the old commit
status. Its dedicated event variant prevents the earlier Forgejo
`synchronize` delivery from suppressing the re-review through event
deduplication. Once the new review request is accepted, the worker resolves the old
issue through its stored capability JTI and marks that strictly bound issue
`blocked`, leaving the new head with its own issue and capability.

The byte-level rule intentionally treats an unrelated edit to the same file as
a changed delta. Renovate therefore groups all `mise` manager updates into one
PR, reducing collisions in `wanxiang/.mise.toml` without weakening the gate.

After equivalence is proven, `multica-gate` marks only the current head
successful. The worker re-reads the combined status and uses
`multica-merger` only when all required checks report success. Its merge request
contains the current `head_commit_id`, disables delayed merging, omits force,
and remains subject to Forgejo branch protection. A concurrent merge that
makes the item stale returns it to the queue for another deterministic update
cycle.

After a successful merge, issue closure is bound to the exact stored Multica
run, autopilot, and issue identifiers. It does not require the Multica run to
report `completed`: webhook-triggered runs currently remain `issue_created`
after an approved callback, while the callback capability and approved tree
snapshot are the authorization boundary for the merge.

Queue states are `queued`, `updating`, `waiting_ci`, `merging`, `merged`,
`blocked`, and `expired`. Claims use a short database lease and
`FOR UPDATE SKIP LOCKED`; approval expires after the original capability's
24-hour lifetime.

## Merge readiness and observability

Human-approved PRs retain the immediate merge path. Immediately before using
the merger credential, n8n re-reads the combined Forgejo commit status for the
exact approved SHA. Failed, missing, or unreadable status never reaches the
merger node. The merge retains `head_commit_id`, omits force merge, and remains
subject to branch protection.

Policy outcomes are sent to the Forgejo CI Matrix room as plain-text notices.
They cover invalid callbacks, capability replay, stale SHA, `reject`,
`human_required`, blocked or failed merges, queued merges, and completed merges.
Notices contain repository, PR, exact SHA, evidence URL when available, and the
n8n execution URL, but never a capability or credential. Callback responses
run in parallel with notification delivery, so a Matrix outage cannot turn an
accepted decision into a retry that would collide with single-use consumption.

For a completed Renovate merge, n8n resolves the originating
Multica autopilot run through a dispatch record bound to the signed capability
JTI, repository, PR number, and head SHA. It then marks that run's Issue as
`done` with the dedicated `multica-closer.no-reply@beacoworks.xyz` member
identity. Agent-supplied Issue URLs are not trusted for this lookup. A queued
merge remains `in_review` until Forgejo confirms the merge.

Multica currently does not expose scopes on personal access tokens. The closer
therefore has ordinary workspace-member permissions, and n8n isolates its token
in a credential attached only to the fixed run-read and Issue-status nodes. The
credential must not be exposed to the agent, callback payload, or workflow JSON.

## Deferred: webhook-triggered Renovate runs

The current Renovate OSS process is a one-shot systemd service scheduled by a
timer. Dependency Dashboard checkbox changes are therefore consumed by the next
scheduled run rather than immediately. Keep the timer as the reliable fallback.

If lower latency becomes useful, Forgejo may send the relevant Issue webhook to
n8n, which can start `renovate.service` on its host through a dedicated,
restricted SSH identity. This path must not provide n8n with a general-purpose
shell. The proposed identity should be limited by an OpenSSH forced command and
`restrict`, with authorization for exactly `systemctl start renovate.service`.
n8n must additionally accept only the expected repository, Dependency Dashboard
issue, event action, and actor. systemd remains responsible for suppressing
concurrent duplicate runs, and the existing timer remains enabled for missed
webhooks.

Do not expose a general systemd HTTP endpoint or reuse an administrator SSH
credential for this convenience trigger. This integration is intentionally not
enabled yet.

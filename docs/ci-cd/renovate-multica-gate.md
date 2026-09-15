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
| Authorized human reviewer | Approve an ordinary PR in Forgejo; initial allowlist is `beacon1096` |
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
to pending. To approve it, an authorized human uses Forgejo's normal PR review
UI and submits an `Approve` review.

The review webhook is only a wake-up signal. n8n does not trust its claimed
reviewer or verdict. It re-reads the open PR and its reviews through the fixed
Forgejo API origin, then requires all of the following:

- repository is one of the two infrastructure repositories and base is `main`;
- PR author is not `renovate`;
- webhook PR head, current PR head, and approved review `commit_id` are equal;
- review is neither stale nor dismissed;
- reviewer is in the explicit human allowlist, initially `beacon1096`.

Only then does `multica-gate` mark that SHA successful and the isolated
`multica-merger` credential request a protected merge with the same
`head_commit_id`. A replay for an older review cannot approve a changed head.
Multica decisions continue to use their separate signed-capability path; an
agent cannot impersonate a Forgejo human review.

## Merge readiness and observability

Immediately before using the merger credential, n8n re-reads the combined
Forgejo commit status for the exact reviewed SHA. A successful status requests
an immediate protected merge with `merge_when_checks_succeed=false`; a pending
status requests a queued merge with `merge_when_checks_succeed=true`. A failed,
missing, or unreadable status never reaches the merger node. Both modes retain
`head_commit_id`, omit force merge, and remain subject to branch protection.

Policy outcomes are sent to the Forgejo CI Matrix room as plain-text notices.
They cover invalid callbacks, capability replay, stale SHA, `reject`,
`human_required`, blocked or failed merges, queued merges, and completed merges.
Notices contain repository, PR, exact SHA, evidence URL when available, and the
n8n execution URL, but never a capability or credential. Callback responses
run in parallel with notification delivery, so a Matrix outage cannot turn an
accepted decision into a retry that would collide with single-use consumption.

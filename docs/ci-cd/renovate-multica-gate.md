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
        │ signed decision for the exact SHA
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

The capability is valid for at most 24 hours. Reuse cannot authorize another
PR or another commit. Repeated delivery for the same SHA is idempotent; a merge
of a closed PR or a request for a changed head is rejected by the fresh PR
lookup and `head_commit_id` constraint.

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

## Failure behavior

All validation failures are closed: no merge is scheduled. A rejected or stale
review writes or retains a failing gate. Forgejo API errors return an explicit
failure to the callback and remain visible in n8n execution history. Updating a
PR produces a new SHA and a new pending gate; approval of the previous SHA has
no effect on it.

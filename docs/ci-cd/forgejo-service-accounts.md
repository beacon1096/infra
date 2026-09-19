# Forgejo service accounts

Automation uses separate restricted Forgejo accounts so dependency discovery,
policy decisions, and merging do not share credentials.

| Username | Email | Purpose | Repository access |
| --- | --- | --- | --- |
| `renovate` | `renovate@noreply.forgejo.beaco.works` | Discover dependency updates and open pull requests | Write collaborator on `infrastructure/infra` and `infrastructure/infra-private` |
| `multica-gate` | `multica-gate.no-reply@beacoworks.xyz` | Read Renovate pull requests and write the `policy/merge-gate` commit status | Write collaborator on `infrastructure/infra` and `infrastructure/infra-private` |
| `multica-merger` | `multica-merger.no-reply@beacoworks.xyz` | Merge a pull request after all protected-branch requirements pass | Write collaborator on `infrastructure/infra` and `infrastructure/infra-private` |
| `ci-publisher` | `ci-publisher.no-reply@beacoworks.xyz` | Publish disposable OCI smoke-test images | No repository or organization membership; owns only packages below `ci-publisher/` |

`multica-gate` cannot merge through the automation workflow. Its PAT has only
the `write:repository` and `read:issue` scopes and is stored encrypted in the
n8n SOPS Secret. `read:issue` is required to re-read a SHA-bound author
confirmation comment; webhook content alone is not trusted.
The Multica agent only receives a credential for submitting its review result
to n8n and never receives a Forgejo PAT.

`multica-merger` has a `write:repository` PAT stored as the dedicated
`Forgejo Multica Merger Token` n8n credential. It is attached only to the fixed
Forgejo merge request node; it is not exposed as an environment variable or to
Renovate, Multica agents, or general review nodes.

`ci-publisher` has only a `write:package` PAT, stored in Forgejo Actions as
`CI_REGISTRY_USER` and `CI_REGISTRY_TOKEN`. It is deliberately not a member of
the `infrastructure` organization, so branch CI can overwrite its disposable
packages without gaining the ability to publish production images or modify a
repository.

## Protected branches

The `main` branches of `infrastructure/infra` and
`infrastructure/infra-private` are protected in Forgejo with the following
policy:

- direct pushes are disabled, including for administrators;
- `policy/merge-gate` and
  `Check Secrets / check-secrets (pull_request)` must both pass;
- rejected reviews and outdated branches block merging;
- only `multica-merger` is allowed to merge.

The whitelist and merger credential are active. n8n may only schedule a merge
after validating a SHA-bound review capability; Forgejo still enforces every
protected-branch requirement. The rules are currently managed through the
Forgejo API and recorded here; they are not yet declaratively managed by the
repository.

Passwords, PATs, webhook URLs, and callback credentials must not be added to
this document. Their source of truth is the corresponding SOPS Secret or the
Forgejo credential store.

## Deferred: per-agent development identities

Multica agents that modify repositories should eventually receive independent
runtime identities instead of inheriting one shared workspace configuration.
This work is intentionally separate from the merge gate and remains pending.

Each agent profile should define and isolate at least:

- its Nix configuration, substituters, trusted keys, builders, and caches;
- Git author name, no-reply email, signing policy, and credential helper;
- a dedicated Forgejo account and narrowly scoped PAT when repository writes
  are required;
- repository allowlists and whether it may read, push branches, open PRs, or
  review them;
- separate cache, home, and temporary directories so global `gitconfig`, Nix
  state, and credentials cannot leak between agents.

Account names and no-reply email addresses belong in this public document once
chosen. Tokens and private signing material remain in the appropriate secret
store. An agent identity must not reuse `renovate`, `multica-gate`, or
`multica-merger`: those accounts have distinct discovery, policy, and merge
responsibilities.

Until those identities exist, an explicitly authorized agent may operate as
`beacon1096`. Forgejo and the merge gate necessarily treat that as the same
principal as the human operator. For a PR authored by that shared principal,
Forgejo self-review is unavailable; the operator confirmation is instead an
exact `/approve <full-head-SHA>` PR comment that n8n re-reads through the API.
This preserves revision binding and an auditable second action, but it is not
independent review and must not be described as one.

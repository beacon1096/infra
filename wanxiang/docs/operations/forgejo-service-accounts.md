# Forgejo service accounts

Automation uses separate restricted Forgejo accounts so dependency discovery,
policy decisions, and merging do not share credentials.

| Username | Email | Purpose | Repository access |
| --- | --- | --- | --- |
| `renovate` | `renovate@noreply.forgejo.beaco.works` | Discover dependency updates and open pull requests | Write collaborator on `infrastructure/infra` and `infrastructure/infra-private` |
| `multica-gate` | `multica-gate.no-reply@beacoworks.xyz` | Read Renovate pull requests and write the `policy/merge-gate` commit status | Write collaborator on `infrastructure/infra` and `infrastructure/infra-private` |
| `multica-merger` | `multica-merger.no-reply@beacoworks.xyz` | Merge a pull request after all protected-branch requirements pass | Write collaborator on `infrastructure/infra` and `infrastructure/infra-private` |

`multica-gate` cannot merge through the automation workflow. Its PAT has only
the `write:repository` scope and is stored encrypted in the n8n SOPS Secret.
The Multica agent only receives a credential for submitting its review result
to n8n and never receives a Forgejo PAT.

`multica-merger` currently has no PAT. Create and deploy one only when the
separate merge executor and protected-branch merge whitelist are enabled. Do
not expose that credential to Renovate, Multica agents, or general n8n review
nodes.

## Protected branches

The `main` branches of `infrastructure/infra` and
`infrastructure/infra-private` are protected in Forgejo with the following
policy:

- direct pushes are disabled, including for administrators;
- `policy/merge-gate` and
  `Check Secrets / check-secrets (pull_request)` must both pass;
- rejected reviews and outdated branches block merging;
- only `multica-merger` is allowed to merge.

The whitelist is active, but `multica-merger` has no PAT, so automated merging
is intentionally disabled until a separate merge executor is deployed. The
rules are currently managed through the Forgejo API and recorded here; they
are not yet declaratively managed by the repository.

Passwords, PATs, webhook URLs, and callback credentials must not be added to
this document. Their source of truth is the corresponding SOPS Secret or the
Forgejo credential store.

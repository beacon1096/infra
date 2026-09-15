# Production release and Nix rollout

## Release boundary

- `infra/main` is the canonical public integration branch. Its CI validates
  reusable modules and the public architecture.
- `infra-private` pins an exact `infra` revision and assembles the complete
  production fleet with private overlays.
- Production approval, release tags, `prod` promotion, and Comin rollout are
  owned by `infra-private`.
- A tag in `infra` can publish a public module or showcase version; it does not
  authorize production rollout.

## Flow

1. Public changes merge into `infra/main` after its required checks pass.
2. `infra-private` updates its locked public input and adds any private
   configuration required by that revision.
3. A push to `infra-private/main` runs the complete fleet build. It validates
   only and does not deploy.
4. An operator manually runs `build-and-push.yaml`. A successful run causes n8n
   to create a release approval record and publish its approval form.
5. Approval makes n8n create an `infra-private` release tag for the exact
   reviewed SHA.
6. The tag runs the complete build again and publishes its outputs. Only after
   every release job succeeds does Forgejo Actions advance `infra-private/prod`
   to the tagged SHA.
7. Comin observes `infra-private/prod` and rolls that revision out to the NixOS
   fleet.

```text
infra/main
    │ pinned revision
    ▼
infra-private/main ── full validation ── n8n approval
                                            │ exact-SHA tag
                                            ▼
                                     release build
                                            │ all jobs pass
                                            ▼
                                  infra-private/prod
                                            │ Comin
                                            ▼
                                      NixOS fleet
```

Never push `prod` directly. A release tag is an authorization record, not just
a version label. Failed or partial release builds must leave `prod` unchanged.

## Trust and rollback

n8n is part of the trusted release control plane: it already holds the ability
to create an `infra-private` tag after approval. Forgejo Actions, rather than
n8n, advances `prod` after rebuilding the tagged revision. Comin is trusted to
deploy only the revision visible on `prod`.

Rollback means selecting a reviewed, known-good `infra-private` revision,
running the same release process, and advancing `prod` through a successful
tag build. Do not repair a broken rollout by moving `prod` around the release
workflow.


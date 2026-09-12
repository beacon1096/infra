# Beacoworks infrastructure

This is the public, canonical infrastructure monorepo on
[Forgejo](https://forgejo.beaco.works/infrastructure/infra).
[GitHub](https://github.com/beacon1096/infra) is a one-way showcase mirror of
`main`. Make changes and run CI on Forgejo; GitHub Actions is disabled.
Production approval and releases remain in `infra-private` on Forgejo.

## Repository layout

- `flake.nix`, `hosts/`, `modules/`, `packages/`, `secrets/`: public NixOS and
  nix-darwin fleet configuration.
- `taichu/`: Harvester/RKE2 environment inventory.
- `wanxiang/`: Talos, Kubernetes, and Flux configuration.
- `kubernetes/flux/`: repository-level Flux entrypoint.

The Nix flake stays at the repository root so existing rebuild and Comin flows
can change only the repository URL. Existing Attic cache and OCI package names
retain the `nix-fleet` name during migration to avoid breaking consumers.

## Public and private boundary

SOPS-encrypted secrets may be committed here. Plaintext credentials, decrypted
outputs, kubeconfigs, Talos configs, age keys, and local runtime state may not.

Use the root `.sops.yaml` for root-level Nix secrets. Run Wanxiang SOPS commands
from `wanxiang/` or pass `--config wanxiang/.sops.yaml` explicitly so cluster
secrets keep their own recipient set.

Private cloud-host definitions and private edge/proxy topology stay in the
separate `infrastructure/infra-private` repository. It is not a submodule of
this repository. Public host baselines may be exported as NixOS modules for a
private overlay, but private behavior and its production output are assembled
and released only from the private repository.

## Release boundary

- `main` is the canonical public integration branch; its CI validates the
  reusable modules and public architecture.
- `infra-private` pins an exact `infra` revision and assembles the complete
  production fleet on top of it.
- Production approval, release tags, `prod` promotion, and Comin rollout are
  owned by `infra-private`.
- Tags in this repository, if used, publish public module or showcase versions;
  they do not authorize a production fleet rollout.

## Production release flow

1. Make reusable or public-facing changes on `infra/main` and wait for its CI
   validation. Skip this step for private-only changes.
2. In `infra-private`, update the locked `infra` input to the reviewed public
   commit, then add any required private overlays or service configuration.
3. Push `infra-private/main` and wait for the complete fleet build to pass.
   A normal `main` push validates only; it does not deploy.
4. Manually run `build-and-push.yaml` for `infra-private`. A successful manual
   run produces the n8n release approval link.
5. Approving the release creates an `infra-private` tag. The tag workflow
   rebuilds the fleet, verifies publication, and advances `infra-private/prod`
   only after every release gate passes.
6. Comin observes `infra-private/prod` and rolls the approved revision out to
   the production fleet. Monitor host health and roll back to a reviewed,
   known-good private revision if necessary.

Never push `prod` directly, and never use an `infra` tag as production
authorization.

## CI runner maintenance

The three Harvester Nix builders use staggered drain, garbage-collection, and
resume windows so two runners remain available while one store is maintained.
See [docs/ci-runner-maintenance.md](docs/ci-runner-maintenance.md) for the
rotation, timeout contract, and failure behavior.

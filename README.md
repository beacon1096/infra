# Beacoworks infrastructure

This is the public, canonical infrastructure monorepo on Forgejo. Its
one-way GitHub mirror is suspended while the public/private boundary and
public Git history are being audited.

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

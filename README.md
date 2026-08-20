# Beacoworks infrastructure

This is the public, canonical infrastructure monorepo on Forgejo. Forgejo
mirrors it to `https://github.com/beacon1096/infra` for public distribution.

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
this repository. A host must be declared in only the repository that owns its
production configuration.

## Release boundary

- `main` is the integration branch.
- Release tags run the full Forgejo Actions build gate.
- A successful tagged build advances `prod`.
- Public fleet hosts pull `infra.git` on `prod`; private hosts pull
  `infra-private.git` on its independently promoted `prod` branch.

No host should be switched to the new repository before its target exists on
`prod` and a single-host canary has verified rebuild, access, runner state, and
rollback.

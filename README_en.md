[中文](README.md) | [English](README_en.md)

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

Enable the repository's staged-content check in each clone:

```bash
git config --local core.hooksPath .githooks
```

The hook uses Nix to provide Python and PyYAML. It checks staged Git content
for private keys, local credential files, and unencrypted protected YAML/JSON
values, including Kubernetes Secrets. Supported example and template values
are allowed; SOPS metadata alone does not exempt plaintext fields. Diagnostics
show file locations without credential values. This is a targeted check, not
a general-purpose detector for every token format or proof of valid encryption.

The `Check Secrets` workflow runs regression tests and scans the checked-out
commit on pushes and pull requests. To run the same checks locally:

```bash
nix-shell -p python3Packages.pyyaml --run 'python3 utils/test-check-secrets.py'
nix-shell -p python3Packages.pyyaml --run 'python3 utils/check-secrets.py'
```

The scanner defaults to `HEAD`; use `--staged` to check pending staged changes.
CI detects committed problems after upload, so it does not replace the local
hook or review of recipient changes in `.sops.yaml`.

Private cloud-host definitions and private edge/proxy topology stay in the
separate `infrastructure/infra-private` repository. It is not a submodule of
this repository. Public host baselines may be exported as NixOS modules for a
private overlay, but private behavior and its production output are assembled
and released only from the private repository.

## CI/CD and production delivery

`infra/main` is the public integration branch. `infra-private` pins reviewed
public revisions and owns production approval, release tags, `prod` promotion,
and Comin rollout. Start with the [CI/CD documentation](docs/ci-cd/README.md)
for the complete release flow, dependency-review gate, service accounts, and
runner maintenance.

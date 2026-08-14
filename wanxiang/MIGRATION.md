# 万象 migration staging

Status: staged for review; not cut over.

## Source and target

- Imported source: `swarm` at commit `0ba3bd4`.
- Canonical write repository: Forgejo `ssh://forgejo-agent/infrastructure/infra.git`.
- Expected public read-only mirror: `https://github.com/beacon1096/infra.git`. Verify the owner/repository name after the mirror is created before applying the bridge.
- The current live source remains `https://github.com/beacon1096/swarm.git` until the bridge is applied.

The source tree is kept under `infra/wanxiang/` so the later NixOS migration can occupy a separate top-level boundary. The relative Talos patch references and the Taskfile are preserved for execution from this directory. Generated kubeconfig, Talos config, age key, and `talos/clusterconfig/` output remain local-only.

## Flux path changes staged here

- Flux instance sync path for the cutover bridge: `kubernetes/flux/cluster`.
- The stable bridge entrypoint is `kubernetes/flux/cluster/ks.yaml`, matching
  the path used by the legacy `swarm` source. It points at the environment tree
  below `wanxiang/` and lets the cutover change only the Git URL.
- The environment-local Flux path remains `wanxiang/kubernetes/flux/cluster`
  for source-tree-local tooling and review.
- Cluster Kustomization path: `./wanxiang/kubernetes/apps`.
- Child Kustomization paths are rooted at `./wanxiang/kubernetes/...`.
- The copied Flux instance points at the expected `infra` mirror, but this branch must not be applied until that mirror exists and contains the complete `main` tree.

## Cutover gates

1. Create the one-way Forgejo → GitHub mirror and verify that an unauthenticated clone from the Wanxiang network sees the expected commit and paths.
2. Disable GitHub Actions for the public mirror, or ensure no mirrored workflow can write contents, releases, issues, or tags.
3. Keep the existing SOPS recipient and Flux `sops-age` Secret unchanged through the cutover. Audit both current files and Git history before expanding public exposure.
4. Run SOPS encryption checks, Talos generation/diff checks, `flux-local`, Kustomize rendering, and schema validation against this tree.
5. Apply a bridge change from the still-authoritative `swarm` source to point Flux at the new URL while retaining the stable `kubernetes/flux/cluster` path. Do not rely on a change that exists only in the new source, because Flux cannot fetch it until the bridge is active.
6. Confirm `GitRepository`, root and child Kustomizations, HelmReleases, and critical workloads are Ready before retiring the old source or webhook.

## Rollback

Before the bridge, rollback is simply leaving the live `swarm` source unchanged. After the bridge, restore the previous URL/path (`https://github.com/beacon1096/swarm.git` and `kubernetes/flux/cluster`) from the old source, then reconcile and verify health. Do not delete the old repository or its deploy material until the new source has passed an observation window.

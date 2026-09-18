# Wanxiang cluster upgrade

This runbook prepares the next Talos and Kubernetes upgrade. It records the
ordering and evidence requirements; it does not authorize a deployment by
itself.

## Pre-upgrade observed baseline

Read-only checks on 2026-09-17 showed:

- three control-plane nodes (`ms01-a`, `ms01-b`, and `ms01-c`) Ready;
- Talos 1.12.7 on all three nodes;
- Kubernetes API server and kubelets at 1.35.4;
- Flux Operator, Flux Instance, Cilium, CoreDNS, and Envoy Gateway Helm
  releases Ready;
- repository pins in `talos/talenv.yaml` agree with the live Talos and
  Kubernetes versions.

Re-run these checks immediately before every stage. Repository state and live
state must agree before proceeding.

## Upgrade invariants

- Upgrade Kubernetes one minor at a time: 1.35 to 1.36, validate, then 1.36
  to 1.37. Kubernetes does not support skipping API-server minor versions.
- Keep HA API servers within one minor of each other. Do not advance a kubelet
  beyond the oldest API server it can reach.
- Upgrade and drain one node at a time while the other two retain quorum and
  ingress/storage service.
- Use the latest suitable patch release for each target minor, not an old
  `.0` merely because a Renovate PR was opened earlier.
- Bind every approval, generated Talos image, machine configuration, and
  validation result to an exact Git revision and target version.
- Stop after any failed health, quorum, storage, networking, admission
  webhook, Flux reconciliation, or workload smoke check. Do not continue to
  the next node or minor while degraded.

## Preparation gate

Before changing a node:

1. Record node, Talos, Kubernetes, Cilium, Flux, CSI, CoreDNS, and ingress
   versions and confirm all relevant resources are Ready.
2. Confirm etcd snapshot creation and restoration instructions, plus current
   backups for stateful workloads. A successful backup job without a tested
   recovery path is insufficient evidence.
3. Check removed/deprecated Kubernetes APIs and every admission webhook
   against the next minor.
4. Confirm the target Talos release supports the target Kubernetes minor and
   rebuild the Image Factory artifact with the existing schematic/extensions.
5. Confirm Cilium, CSI, Flux Operator/Instance, CoreDNS, Envoy Gateway, and
   other control-plane-adjacent charts support the next minor. Upgrade a
   prerequisite separately and return the cluster to green before continuing.
6. Render the complete Flux tree and run secret, CUE, Nix, and policy checks.
   `flux-local` 8.4.0 is the current bridge; `flate` will replace it in a
   separate validation migration.

## Staged execution

### Selected 1.36 target

- Talos: 1.13.10;
- Kubernetes: 1.36.3, matching the control-plane and kubelet images shipped
  in the Talos 1.13.10 release;
- Cilium: 1.20.2, qualified on the existing Kubernetes 1.35.4 cluster before
  the control-plane upgrade.

Kubernetes 1.36.4 is newer, but it is intentionally deferred to a separate
patch update after the 1.36.3 minor transition is stable. This keeps the
first 1.35 to 1.36 rollout aligned with the exact component set published and
tested together by Talos.

### Stage 1: platform prerequisites

Review the pending controller/chart PRs as compatibility prerequisites, not as
one bulk merge. Flux Operator and Flux Instance must be evaluated as a pair,
including the manifest artifact pin. Cilium must be qualified for both the
current and next Kubernetes minors before the API-server upgrade. Apply at
most one subsystem change at a time and wait for Flux and workloads to settle.

For Kubernetes 1.36 specifically, upgrade CloudNativePG to 1.30.x (chart
0.29.x) and Longhorn to 1.12.x first. CloudNativePG 1.29.x supports Kubernetes
only through 1.35, and Longhorn 1.11.1 was tested only through Kubernetes 1.35.
Deploy and validate these prerequisites separately before running
`talosctl upgrade-k8s`.

### Stage 2: Talos/Kubernetes 1.36

Choose the supported Talos target for Kubernetes 1.36 from its release matrix.
Roll Talos across one node at a time, checking etcd membership and workloads
after each node. Upgrade Kubernetes from 1.35 to the latest selected 1.36
patch using the Talos-supported procedure. Validate all nodes, system pods,
webhooks, CRDs, storage, DNS, ingress, Flux reconciliation, and representative
stateful workloads before leaving this stage.

### 2026-09-19 execution record

Stage 2 completed with the repository pins from PRs #79, #80, and #81:

- Talos rolled one node at a time from 1.12.7 to 1.13.10. Etcd retained three
  consistent voting members and the Talos health checks passed after the roll.
- Two CloudNativePG replica PVCs exposed invalid PostgreSQL checkpoints during
  node drains. Their primaries and other replicas remained healthy. The broken
  instances were replaced with `kubectl cnpg destroy`; replacement replicas
  reached streaming state before work continued.
- CloudNativePG was upgraded to operator 1.30.0 / chart 0.29.0. Updating the
  bootstrap controller image restarted each cluster primary in place, briefly
  removing its write endpoint. All eight clusters returned to three ready
  instances with two streaming replicas. Treat future operator upgrades that
  change the bootstrap image as a coordinated database maintenance event.
- Longhorn's chart, manager, CSI components, and V1 engine image were upgraded
  from 1.11.1 to 1.12.1. The Helm pre-upgrade check passed. One healthy volume
  was used as a live-upgrade canary, then the remaining attached volumes were
  upgraded serially. The final inventory was 38 attached healthy volumes and
  two intentionally detached workspace volumes, all on the 1.12.1 engine.
- A Ready Longhorn system backup covering all 40 volumes and a fresh etcd
  snapshot were verified before the Kubernetes change. The final etcd snapshot
  had revision 97697615 and SHA-256
  `28f31e210244cf9b6d8123b402e89710488f541a8e9bc4f03db34d582f9f0114`.
- `talosctl upgrade-k8s --dry-run` found no removed component flags or API
  versions. The real upgrade then moved API server, controller manager,
  scheduler, and kubelet from 1.35.4 to 1.36.3.

Post-upgrade checks showed all three nodes Ready on Talos 1.13.10 and
Kubernetes 1.36.3, the API readiness endpoint passing, Cilium healthy with all
cluster Pods managed, all Flux Kustomizations and HelmReleases Ready, no
unavailable Deployments or StatefulSets, Longhorn healthy, and every
CloudNativePG primary serving SQL with two streaming replicas. Static Pod,
CSI registration, and volume-mount warnings seen during kubelet restarts were
transient and had cleared at the final observation point.

### Stage 3: Talos/Kubernetes 1.37

Only after a stable observation period on 1.36, repeat the same process for
the Talos release supporting Kubernetes 1.37, then upgrade Kubernetes from
1.36 to the selected 1.37 patch. Do not combine the two Kubernetes minor
transitions into one maintenance action.

### Stage 4: clients and remaining charts

Keep Renovate PR #36 open while planning. The kubectl 1.37 client becomes
version-skew compatible once all reachable API servers are at least 1.36, but
prefer merging it after the 1.37 control plane is stable unless an earlier
client is required for validation. Process remaining workload chart updates
only after the platform baseline is green, so failures retain a narrow cause.

## Per-stage evidence

Record the exact before/after versions, nodes touched, commands used, etcd and
workload backup evidence, drain and uncordon results, health checks, Flux
status, and rollback decision point. A stage is complete only when repository
pins, generated configuration, and live state match and the cluster has
returned to steady state.

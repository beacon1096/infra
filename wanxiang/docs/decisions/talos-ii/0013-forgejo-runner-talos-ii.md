# ADR talos-ii/0013 — Forgejo Actions runner on talos-ii (DinD, hostNetwork)

**Scope:** talos-ii. Replaces the talos-i runner (swarm-01); not
deployed on talos-i.
**Status:** accepted
**Date:** 2026-05-05

## Context

The Forgejo Actions runner (the CI executor for `nix-fleet` and any
future workflow on `git.beaco.works`) had been running on talos-i
(swarm-01 repo, `kubernetes/apps/development/forgejo-runner/`). Two
forces converged to require its move to talos-ii:

1. **talos-i is being repositioned offsite as observability + backup
   only**, per [shared/0003](../shared/0003-talos-i-positioning.md).
   The post-move home is residential, no public IPv4, tailnet-only
   inbound. CI workloads (which need fast, low-latency reach to
   `forgejo` / `attic` / `zot` on talos-ii) don't belong on the
   secondary cluster anymore. The cleanest landing is to **stop
   crossing clusters at all** — keep the runner on the same cluster
   as Forgejo, attic, and the in-cluster registry.
2. **The original CI failure** that motivated this work was a sandboxed
   Go module fetcher repeatedly timing out because Nix fixed-output
   builders do not inherit the runner Pod's egress environment.

This ADR is the talos-ii-side landing of those two threads. The
implementation is also the first per-namespace consumer of the
separately managed upstream network policy.

Sub-decisions to nail down:

1. Helm chart shape (DinD vs. host-mode vs. Kubernetes-native).
2. Why `hostNetwork: true` rather than the chart-default PodCIDR
   shape.
3. Image registry + tag pinning under the LAN zot pull-through
   cache (Phase 1).
4. Cluster-local Service-name targets vs. swarm-01's tailnet
   hostnames.
5. Phase 1 / Phase 2 split for the dockerd registry mirror
   (LAN zot → in-cluster zot).
6. Per-cluster scoping: explicitly `[talos-ii]` only, not
   `[both]`.

## Decision

### 1. wrenix `forgejo-runner` chart 0.7.6, DinD shape

Deploy via the wrenix `forgejo-runner` Helm chart 0.7.6, fetched
from `oci://codeberg.org/wrenix/helm-charts/forgejo-runner`. Chart
shape: a single Deployment with two long-running containers
(`act_runner` + privileged `dockerd` sidecar) plus the chart's
one-shot `forgejo-runner-init-config` Job. `replicaCount: 1`,
`runner.config.file.runner.capacity: 3`. Namespace
`forgejo-runner` carries all three PSA labels at `privileged`.

DinD is the chosen runtime over rootless docker / Sysbox /
Kubernetes-native runners because it is **forward-compatible** with
the workload patterns we expect to grow into: `container:` /
`services:` / `uses: docker://...` workflow steps, devcontainer-
style CI, future GitLab migrations. The cost — privileged dind
container — is accepted as a CI sandbox by design (this namespace
hosts no other workloads).

The `runner` container also runs privileged in chart 0.7.6 (the
chart's `securityContext.privileged: true` is shared by both
containers). Hardening it to non-root + drop privileged is a
follow-up commit, not v1; the chart's startup ordering depends on
root for `nc -z 127.0.0.1 2376` against the dind socket and we
chose not to risk breaking that on the same commit as the cluster
move.

### 2. `hostNetwork: true` — upstream network compatibility

Validation showed that the default PodCIDR datapath and the runner's
container-environment propagation did not satisfy the cluster upstream
network contract. Detailed packet-path findings are archived in the
private infrastructure repository.

The runner Pod therefore uses `hostNetwork: true`, and spawned build
containers use `runner.container.network: host`. `dnsPolicy:
ClusterFirstWithHostNet` keeps cluster CoreDNS reachable for
`*.svc.cluster.local` resolution. Exact network settings are maintained
separately.

### 3. Image registry + tag pinning via LAN zot (Phase 1)

`act_runner` image: `code.forgejo.org/forgejo/runner:12.7.3`.
`dind` image: `172.16.80.240:5000/library/docker:29.2.1-dind`.
Chart's registration-Job kubectl image: pinned to LAN zot
`172.16.80.240:5000/alpine/kubectl:1.35.3`.

Three tag-pinning facts of note:

- **swarm-01's `-amd64`-suffixed tags do not exist upstream.**
  The talos-i runner had `forgejo/runner:12.7.3-amd64` and
  `library/docker:29.2.1-dind-amd64`. Neither literal tag is
  published — Docker Hub and `code.forgejo.org` both publish
  multi-arch manifest lists at the unsuffixed tag, which resolve
  to amd64 on x86_64 nodes automatically. The unsuffixed tags
  are what we land here. (Spec 003 fold-back T003.)
- **`kubectl` image must be pinned to LAN zot directly**, not
  the chart-default `docker.io/alpine/kubectl:1.35.3`. Talos's
  Spegel `_default` registry mirror catches `docker.io` pulls
  with `resolve` capability and 404s for images not already in
  any node's containerd cache (treated as definitive — no
  fallthrough). The LAN zot proxies docker.io and serves the
  image directly. Same workaround pattern is documented
  separately for other docker.io pulls; this is the spot we hit
  it with the chart's registration Job.
- **Phase 1 vs. Phase 2 (in-cluster zot)** — see §5.

### 4. Cluster-local Service-name targets, no Tailscale hops

The talos-i runner reached Forgejo / attic / zot via three
tailnet hostnames (`forgejo.tail5d550.ts.net`, etc.) wrapped in
ExternalName Services. This whole layer goes away on talos-ii.
The runner registers against and streams logs to:

- `http://forgejo-http.development.svc.cluster.local:3000` —
  Forgejo HTTP API (chart-default Service name is `forgejo-http`,
  not `forgejo`).
- `attic.nix.svc.cluster.local:8080` — attic (Phase 4a).
- `zot.registry.svc.cluster.local:5000` — in-cluster zot
  (Phase 2 only; Phase 1 uses the LAN zot above).

Cluster-local plain HTTP is fine because the traffic stays
inside the Pod / host network namespace. NO_PROXY exempts
`.svc.cluster.local` (and `.svc.cluster.local.` — the trailing-
dot variant, per the attic 2026-04-28 incident — Go's
`net/http/httpproxy` matcher does not normalize trailing dots).
Three vestigial swarm-01 ExternalName Services (`service-forgejo
-egress.yaml`, `-attic-`, `-zot-`) are explicitly NOT carried
across.

### 5. Phase 1 (LAN zot) → Phase 2 (in-cluster zot) split

dockerd's `daemon.json` is mounted from a ConfigMap, with the
mirror URL split into two phases:

- **Phase 1 (this commit chain, today):** `registry-mirrors:
  ["http://172.16.80.240:5000"]`. Anonymous read-only on the LAN
  zot. `insecure-registries` lists the same host because the LAN
  zot serves plain HTTP. dockerd talks only to the configured mirror;
  upstream egress remains the mirror's responsibility.
- **Phase 2 (separate follow-up commit, gated on spec 002 burn-
  in close):** flip to `zot.registry.svc.cluster.local:5000` and
  add a `dockerd-zot-auth` SOPS Secret mounted at
  `/root/.docker/config.json` carrying htpasswd basic auth
  against the in-cluster zot (which requires auth on read paths
  per its accessControl).

The split exists because spec 002's in-cluster zot is still in
its 7-day burn-in window (per ADR 0012 §10); cutting the runner
over to it before the burn-in closes would couple two phase
gates. Phase 2 is a single config-only commit when ready.

dockerd's bridge IP is `10.250.0.1/16` — explicitly outside
both Cilium PodCIDR `10.44.0.0/16` and ServiceCIDR `10.55.0.0/16`,
outside the `172.16.0.0/12` Tailscale subnet umbrella. DinD-internal
traffic remains local to docker0 according to the cluster network policy.

### 6. `[talos-ii]` only — never `[both]`

Per the per-cluster scoping rule (project memory
`feedback_per_cluster_scoping.md`): one workload, one cluster.
This runner replaces, does not duplicate, the talos-i runner.
The talos-i side is decommissioned in two beats: scale to zero
during cutover (preserve the registration row in case of
rollback), then unregister + remove manifests on swarm-01 only
after Story 1 (full nix-fleet matrix) goes green. The swarm-01
cleanup PR is a separate change on a separate repo, not part of
this ADR's commit chain.

## Cross-links

- [shared/0002 — Mesh integration modes for K8s clusters](../shared/0002-mesh-integration-modes.md) — mesh model that makes
  cross-cluster `forgejo`/`attic` reach over tailnet feasible if
  needed; the runner doesn't use it because Forgejo / attic are
  on the same cluster.
- [shared/0003 — talos-i positioning](../shared/0003-talos-i-positioning.md) — driver for moving CI off talos-i.
- Private runner implementation archive — spec, plan, tasks, and fold-back notes.

## Consequences

Positive:

- The runner satisfies the upstream network contract. nix-fleet CI
  succeeds for non-flaky derivations on first attempt.
- Same-cluster reach to Forgejo / attic / in-cluster zot.
  Eliminates three tailnet hops, three ExternalName Services,
  and a per-Service Tailscale proxy Pod.
- The host-network runner and dind-sidecar pattern carries forward
  cleanly to future CI shapes (GitLab / devcontainer-style workloads).

Negative / accepted trade-offs:

- **Privileged dind container** — accepted as a CI sandbox by
  design, namespace-scoped via PSA labels at `privileged`. No
  other workload shares this namespace.
- **`runner` container also privileged** — chart default; runner
  hardening (drop privileged + `runAsUser: 1000`) is deferred to
  a follow-up commit. Plan-stage decision per spec 003 research
  Q4: shipping the postRenderer patch on the same commit as the
  cluster move risked breaking the chart's startup ordering on a
  non-load-bearing security improvement.
- **Single-pod, single-node** — the runner is on whichever
  ms01-* node Cilium scheduled it on. `capacity: 3` means at the 6-job nix-fleet
  matrix peak, 3 jobs queue. Acceptable since nix-fleet is
  human-triggered.
- **QQ / wechat-uos build steps disabled.** During spec 003
  validation, those derivations 502'd at upstream WAF (TLS
  fingerprint anti-bot, not proxy-related). Disabled in
  `nix-fleet`; tracked as a separate workaround item (likely
  uTLS or fingerprint-rotating client). Not a regression vs.
  swarm-01 — same WAFs reject from there too.
- **LAN zot dependency for Phase 1 image pull.** If
  `172.16.80.240:5000` is down at first deploy, the dind sidecar
  can't pull. Phase 2 removes this dependency by moving to in-
  cluster zot. Mitigation today: LAN zot is already a hard
  dependency for talos-ii containerd's mirror config (per ADR
  0012 §1, two-endpoint shape during burn-in).

Detailed upstream network findings and workarounds are archived in
the private infrastructure repository.

Discovered during implementation, recorded for institutional memory:

- **nix sandbox needs `extra-sandbox-paths` for glibc
  getaddrinfo.** Without `/etc/nsswitch.conf` `/etc/hosts`
  `/etc/services` `/etc/protocols` mapped into the fixed-output
  sandbox, glibc can't actually resolve DNS — it falls back to
  numeric-only and times out. The four files are added in the
  workflow's `nix.conf` snippet.
- **attic `api-endpoint` is a global all-clients setting.** When
  set, every client (in-cluster + tailnet + workstation) is
  forced to use the same URL. This can't satisfy the in-cluster
  + tailnet topology with one URL (each path needs its own
  hostname). Fix: unset it, let each client config carry its own
  endpoint URL (commit `748fbad`).
- **Spegel `_default` registry mirror catches docker.io pulls
  with `resolve` capability and 404s for un-cached images.** The
  404 is treated as definitive — no fallthrough to upstream.
  Workarounds: pre-cache via `talosctl image pull`, or pin the
  image registry to LAN zot directly in chart values (the path
  taken for the kubectl image, see §3).
- **`act_runner` v12.7.3 does not propagate `container.envs` to
  spawned containers via `docker run --env`.** Chart's native
  env-injection channel goes into the runner's TOML config but
  doesn't reach build containers. Documented in §2; rationale
  for the `hostNetwork: true` structural fix.
- **swarm-01-era `-amd64`-suffixed image tags do not exist
  upstream.** `library/docker:29.2.1-dind-amd64` and
  `forgejo/runner:12.7.3-amd64` both 404. Multi-arch tags are
  unsuffixed; they resolve correctly on x86_64. (Spec 003
  fold-back T003.)

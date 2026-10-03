# ADR shared/0004 — Site edge and ingress responsibility boundaries

**Scope:** shared — applies to the wanxiang cluster and the self-hosted edge fleet.
**Status:** accepted (2026-10-01)
**Date:** 2026-10-01

## Context

Public entry for wanxiang services was served by three overlapping mechanisms —
Cloudflare Tunnel, Tailscale, and a self-hosted Caddy edge — without a written
statement of which layer owns what. The immediate trigger was CI publish:
pushing large OCI layers to `forgejo.beaco.works` through Cloudflare returned
`502`/`413`/`524`, and Attic pushes returned `502`. The design discussion behind
[spec 009](../../../specs/009-caddy-edge-ingress/spec.md) proposed a clear split.

## Decision

Four layers, each with a single owner:

1. **Kubernetes service ingress = Envoy Gateway** (`envoy-external` /
   `envoy-internal`): `HTTPRoute` → `Service`, in-cluster TLS, HTTP/3, retries.
   This is not replaced.
2. **Site edge = self-hosted Caddy** (NixOS edge nodes): public TLS (ACME
   DNS-01), hostname, reverse proxy to mesh-reachable upstreams,
   WebSocket/HTTP2/HTTP3, health/failover, and entry for devices without a mesh
   client. It does **not** learn Kubernetes routing.
3. **Site interconnect = mesh VPN** (currently Tailscale): L3/L4 transport
   between the edge and the cluster. The edge dials a mesh name and is agnostic
   to how the mesh is implemented.
4. **Name resolution = DNS, doing locality**: public clients resolve
   edge-served hostnames to the edge; in-cluster clients keep a split-horizon
   override (`envoy-internal`) so their traffic stays on the LAN.

Corollaries:

- High-bandwidth names migrate **additively, one hostname at a time**, as the
  constitution's per-service VPS exception; the Cloudflare Tunnel stays the
  default for every other hostname.
- Edge-served names use a **per-node DNS alias plus a service CNAME** (e.g.
  `forgejo`/`nix` → CNAME `cygnus.beaco.works`), so a service can move between
  edge nodes without reserving a single global "edge" name.
- The in-cluster split-horizon is expressed as Talos node
  `machine.network.extraHostEntries` (for containerd/host traffic) and runner
  pod `hostAliases` (for CI). It is deliberate locality, not a Cloudflare
  workaround; removing it would send node pulls to the public edge.

## Consequences

Positive: one certificate-validated endpoint per service; no Cloudflare
body-size limits on the migrated paths; in-cluster traffic stays on the LAN;
the boundary is documented and reviewable.

Limits: each migrated hostname currently depends on a single edge node (a SPOF;
mitigations are a Cloudflare fallback and/or multiple A records); the DNS
cutover is out-of-band (Terraform record + external-dns ownership change) and
needs operator approval; the GitHub read-only mirror shows these commits as
unverified, which is independent of this decision.

Edge topology and host selection stay in `infra-private`; this ADR records only
the boundary.

## References

- [spec 009 — Caddy edge ingress](../../../specs/009-caddy-edge-ingress/spec.md)
- [`docs/platform/mesh-vpn.md`](../../../../docs/platform/mesh-vpn.md)
- [ADR shared/0002 — Mesh integration modes](0002-mesh-integration-modes.md)

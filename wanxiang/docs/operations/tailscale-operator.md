# Tailscale operator — exposing services on the tailnet

The Tailscale Kubernetes operator (`tailscale-operator` Helm chart,
v1.96.5) lets us expose any in-cluster Service onto the tailnet by
adding an annotation. Each exposed Service gets its own per-Service
proxy pod (a StatefulSet `ts-<svc>-<id>-0`) joined to the tailnet as
a discrete Tailscale device. Today this is how cross-cluster
traffic reaches into talos-ii without going through Cloudflare.

## Where it runs

[`kubernetes/apps/network/tailscale/`](../../kubernetes/apps/network/tailscale/)

| file | role |
|---|---|
| `helmrelease.yaml` | the operator chart; cluster-specific network integration is applied outside this public runbook |
| `ocirepository.yaml` | flux OCIRepository pointing at `oci://172.16.80.240:5000/charts/tailscale-operator` (chart pre-pushed to local zot — see below) |
| `proxyclass.yaml` | a `ProxyClass` resource named `proxied` for per-Service proxy pods |
| `kustomization.yaml` | resource list |

OAuth client credentials live in `cluster-secrets` (re-encrypted from
the swarm-01 era; same OAuth client serves both clusters since they
share a tailnet):

```yaml
SECRET_TAILSCALE_OAUTH_CLIENT_ID
SECRET_TAILSCALE_OAUTH_CLIENT_SECRET
```

These are referenced by `${SECRET_TAILSCALE_OAUTH_CLIENT_ID}` /
`${SECRET_TAILSCALE_OAUTH_CLIENT_SECRET}` in the operator's
`oauth.clientId` / `oauth.clientSecret` values.

## Upstream network integration

The operator and its per-Service proxy pods both require the cluster
upstream network policy. Exact endpoints and environment values are
maintained in the private infrastructure repository.

### 1. Operator pod — postRenderer Kustomize patch

The chart does not expose all required operator-container settings, so
the rendered Deployment receives a `postRenderers` Kustomize patch. The
private repository owns the patch values.

### 2. Per-Service proxy pods — `ProxyClass`

The operator spawns a StatefulSet (`ts-<svc>-<id>-0`) per exposed
Service. A referenced `ProxyClass` applies the required network settings
to those pods.

Services that should be exposed on the tailnet must opt in to this
ProxyClass:

```yaml
metadata:
  annotations:
    tailscale.com/expose: "true"
    tailscale.com/hostname: "forgejo"
    tailscale.com/proxy-class: "proxied"
```

Without `proxy-class: proxied`, the per-Service proxy pod misses the
required network settings and may remain in `NeedsLogin`.

The `NO_PROXY` value is maintained with the private network policy.

## Why the chart is on local zot

The official Helm chart source is not reliably reachable from this
cluster, and applying cluster-specific network settings globally to Flux
controllers caused unrelated reconciliation failures.

Workaround: pre-pull and re-push to the LAN zot:

```bash
helm pull tailscale/tailscale-operator --version 1.96.5
helm push tailscale-operator-1.96.5.tgz oci://172.16.80.240:5000/charts --plain-http
```

The `OCIRepository` then references `oci://172.16.80.240:5000/charts/tailscale-operator`
on the LAN. zot is configured plain-HTTP
on `:5000` — the self-referential entry in
[`machine-registries.yaml.j2`](../../templates/config/talos/patches/global/machine-registries.yaml.j2)
tells containerd that.

## Currently exposed services

| service | namespace | tailscale hostname | use |
|---|---|---|---|
| `forgejo-tailscale` | `development` | `forgejo` | the talos-i forgejo-runner (when ported in) needs a non-Cloudflare path back to forgejo for event hooks; also serves `LOCAL_ROOT_URL` for in-cluster callers |

That's the only one for now. As more services need cross-cluster or
remote-laptop reach, follow the same pattern: ClusterIP Service with
the three annotations.

## Adding a new exposed service

1. Create (or edit) the Service. Add:
   ```yaml
   metadata:
     annotations:
       tailscale.com/expose: "true"
       tailscale.com/hostname: "<short-name>"
       tailscale.com/proxy-class: "proxied"
   ```
2. Commit + flux reconcile. The operator notices the annotation and
   spawns a `ts-<svc>-<id>-0` StatefulSet in the `tailscale` namespace.
3. The new device shows up at `tailscale.com/admin/machines` named
   `<short-name>` after ~30 s. Authorize it if your tailnet is
   ACL-restricted.
4. Test: from any tailnet member, `curl http://<short-name>.<tailnet>.ts.net:<port>/...`

## Known issues / caveats

- **DERP relay flakiness**: the `cn-qcloud` DERP region is part of
  Tailscale's official infra but unreliable from inside CN. Control
  plane follows the cluster network policy; data plane
  direct-connection works for hosts
  with public IPs but DERP-relayed connections drop frequently.
  Deferred until we either run our own DERP or tailnet routing
  matures.
- **OAuth client is shared between clusters**: same client ID and
  secret used for talos-ii and talos-i. Don't rotate without
  coordinating both clusters' `cluster-secrets`.
- **Operator control-plane reachability depends on upstream networking**:
  always check the postRenderer is in effect after any `HelmRelease`
  change; exact verification steps live in the private runbook.

## Status as of 2026-04-28

- Operator running, OAuth handshake successful
- ProxyClass `proxied` created, in use by `forgejo-tailscale`
- `forgejo` device visible on the tailnet (control plane), data
  plane subject to DERP flakiness above

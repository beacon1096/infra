# k8s sing-box image — TUN+auto_redirect rebuild plan

**Status:** notes only, **not committed**. Captures the changes
this repo needs to land for swarm ADR
[`shared/0004 — Cluster egress gateway`](../../beacon/swarm/docs/decisions/shared/0004-cluster-egress-gateway.md)
Phase 2 to ship. Created 2026-05-04.

## Why these notes exist

The swarm cluster (talos-ii) is migrating from "every app sets
`HTTPS_PROXY=http://sing-box.network.svc.cluster.local:7890`"
to a transparent egress gateway: Cilium egress-gateway routes
matched namespaces' outbound to a sing-box DaemonSet on
`role=egress` nodes; sing-box uses TUN + `auto_redirect: true`
to intercept transparently with no app-side env.

The PoC (Cilium side) and the spike (sing-box auto_redirect on
Talos with Cilium) both passed. Spike findings recorded in the
swarm ADR (link above). The remaining work to ship Phase 2 is
the image rebuild — which lives in **this** repo, hence these
notes.

## What needs to change in this repo

### 1. `modules/common/sing-box.nix` — make inbounds platform-/mode-aware

Currently the shared module unconditionally configures:
- `tun` inbound with `auto_route: true` (host-mode, fine for
  laptops / NixOS hosts where sing-box should own the default
  route)
- `mixed` inbound on `:7890` (HTTP/SOCKS5 forward proxy)

The k8s image needs a different shape:
- `tun` inbound with **`auto_route: true` + `auto_redirect: true`**
  + `route_exclude_address_set: ["geoip-cn"]` so CN-IP traffic
  bypasses sing-box entirely (kernel route, no userspace tax)
- `mixed` inbound on `:7890` **retained** during the
  deprecation cycle. The k8s image therefore has two inbounds
  active concurrently: the transparent `tun` path (primary)
  and the env-based `mixed` path (fallback). Removal of
  `mixed-in` is gated by swarm ADR shared/0004 Phase 4
  ("Workflow patch removal") which requires ≥1 week of
  Phase-3 stability burn-in *and* a per-namespace audit
  confirming no app still uses `HTTP_PROXY` env. As of
  2026-05-04 there are 5 active consumers on talos-ii
  (`flux-system/flux-instance`, `network/tailscale`,
  `collaboration/matrix`, `nix/attic`, `registry/zot`); each
  must be migrated onto a `CiliumEgressGatewayPolicy` before
  `mixed-in` can be dropped, in a follow-up image rebuild.

Two ways to add the conditional:

**(A) specialArgs flag (recommended, minimal diff)**

In `flake.nix`'s `k8s-sing-box-image` package def, extend
`specialArgs`:

```nix
specialArgs = { inherit inputs; k8sTransparentProxy = true; };
```

In `modules/common/sing-box.nix`, accept the flag in the module
function head:

```nix
{ config, lib, pkgs, k8sTransparentProxy ? false, ... }:
```

Then conditionally branch on it in the `inbounds` list:

```nix
inbounds = [ ]
  ++ lib.optionals pkgs.stdenv.isDarwin [ /* darwin DNS */ ]
  ++ (if k8sTransparentProxy then [
       {
         type = "tun";
         tag = "tun-in";
         auto_route = true;
         auto_redirect = true;
         address = [ "172.19.0.1/30" "fdfe:dcba:9876::1/126" ];
         # strict_route = false: lets SO_BINDTODEVICE host
         # services (kubelet → API server, containerd image
         # pulls) bypass sing-box even though the gateway runs
         # in host network. Required for the node not to
         # self-deadlock; see swarm ADR shared/0004 Stage 1b
         # spike result for why this matters.
         strict_route = false;
         # stack = "system" not "gvisor": faster (host kernel
         # L3→L4) and fine for a hostNetwork DaemonSet pod
         # where there is no per-pod isolation to enforce.
         # Host config in non-k8s mode keeps gvisor for the
         # laptop case where stack matters more.
         stack = "system";
         # route_address_set deliberately omitted. With
         # auto_redirect, an explicit empty list matches
         # nothing — i.e. would bypass sing-box for everything.
         # Omitting the field uses the inbound's address CIDR
         # as the implicit capture set, which is what we want.
         #
         # route_exclude_address_set takes IP rule-sets only
         # (geoip-*, never geosite-* — domain rule-sets are
         # resolved per-request via DNS and cannot populate
         # firewall/route rules at install time). CN-domain
         # bypass, if/when wanted, lives in route.rules.
         # geoip-private covers RFC1918 (10/8, 172.16/12,
         # 192.168/16), link-local (169.254/16), loopback (127/8),
         # multicast and reserved — destinations sing-box MUST NOT
         # intercept on a gateway running hostNetwork in K8s.
         # Without it, auto_redirect captured cluster pod CIDR
         # (10.44/16) and service CIDR traffic, sending it to
         # direct outbound and breaking intra-cluster routing on
         # the gateway node — incident 2026-05-04. geoip-cn keeps
         # China-IP destinations on the kernel path for performance.
         route_exclude_address_set = [
           "geoip-private"
           "geoip-cn"
         ];
       }
       # Mixed inbound retained during the deprecation cycle so
       # existing HTTPS_PROXY=...:7890 consumers (flux-instance,
       # tailscale, matrix, attic, zot) keep working until each
       # is migrated to a CiliumEgressGatewayPolicy. Drop this
       # in a follow-up image rebuild after swarm ADR Phase 4
       # burn-in.
       {
         type = "mixed";
         tag = "mixed-in";
         listen = "::";
         listen_port = 7890;
         users = [ ];
         set_system_proxy = false;
       }
     ] else [
       {
         type = "tun";
         tag = "tun-in";
         auto_route = true;
         address = [ "172.19.0.1/30" "fdfe:dcba:9876::1/126" ];
         strict_route = true;
         stack = if pkgs.stdenv.isDarwin then "mixed" else "gvisor";
         route_exclude_address = [ ];
       }
       {
         type = "mixed";
         tag = "mixed-in";
         listen = "::";
         listen_port = 7890;
         users = [ ];
         set_system_proxy = false;
       }
     ]);
```

The `route_exclude_address_set` references the existing pinned
rule-set in the same module (`mkPinnedRuleSet "geoip-cn"`) —
already baked into the k8s image build's closure. Note: only
**IP** rule-sets (`geoip-*`) belong in this field. Domain
rule-sets (`geosite-*`) cannot populate firewall rules at
install time and must be applied via `route.rules` instead.

**TUN address audit** (`172.19.0.1/30`): does not collide with
talos-ii's Cilium pod CIDR (`10.44.0.0/16` per cilium HR
`ipv4NativeRoutingCIDR`), service CIDR (`10.43.0.0/16`), or LAN
VLAN 87 (`172.16.87.0/24`). Audit performed during the Stage 1b
spike on 2026-05-04 — see swarm ADR shared/0004's spike result
section.

**fwmark audit** (`auto_redirect_input_mark = 0x2023`,
`auto_redirect_output_mark = 0x2024`): does not collide with
Cilium's BPF SNAT mask (`0x200/0xf00`). Confirmed during the
Stage 1b spike on 2026-05-04 — same reference.

**(B) separate module file**

If the conditional grows, factor `modules/common/sing-box-k8s.nix`
out and have only the k8s image import it. More files but
simpler logic per file. Defer until the conditional is more
than 1-2 spots.

**Why specialArgs over a proper `options.beacon.singbox.k8sTransparentProxy`
declaration**: a single boolean flag has small enough
"discoverability cost" that a proper option (with description,
default, type, nixos-option introspection) would be more
ceremony than payoff. If a second k8s-mode flag is ever added,
promote both to `options.beacon.singbox.*` together — that's
the natural breakpoint.

### 2. `modules/nixos/sing-box.nix` — host-mode override stays

No change needed for k8s image (it doesn't import this file).
The host-NixOS override (`AmbientCapabilities`, sops template
copy ExecStartPre) is host-only and continues to work.

### 3. `flake.nix` — pass the flag

In `k8s-sing-box-image` (around line 606):

```nix
nixos = nixpkgs.lib.nixosSystem {
  system = "x86_64-linux";
  specialArgs = { inherit inputs; k8sTransparentProxy = true; };
  modules = [ ... ];
};
```

The corresponding `k8s-sing-box-oci` (around line 683) passes
through; no change needed there.

## Build + push

```bash
cd /etc/nixos
nix build .#k8s-sing-box-oci
# Result is a Docker tarball at result/

# Load into a local Docker daemon (if available) and push, or
# use skopeo for direct OCI-to-registry push:
skopeo copy \
  docker-archive:./result \
  docker://172.16.80.240:5000/infrastructure/nix-fleet/sing-box:tproxy-2026-05-04
```

The LAN zot at `172.16.80.240:5000` accepts unauthenticated push
(per `docs/operations/zot-mirror.md` in the swarm repo). Tag
convention: `tproxy-YYYY-MM-DD` until CI takes over (post-Phase
4 in the ADR), then plain dates.

## Verify

After the swarm-side HelmRelease swap to the new image lands,
verify on `ms01-a` (the labeled egress node).

The image does **not** bundle `nft` (we keep the rootfs
minimal); inspect from a node-debug pod via `nsenter` against
the sing-box pod's PID, or via `kubectl debug node/`:

```bash
# nft rules generated by sing-box auto_redirect
kubectl debug node/ms01-a -it --image=nicolaka/netshoot \
  -- chroot /host nft list ruleset

# ip rules: sing-box adds 9000-9002 (observed during the
# Stage 1b spike on ms01-a, 2026-05-04) + a 32768 fallback
# rule. Upstream docs only document 9000 as the start index;
# the 9001/9002 follow empirically. The 32768 rule was added
# in sing-box 1.12.18; the image currently builds against
# sing-box 1.13.5 (binary path:
# /nix/store/<hash>-sing-box-1.13.5/bin/sing-box), so the
# assertion holds. Re-check this if downgrading.
kubectl debug node/ms01-a -it --image=nicolaka/netshoot \
  -- chroot /host ip rule list
kubectl debug node/ms01-a -it --image=nicolaka/netshoot \
  -- chroot /host ip route show table 2022

# fwmark test: a Cilium-egressed pod's traffic should now hit
# TUN (visible via sing-box's own logs as inbound/tun
# redirect connection events)
kubectl -n network logs ds/sing-box -c app | grep 'tun-in.*redirect'
```

Alternative if `nft` bundling is preferred (so the sing-box
container itself can introspect its rules): add
`environment.systemPackages = [ pkgs.nftables ]` to the k8s
NixOS config inside `flake.nix`'s `k8s-sing-box-image`. ~5 MB
closure cost; weighed against the convenience of `kubectl
exec`-able introspection. Defer unless we need it routinely.

## What this does NOT change

- **Host NixOS sing-box behavior**: `auto_route: true`, mixed
  inbound on :7890 — completely unchanged. Operators on laptops
  / NixOS hosts continue to use sing-box exactly as before.
- **darwin sing-box**: also unchanged. The `k8sTransparentProxy`
  flag is only set in `flake.nix`'s `k8s-sing-box-image` build
  (which targets `x86_64-linux`); the darwin host import path
  defaults the flag to `false` and never sees the new branch.
  The module body itself isn't gated on `pkgs.stdenv.isLinux`
  for the k8s branch — it relies on the flag-set discipline at
  the build sites. If a future failure mode is "darwin
  accidentally took the k8s path", harden by gating the
  conditional on `pkgs.stdenv.isLinux && k8sTransparentProxy`.
- **Rule-set definitions**: existing `geoip-cn`, `geosite-cn`,
  etc. stay; the k8s image just uses them differently.

## Related

- swarm ADR shared/0002 (mesh integration, accepted)
- swarm ADR shared/0003 (talos-i positioning, accepted)
- swarm ADR shared/0004 (this work) — read its
  "Stage 1b spike result" section before editing here. The
  findings (e.g. `auto_route` is a hard prerequisite for
  `auto_redirect`, plus the fwmark and CIDR audit values)
  inform the exact field names and values above.

## Stage 1c TBD (later)

fakeip migration is deferred to a future iteration once the
auto_redirect path is stable. When it's time:

- Add `experimental.cache_file: { enabled: true, path: ..., store_fakeip: true }`
- Add a fakeip DNS server to `dns.servers`
- Add DNS rules to direct non-CN queries through fakeip server
- May involve another image rebuild + bump

Don't bundle this into the Phase 2 first cut.

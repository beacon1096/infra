# Mesh overlay DNS: provider abstraction & TUN-mode spike

Status: **scoping / to-be-picked-up.** This is a design note + test plan, not a
merged change. Hand to an agent when there's time.

## Why this exists

Today the laptop (`msi-claw`) reaches Tailnet services (e.g.
`browser.tail5d550.ts.net:3000`, `steel.tail5d550.ts.net:3000`) through a
Tailscale-specific arrangement. We want the option to migrate the overlay to a
fully self-hosted mesh (NetBird or similar) later, so the goal is to understand
where Tailscale is load-bearing and carve a *good-enough* seam — **not** a
perfect abstraction.

### Current architecture (and its history)

- **Invariant:** sing-box is the sole kernel TUN / route / DNS owner on the host
  (`modules/nixos/tailscale-userspace.nix` sets
  `beacoworks.sing-box.useSystemTailscale = true`). This exists so the
  China-egress proxy has unambiguous control of routing; a second overlay TUN
  writing default routes would conflict.
- To keep that invariant, system `tailscaled` runs **userspace** with
  `--tun=userspace-networking` + `--socks5-server=127.0.0.1:1055`
  (`--accept-dns=false`). sing-box has a `socks` outbound `tailscale` dialing
  that proxy, and routes the Tailnet CGNAT CIDR + `ts.net` suffix into it
  (`modules/common/sing-box.nix`, guarded by `enableTailscaleRouting` +
  `useSystemTailscale`).
- **MagicDNS trick:** sing-box sends `*.tail5d550.ts.net` queries to server
  `dns_ts` = `100.100.100.100` **via the `tailscale` SOCKS outbound**; userspace
  tailscaled answers MagicDNS internally. See `dns_ts` /
  `dns_tailscale_socks` / the `tails_suffix` route rule in `sing-box.nix`.

### Vestigial history to be aware of

- The `k8sTransparentProxy` branch in `modules/common/sing-box.nix`
  (~L380–465) is the **Talos-cluster egress-gateway shape**. That deployment
  was abandoned — Cilium's egress-gateway custom options couldn't achieve the
  intended behaviour, and egress was moved to a dedicated box running
  **sing-box + OSPF**. The branch is now only reached by the
  `k8s-sing-box-image` build target in `flake.nix:932` (passes
  `k8sTransparentProxy = true`), i.e. **live-but-buildable dead code** serving a
  retired deployment. Decide whether to retire the flake target too.
- The `!useSystemTailscale` path (sing-box's **native** `tailscale` endpoint,
  `type = "tailscale"` / `ts-ep`) is the built-in integration we intend to move
  *away* from. Under the abstraction it collapses to "always userspace-SOCKS"
  and can be dropped.

## Key finding: name-resolution does NOT abstract cleanly

Transport/routing is symmetric across providers (both do SOCKS5, by IP). Name
resolution is not, because MagicDNS is bundled into how Tailscale exposes its
userspace proxy:

- **Tailscale userspace-SOCKS bundles MagicDNS.** Verified on `msi-claw`:
  `curl -x socks5h://127.0.0.1:1055 http://steel.tail5d550.ts.net:3000/ui`
  → HTTP 200 (proxy-side DNS resolves the Tailnet name). Pure-IP
  `http://100.81.108.9:3000/ui` via the same SOCKS also 200.
- **NetBird netstack-SOCKS drops DNS entirely.** Official: in netstack mode
  "The DNS feature is not supported. You can reach the peers by IP address
  only." (`NB_USE_NETSTACK_MODE`, `NB_SOCKS5_LISTENER_PORT` default 1080, binds
  127.0.0.1). NetBird's name resolution normally rides a local DNS proxy
  (`127.0.0.1:53`, fallback `127.0.0.153`, override `NB_DNS_RESOLVER_ADDRESS`) +
  systemd-resolved split-DNS — which netstack mode disables.
  - Sources: https://docs.netbird.io/use-cases/cloud/netbird-on-faas ,
    https://deepwiki.com/netbirdio/netbird/5.4-dns-resolution-system

**Implication:** the pluggable three-tuple splits into two layers —
`transport` (socks addr/port, provider-neutral) and `resolver`
(**provider-specific**: TS = `100.100.100.100`; NetBird-netstack = a real
central nameserver IP, or `null` = degrade to IP-only). We accept an imperfect
seam here for now.

### Known host bug (in scope to fix)

`getent hosts steel.tail5d550.ts.net` fails (exit 2) even though socks5h
resolves it — the system libc path is not reaching sing-box's suffix
resolution, only the SOCKS proxy resolves. This is the direct reason Firefox
can't open `*.tail5d550.ts.net:3000`. Root-cause and fix the host DNS path so
plain hostname resolution works system-wide.

## Test objectives

1. **Fix current host DNS (priority).** Make `getent hosts
   steel.tail5d550.ts.net` and browser hostname access work on `msi-claw`
   without breaking the China-egress routing. Compare against known-good targets
   `steel.tail5d550.ts.net:3000` / `100.81.108.9:3000/ui` and
   `browser.tail5d550.ts.net:3000`.
2. **Tailscale TUN-mode spike.** As an experiment, try running Tailscale in
   kernel-TUN mode (`--accept-dns=true --accept-routes`, its own `tailscale0`),
   letting Tailscale own MagicDNS via systemd-resolved, and have sing-box merely
   *avoid* the Tailnet CIDR/suffix (route → direct into `tailscale0`). Confirm
   whether this coexists with the sing-box egress TUN without route conflict
   (Tailscale must advertise only 100.64/10, not a default route). This is the
   shape a future NetBird kernel-TUN migration would also use. `msi-claw` is the
   test bed (passwordless sudo); it's fine to break/revert here.
3. **Factor the seam (optional, good-enough).** Rename the Tailscale-specific
   options to provider-neutral `beacoworks.mesh.*`:
   - `enableTailscaleRouting`/`useSystemTailscale` → `mesh.enable`/`mesh.mode`
   - `tailscaleSocks{Server,Port}` → `mesh.socks.{addr,port}`
   - `tailscaleSocksDnsServer` → `mesh.socksDnsServer`
   - `dns_ts` `100.100.100.100` → `mesh.resolver`
   - `tails_suffix` / `"ts.net"` / Tailnet CIDR → `mesh.suffixes` / `mesh.cidrs`
   - `modules/nixos/tailscale-userspace.nix` → `mesh-provider/tailscale.nix`,
     leave a `mesh-provider/netbird.nix` stub (resolver field = TODO, pending a
     self-hosted-instance test of whether a central NetBird nameserver can serve
     per-peer A records — peer names are resolved client-side by default).
4. **Cleanup call.** Decide whether to retire the `k8sTransparentProxy` branch +
   `k8s-sing-box-image` flake target, and delete the `!useSystemTailscale`
   native-Tailscale path.

## Deferred

Whether NetBird eventually adds DNS to netstack mode, or whether we switch to
kernel-TUN, is a later decision. Do not block the seam on a perfect abstraction.

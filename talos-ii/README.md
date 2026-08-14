# talos-ii

This directory records the second independent environment collected during onboarding. The owner refers to its gateway as `UDR-Pro`; the live device identifies itself as a `UniFi Dream Machine Pro (UDM-Pro)`. Keep that naming discrepancy visible until the physical model is confirmed.

## Observation

- Observation date: 2026-08-14.
- The source Talos configuration is `swarm/talos/talconfig.yaml`; the live Talos client context is the runtime-mounted `kubernetes` context.
- The UDM-Pro was queried over SSH as root using read-only commands. Generated dnsmasq and FRR state was read only to identify current networks and routing.
- The cluster was queried with `talosctl` and `kubectl`; no Talos, Kubernetes, UDM-Pro, or routing change was made.
- No kubeconfig, Talos client config, private key, token, serial number, MAC address, or raw device export is stored here.

## Topology

The gateway is designed as a standalone cluster router: it may uplink to a home network, sit below another cluster network, or be connected directly to an optical modem. At observation time its active upstream-facing interface was `eth8` on `172.16.20.216/24`. Its current public-route lookup went through the OSPF peer `172.16.80.240` on `br0`, which is the observed in-place topology rather than proof of the intended final uplink.

The UDM-Pro exposes the Talos VLAN on `br87` / `172.16.87.0/24`. The Talos cluster uses a bonded pair on each MS-01, VLAN 87, API VIP `172.16.87.1`, and gateway `172.16.87.254`.

## Current cluster state

All three control-plane members were reachable and `Ready`: `ms01-a` (`172.16.87.201`), `ms01-b` (`172.16.87.202`), and `ms01-c` (`172.16.87.203`). `ms01-c` was also `SchedulingDisabled`, so it is ready but cordoned. The cluster API and Kubernetes versions were `v1.35.4`; Talos was `v1.12.7` on all three nodes.

The live user workload groups included LiteLLM and SearXNG; Element, Firefox Sync, Matrix, and Syncthing; Coder, Forgejo, Kasm Browser, Multica, n8n, Paseo Relay, and Steel Browser; Authentik and Vaultwarden; Attic; Zot; Cloudflare DNS/tunnel, Envoy, k8s-gateway, and Tailscale endpoints; OpenStatus; and Longhorn storage. Cilium, CoreDNS, Spegel, and the control-plane components were also running. One old `default/node-debugger` pod was `Error`; this was the only non-Running/non-Completed pod in the bounded check.

See [`inventory.yaml`](./inventory.yaml) for the structured, non-secret record and the follow-up items.

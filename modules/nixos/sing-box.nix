# sing-box NixOS service binding
#
# The sing-box configuration (outbounds, DNS, routes, secrets) is defined
# in modules/common/sing-box.nix (shared with darwin).
#
# On NixOS, the upstream nixpkgs module provides services.sing-box but
# expects settings with `_secret` attrs for secret handling.  We use
# sops.templates instead (renders the entire JSON with secrets injected),
# so we override the systemd ExecStartPre to copy the rendered config
# into the runtime directory where sing-box expects it.
{ config, pkgs, lib, ... }:

let
  # auto_redirect / auto_route leave nftables tables, ip rules, and a
  # routing table (default 2022) on the host. On graceful shutdown
  # systemd runs this so we don't leave orphaned redirect state when
  # the service stops. The corresponding init container in the K8s
  # HelmRelease covers the force-delete (SIGKILL) path where systemd
  # never gets to run ExecStopPost. Safe to run unconditionally:
  # on hosts without auto_redirect / auto_route, no matching tables
  # or rules exist and the script is a quick no-op. See
  # docs/k8s-sing-box-egress-gateway.md and the swarm-side
  # operations/sing-box-egress-gateway-poc-2026-05-04.md post-mortem
  # for context.
  cleanupScript = pkgs.writeShellScript "sing-box-cleanup" ''
    set +e

    # Best-effort: drop any nftables table sing-box created. auto_route
    # and auto_redirect both create tables under variant names across
    # sing-box versions, so we match by substring.
    ${pkgs.nftables}/bin/nft -j list tables 2>/dev/null \
      | ${pkgs.jq}/bin/jq -r '.nftables[]?.table | "\(.family) \(.name)"' 2>/dev/null \
      | while IFS= read -r entry; do
          case "$entry" in
            *sing-box*|*sing_box*)
              echo "sing-box-k8s-cleanup: nft delete table $entry" >&2
              ${pkgs.nftables}/bin/nft delete table $entry 2>/dev/null
              ;;
          esac
        done

    # Drop ip rules pointing at sing-box's TUN routing table (default
    # 2022). Repeat until none remain since multiple priorities may
    # reference the same table.
    for af in -4 -6; do
      while ${pkgs.iproute2}/bin/ip $af rule del lookup 2022 2>/dev/null; do :; done
    done

    # Flush the routing table itself.
    ${pkgs.iproute2}/bin/ip -4 route flush table 2022 2>/dev/null
    ${pkgs.iproute2}/bin/ip -6 route flush table 2022 2>/dev/null

    exit 0
  '';
in
{
  networking.networkmanager = lib.mkIf (config.services.sing-box.enable && config.networking.networkmanager.enable) {
    # NetworkManager otherwise flushes sing-box's external TUN during activation.
    unmanaged = [ "interface-name:tun0" ];

    # sing-box does not rebuild its TUN routes after every link flap.
    dispatcherScripts = [
      {
        source = pkgs.writeShellScript "restart-sing-box-after-network-up" ''
          tun_ready() {
            ${pkgs.iproute2}/bin/ip -4 address show dev tun0 2>/dev/null \
              | ${pkgs.gnugrep}/bin/grep -q 'inet 172.19.0.1/30' \
              && ${pkgs.iproute2}/bin/ip route show table 2022 \
              | ${pkgs.gnugrep}/bin/grep -q 'dev tun0'
          }

          if [ -n "$1" ] && [ "$1" != "tun0" ] && [ "$2" = "up" ] && ! tun_ready; then
            ${pkgs.systemd}/bin/systemctl restart sing-box.service
            for attempt in {1..20}; do
              if tun_ready; then
                ${pkgs.systemd}/bin/systemctl try-restart nscd.service
                exit 0
              fi
              ${pkgs.coreutils}/bin/sleep 1
            done
            exit 1
          fi
        '';
        type = "basic";
      }
    ];
  };

  networking.firewall = {
    # Open firewall for sing-box dashboard (Clash API / yacd)
    allowedTCPPorts = [ 9091 ];

    # auto_redirect DNATs container TCP into sing-box's local listener.
    extraCommands = lib.mkIf (config.networking.firewall.backend == "iptables") ''
      ip46tables -A nixos-fw -i docker0 -p tcp -m conntrack --ctstate DNAT -j nixos-fw-accept
      ip46tables -A nixos-fw -i 'br+' -p tcp -m conntrack --ctstate DNAT -j nixos-fw-accept
    '';

    extraInputRules = lib.mkIf (config.networking.firewall.backend == "nftables") ''
      iifname "docker0" meta l4proto tcp ct status dnat accept
      iifname "br-*" meta l4proto tcp ct status dnat accept
    '';
  };

  # Override common configuration to listen on all interfaces for NixOS hosts
  # (Allows accessing the dashboard from other machines like your Mac)
  services.sing-box.settings.experimental.clash_api.external_controller = "0.0.0.0:9091";

  systemd.services.sing-box = {
    # sops secrets are rendered during system activation (not a systemd service),
    # so the template file is already present when sing-box starts.
    # sing-box needs TUN device access and NET_ADMIN for transparent proxy
    serviceConfig = {
      AmbientCapabilities = [ "CAP_NET_ADMIN" "CAP_NET_BIND_SERVICE" ];
      ExecStartPre = let
        script = pkgs.writeShellScript "sing-box-sops-config" ''
          install -m 0600 -o sing-box -g sing-box \
            ${config.sops.templates."sing-box-config.json".path} \
            /run/sing-box/config.json
        '';
      in lib.mkForce [ "+${script}" ];
      ExecStopPost = [ "+${cleanupScript}" ];
    };
  };
}

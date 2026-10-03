{ config, lib, pkgs, ... }:

let
  cfg = config.services.tailscale.userspace;
  stateDir = "/var/lib/tailscale-userspace";
  startScript = pkgs.writeShellScript "tailscaled-userspace-start" ''
    /usr/bin/install -d -m 700 -o root -g wheel ${stateDir}
    exec ${lib.getExe' config.services.tailscale.package "tailscaled"} \
      --tun=userspace-networking \
      --state=${stateDir}/tailscaled.state \
      --statedir=${stateDir} \
      --socket=/var/run/tailscaled.socket \
      --port=41641 \
      --socks5-server=127.0.0.1:1055 \
      --outbound-http-proxy-listen=127.0.0.1:1056
  '';
in
{
  options.services.tailscale.userspace = {
    enable = lib.mkEnableOption "userspace Tailscale with loopback SOCKS and HTTP proxies";
    mtu = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      description = "Optional Tailscale userspace MTU override.";
    };
    resolverAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Local DNS resolver that handles mesh names for the userspace proxy.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.tailscale = {
      enable = true;
      overrideLocalDns = false;
    };

    launchd.daemons.tailscaled = {
      command = lib.mkForce (toString startScript);
      environment = lib.optionalAttrs (cfg.mtu != null) {
        TS_DEBUG_MTU = toString cfg.mtu;
      };
      serviceConfig = {
        KeepAlive = true;
        StandardOutPath = "/var/log/tailscaled.log";
        StandardErrorPath = "/var/log/tailscaled.log";
      };
    };

    environment.etc."resolver/ts.net".text = lib.mkForce "nameserver ${cfg.resolverAddress}\n";
  };
}

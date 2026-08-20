# System tailscaled userspace integration for local workstations.
{ ... }:

{
  # Keep sing-box as the only kernel TUN/route owner. System tailscaled runs in
  # userspace mode so we retain the Tailscale CLI/debug tools without installing
  # tailscale0, DNS, or subnet routes into the host network stack.
  beacoworks.sing-box.useSystemTailscale = true;

  services.tailscale = {
    enable = true;
    interfaceName = "userspace-networking";
    openFirewall = true;
    extraDaemonFlags = [
      "--socks5-server=127.0.0.1:1055"
      "--outbound-http-proxy-listen=127.0.0.1:1056"
    ];
    extraSetFlags = [
      "--accept-dns=false"
      "--accept-routes=true"
    ];
  };
}

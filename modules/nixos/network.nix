# Network — NetworkManager + firewall
{ lib, ... }:

{
  networking.networkmanager.enable = true;

  # Firewall — enabled by default, open ports as needed per-host
  networking.firewall = {
    enable = true;
    # sing-box mixed inbound (HTTP/SOCKS5 proxy for LAN devices)
    allowedTCPPorts = [ 7890 ];
    allowedUDPPorts = [ ];
  };

  # mDNS for local network discovery
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };
}

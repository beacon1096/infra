# beacon-mac-mini-m4 — machine-specific system configuration
{ lib, ... }:

{
  imports = [
    ../common/configuration.nix
    ../../../modules/darwin/comin.nix
    ../../../modules/darwin/forgejo-runner.nix
  ];

  networking.hostName = "beacon-mac-mini-m4";
  networking.computerName = "beacon-mac-mini-m4";
  networking.localHostName = "beacon-mac-mini-m4";
  system.activationScripts.postActivation.text = ''
    /usr/bin/sed -i "" \
      -e '/forgejo\.beaco\.works/d' \
      -e '/nix\.beaco\.works/d' \
      /etc/hosts
    printf '%s\n' \
      '100.126.205.111 forgejo.beaco.works nix.beaco.works' \
      'fd7a:115c:a1e0::5832:cd70 forgejo.beaco.works nix.beaco.works' \
      >> /etc/hosts
    /usr/bin/dscacheutil -flushcache
  '';

  launchd.daemons.iogpuWiredLimit = {
    serviceConfig = {
      Label = "org.beacon.iogpu-wired-limit";
      ProgramArguments = [
        "/bin/sh"
        "-c"
        "/usr/sbin/sysctl -w iogpu.wired_limit_mb=28672"
      ];
      RunAtLoad = true;
      StandardOutPath = "/var/log/iogpu-wired-limit.log";
      StandardErrorPath = "/var/log/iogpu-wired-limit.log";
    };
  };

  beacoworks.forgejoRunner.enable = true;
  beacoworks.comin.enable = lib.mkDefault false;

  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
}

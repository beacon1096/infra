# microserver-gen10plus — fixed personal device
#
# HPE ProLiant MicroServer Gen10 Plus
# Intel CC150 (8C/16T), 64GB DDR4 ECC, 3× KIOXIA SATA SSD (RAID5)
# Role: local home server, can also be used as desktop with monitor
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  dataFs = "/dev/disk/by-uuid/a81042d9-d4d5-4021-a657-4ec1ec4c337c";
in

{
  imports = [
    ./hardware-configuration.nix
    ./disko.nix
    ../../common/nixos-configuration.nix
    ../../../../modules/nixos/hyprland.nix
    ../../../../modules/nixos/comin.nix
    ../../../../modules/nixos/tpm-ssh.nix
  ];

  networking.hostName = "microserver-gen10plus";

  users.users.beacon.linger = true;
  home-manager.users.beacon.imports = [ ../../../../modules/home/tpm-ssh.nix ];
  systemd.services.nix-daemon.environment.SSH_AUTH_SOCK = "/run/user/1000/ssh-tpm-agent.sock";

  nixpkgs.overlays = [ inputs.nix-cachyos-kernel.overlays.pinned ];
  boot.kernelPackages = pkgs.cachyosKernels.linuxPackages-cachyos-server-lto;
  # CachyOS is built with Clang, while VMware's external Kbuild defaults to gcc.
  boot.extraModulePackages = lib.mkForce [
    (config.boot.kernelPackages.vmware.overrideAttrs (old: {
      makeFlags = (old.makeFlags or [ ]) ++ [ "CC=cc" ];
    }))
  ];

  users.groups.nixremote = { };
  users.users.nixremote = {
    isSystemUser = true;
    group = "nixremote";
    shell = pkgs.bashInteractive;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINyr6d7piXyr3ueYNJ/NFc4Q8IEsAbioAybcsDnc/lvM nix-builder@flint"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJkAqz7fZQZ53hc6A2aTH0SaLkEwTd5cxBB30kWhRhpX nix-builder@cygnus"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAn9tcA6w8tvryTI+iThfvsNPcKAGJNapP7C4BL8kORh nix-builder@courier"
    ];
  };
  nix.settings.trusted-users = [ "nixremote" ];

  # Stage-1 may assemble the RAID5 volume as /dev/md127 first, with /dev/md/data
  # appearing later as a symlink. Mount the btrfs filesystem by UUID so boot does
  # not depend on that md device name.
  fileSystems."/".device = lib.mkForce dataFs;
  fileSystems."/home".device = lib.mkForce dataFs;
  fileSystems."/nix".device = lib.mkForce dataFs;

  # ── Networking ──────────────────────────────────────────────
  # Use systemd-networkd with DHCP on wired NIC
  networking.networkmanager.enable = lib.mkForce false;
  networking.useDHCP = lib.mkForce false;
  systemd.network.enable = true;
  systemd.network.networks."10-eno1" = {
    matchConfig.Name = "eno1";
    networkConfig.DHCP = "yes";
    linkConfig.RequiredForOnline = "routable";
  };
  # Keep CI control, cache, artifact, and registry uploads off Cloudflare.
  networking.hosts."100.126.205.111" = [
    "forgejo.beaco.works"
    "nix.beaco.works"
  ];

  # The userspace SOCKS path drops long registry uploads. Keep sing-box away
  # from the tailnet CIDR and let the kernel Tailscale interface carry CI.
  beacoworks.sing-box = {
    enableTailscaleRouting = lib.mkForce false;
    useSystemTailscale = lib.mkForce false;
    routeExcludeAddress = [ "100.64.0.0/10" ];
  };
  services.tailscale = {
    interfaceName = lib.mkForce "tailscale0";
    extraDaemonFlags = lib.mkForce [ ];
    extraSetFlags = lib.mkForce [
      "--accept-dns=false"
      "--accept-routes=false"
    ];
  };

  # Relay Taichu CI control and cache traffic into the tailnet without
  # terminating TLS; SNI remains visible to the cluster ingress.
  systemd.sockets.forgejo-tailnet-relay = {
    wantedBy = [ "sockets.target" ];
    listenStreams = [ "172.16.20.11:443" ];
  };
  systemd.services.forgejo-tailnet-relay = {
    requires = [ "tailscaled.service" ];
    wants = [ "network-online.target" ];
    after = [
      "network-online.target"
      "tailscaled.service"
    ];
    serviceConfig.ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd 100.126.205.111:443";
  };

  # ── Firmware ────────────────────────────────────────────────
  hardware.enableRedistributableFirmware = true;

  # ── Virtualization ──────────────────────────────────────────
  virtualisation.vmware.host.enable = true;
  virtualisation.docker = {
    enable = true;
    autoPrune.enable = true;
  };

  # Temporary native Outline migration target. The public service remains on Shuttle.
  sops.secrets."outline/secret-key" = {
    sopsFile = ../../../../secrets/personal/outline-migration.yaml;
    key = "SECRET_KEY";
    owner = config.services.outline.user;
  };
  sops.secrets."outline/utils-secret" = {
    sopsFile = ../../../../secrets/personal/outline-migration.yaml;
    key = "UTILS_SECRET";
    owner = config.services.outline.user;
  };
  sops.secrets."outline/oidc-client-secret" = {
    sopsFile = ../../../../secrets/personal/outline-migration.yaml;
    key = "OIDC_CLIENT_SECRET";
    owner = config.services.outline.user;
  };

  services.outline = {
    enable = true;
    publicUrl = "https://docs.beacoworks.xyz";
    port = 25301;
    secretKeyFile = config.sops.secrets."outline/secret-key".path;
    utilsSecretFile = config.sops.secrets."outline/utils-secret".path;
    databaseUrl = "local";
    redisUrl = "local";
    forceHttps = true;
    enableUpdateCheck = true;
    defaultLanguage = "en_US";
    rateLimiter.enable = true;
    storage = {
      storageType = "local";
      localRootDir = "/var/lib/outline/data";
      uploadMaxSize = 262144000;
    };
    oidcAuthentication = {
      clientId = "qTPz2aopLE5BxWqo2aCUHGxECBFsnst2hyrQVtTW";
      clientSecretFile = config.sops.secrets."outline/oidc-client-secret".path;
      authUrl = "https://id.beaco.works/application/o/authorize/";
      tokenUrl = "https://id.beaco.works/application/o/token/";
      userinfoUrl = "https://id.beaco.works/application/o/userinfo/";
      usernameClaim = "preferred_username";
      displayName = "ID @ Beacoworks";
      scopes = [
        "openid"
        "profile"
        "email"
      ];
    };
  };

  # ── Forgejo Actions runner ──────────────────────────────────
  sops.secrets."forgejo/runner/token" = {
    sopsFile = ../../../../secrets/shared/forgejo-runner.yaml;
  };
  sops.templates."forgejo-runner.env".content = ''
    TOKEN=${config.sops.placeholder."forgejo/runner/token"}
  '';

  services.gitea-actions-runner = {
    package = pkgs.forgejo-runner;
    instances.gen10plus = {
      enable = true;
      name = "microserver-gen10plus";
      url = "https://forgejo.beaco.works";
      tokenFile = config.sops.templates."forgejo-runner.env".path;
      labels = [ "nix-builder:host" ];
      hostPackages = [ config.nix.package ] ++ (with pkgs; [
        attic-client
        bash
        coreutils
        curl
        findutils
        gawk
        gitMinimal
        gnugrep
        gnused
        gnutar
        gzip
        jq
        nodejs
        python3
        unzip
        wget
        xz
        zstd
      ]);
      settings = {
        runner = {
          capacity = 1;
          timeout = "12h";
          shutdown_timeout = "30m";
          fetch_timeout = "5m";
        };
        cache = {
          enabled = true;
          port = 30000;
        };
      };
    };
  };
  systemd.services.gitea-runner-gen10plus.serviceConfig.TimeoutStopSec = "31m";

  # ── Sudo ────────────────────────────────────────────────────
  security.sudo.wheelNeedsPassword = lib.mkForce false;

  # ── Sops ────────────────────────────────────────────────────
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  # ── Firewall ────────────────────────────────────────────────
  networking.firewall.allowedTCPPorts = [
    22
    443
    4096
  ];
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 25301 ];

  beacoworks.comin = {
    enable = true;
    remote = {
      url = "https://forgejo.beaco.works/infrastructure/infra.git";
      branch = "prod";
      username = "beacon1096";
    };
    tokenSecret.sopsFile = ../../../../secrets/shared/comin-forgejo-token.yaml;
  };
}

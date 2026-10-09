# Coder-backed general coding agent profile.
{ lib, pkgs, ... }:

let
  multica = pkgs.stdenvNoCC.mkDerivation {
    pname = "multica";
    version = "0.6.0";
    src = pkgs.fetchurl {
      url = "https://github.com/multica-ai/multica/releases/download/v0.6.0/multica-cli-0.6.0-linux-amd64.tar.gz";
      hash = "sha256-eITj5sZ4rEhcryC85MyYNT6SxvWG7I3z3z/ry3yOnls=";
    };
    dontUnpack = true;
    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      tar -xzf $src
      install -m 0755 multica $out/bin/multica
      runHook postInstall
    '';
  };
in
{
  imports = [
    ../common/home.nix
  ];

  # Web IDE for interactive Coder workspaces. nixpkgs' code-server is
  # patchelf'd to the Nix loader, so it runs on the pure-Nix image without
  # nix-ld; the template launches it as a coder_app.
  home.packages = [
    pkgs.code-server
    pkgs.gnupg
    # Ops/troubleshooting tools the minimal image otherwise lacks.
    pkgs.kubernetes-helm
    pkgs.yq-go
    pkgs.gawk
    pkgs.diffutils
    multica
  ];

  programs.git.settings = {
    user = {
      name = lib.mkForce "Agent @ Beacoworks";
      email = lib.mkForce "noreply@beaco.works";
      signingKey = lib.mkForce "/home/coder/.ssh/runtime/id_ed25519";
    };
    commit.gpgsign = lib.mkForce true;
    gpg.format = lib.mkForce "ssh";
    core.editor = lib.mkForce "vim";
  };

  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    settings."*" = {
      ForwardAgent = false;
      AddKeysToAgent = "no";
      Compression = false;
      ServerAliveInterval = 0;
      ServerAliveCountMax = 3;
      HashKnownHosts = false;
      UserKnownHostsFile = "~/.ssh/known_hosts";
      ControlMaster = "no";
      ControlPath = "~/.ssh/master-%r@%n:%p";
      ControlPersist = "no";
    };
    extraConfig = ''
      Host forgejo-agent
        HostName forgejo-ssh.development.svc.cluster.local
        HostKeyAlias forgejo.beaco.works
        User git
        Port 22
        IdentityFile /home/coder/.ssh/runtime/id_ed25519
        UserKnownHostsFile /home/coder/.ssh/known_hosts
        IdentitiesOnly yes
        StrictHostKeyChecking yes

      Host github.com
        User git
        IdentityFile /home/coder/.ssh/runtime/id_ed25519
        UserKnownHostsFile /home/coder/.ssh/known_hosts
        IdentitiesOnly yes
        StrictHostKeyChecking yes

      Host mc5-01
        HostName 172.16.100.201
        HostKeyAlias 172.16.100.201
        User rancher

      Host mc4-01
        HostName 172.16.100.202
        HostKeyAlias 172.16.100.202
        User rancher

      Host mc4-02
        HostName 172.16.100.203
        HostKeyAlias 172.16.100.203
        User rancher

      Host rb5009
        HostName 172.16.100.254
        HostKeyAlias 172.16.100.254
        User admin

      Host m920x
        HostName 172.16.100.250
        HostKeyAlias 100.101.83.77
        User beacon

      Host m920x-probe
        HostName 172.16.100.250
        HostKeyAlias 100.101.83.77
        User agent-prober
        ProxyCommand none
        IdentityFile /home/coder/.ssh/runtime/id_ed25519
        UserKnownHostsFile /home/coder/.ssh/known_hosts
        IdentitiesOnly yes
        StrictHostKeyChecking yes

      Host ms-r1
        HostName 172.16.80.240
        User beacon

      Host ms-r1-probe
        HostName 172.16.80.240
        HostKeyAlias 172.16.80.240
        User agent-prober
        ProxyCommand /bin/tailscale --socket=/tmp/tailscale/tailscaled.sock nc %h %p
        IdentityFile /home/coder/.ssh/runtime/id_ed25519
        UserKnownHostsFile /home/coder/.ssh/known_hosts
        IdentitiesOnly yes
        StrictHostKeyChecking yes

      Host udm-pro
        HostName 172.16.80.254
        User root

      Host ark 107.189.6.180
        HostName 107.189.6.180
        HostKeyAlias ark
        User beacon
        Port 2233

      Host courier 89.208.240.145
        HostName 89.208.240.145
        HostKeyAlias courier
        User beacon
        Port 2233

      Host cygnus 67.230.162.189
        HostName 67.230.162.189
        HostKeyAlias cygnus
        User beacon
        Port 2233

      Host flint 103.118.41.228
        HostName 103.118.41.228
        HostKeyAlias flint
        User beacon
        Port 2233

      Host glacier 1.116.139.81
        HostName 1.116.139.81
        HostKeyAlias glacier
        User beacon
        Port 2233

      Host navi 89.208.253.236
        HostName 89.208.253.236
        HostKeyAlias navi
        User beacon
        Port 2233

      Host octo 23.247.139.23
        HostName 23.247.139.23
        HostKeyAlias octo
        User beacon
        Port 2233

      Host shuttle 89.208.241.145
        HostName 89.208.241.145
        HostKeyAlias shuttle
        User beacon
        Port 2233

      Host speicher 167.179.83.73
        HostName 167.179.83.73
        HostKeyAlias speicher
        User beacon
        Port 2233

      Host ark-probe
        HostName 107.189.6.180
        HostKeyAlias ark
        User agent-prober
        Port 2233

      Host courier-probe
        HostName 89.208.240.145
        HostKeyAlias courier
        User agent-prober
        Port 2233

      Host cygnus-probe
        HostName 67.230.162.189
        HostKeyAlias cygnus
        User agent-prober
        Port 2233

      Host flint-probe
        HostName 103.118.41.228
        HostKeyAlias flint
        User agent-prober
        Port 2233

      Host glacier-probe
        HostName 1.116.139.81
        HostKeyAlias glacier
        User agent-prober
        Port 2233

      Host navi-probe
        HostName 89.208.253.236
        HostKeyAlias navi
        User agent-prober
        Port 2233

      Host octo-probe
        HostName 23.247.139.23
        HostKeyAlias octo
        User agent-prober
        Port 2233

      Host shuttle-probe
        HostName 89.208.241.145
        HostKeyAlias shuttle
        User agent-prober
        Port 2233

      Host speicher-probe
        HostName 167.179.83.73
        HostKeyAlias speicher
        User agent-prober
        Port 2233

      Host ark courier cygnus flint glacier navi octo shuttle speicher 107.189.6.180 89.208.240.145 67.230.162.189 103.118.41.228 1.116.139.81 89.208.253.236 23.247.139.23 89.208.241.145 167.179.83.73
        IdentityFile /home/coder/.ssh/runtime/id_ed25519
        UserKnownHostsFile /home/coder/.ssh/known_hosts
        IdentitiesOnly yes
        StrictHostKeyChecking yes

      Host ark-probe courier-probe cygnus-probe flint-probe glacier-probe navi-probe octo-probe shuttle-probe speicher-probe
        IdentityFile /home/coder/.ssh/runtime/id_ed25519
        UserKnownHostsFile /home/coder/.ssh/known_hosts
        IdentitiesOnly yes
        StrictHostKeyChecking yes

      Host microserver-gen10plus 100.121.229.9
        HostName 100.121.229.9
        HostKeyAlias microserver-gen10plus
        User beacon
        ProxyCommand /bin/tailscale --socket=/tmp/tailscale/tailscaled.sock nc %h %p
        IdentityFile /home/coder/.ssh/runtime/id_ed25519
        UserKnownHostsFile /home/coder/.ssh/known_hosts
        IdentitiesOnly yes
        StrictHostKeyChecking yes

      Host microserver-gen10plus-probe
        HostName 100.121.229.9
        HostKeyAlias microserver-gen10plus
        User agent-prober
        ProxyCommand /bin/tailscale --socket=/tmp/tailscale/tailscaled.sock nc %h %p
        IdentityFile /home/coder/.ssh/runtime/id_ed25519
        UserKnownHostsFile /home/coder/.ssh/known_hosts
        IdentitiesOnly yes
        StrictHostKeyChecking yes

      Host nixbuilder-01-probe
        HostName 172.16.101.31
        HostKeyAlias 172.16.101.31
        User agent-prober
        ProxyCommand /bin/tailscale --socket=/tmp/tailscale/tailscaled.sock nc %h %p
        IdentityFile /home/coder/.ssh/runtime/id_ed25519
        UserKnownHostsFile /home/coder/.ssh/known_hosts
        IdentitiesOnly yes
        StrictHostKeyChecking yes

      Host nixbuilder-02-probe
        HostName 172.16.101.32
        HostKeyAlias 172.16.101.32
        User agent-prober
        ProxyCommand /bin/tailscale --socket=/tmp/tailscale/tailscaled.sock nc %h %p
        IdentityFile /home/coder/.ssh/runtime/id_ed25519
        UserKnownHostsFile /home/coder/.ssh/known_hosts
        IdentitiesOnly yes
        StrictHostKeyChecking yes

      Host nixbuilder-03-probe
        HostName 172.16.101.33
        HostKeyAlias 172.16.101.33
        User agent-prober
        ProxyCommand /bin/tailscale --socket=/tmp/tailscale/tailscaled.sock nc %h %p
        IdentityFile /home/coder/.ssh/runtime/id_ed25519
        UserKnownHostsFile /home/coder/.ssh/known_hosts
        IdentitiesOnly yes
        StrictHostKeyChecking yes

      Host 172.16.100.250
        HostName 172.16.100.250
        HostKeyAlias 100.101.83.77
        User beacon

      # 172.16.100.0/24 (太初 Harvester / RB5009 / m920x) is reachable directly
      # over the runtime's tailnet route; the userspace `tailscale nc` proxy
      # hangs on this path, so disable it for these hosts.
      Host mc5-01 mc4-01 mc4-02 rb5009 m920x 172.16.100.201 172.16.100.202 172.16.100.203 172.16.100.250 172.16.100.254
        ProxyCommand none

      Host mc5-01 mc4-01 mc4-02 rb5009 m920x ms-r1 udm-pro 100.100.250.57 100.101.83.77 172.16.20.* 172.16.80.* 172.16.81.* 172.16.82.* 172.16.83.* 172.16.84.* 172.16.85.* 172.16.86.* 172.16.87.* 172.16.88.* 172.16.89.* 172.16.90.* 172.16.91.* 172.16.92.* 172.16.93.* 172.16.94.* 172.16.95.* 172.16.100.* 172.16.101.* 172.16.102.* 172.16.107.*
        ProxyCommand /bin/tailscale --socket=/tmp/tailscale/tailscaled.sock nc %h %p
        IdentityFile /home/coder/.ssh/runtime/id_ed25519
        UserKnownHostsFile /home/coder/.ssh/known_hosts
        IdentitiesOnly yes
        StrictHostKeyChecking yes

      # Per-identity root aliases for the GitOps runtime. The base aliases
      # above stay on the unprivileged user for humans and read-only agents;
      # GitOps connects through these to the root key granted by
      # modules/nixos/gitops-root-access.nix.
      Host ark-root
        HostName 107.189.6.180
        HostKeyAlias ark
        User root
        Port 2233

      Host courier-root
        HostName 89.208.240.145
        HostKeyAlias courier
        User root
        Port 2233

      Host cygnus-root
        HostName 67.230.162.189
        HostKeyAlias cygnus
        User root
        Port 2233

      Host flint-root
        HostName 103.118.41.228
        HostKeyAlias flint
        User root
        Port 2233

      Host glacier-root
        HostName 1.116.139.81
        HostKeyAlias glacier
        User root
        Port 2233

      Host navi-root
        HostName 89.208.253.236
        HostKeyAlias navi
        User root
        Port 2233

      Host octo-root
        HostName 23.247.139.23
        HostKeyAlias octo
        User root
        Port 2233

      Host shuttle-root
        HostName 89.208.241.145
        HostKeyAlias shuttle
        User root
        Port 2233

      Host speicher-root
        HostName 167.179.83.73
        HostKeyAlias speicher
        User root
        Port 2233

      Host ark-root courier-root cygnus-root flint-root glacier-root navi-root octo-root shuttle-root speicher-root
        IdentityFile /home/coder/.ssh/runtime/id_ed25519
        UserKnownHostsFile /home/coder/.ssh/known_hosts
        IdentitiesOnly yes
        StrictHostKeyChecking yes

      Host m920x-root
        HostName 172.16.100.250
        HostKeyAlias 100.101.83.77
        User root
        ProxyCommand none
        IdentityFile /home/coder/.ssh/runtime/id_ed25519
        UserKnownHostsFile /home/coder/.ssh/known_hosts
        IdentitiesOnly yes
        StrictHostKeyChecking yes

      Host ms-r1-root
        HostName 172.16.80.240
        HostKeyAlias 172.16.80.240
        User root
        ProxyCommand /bin/tailscale --socket=/tmp/tailscale/tailscaled.sock nc %h %p
        IdentityFile /home/coder/.ssh/runtime/id_ed25519
        UserKnownHostsFile /home/coder/.ssh/known_hosts
        IdentitiesOnly yes
        StrictHostKeyChecking yes

      Host microserver-gen10plus-root
        HostName 100.121.229.9
        HostKeyAlias microserver-gen10plus
        User root
        ProxyCommand /bin/tailscale --socket=/tmp/tailscale/tailscaled.sock nc %h %p
        IdentityFile /home/coder/.ssh/runtime/id_ed25519
        UserKnownHostsFile /home/coder/.ssh/known_hosts
        IdentitiesOnly yes
        StrictHostKeyChecking yes
    '';
  };

  home.file.".ssh/known_hosts".text = ''
    forgejo.beaco.works ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDFSbio+wB8pGs+wsuNgwg8qK4sIpYkHafO+00p36aLdHG7lqDvyVkN96L2bgSFtCou2QQKl4cV6+kjdNNzXPn1dzbyoqceG/6kmnUDlUurBzMnkF6ZoaV5CQsmhsPmY1zO7fXACfBMpiXi7+wt9aDvVNb7pneqiyk6yhi49dQ9Uto85DT+mw6o5SiwG7LcnV4FFujIFC5Zy0NHMOnXMMnXgYGEzgTIRSqHuMM6CTRuoW7gY4KKXIAzWlk6ht0riKWWtNZiL9/rZqnMGPB/OYTlFmqiwSo/1TSuLqt1kZ+DWtkwYTEBrv6/iVU27T6IcGPH2tX2XTGYfNVFPy1SAL4SjUoa81Q3RZn6jty7FASlwHcX++4r8ZCgm1ocBp1O2cX5mk6eTKWiyCZBav7P7mRn1J8DUuuPYg0vNG+4MTuakpwn3n/4ZdxBOAGlG+L32IVycA7lToCWXVqmnkaENldrNa5qQ6LLdqo+PxTkX6Xfdg7BfNoudA6UMjfe5wNsYf2Rfjc4Hs3HJev+n6yhKwhTn60bsG/gGq6CVOLsWAKhkMWWhoN3Zq0eWGqY1C4Nl2DKKNKB+DX/d/grt7/RZkHxqtQzqCNQQBfGe+C4HzbdscttN2vAvYBmcNXM/IxvUn3PpSEfOchM99y1w++Irps/4ovnOWJMWkDF0Uv96/wFDQ==
    github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
    172.16.100.201 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDDOM5tvAKArzAxiOKzNAcYuDEpnD2DWAd2BBFblYj0S
    172.16.100.202 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOikROTkMCwuryzx9SGcFvzN36feTZo+9ZGGqL4kRpVe
    172.16.100.203 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHUjlPsAqLLX1D9qw52ND81Ck6qNqP4Z8YnCnBWzyu8y
    172.16.100.254 ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC9FghzoPSPh43lGLv1oqqni0zUKUkEAxWFZxr6OlYzZ/dXztWtIoxB/4vSaNbvpxRqJAHv+ole/3Gj7Wab6cK54eNcDE40c9WkQA3Cf777jJKtDN3dTY/jVWQo+0T5dm/MqoPAqHk/c2yju3WT4O+OcWylrMxc21D6adfHw7BXRWiRKaSK/Ak7I0iFHcbeeZT3K1dZybJDnuHCXRRta06OzhfDtXFDlcTWSQnWMtszyuiJoq/MHgAAWh4g0KwZy03RSoLtc5e5CrBh66bRU4WyyH8rBFcZH9asfB2r9Rp5yoqRSqiJhkkD6h3FgUVrFOxTlOopNujw/kvMzUtnJUcl
    100.101.83.77 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGQk7lTi/uGgeVgnTK1yQiAdOcGAV54pXLb5IJcAlubC
    172.16.80.240 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDzrmAFnGo6OoHvFYnY+9vF27Dr1rK/q4YzsnN1lii2w
    172.16.80.254 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINejKkq7ZWaVSrxE5Txzn3z9FiHuc8KBoWtB0EPSrAMN
    ark ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILyJmhQ1P6k3/RZXmkGcMCttUsrEldsPSYVisrDx8Gb5
    courier ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN3oodZG7PXY2KdM9DAJvyRJQry2SrlBC4FYu7Sbq62E
    cygnus ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHXv7vRzeghi2QcwMAbZEblsDJT4u7tjWD7m+QlAaFhT
    flint ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM3K8KEwf4WATpzkxLEySbIvwMoQf53DiUajPq/5CGMu
    glacier ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMJ52O6VjcgL3tjxbdCgL/7xdCQ5Vj74AHzKrTyf6yaS
    navi ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHXv7vRzeghi2QcwMAbZEblsDJT4u7tjWD7m+QlAaFhT
    octo ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIImnjmhMm9y237qyiOCHy0u/SqAVlNFAHgK6hoqkANQk
    shuttle ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOAiH462EesK5dTUptJNIU6/a9DLg7avt25WzYmLFmlt
    speicher ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPG6A01gvklGhywdvyBYHZ1NnjtAVulbbSKKC2l9hOpM
    microserver-gen10plus ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFwIj0TXFM0sux8NYQgN2mhw/ckVVkhg0CTzxqjml210
    172.16.101.31 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPES6nlhfYix8xFxsDthfzlRvEpb7FdJu1kEo1SvNNTV
    172.16.101.32 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILsez8FJTnMSm8O4puhqiGQAst8JhYadYulzD4/oflPF
    172.16.101.33 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII6SZCsVJAdprACzooahbj3LXDzsE68jBSYzqB4I3wdG
  '';
}

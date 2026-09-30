# beacon-mac-mini-m4 — machine-specific system configuration
{ lib, ... }:

{
  imports = [
    ../common/configuration.nix
    ../../../modules/darwin/omlx
    ../../../modules/darwin/comin.nix
    ../../../modules/darwin/forgejo-runner.nix
  ];

  networking.hostName = "beacon-mac-mini-m4";
  # GitOps + 运维 runtime root SSH access (BEACO-2).
  # macOS has no NixOS-style users.users.root.openssh option, so the key is
  # written by an activation script. The file is rewritten on each activation,
  # so rotation/removal stay declarative. Root key login must be verified on
  # the Mac (the root account may also need `dsenableroot`).
  services.openssh.extraConfig = ''
    PermitRootLogin prohibit-password
  '';

  system.activationScripts.gitopsRootAuthorizedKeys.text = ''
    install -d -m 700 /var/root/.ssh
    printf '%s\n' \
      'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBwxZlOGdS5wy5dWPvAaI7d0dXt9+aGz+p8XTzZG+y6Q multica-gitops-push' \
      > /var/root/.ssh/authorized_keys
    chmod 600 /var/root/.ssh/authorized_keys
  '';
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

  services.omlx = {
    enable = true;
    extraArgs = [
      "--host"
      "0.0.0.0"
      "--port"
      "8000"
    ];
    models = {
      "mlx-community--Qwen3-Embedding-0.6B-4bit-DWQ" = {
        repo = "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ";
        revision = "6c3ae70858513f1a78e9cdca3cae330d9075cd2a";
      };
      "mlx-community--bge-m3-mlx-8bit" = {
        repo = "mlx-community/bge-m3-mlx-8bit";
        revision = "7eca4a1c6ea1a0c5efc37598b369012f3985910f";
      };
      "mlx-community--Qwen3-ASR-0.6B-8bit" = {
        repo = "mlx-community/Qwen3-ASR-0.6B-8bit";
        revision = "89e96d92ba34aca20b3e29fb10cc284097d1219f";
      };
      "mlx-community--whisper-large-v3-turbo-asr-fp16" = {
        repo = "mlx-community/whisper-large-v3-turbo-asr-fp16";
        revision = "624c19c9af5603fa73b83bce14d4aeea96156d18";
      };
      "mlx-community--Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit" = {
        repo = "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit";
        revision = "049ef77fe8816b536193c0c25f9a214d17921282";
      };
    };
  };

  beacoworks.forgejoRunner.enable = true;
  beacoworks.comin.enable = lib.mkDefault false;

  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
}

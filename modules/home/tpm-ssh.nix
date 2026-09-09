# Home-manager configuration for ssh-tpm-agent based SSH.
{ pkgs, ... }:

let
  tpmSshKeygenScript = pkgs.writeShellScriptBin "tpm-ssh-keygen" ''
    set -euo pipefail

    name="''${1:-id_ecdsa}"
    exec ${pkgs.ssh-tpm-agent}/bin/ssh-tpm-keygen -f "$HOME/.ssh/$name"
  '';

  useTpmSshAgentScript = pkgs.writeShellScriptBin "use-tpm-ssh-agent" ''
    set -euo pipefail

    tpm_sock="''${XDG_RUNTIME_DIR:-/run/user/$UID}/ssh-tpm-agent.sock"

    if [[ "''${1:-}" != "--emit" ]]; then
      printf '%s\n' 'Run this to switch the current shell:' >&2
      printf '%s\n' '  eval "$(use-tpm-ssh-agent --emit)"' >&2
      exit 0
    fi

    printf 'export SSH_AUTH_SOCK=%q\n' "$tpm_sock"
    printf 'echo %q\n' "SSH_AUTH_SOCK -> $tpm_sock"
  '';

  useGpgSshAgentScript = pkgs.writeShellScriptBin "use-gpg-ssh-agent" ''
    set -euo pipefail

    ${pkgs.gnupg}/bin/gpgconf --launch gpg-agent >/dev/null 2>&1 || true
    gpg_sock="$(${pkgs.gnupg}/bin/gpgconf --list-dirs agent-ssh-socket 2>/dev/null)"

    if [[ -z "$gpg_sock" ]]; then
      printf '%s\n' 'gpg-agent SSH socket not found' >&2
      exit 1
    fi

    if [[ "''${1:-}" != "--emit" ]]; then
      printf '%s\n' 'Run this to switch the current shell:' >&2
      printf '%s\n' '  eval "$(use-gpg-ssh-agent --emit)"' >&2
      exit 0
    fi

    printf 'export SSH_AUTH_SOCK=%q\n' "$gpg_sock"
    printf 'echo %q\n' "SSH_AUTH_SOCK -> $gpg_sock"
  '';

  showSshAgentScript = pkgs.writeShellScriptBin "show-ssh-agent" ''
    set -euo pipefail

    echo "SSH_AUTH_SOCK=''${SSH_AUTH_SOCK:-}"
    ${pkgs.openssh}/bin/ssh-add -L 2>/dev/null || true
  '';

  startSshTpmAgentScript = pkgs.writeShellScriptBin "start-ssh-tpm-agent" ''
    set -euo pipefail
    exec ${pkgs.systemd}/bin/systemctl --user start ssh-tpm-agent
  '';
in
{
  # Set SSH_AUTH_SOCK at session level so non-interactive processes
  # (IDE terminals, agents, etc.) also default to the TPM agent.
  home.sessionVariables = {
    SSH_AUTH_SOCK = "\${XDG_RUNTIME_DIR}/ssh-tpm-agent.sock";
  };

  # SSH client configuration
  programs.ssh = {
    enable = true;
    includes = [ "~/.ssh/config.d/*" ];

    extraConfig = ''
      IdentityAgent $SSH_AUTH_SOCK

      # Security settings
      ForwardAgent no
      ForwardX11 no
      PermitLocalCommand no
      HashKnownHosts yes
      CheckHostIP yes
    '';

  };

  home.packages = [
    tpmSshKeygenScript
    useTpmSshAgentScript
    useGpgSshAgentScript
    showSshAgentScript
    startSshTpmAgentScript
  ];

  programs.bash.initExtra = ''
    export SSH_AUTH_SOCK_TPM="''${XDG_RUNTIME_DIR:-/run/user/$UID}/ssh-tpm-agent.sock"
    export SSH_AUTH_SOCK="''${SSH_AUTH_SOCK:-$SSH_AUTH_SOCK_TPM}"

    ssh() {
      TERM=xterm-256color command ssh "$@"
    }
  '';

  programs.zsh.initContent = ''
    export SSH_AUTH_SOCK_TPM="''${XDG_RUNTIME_DIR:-/run/user/$UID}/ssh-tpm-agent.sock"
    export SSH_AUTH_SOCK="''${SSH_AUTH_SOCK:-$SSH_AUTH_SOCK_TPM}"

    ssh() {
      TERM=xterm-256color command ssh "$@"
    }
  '';

  home.shellAliases = {
    "use-tpm-ssh-agent" = ''eval "$(${useTpmSshAgentScript}/bin/use-tpm-ssh-agent --emit)"'';
    "use-gpg-ssh-agent" = ''eval "$(${useGpgSshAgentScript}/bin/use-gpg-ssh-agent --emit)"'';
  };

  # systemd user service for ssh-tpm-agent
  systemd.user.services.ssh-tpm-agent = {
    Unit = {
      Description = "SSH TPM Agent";
      After = [ "graphical-session-pre.target" ];
    };

    Service = {
      Type = "simple";
      ExecStart = "${pkgs.ssh-tpm-agent}/bin/ssh-tpm-agent -l %t/ssh-tpm-agent.sock";
      Environment = [
        "TPM2TOOLS_TCTI=tabrmd"
      ];
      Restart = "on-failure";
      RestartSec = "5s";
    };

    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  # Create SSH directory with proper permissions
  home.file.".ssh/README_TPM.md".text = ''
    # TPM-Backed SSH Keys

    This host uses `ssh-tpm-agent` and `ssh-tpm-keygen` for TPM-backed SSH.

    ## Quick Start

    1. Generate a TPM-backed SSH key:
       ```bash
       tpm-ssh-keygen id_ecdsa
       ```

       This creates `~/.ssh/id_ecdsa.tpm` and `~/.ssh/id_ecdsa.pub`.

    2. Restart the agent after adding or rotating keys:
       ```bash
       systemctl --user restart ssh-tpm-agent
       ```

    3. Check what the current agent exposes:
       ```bash
       show-ssh-agent
       ```

    4. Switch to the GPG/YubiKey-backed SSH socket when needed:
       ```bash
       use-gpg-ssh-agent
       ```

       If your current shell does not load aliases, use:
       ```bash
       eval "$(use-gpg-ssh-agent --emit)"
       ```

    5. Switch back to the TPM-backed SSH socket:
       ```bash
       use-tpm-ssh-agent
       ```

       If your current shell does not load aliases, use:
       ```bash
       eval "$(use-tpm-ssh-agent --emit)"
       ```

    6. Print the public key from a TPM private key file:
       ```bash
       ssh-tpm-keygen --print-pubkey ~/.ssh/id_ecdsa.tpm
       ```

    ## Using ssh-tpm-agent

    The ssh-tpm-agent is automatically started. It provides:
    - Secure key storage in TPM hardware
    - Protection against key extraction
    - Hardware-based key operations
    - The default `SSH_AUTH_SOCK` for new shells on this host

    GPG/YubiKey SSH support can coexist, but it is selected explicitly with
    `use-gpg-ssh-agent` so it does not override the TPM socket by default.

    ## Import an existing software key

    If you need to migrate an existing SSH private key into a TPM-backed file:
    ```bash
    ssh-tpm-keygen --import ~/.ssh/id_ecdsa
    ```

    ## Troubleshooting

    - Check TPM status: `systemctl status tpm2-abrmd`
    - Check ssh-tpm-agent: `systemctl --user status ssh-tpm-agent`
    - Check the agent socket: `echo $SSH_AUTH_SOCK`
    - Test TPM: `tpm2_getcap properties-fixed`
  '';
}

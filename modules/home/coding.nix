# Coding and AI tools for Beacon's full desktop Home Manager profile.
{
  pkgs,
  lib,
  inputs,
  config,
  ...
}:

let
  unstablePkgs = import inputs.nixpkgs-unstable {
    system = pkgs.stdenv.hostPlatform.system;
    config = pkgs.config;
  };

  paseoPackage = inputs.paseo.packages.${pkgs.stdenv.hostPlatform.system}.default.override {
    npmDepsHash = "sha256-oXz8hMk+5DlTYK8OndUAjB+RJMDbPqobVGXLFeoH++o=";
  };
  paseoDesktop = inputs.paseo.packages.${pkgs.stdenv.hostPlatform.system}.desktop.override {
    paseo = paseoPackage;
  };

  antigravityCli = pkgs.writeShellScriptBin "antigravity-cli" ''
    exec ${lib.getExe unstablePkgs.antigravity-cli} "$@"
  '';
in
{
  imports = [
    ./coding-agent.nix
  ];

  home.sessionVariables.CODER_SSH_CONFIG_FILE = "${config.home.homeDirectory}/.ssh/config.d/coder";

  programs.ssh.settings."coder-vscode.*".UserKnownHostsFile = "/dev/null";

  home.packages =
    with pkgs;
    [
      unstablePkgs.coder

      # OpenCode desktop launcher (CLI itself comes via programs.opencode)
      opencode-desktop
      # llm-agents.oh-my-opencode

      # Antigravity
    ]
    ++ lib.optionals pkgs.stdenv.isLinux [
      paseoDesktop

      # Terminal
      warp-terminal

      # USB imaging
      usbimager
      woeusb
      writedisk
      unetbootin
      bootiso
      #ventoy-full
      #ventoy-full-qt
      #ventoy-full-gtk

      # 3D Printing
      bambu-studio
      orca-slicer

      # FHS environment for some Linux-specific tools
      antigravity-fhs
      antigravityCli
    ]
    ++ lib.optionals pkgs.stdenv.isDarwin [
      # Darwin-specific launcher
      antigravity
    ];
}

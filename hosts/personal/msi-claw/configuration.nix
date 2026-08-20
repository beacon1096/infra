# MSI Claw 8+ AI — gaming handheld
#
# Intel Core Ultra 7 258V (Lunar Lake) + Intel Arc 130V/140V (xe driver)
# Primary use: Hyprland desktop + Steam Gaming Mode
{
  pkgs,
  lib,
  inputs,
  ...
}:

{
  imports = [
    ./hardware-configuration.nix
    ../common/nixos-configuration.nix
    ../../../modules/nixos/gaming.nix
    ../../../modules/nixos/hyprland.nix
    ../../../modules/nixos/tpm-ssh.nix
    ../../../modules/nixos/tpm-sops.nix
  ];

  networking.hostName = "msi-claw";

  beacoworks.sing-box = {
    routeAddress = [
      "0.0.0.0/1"
      "128.0.0.0/1"
    ];
    routeExcludeAddress = [
      "0.0.0.0/8"
      "10.0.0.0/8"
      "127.0.0.0/8"
      "169.254.0.0/16"
      "192.168.0.0/16"
    ];
    routeExcludeAddressSet = [ "geoip-cn" ];
  };

  services.tailscale.package = inputs."nixpkgs-unstable".legacyPackages.x86_64-linux.tailscale;

  home-manager.users.beacon.wayland.windowManager.hyprland.settings.monitor = lib.mkForce [
    "eDP-1, preferred, auto, 2"
    "desc:Xiaomi Corporation Mi Monitor 5877500072985, 3840x2160@60, auto, 1.5"
    ", preferred, auto, 1"
  ];

  # Work around Valve's current steam-launcher Makefile:
  # it conditionally writes apt source files into host /etc and /usr
  # during `make install`, which breaks inside the Nix sandbox.
  nixpkgs.overlays = [
    inputs.nix-cachyos-kernel.overlays.pinned
    (final: prev: {
      mangohud =
        prev.runCommand "mangohud-disabled"
          {
            outputs = [
              "out"
              "doc"
              "man"
            ];
          }
          ''
            mkdir -p "$out" "$doc" "$man"
          '';

      steam-unwrapped = prev.steam-unwrapped.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          substituteInPlace Makefile \
            --replace-fail \
              'install: install-bin install-docs install-icons install-bootstrap install-desktop install-appdata install-apt-source' \
              'install: install-bin install-docs install-icons install-bootstrap install-desktop install-appdata'
        '';
      });
      steam = prev.steam.override {
        extraPkgs =
          steamPkgs: with steamPkgs; [
            noto-fonts
            noto-fonts-cjk-sans
            noto-fonts-cjk-serif
            noto-fonts-color-emoji
          ];
      };

      gamescope = prev.gamescope.overrideAttrs (old: {
        patches = builtins.filter (
          patch:
          let
            patchPath = toString patch;
          in
          !(lib.hasSuffix "shaders-path.patch" patchPath)
          && !(lib.hasInfix "54e844748029d4874e14d0c086d50092c04c8899" patchPath)
        ) (old.patches or [ ]);
        postPatch =
          lib.replaceStrings
            [ ''substituteInPlace src/reshade_effect_manager.cpp --replace-fail "@out@" "$out"'' ]
            [
              ''
                if [ -e src/Utils/DirHelpers.cpp ]; then
                  substituteInPlace src/Utils/DirHelpers.cpp --replace-fail 'return "/usr";' "return \"$out\";"
                elif grep -q '@out@' src/reshade_effect_manager.cpp; then
                  substituteInPlace src/reshade_effect_manager.cpp --replace-fail "@out@" "$out"
                fi
              ''
            ]
            (old.postPatch or "");
        mesonFlags = (old.mesonFlags or [ ]) ++ [ "-Denable_tests=false" ];
        NIX_CFLAGS_COMPILE = (old.NIX_CFLAGS_COMPILE or "") + " -Wno-error=switch";
      });
      gamescope-wsi = final.gamescope.override {
        enableExecutable = false;
        enableWsi = true;
      };

    })
  ];

  # ── Kernel ──────────────────────────────────────────────────
  # CachyOS handheld variant: BORE scheduler + LTO + Deck-tuned defaults.
  # Built remotely on microserver-gen10plus (see modules/common/remote-builder.nix).
  boot.kernelPackages = pkgs.cachyosKernels.linuxPackages-cachyos-deckify-lto;

  # The deckify kernel ships an in-tree `hid-msi-claw` driver that registers
  # the controller's HID Keyboard interface (USB iface 2) with broader evdev
  # capabilities — BTN_A, KEY_ESC, and BTN_MOUSE all show up on the same node
  # (event10). HHD 4.1.8's Claw plugin instantiates three separate evdev
  # listeners (d_xinput / d_kbd_2 / d_mouse) keyed on those caps, so all three
  # match event10 and compete for EVIOCGRAB on it — the second grab races and
  # returns EBUSY, killing CLAW init and leaving M1/M2 unmapped. The stock
  # path (hid-generic + xpad) keeps capabilities split across interfaces, so
  # blacklisting this driver restores the layout HHD expects.
  boot.blacklistedKernelModules = [ "hid_msi_claw" ];

  nix.settings = {
    substituters = lib.mkBefore [ "https://attic.xuyh0120.win/lantian" ];
    trusted-public-keys = lib.mkBefore [ "lantian:EeAUQ+W+6r7EtwnmYjeVwx5kOGEBpjlBfPlzGlTNvHc=" ];
  };

  # Let the root-owned nix-daemon reuse the user TPM-backed SSH agent for
  # remote builds to microserver-gen10plus.
  systemd.services.nix-daemon.environment.SSH_AUTH_SOCK = "/run/user/1000/ssh-tpm-agent.sock";

  # Lunar Lake uses the xe driver (not i915) — no i915 kernel params needed.
  # Jovian's SteamOS profile injects amdgpu.* / amd_iommu / ttm.* params for the
  # Steam Deck APU — useless on Intel Arc. Override to a clean set; tpm-ssh's
  # tpm_tis.interrupts=0 is re-added explicitly because mkForce wins over its
  # contribution.
  hardware.enableRedistributableFirmware = true;
  boot.kernelParams = lib.mkForce [
    "splash"
    "tpm_tis.interrupts=0"
    # Lunar Lake xe display-engine freeze workaround: cap deep C-states.
    # LNL's C10 + GPU power gating has a known firmware race that manifests as
    # a stripe pattern on the internal eDP followed by a watchdog hard reset.
    # Capping cstate to C6 avoids the race at a small idle-power cost.
    "intel_idle.max_cstate=2"
    # Verbose console + persistent kmsg so the next freeze leaves more context
    # in dmesg / EFI pstore (pstore was empty after the last incident).
    "loglevel=7"
    "printk.devkmsg=on"
    "pstore.backend=efi"
  ];

  # Soft-lockup → panic so the watchdog fires the panic path (which flushes
  # to EFI pstore) instead of the EC just power-cycling us silently.
  boot.kernel.sysctl = {
    "kernel.softlockup_panic" = 1;
    "kernel.hardlockup_panic" = 1;
    "kernel.panic_on_oops" = 1;
    "kernel.panic" = 10; # auto-reboot 10s after panic, after pstore flush
  };

  # Plymouth boot splash
  boot.plymouth.enable = true;

  # ── Intel Arc GPU ───────────────────────────────────────────
  # VA-API hardware video acceleration
  hardware.graphics.extraPackages = with pkgs; [
    intel-media-driver # VA-API (iHD)
    vpl-gpu-rt # Intel Quick Sync Video
    intel-compute-runtime # OpenCL + Level Zero
  ];
  fonts.fontconfig.defaultFonts = {
    sansSerif = [
      "Noto Sans CJK SC"
      "Noto Sans"
      "DejaVu Sans"
    ];
    serif = [
      "Noto Serif CJK SC"
      "Noto Serif"
      "DejaVu Serif"
    ];
    monospace = [
      "Noto Sans Mono CJK SC"
      "JetBrainsMono Nerd Font"
      "DejaVu Sans Mono"
    ];
    emoji = [ "Noto Color Emoji" ];
  };
  home-manager.users.beacon.xdg.configFile."fontconfig/conf.d/52-noto-cjk-sc.conf".text = ''
    <?xml version="1.0"?>
    <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
    <fontconfig>
      <alias binding="strong">
        <family>sans</family>
        <prefer>
          <family>Noto Sans CJK SC</family>
          <family>Noto Sans</family>
          <family>DejaVu Sans</family>
        </prefer>
      </alias>
      <alias binding="strong">
        <family>sans-serif</family>
        <prefer>
          <family>Noto Sans CJK SC</family>
          <family>Noto Sans</family>
          <family>DejaVu Sans</family>
        </prefer>
      </alias>
      <alias binding="strong">
        <family>serif</family>
        <prefer>
          <family>Noto Serif CJK SC</family>
          <family>Noto Serif</family>
          <family>DejaVu Serif</family>
        </prefer>
      </alias>
      <alias binding="strong">
        <family>monospace</family>
        <prefer>
          <family>Noto Sans Mono CJK SC</family>
          <family>JetBrainsMono Nerd Font</family>
          <family>DejaVu Sans Mono</family>
        </prefer>
      </alias>
      <alias binding="strong">
        <family>emoji</family>
        <prefer>
          <family>Noto Color Emoji</family>
        </prefer>
      </alias>
    </fontconfig>
  '';
  environment.sessionVariables.LIBVA_DRIVER_NAME = "iHD";

  # ── Jovian-NixOS (Gaming Mode) ─────────────────────────────
  jovian.steam = {
    enable = true;
    autoStart = true;
    desktopSession = "hyprland";
    user = "beacon";
  };
  jovian.hardware.has.amd.gpu = false;
  jovian.steamos.useSteamOSConfig = lib.mkDefault true;
  # jovian.decky-loader.enable = true; # pnpm insecure
  # Use Jovian's gamescope, not nixpkgs' (avoids conflicting wrapper)
  programs.gamescope.enable = lib.mkForce false;
  systemd.user.services.gamescope-session = {
    restartIfChanged = false;
    serviceConfig.UnsetEnvironment = [ "WAYLAND_DISPLAY" ];
  };
  services.displayManager.sddm.wayland.enable = true;
  services.greetd.enable = lib.mkForce false;
  # ── Power management ────────────────────────────────────────
  # Intel RAPL-based power limits
  services.thermald.enable = true;
  services.power-profiles-daemon.enable = true;

  # ── Audio: WirePlumber headroom workaround ─────────────────
  # The Claw's HDA controller underruns at the default headroom and produces
  # cracks/dropouts. CachyOS-handheld pins headroom=1024 on this sink; mirror
  # that here. Only matches the Lunar Lake-M HDA controller.
  environment.etc."wireplumber/wireplumber.conf.d/51-msi-claw-headroom.conf".text = ''
    monitor.alsa.rules = [
      {
        matches = [ { node.name = "~alsa_output.pci-0000_00_1f.3.*" } ]
        actions = {
          update-props = {
            api.alsa.headroom = 1024
          }
        }
      }
    ]
  '';

  # UCM detects the headphone jack but leaves its mixer channel muted on boot.
  systemd.user.services.msi-claw-headphone-route = {
    description = "Enable MSI Claw headphone mixer channel";
    wantedBy = [ "default.target" ];
    wants = [ "wireplumber.service" ];
    after = [ "wireplumber.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "msi-claw-headphone-route" ''
        if ${pkgs.alsa-utils}/bin/amixer -c 0 cget numid=12 | ${pkgs.gnugrep}/bin/grep -q 'values=on'; then
          ${pkgs.alsa-utils}/bin/amixer -q -c 0 cset numid=2 on
        fi
      '';
    };
  };

  # ── Extra packages ─────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    parsec-bin # Remote desktop / game streaming
  ];

  # ── Handheld Daemon (HHD) ──────────────────────────────────
  # Maps MSI/Xbox button → Steam menu, TDP control, gyro, etc.
  services.handheld-daemon = {
    enable = true;
    user = "beacon";
  };

  # HHD and InputPlumber are competing gamepad-abstraction daemons; both want
  # to EVIOCGRAB+hide the physical X360 controller and present an emulated one.
  # Jovian's SteamOS profile enables InputPlumber by default — on the Claw,
  # InputPlumber wins the race and HHD's CLAW init fails with EBUSY, leaving
  # M1/M2 unmapped. HHD has the better Claw-specific button mapping, so disable
  # InputPlumber and let HHD own the controller.
  services.inputplumber.enable = lib.mkForce false;

  # Shrink HHD's retry window so reconnects after suspend/USB churn recover
  # quickly instead of waiting the default 10s.
  systemd.services.handheld-daemon.serviceConfig.RestartSec = lib.mkForce 2;

  # ── Paseo ───────────────────────────────────────────────────
  services.paseo = {
    enable = true;
    listenAddress = "0.0.0.0";
    openFirewall = false;
    user = "beacon";
    group = "users";
    hostnames = [
      "paseo.beaco.works"
      "msi-claw-1.tail5d550.ts.net"
    ];
    relay = {
      enable = true;
      mode = "remote";
      host = "paseo.beaco.works";
      port = 443;
      useTls = true;
      publicUseTls = true;
    };
    environment.PASEO_RELAY_PUBLIC_ENDPOINT = "paseo.beaco.works:443";
  };
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 6767 ];

  # TPM-backed sops decryption via age-plugin-tpm. Keep this identity path
  # materialized before activation:
  # /var/lib/sops-nix/age-plugin-tpm.txt

  programs.firefox.enable = true;

  # Keep SSH default socket on TPM-backed agent for this host,
  # with explicit helper functions to switch to gpg-agent/YubiKey when needed.
  home-manager.users.beacon.imports = [ ../../../modules/home/tpm-ssh.nix ];
}

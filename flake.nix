{
  description = "Beacon's multi-platform Nix configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    nix-darwin = {
      url = "github:LnL7/nix-darwin/nix-darwin-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nur = {
      url = "github:nix-community/NUR";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-openclaw = {
      url = "github:openclaw/nix-openclaw";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };

    # NixOS hardware quirks (Surface kernel, firmware, etc.)
    nixos-hardware.url = "github:NixOS/nixos-hardware";

    # SteamOS-like gaming mode for NixOS (Steam Deck UI, Gamescope session)
    jovian-nixos = {
      url = "github:Jovian-Experiments/Jovian-NixOS";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-cachyos-kernel.url = "github:xddxdd/nix-cachyos-kernel/release";

    llmAgents.url = "github:numtide/llm-agents.nix";

    codex-desktop-linux.url = "github:ilysenko/codex-desktop-linux";

    comin = {
      url = "github:nlewo/comin";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    paseo = {
      url = "github:getpaseo/paseo/v0.3.1";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nchnroutes-src = {
      url = "github:dndx/nchnroutes";
      flake = false;
    };

    china-ip-list = {
      url = "github:17mon/china_ip_list";
      flake = false;
    };
  };

  outputs = inputs@{ self, nixpkgs, nix-darwin, home-manager, sops-nix, nur, nix-openclaw, nixos-hardware, jovian-nixos, disko, nix-cachyos-kernel, llmAgents, comin, ... }:
  let
    domainVars = {
      SECRET_DOMAIN_01 = "example.invalid";
      SECRET_DOMAIN_02 = "alt.example.invalid";
    };
    # sing-box pinned to upstream nixpkgs-unstable HEAD's package.nix
    # (1.13.11) instead of the rev locked in flake.lock (1.13.9). 1.13.9
    # has an auto_redirect regression: nftablesCreateAddressSets fails
    # with "create ipv4 route exclude address set: file exists" when
    # route_exclude_address_set has 2+ rule-set entries. Reproduced
    # 2026-05-04 on talos-ii ms01-b (the cluster egress gateway pod).
    # Keep this override until our nixpkgs lock catches up past the fix.
    singBoxOverlay = final: prev: {
      sing-box = prev.callPackage ./modules/common/sing-box-package.nix { };
    };
    baseOverlay = {
      nixpkgs.overlays = [
        llmAgents.overlays.shared-nixpkgs
        singBoxOverlay
      ];
    };
    nurOverlay = {
      nixpkgs.overlays = [
        nur.overlays.default
        llmAgents.overlays.shared-nixpkgs
        singBoxOverlay
      ];
    };
    mkClerk = import ./lib/darwin/mk-clerk.nix { inherit inputs nurOverlay domainVars; };
    mkNixosHost =
      {
        system ? "x86_64-linux",
        modules,
      }:
      nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs; } // domainVars;
        modules = [
          nurOverlay
          sops-nix.nixosModules.sops
          disko.nixosModules.disko
        ] ++ modules;
      };

  in
  {
    lib.mkNixosHost = mkNixosHost;

    nixosModules = {
      serverBase = ./hosts/server/common/configuration.nix;
      comin = ./modules/nixos/comin.nix;
    };

    # ──────────────────────────────────────────────────────────
    #  macOS (nix-darwin)
    # ──────────────────────────────────────────────────────────

    darwinConfigurations = {
      # Personal — Beacon's Mac Mini M4
      # Build: darwin-rebuild switch --flake .#beacon-mac-mini-m4
      "beacon-mac-mini-m4" = nix-darwin.lib.darwinSystem {
        system = "aarch64-darwin";
        specialArgs = { inherit inputs; } // domainVars;
        modules = [
          nurOverlay
          sops-nix.darwinModules.sops
          ./hosts/personal/beacon-mac-mini-m4/configuration.nix
          home-manager.darwinModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = { inherit inputs; } // domainVars;
            home-manager.users.beacon = import ./hosts/personal/common/home.nix;
          }
        ];
      };

      # Clerks — AI assistant macOS VMs
      # Build: darwin-rebuild switch --flake .#clerk-<name>
      "clerk" = mkClerk "default";
      "clerk-technician" = mkClerk "technician";
      "clerk-secretary" = mkClerk "secretary";
    };

    # ──────────────────────────────────────────────────────────
    #  NixOS
    # ──────────────────────────────────────────────────────────

    nixosConfigurations = {
      # MSI Claw 8+ AI — gaming handheld (Intel Core Ultra + Arc GPU)
      # Build: nixos-rebuild switch --flake .#msi-claw
      "msi-claw" = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; } // domainVars;
        modules = [
          nurOverlay
          sops-nix.nixosModules.sops
          jovian-nixos.nixosModules.default
          ./hosts/personal/msi-claw/configuration.nix
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = { inherit inputs; } // domainVars;
            home-manager.users.beacon = import ./hosts/personal/common/nixos-home.nix;
          }
        ];
      };

      # Surface Pro 8 — portable workstation
      # Build: nixos-rebuild switch --flake .#surface-pro-8
      "surface-pro-8" = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; } // domainVars;
        modules = [
          nurOverlay
          sops-nix.nixosModules.sops
          disko.nixosModules.disko
          # linux-surface kernel for IPTS touchscreen/pen, cameras
          nixos-hardware.nixosModules.microsoft-surface-pro-intel
          ./hosts/personal/surface-pro-8/configuration.nix
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = { inherit inputs; } // domainVars;
            home-manager.users.beacon = import ./hosts/personal/common/nixos-home.nix;
          }
        ];
      };

      # Surface Book 3 — secondary / spare machine
      # Build: nixos-rebuild switch --flake .#surface-book-3
      "surface-book-3" = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; } // domainVars;
        modules = [
          nurOverlay
          sops-nix.nixosModules.sops
          # TODO: re-enable once linux-surface 6.12 patch set catches up
          # to nixpkgs / nixos-hardware again, or once we have a remote
          # x86 builder for trying patched-kernel updates safely.
          # nixos-hardware.nixosModules.microsoft-surface-common
          ./hosts/personal/surface-book-3/configuration.nix
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = { inherit inputs; } // domainVars;
            home-manager.users.beacon = import ./hosts/personal/common/nixos-home.nix;
          }
        ];
      };

      # ThinkBook Plus G5 Hybrid Station — Windows/NixOS dual-boot workstation
      # Build: nixos-rebuild switch --flake .#thinkbook-plus-hybrid
      "thinkbook-plus-hybrid" = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; } // domainVars;
        modules = [
          nurOverlay
          sops-nix.nixosModules.sops
          ./hosts/personal/thinkbook-plus-hybrid/configuration.nix
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = { inherit inputs; } // domainVars;
            home-manager.users.beacon = import ./hosts/personal/common/nixos-home.nix;
          }
        ];
      };

      # m920x — home server (Lenovo ThinkCentre M920x Tiny)
      # Build: nixos-rebuild switch --flake .#m920x
      "m920x" = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; } // domainVars;
        modules = [
          nurOverlay
          sops-nix.nixosModules.sops
          disko.nixosModules.disko
          ./hosts/personal/fixed/m920x/configuration.nix
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = { inherit inputs; } // domainVars;
            home-manager.users.beacon = import ./hosts/personal/common/nixos-home.nix;
          }
        ];
      };

      # microserver-gen10plus — home server (HPE ProLiant MicroServer Gen10 Plus)
      # Build: nixos-rebuild switch --flake .#microserver-gen10plus
      "microserver-gen10plus" = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; } // domainVars;
        modules = [
          nurOverlay
          sops-nix.nixosModules.sops
          disko.nixosModules.disko
          ./hosts/personal/fixed/microserver-gen10plus/configuration.nix
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = { inherit inputs; } // domainVars;
            home-manager.users.beacon = import ./hosts/personal/common/nixos-home.nix;
          }
        ];
      };

      # MS-R1 - ARM boundary egress router
      # Build: nixos-rebuild switch --flake .#ms-r1
      "ms-r1" = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        specialArgs = { inherit inputs; } // domainVars;
        modules = [
          baseOverlay
          sops-nix.nixosModules.sops
          disko.nixosModules.disko
          ./hosts/personal/fixed/ms-r1/configuration.nix
        ];
      };

      # nixbuilder-0{1,2,3} — Harvester NixOS build/runner nodes (VLAN 1096)
      # Forgejo Actions runner (nix-builder:host) + local Nix builder.
      # Build: nixos-rebuild switch --flake .#nixbuilder-01
    } // builtins.listToAttrs (map
      (name: {
        inherit name;
        value = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = { inherit inputs; } // domainVars;
          modules = [
            nurOverlay
            sops-nix.nixosModules.sops
            disko.nixosModules.disko
            ./hosts/server/${name}/configuration.nix
          ];
        };
      })
      [ "nixbuilder-01" "nixbuilder-02" "nixbuilder-03" ]) // {

      # Installer ISO — minimal NixOS with sing-box proxy + CN mirrors
      # Used to bootstrap new machines from mainland China
      "installer" = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; } // domainVars;
        modules = [
          nurOverlay
          sops-nix.nixosModules.sops
          ./hosts/installer/configuration.nix
        ];
      };
    };

    # ──────────────────────────────────────────────────────────
    #  Installer ISO packages
    # ──────────────────────────────────────────────────────────

    packages.x86_64-linux =
      let
        pkgs = import nixpkgs { system = "x86_64-linux"; };
        paseoPackage = inputs.paseo.packages.x86_64-linux.default.override {
          npmDepsHash = "sha256-oXz8hMk+5DlTYK8OndUAjB+RJMDbPqobVGXLFeoH++o=";
        };
        paseoDesktop = inputs.paseo.packages.x86_64-linux.desktop.override {
          paseo = paseoPackage;
        };
      in {
      # nix build .#installer-iso
      installer-iso = self.nixosConfigurations.installer.config.system.build.isoImage;

      nchnroutes = pkgs.callPackage ./packages/nchnroutes {
        source = inputs.nchnroutes-src;
        chinaIpList = inputs.china-ip-list;
      };

      gh-proxy = pkgs.callPackage ./packages/gh-proxy { };

      paseo-desktop = paseoDesktop;

      # Coder workspace base image for interactive coding and autonomous agents.
      # Build: nix build .#coding-agent-oci
      coding-agent-oci =
        let
          pkgs = import nixpkgs {
            system = "x86_64-linux";
            config.allowUnfree = true;
            overlays = [ llmAgents.overlays.shared-nixpkgs ];
          };
          homeActivation = (home-manager.lib.homeManagerConfiguration {
            inherit pkgs;
            extraSpecialArgs = { inherit inputs; } // domainVars;
            modules = [
              ./hosts/agents/coding/home.nix
              { home.enableNixpkgsReleaseCheck = false; }
            ];
          }).activationPackage;
          # buildLayeredImage lays store paths on disk but does not register
          # them as valid in the nix DB, so `nix-store --realise` (called by HM
          # activation) treats the on-disk activation closure as missing and
          # tries to fetch it from a substituter (401 on the private cache).
          # Bake the closure's registration so the entrypoint can --load-db it.
          nixDbRegistration = pkgs.closureInfo { rootPaths = [ homeActivation ]; };
          coderAgent = pkgs.runCommand "coder-agent-2.31.2" {
            nativeBuildInputs = [ pkgs.gnutar pkgs.gzip ];
          } ''
            mkdir -p $out/bin
            tar -xzf ${pkgs.fetchurl {
              url = "https://github.com/coder/coder/releases/download/v2.31.2/coder_2.31.2_linux_amd64.tar.gz";
              hash = "sha256-vaOQmZXrelbamCPlhZwfkHbGLLUSSNbrL6VvhAvwnDY=";
            }}
            install -m 0755 coder $out/bin/coder-agent
          '';
          nodePtyPrebuild = pkgs.runCommand "node-pty-1.2.0-beta.15-linux-x64" {
            nativeBuildInputs = [ pkgs.gnutar pkgs.gzip ];
          } ''
            mkdir -p $out
            tar -xzf ${pkgs.fetchurl {
              url = "https://registry.npmjs.org/node-pty/-/node-pty-1.2.0-beta.15.tgz";
              hash = "sha256-EUrIDD/gde/3YhekEi0TVXZYJpX0nAOl2jg1zfwvicU=";
            }}
            cp -R package/prebuilds/linux-x64 $out/
          '';
          paseoPackage = (inputs.paseo.packages.x86_64-linux.default.override {
            npmDepsHash = "sha256-oXz8hMk+5DlTYK8OndUAjB+RJMDbPqobVGXLFeoH++o=";
          }).overrideAttrs (old: {
            postInstall = (old.postInstall or "") + ''
              ptyRoot=$out/lib/paseo/packages/server/node_modules/node-pty
              mkdir -p "$ptyRoot/prebuilds"
              cp -R ${nodePtyPrebuild}/linux-x64 "$ptyRoot/prebuilds/"
            '';
          });
          # nix-ld: lets foreign (downloaded, glibc/FHS-linked) binaries run in
          # this pure-Nix image — e.g. code-server from Coder's vscode-web
          # module, and any other tool a workspace curls in. The shim at the
          # ELF interpreter path reads NIX_LD (real loader) + NIX_LD_LIBRARY_PATH.
          # Library set mirrors nixpkgs' programs.nix-ld default.
          nixLdLibraryPath = pkgs.lib.makeLibraryPath (with pkgs; [
            zlib zstd stdenv.cc.cc curl openssl attr libssh bzip2 libxml2 acl
            libsodium util-linux xz systemd
          ]);
          rootFiles = pkgs.runCommand "coding-agent-root-files" { } ''
            mkdir -p $out/etc/nix $out/home/coder $out/root/.ssh $out/workspace
            ln -s /home/coder/.ssh/config $out/root/.ssh/config
            ln -s /home/coder/.ssh/known_hosts $out/root/.ssh/known_hosts
            # Home Manager activation shells out to nix, which needs a
            # writable /tmp (sandbox is off, so builds land in /tmp/nix-build-*).
            # The minimal dockerTools image has no /tmp otherwise -> activation
            # dies with "creating directory /tmp/...: No such file or directory".
            mkdir -p $out/tmp && chmod 1777 $out/tmp
            # nix-ld: place the shim at the ELF interpreter path so foreign
            # dynamic binaries (e.g. downloaded code-server) resolve a loader.
            mkdir -p $out/lib64
            ln -s ${pkgs.nix-ld}/libexec/nix-ld $out/lib64/ld-linux-x86-64.so.2
            cat > $out/etc/passwd <<'EOF'
            root:x:0:0:root:/root:/bin/bash
            coder:x:1000:1000:Coder:/home/coder:/bin/bash
            EOF
            cat > $out/etc/group <<'EOF'
            root:x:0:
            coder:x:1000:
            EOF
            # coder agent's clistat resources monitor needs an /etc/*-release
            # to identify the host; without it agent.run exits ("no valid
            # /etc/<distrib>-release file found") and the agent flaps
            # disconnected, so the startup script never runs.
            cat > $out/etc/os-release <<'EOF'
            NAME=NixOS
            ID=nixos
            VERSION_ID="26.05"
            PRETTY_NAME="NixOS (coding-agent)"
            EOF
            cat > $out/etc/nix/nix.conf <<'EOF'
            experimental-features = nix-command flakes
            sandbox = false
            build-users-group =
            substituters = https://cache.nixos.org https://nix.beaco.works/nix-fleet https://nix-community.cachix.org https://cache.numtide.com
            trusted-public-keys = nix-fleet:y2rSAuD7txybrsaKciEu0z25W6nvS2fNfGorGLpIB2k= nix-community.cachix.org-1:mB9xqQyK3k3k0mBf2j7a1oUczJ9xwYpR2CtX5QBYBCE= cache.numtide.com-1:U0mE9AwWfcn3cFErm7dGd0nw3hEqNfYxckeeGJk2wJE=
            EOF
          '';
          entrypoint = pkgs.writeShellApplication {
            name = "coding-agent-entrypoint";
            runtimeInputs = with pkgs; [ bashInteractive coreutils ];
            text = ''
              set -euo pipefail

              export HOME="''${HOME:-/home/coder}"
              export USER="''${USER:-coder}"
              export SHELL="${pkgs.bashInteractive}/bin/bash"
              export CODER_WORKSPACE_DIR="''${CODER_WORKSPACE_DIR:-$HOME/workspace}"
              # /bin (image contents: nix, bash, coreutils, curl, git) is enough
              # to run activation; the Home Manager profile bin is added after.
              export PATH="/bin:$PATH"

              # Home Manager activation manages a nix profile; give it both the
              # per-user profile dir and the XDG-state profile dir it probes for,
              # plus the usual XDG homes, or it aborts with "Could not find
              # suitable profile directory".
              mkdir -p "$HOME" "$CODER_WORKSPACE_DIR" \
                /nix/var/nix/{db,gcroots,profiles,temproots,userpool} \
                "/nix/var/nix/profiles/per-user/$USER" \
                /nix/var/nix/gcroots/per-user/"$USER" \
                "$HOME/.local/state/nix/profiles" \
                "$HOME/.local/state/home-manager/gcroots" \
                "$HOME/.local/share/nix" \
                "$HOME/.config" "$HOME/.cache"

              # The activation marker lives on the persistent /home/coder
              # volume, so key it to THIS image's Home Manager generation.
              # On an image update the new generation's store paths differ,
              # and a stale "already activated" marker would leave the profile
              # symlinks dangling (broken PATH/tools). Naming the marker after
              # the generation forces a re-activation when the image changes
              # and skips it on a plain restart of the same image.
              actMarker="$HOME/.hm-activated-$(basename ${homeActivation})"
              if [ ! -e "$actMarker" ]; then
                if [ ! -e /nix/var/nix/.db-loaded ]; then
                  nix-store --load-db < ${nixDbRegistration}/registration
                  touch /nix/var/nix/.db-loaded
                fi
                # Drop markers from previous generations (and the legacy name).
                rm -f "$HOME"/.hm-activated-* "$HOME/.coding-agent-home-activated" 2>/dev/null || true
                ${homeActivation}/activate
                touch "$actMarker"
              fi

              # Put the Home Manager profile on PATH. Standalone HM points
              # ~/.nix-profile at the (empty) root nix-env profile here, and
              # hm-session-vars.sh doesn't export PATH, so reference the
              # generation's home-path directly.
              hmPath="$HOME/.local/state/nix/profiles/home-manager/home-path"
              if [ -e "$hmPath/bin" ]; then
                export PATH="$hmPath/bin:$PATH"
              fi
              # shellcheck disable=SC1090,SC1091
              [ -e "$hmPath/etc/profile.d/hm-session-vars.sh" ] && \
                . "$hmPath/etc/profile.d/hm-session-vars.sh"

              tailscaleSocket="''${TS_SOCKET:-/tmp/tailscale/tailscaled.sock}"
              tailscalePid=""
              paseoPid=""
              commandPid=""

              # shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
              cleanup() {
                set +e
                if [ -n "$tailscalePid" ]; then
                  tailscale --socket="$tailscaleSocket" logout >/dev/null 2>&1
                fi
                [ -n "$paseoPid" ] && kill -TERM "$paseoPid" 2>/dev/null
                [ -n "$tailscalePid" ] && kill -TERM "$tailscalePid" 2>/dev/null
                [ -n "$paseoPid" ] && wait "$paseoPid" 2>/dev/null
                [ -n "$tailscalePid" ] && wait "$tailscalePid" 2>/dev/null
              }
              trap cleanup EXIT
              trap '[ -n "$commandPid" ] && kill -TERM "$commandPid" 2>/dev/null' TERM INT

              if [ -n "''${TS_AUTHKEY:-}" ]; then
                tailscaleStateDir=/tmp/tailscale/state
                mkdir -p "$(dirname "$tailscaleSocket")" "$tailscaleStateDir" "$HOME/.paseo"
                tailscaled \
                  --tun=userspace-networking \
                  --state=mem: \
                  --statedir="$tailscaleStateDir" \
                  --socket="$tailscaleSocket" \
                  >"$HOME/.tailscaled.log" 2>&1 &
                tailscalePid=$!

                for _ in $(seq 1 60); do
                  [ -S "$tailscaleSocket" ] && break
                  kill -0 "$tailscalePid" 2>/dev/null
                  sleep 1
                done
                [ -S "$tailscaleSocket" ] || {
                  echo "tailscaled socket did not appear: $tailscaleSocket" >&2
                  exit 1
                }

                tailscale --socket="$tailscaleSocket" up \
                  --auth-key="$TS_AUTHKEY" \
                  --hostname="''${TS_HOSTNAME:-coder-workspace}" \
                  --accept-dns=false \
                  --ssh

                export PASEO_HOME="''${PASEO_HOME:-$HOME/.paseo}"
                export PASEO_LISTEN="''${PASEO_LISTEN:-127.0.0.1:6767}"
                # Tailscale Serve terminates the public-facing connection and
                # forwards the tailnet DNS name in Host; the daemon remains
                # bound to loopback, so this does not expose it publicly.
                export PASEO_HOSTNAMES="''${PASEO_HOSTNAMES:-true}"
                rm -f "$PASEO_HOME/paseo.pid"
                paseo-server --no-relay >"$HOME/.paseo-server.log" 2>&1 &
                paseoPid=$!

                for _ in $(seq 1 60); do
                  curl --fail --silent http://127.0.0.1:6767/api/health >/dev/null && break
                  kill -0 "$paseoPid" 2>/dev/null
                  sleep 1
                done
                curl --fail --silent http://127.0.0.1:6767/api/health >/dev/null
                tailscale --socket="$tailscaleSocket" serve --bg \
                  --tcp=6767 tcp://127.0.0.1:6767 \
                  >"$HOME/.tailscale-serve.log" 2>&1 &
              fi

              cd "$CODER_WORKSPACE_DIR"
              if [ "$#" -eq 0 ]; then
                "$SHELL" -l &
              else
                "$@" &
              fi
              commandPid=$!
              set +e
              wait "$commandPid"
              commandStatus=$?
              set -e
              exit "$commandStatus"
            '';
          };
        in
        pkgs.dockerTools.buildLayeredImage {
          name = "172.16.87.51:5000/infrastructure/nix-fleet/coding-agent";
          tag = "latest";
          contents = [
            rootFiles
            entrypoint
            coderAgent
            pkgs.bashInteractive
            pkgs.cacert
            pkgs.coreutils
            pkgs.curl
            # POSIX tools the coder agent bootstrap + startup scripts call.
            # Without grep the agent's `coder --version | grep -q Coder` sanity
            # check fails ("grep: command not found") -> agent exits 2 -> the
            # workspace never comes up. sed/tar/gzip round out what dotfiles /
            # module-style startup scripts commonly need.
            pkgs.gnugrep
            pkgs.gnused
            pkgs.gnutar
            pkgs.gzip
            pkgs.git
            pkgs.fluxcd
            pkgs.kubectl
            pkgs.lbzip2
            pkgs.nix
            pkgs.openssh
            pkgs.procps
            pkgs.sops
            pkgs.talosctl
            pkgs.tailscale
            paseoPackage
          ];
          config = {
            Entrypoint = [ "/bin/coding-agent-entrypoint" ];
            WorkingDir = "/home/coder/workspace";
            Env = [
              "HOME=/home/coder"
              "USER=coder"
              "NIX_SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
              "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
              # nix-ld: real glibc loader + library search path for foreign binaries.
              "NIX_LD=${pkgs.stdenv.cc.bintools.dynamicLinker}"
              "NIX_LD_LIBRARY_PATH=${nixLdLibraryPath}"
            ];
          };
        };

      # K8s OCI Container Image — NixOS-in-a-container with sing-box + sops-nix
      # Build:  nix build .#k8s-sing-box-image
      # Import: docker import result/tarball/nixos-system-x86_64-linux.tar.xz k8s-sing-box
      # Run:    docker run --privileged k8s-sing-box /init
      #
      # Note: nixpkgs make-system-tarball.nix has a __structuredAttrs bug that
      # produces empty tarballs (41K, no store closure). We build manually here.
      k8s-sing-box-image = let
        nixos = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = { inherit inputs; k8sTransparentProxy = true; };
          modules = [
            nurOverlay
            sops-nix.nixosModules.sops
            ./modules/common/sing-box.nix
            ./modules/nixos/sing-box.nix
            ({ pkgs, lib, config, ... }: {
              boot.isContainer = true;
              networking.firewall.enable = false;
              services.tailscale.enable = lib.mkForce false;
              beacoworks.sing-box.useSystemTailscale = true;
              beacoworks.sing-box.tailscaleSocksServer = "ts-userspace.network.svc.cluster.local";
              beacoworks.sing-box.tailscaleSocksDnsServer = "10.55.0.10";

              # sops age key: mount a K8s secret to this path
              sops.age.sshKeyPaths = [ ];
              sops.age.keyFile = "/var/lib/sops-nix/age.key";

              # Stream systemd/journal logs to container stdout
              services.journald.console = "/dev/console";

              system.stateVersion = "25.05";

              # Container init (from nixpkgs docker-container profile)
              boot.postBootCommands = ''
                echo "docker" > /run/systemd/container
                if [ -f /nix-path-registration ]; then
                  ${config.nix.package.out}/bin/nix-store --load-db < /nix-path-registration && rm /nix-path-registration
                fi
                ${config.nix.package.out}/bin/nix-env -p /nix/var/nix/profiles/system --set /run/current-system
              '';
              system.activationScripts.installInitScript = ''
                ln -fs $systemConfig/init /init
              '';
            })
          ];
        };
        pkgs = import nixpkgs { system = "x86_64-linux"; };
        toplevel = nixos.config.system.build.toplevel;
        closureInfo = pkgs.closureInfo { rootPaths = [ toplevel ]; };
      in pkgs.runCommand "k8s-sing-box-tarball" {
        nativeBuildInputs = [ pkgs.pixz ];
      } ''
        rootfs=$TMPDIR/rootfs
        mkdir -p $rootfs && cd $rootfs

        # System toplevel → image root (chmod: store paths are read-only)
        cp -a ${toplevel}/. .
        chmod -R u+w .

        # Nix store closure
        mkdir -p nix/store
        while IFS= read -r p; do
          cp -a "$p" ".$p"
        done < ${closureInfo}/store-paths

        # Nix DB registration (for nix-store --load-db at first boot)
        cp ${closureInfo}/registration nix-path-registration

        # Container filesystem
        rm -rf etc
        mkdir -p proc sys dev etc

        # Compressed tarball
        mkdir -p $out/tarball
        tar --sort=name --mtime='@1' --owner=0 --group=0 --numeric-owner -c . \
          | pixz -t > $out/tarball/nixos-system-x86_64-linux.tar.xz

        mkdir -p $out/nix-support
        echo "x86_64-linux" > $out/nix-support/system
        echo "file system-tarball $out/tarball/nixos-system-x86_64-linux.tar.xz" \
          > $out/nix-support/hydra-build-products
      '';

      # Proper OCI image for K8s
      # Build:  nix build .#k8s-sing-box-oci
      # Run:    docker run --privileged ${SECRET_IMAGE_REGISTRY}/infrastructure/nix-fleet/sing-box:latest
      k8s-sing-box-oci = let
        pkgs = import nixpkgs { system = "x86_64-linux"; };
        tarball = self.packages.x86_64-linux.k8s-sing-box-image;
      in pkgs.dockerTools.buildImage {
        name = "registry.example.invalid/infrastructure/nix-fleet/sing-box";
        tag = "latest";
        fromImage = null;
        fromImageName = null;
        fromImageTag = null;
        # Import the rootfs from the tarball we built
        copyToRoot = pkgs.runCommand "k8s-sing-box-rootfs" { } ''
          mkdir -p $out
          tar -xvf ${tarball}/tarball/nixos-system-x86_64-linux.tar.xz -C $out
        '';
        config = {
          Cmd = [ "/init" ];
          Entrypoint = [ ];
          WorkingDir = "/";
        };
      };

      # ── Common NixOS closure (CI cache warming) ───────────────
      # Minimal NixOS system with all shared modules but no hardware-
      # specific config.  Built first in CI and pushed to Attic so that
      # subsequent per-host builds hit the binary cache for the bulk of
      # their closure.
      common-nixos-closure =
        (nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = { inherit inputs; } // domainVars;
          modules = [
            nurOverlay
            sops-nix.nixosModules.sops
            ./hosts/personal/common/nixos-configuration.nix
            ./modules/nixos/hyprland.nix
            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.extraSpecialArgs = { inherit inputs; } // domainVars;
              home-manager.users.beacon = import ./hosts/personal/common/nixos-home.nix;
            }
            # Minimal stubs so this evaluates without real hardware
            ({ lib, ... }: {
              networking.hostName = "common-closure";
              fileSystems."/" = { device = "/dev/null"; fsType = "tmpfs"; };
              boot.loader.grub.enable = false;
              system.stateVersion = lib.mkForce "25.05";
            })
          ];
        }).config.system.build.toplevel;

      };

    packages.aarch64-linux = {
      common-nixos-closure =
        (nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          specialArgs = { inherit inputs; } // domainVars;
          modules = [
            ./modules/common/nix.nix
            ./modules/common/packages.nix
            ({ lib, ... }: {
              networking.hostName = "common-aarch64-linux-closure";
              fileSystems."/" = { device = "/dev/null"; fsType = "tmpfs"; };
              boot.loader.grub.enable = false;
              system.stateVersion = lib.mkForce "25.05";
            })
          ];
        }).config.system.build.toplevel;

      nchnroutes =
        let
          pkgs = import nixpkgs { system = "aarch64-linux"; };
        in
        pkgs.callPackage ./packages/nchnroutes {
          source = inputs.nchnroutes-src;
          chinaIpList = inputs.china-ip-list;
        };
    };

    packages.aarch64-darwin.common-darwin-closure =
      (nix-darwin.lib.darwinSystem {
        system = "aarch64-darwin";
        specialArgs = { inherit inputs; } // domainVars;
        modules = [
          nurOverlay
          sops-nix.darwinModules.sops
          ./hosts/personal/common/configuration.nix
          home-manager.darwinModules.home-manager
          {
            networking.hostName = "common-aarch64-darwin-closure";
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = { inherit inputs; } // domainVars;
            home-manager.users.beacon = import ./hosts/personal/common/home.nix;
          }
        ];
      }).system;
  };
}

# sing-box launchd daemon — darwin module definition
#
# This provides the services.sing-box option for nix-darwin.
# On NixOS, this module is NOT needed (nixpkgs has its own).
#
# Usage:
#   services.sing-box.enable = true;
#   services.sing-box.settings = { /* sing-box JSON config */ };
#   # or
#   services.sing-box.configFile = "/path/to/config.json";

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.sing-box;
  settingsFormat = pkgs.formats.json { };

  effectiveConfigFile =
    if cfg.configFile != null then
      cfg.configFile
    else
      settingsFormat.generate "sing-box-config.json" cfg.settings;

  configFileArg = lib.escapeShellArg (toString effectiveConfigFile);
  stateDir = "/var/lib/sing-box";
  configHashFile = "${stateDir}/config.sha256";

  startScript = pkgs.writeShellScript "sing-box-start" ''
    config_file=${configFileArg}
    state_dir=${lib.escapeShellArg stateDir}

    /bin/mkdir -p "$state_dir"
    for _ in $(${lib.getExe' pkgs.coreutils "seq"} 1 60); do
      if [[ -r "$config_file" ]]; then
        break
      fi
      ${lib.getExe' pkgs.coreutils "sleep"} 1
    done

    if [[ ! -r "$config_file" ]]; then
      echo "sing-box configuration is not readable after 60 seconds: $config_file" >&2
      exit 1
    fi

    ${lib.getExe cfg.package} check -c "$config_file"
    ${lib.getExe' pkgs.coreutils "sha256sum"} "$config_file" > "$state_dir/config.sha256.new"
    ${lib.getExe' pkgs.coreutils "mv"} "$state_dir/config.sha256.new" ${lib.escapeShellArg configHashFile}

    export ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true
    exec ${lib.getExe cfg.package} run -c "$config_file" -D "$state_dir"
  '';
in
{
  options.services.sing-box = {
    enable = lib.mkEnableOption "sing-box universal proxy platform (launchd)";

    package = lib.mkPackageOption pkgs "sing-box" { };

    configFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to a sing-box configuration file.
        If set, this takes precedence over the `settings` option.
        Useful for sops-nix managed config files.
      '';
    };

    settings = lib.mkOption {
      type = lib.types.submodule {
        freeformType = settingsFormat.type;
      };
      default = { };
      description = ''
        sing-box configuration as a Nix attribute set.
        Serialized to JSON and passed to sing-box.
        Ignored if `configFile` is set.
        See: https://sing-box.sagernet.org/configuration/
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    system.activationScripts.postActivation.text = lib.mkAfter ''
      config_file=${configFileArg}
      config_hash_file=${lib.escapeShellArg configHashFile}

      if [[ ! -r "$config_file" ]]; then
        echo "sing-box configuration is not readable: $config_file" >&2
        exit 1
      fi

      new_hash="$(${lib.getExe' pkgs.coreutils "sha256sum"} "$config_file")"
      loaded_hash="$(${lib.getExe' pkgs.coreutils "cat"} "$config_hash_file" 2>/dev/null || true)"
      if [[ "$new_hash" != "$loaded_hash" ]]; then
        ${lib.getExe cfg.package} check -c "$config_file"
        if /bin/launchctl print system/org.sagernet.sing-box >/dev/null 2>&1; then
          echo "Restarting sing-box after configuration change..."
          /bin/launchctl kickstart -k system/org.sagernet.sing-box
        fi
      fi
    '';

    launchd.daemons.sing-box = {
      serviceConfig = {
        Label = "org.sagernet.sing-box";
        ProgramArguments = [
          "/bin/sh"
          "-c"
          "/bin/wait4path /nix/store && exec ${startScript}"
        ];
        RunAtLoad = true;
        KeepAlive = true;
        StandardOutPath = "/var/log/sing-box.log";
        StandardErrorPath = "/var/log/sing-box.log";
      };
    };
  };
}

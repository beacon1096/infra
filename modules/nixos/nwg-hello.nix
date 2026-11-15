{ config, lib, pkgs, ... }:

let
  cfg = config.beacoworks.nwg-hello;
  jsonFormat = pkgs.formats.json { };
  sidebarPackage = pkgs.nwg-hello.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      ${pkgs.python3}/bin/python3 ${./nwg-hello/layout.py}
    '';
    postInstall = (old.postInstall or "") + ''
      install -m 644 nwg_hello/template.glade "$out/share/nwg-hello/sidebar.glade"
    '';
  });
  greeterConfig = jsonFormat.generate "nwg-hello.json" {
    session_dirs = [
      "${config.services.displayManager.sessionData.desktops}/share/wayland-sessions"
      "${config.services.displayManager.sessionData.desktops}/share/xsessions"
    ];
    custom_sessions = [ ];
    delay_secs = 0;
    gtk-theme = "Adwaita";
    gtk-icon-theme = "Adwaita";
    gtk-cursor-theme = "Adwaita";
    prefer-dark-theme = true;
    template-name = "${cfg.package}/share/nwg-hello/sidebar.glade";
    panel-fraction = cfg.panelFraction;
    default-session = cfg.defaultSession;
    show-welcome = cfg.showWelcome;
    time-format = "%H:%M";
    date-format = "%A, %d %B";
    keyboard-mode = "exclusive";
    lang = "en_US";
  };
  greeterStyle = pkgs.writeText "nwg-hello.css" (''
    window {
      background-image: url(${builtins.toJSON cfg.background});
      background-size: cover;
      background-position: center;
      background-repeat: no-repeat;
    }
  '' + builtins.readFile ./nwg-hello/style.css + cfg.extraCss);
  greeterSession = pkgs.writeShellScript "nwg-hello-session" ''
    status=0
    ${lib.getExe cfg.package} -c ${greeterConfig} -s ${greeterStyle} "$@" || status=$?
    ${pkgs.sway}/bin/swaymsg exit
    exit "$status"
  '';
  swayConfig = pkgs.writeText "nwg-hello-sway.conf" ''
    xwayland disable
    output * scale ${toString cfg.outputScale}
    ${lib.optionalString (cfg.outputMode != "") "output * mode ${builtins.toJSON cfg.outputMode}"}
    seat seat0 xcursor_theme Adwaita 24
    exec ${greeterSession}
  '';
  greeterCommand = pkgs.writeShellScript "nwg-hello-greeter" ''
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.getent pkgs.systemd pkgs.sway ]}:"$PATH"
    export XDG_SESSION_TYPE=wayland
    export XDG_CACHE_HOME=/var/cache/nwg-hello
    export XDG_CONFIG_HOME="$XDG_RUNTIME_DIR/nwg-hello"
    mkdir -p "$XDG_CONFIG_HOME"
    exec ${pkgs.dbus}/bin/dbus-run-session ${pkgs.sway}/bin/sway --config ${swayConfig}
  '';
in
{
  options.beacoworks.nwg-hello = {
    enable = lib.mkEnableOption "the nwg-hello sidebar greeter";

    package = lib.mkOption {
      type = lib.types.package;
      default = sidebarPackage;
      defaultText = lib.literalExpression "pkgs.nwg-hello.overrideAttrs (...)";
      description = "nwg-hello with the proportional sidebar layout.";
    };

    background = lib.mkOption {
      type = lib.types.str;
      example = "/var/lib/greetd/background.png";
      description = "Absolute runtime background path readable by the greeter user.";
    };

    panelFraction = lib.mkOption {
      type = lib.types.addCheck lib.types.number (value: value > 0 && value < 1);
      default = 0.342;
      description = "Fraction of the output's logical width occupied by the left panel.";
    };

    outputScale = lib.mkOption {
      type = lib.types.addCheck lib.types.number (value: value > 0);
      default = 1.0;
      description = "Sway output scale used by the greeter.";
    };

    outputMode = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "2880x1920";
      description = "Sway output mode; an empty value keeps the preferred mode.";
    };

    defaultSession = lib.mkOption {
      type = lib.types.str;
      default = "Hyprland";
      description = "Session name selected when the greeter has no saved choice.";
    };

    showWelcome = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Show the welcome label above the clock.";
    };

    extraCss = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Additional GTK3 styles appended to the default appearance.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.hasPrefix "/" cfg.background;
        message = "beacoworks.nwg-hello.background must be an absolute runtime path.";
      }
    ];

    environment.systemPackages = [ cfg.package pkgs.adwaita-icon-theme ];
    fonts.packages = [ pkgs.dejavu_fonts ];

    services.greetd = {
      enable = true;
      settings.default_session = {
        command = toString greeterCommand;
        user = "greeter";
      };
    };

    systemd.tmpfiles.rules = [
      "d /var/cache/nwg-hello 0750 greeter greeter - -"
      "f /var/cache/nwg-hello/cache.json 0600 greeter greeter - {}"
    ];
  };
}

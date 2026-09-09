# Hyprland — Home Manager user configuration
#
# Keybindings, animations, waybar, app launcher, notifications, etc.
# This module is opt-in: import it in nixos-home.nix for desktop hosts.
{ pkgs, ... }:

{
  wayland.windowManager.hyprland = {
    enable = true;
    settings = {
      # ── Monitors ──────────────────────────────────────────────
      # Default: auto-detect. Override per-host in host home.nix.
      monitor = [
        # Surface Pro 8 Main Display
        "desc:LG Display 0x06B1 0x002127A1, preferred, auto, 1.5"
        # External 4K monitor (identified via description - persistent across ports)
        "desc:Xiaomi Corporation Mi Monitor 5877500072985, 3840x2160@60, auto, 1.5"
        # Default fallback
        ", preferred, auto, 1"
      ];

      # ── General ───────────────────────────────────────────────
      general = {
        gaps_in = 4;
        gaps_out = 8;
        border_size = 2;
        "col.active_border" = "rgba(88c0d0ff) rgba(81a1c1ff) 45deg";
        "col.inactive_border" = "rgba(3b4252aa)";
        layout = "dwindle";
        allow_tearing = true;
      };

      # ── Misc ──────────────────────────────────────────────────
      misc = {
        vrr = 2;
      };

      # ── Decoration ────────────────────────────────────────────
      decoration = {
        rounding = 10;
        blur = {
          enabled = true;
          size = 6;
          passes = 2;
          new_optimizations = true;
        };
        shadow = {
          enabled = true;
          range = 12;
          render_power = 3;
          color = "rgba(1a1a1aee)";
        };
      };

      # ── Animations (macOS-inspired smooth transitions) ────────
      animations = {
        enabled = true;
        bezier = [
          "easeOut, 0.16, 1, 0.3, 1"
          "easeInOut, 0.45, 0, 0.55, 1"
          "spring, 0.5, 1.2, 0.3, 1"
        ];
        animation = [
          "windows, 1, 4, spring, slide"
          "windowsOut, 1, 4, easeOut, slide"
          "fade, 1, 3, easeOut"
          "workspaces, 1, 4, easeInOut, slide"
          "border, 1, 5, easeOut"
        ];
      };

      # ── Input ─────────────────────────────────────────────────
      input = {
        kb_layout = "us";
        follow_mouse = 1;
        touchpad = {
          natural_scroll = true; # macOS-style natural scrolling
          tap-to-click = true;
          drag_lock = true;
          disable_while_typing = true;
        };
        sensitivity = 0;
      };

      # ── Gestures ──────────────────────────────────────────────
      gesture = [
        "3, horizontal, workspace"
      ];

      # ── Dwindle layout ────────────────────────────────────────
      dwindle = {
        preserve_split = true;
      };

      # ── Key bindings ──────────────────────────────────────────
      "$mod" = "SUPER";

      bind = [
        # Window management
        "$mod, Q, killactive"
        "$mod, F, fullscreen"
        "$mod, Space, togglefloating"
        "$mod, P, pseudo" # dwindle pseudotile
        "$mod, S, layoutmsg, togglesplit" # dwindle split direction

        # App launchers
        "$mod, Return, exec, foot" # terminal
        "$mod, D, exec, wofi --show drun" # app launcher
        "$mod, E, exec, spacedrive" # file manager

        # Focus movement (vim-style)
        "$mod, H, movefocus, l"
        "$mod, L, movefocus, r"
        "$mod, K, movefocus, u"
        "$mod, J, movefocus, d"

        # Window movement
        "$mod SHIFT, H, movewindow, l"
        "$mod SHIFT, L, movewindow, r"
        "$mod SHIFT, K, movewindow, u"
        "$mod SHIFT, J, movewindow, d"

        # Workspaces
        "$mod, 1, workspace, 1"
        "$mod, 2, workspace, 2"
        "$mod, 3, workspace, 3"
        "$mod, 4, workspace, 4"
        "$mod, 5, workspace, 5"
        "$mod, 6, workspace, 6"
        "$mod, 7, workspace, 7"
        "$mod, 8, workspace, 8"
        "$mod, 9, workspace, 9"

        # Move window to workspace
        "$mod SHIFT, 1, movetoworkspace, 1"
        "$mod SHIFT, 2, movetoworkspace, 2"
        "$mod SHIFT, 3, movetoworkspace, 3"
        "$mod SHIFT, 4, movetoworkspace, 4"
        "$mod SHIFT, 5, movetoworkspace, 5"
        "$mod SHIFT, 6, movetoworkspace, 6"
        "$mod SHIFT, 7, movetoworkspace, 7"
        "$mod SHIFT, 8, movetoworkspace, 8"
        "$mod SHIFT, 9, movetoworkspace, 9"

        # Screenshot area → annotate in swappy (default)
        ", Print, exec, grimblast --freeze save area - | swappy -f -"
        "$mod SHIFT, S, exec, grimblast --freeze save area - | swappy -f -"
        # Screenshot straight to clipboard (no annotation)
        "SHIFT, Print, exec, grimblast copy screen"
        "$mod, Print, exec, grimblast copy active"
        "$mod SHIFT, A, exec, grimblast --freeze copy area"

        # Screen lock
        "$mod SHIFT, Escape, exec, hyprlock"

        # Exit Hyprland
        "$mod SHIFT, E, exit"

        # Main panel brightness
        "$mod CONTROL, Down, exec, brightnessctl -c backlight set 5%-"
        "$mod CONTROL, Up, exec, brightnessctl -c backlight set 5%+"
      ];

      # Mouse bindings
      bindm = [
        "$mod, mouse:272, movewindow" # Super + left click = drag
        "$mod, mouse:273, resizewindow" # Super + right click = resize
      ];

      # Media / brightness keys (work without modifier)
      bindel = [
        ", XF86AudioRaiseVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+"
        ", XF86AudioLowerVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"
        # Use evdev keycodes for brightness to avoid keysym variations across devices.
        ", code:233, exec, brightnessctl -c backlight set 5%+" # KEY_BRIGHTNESSUP
        ", code:232, exec, brightnessctl -c backlight set 5%-" # KEY_BRIGHTNESSDOWN
      ];

      bindl = [
        ", XF86AudioMute, exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"
        ", XF86AudioPlay, exec, playerctl play-pause"
        ", XF86AudioNext, exec, playerctl next"
        ", XF86AudioPrev, exec, playerctl previous"
      ];

      # ── Window rules (Hyprland 0.53+ syntax) ────────────────
      windowrule = [
        "match:class ^(pavucontrol)$, float 1"
        "match:class ^(blueman-manager)$, float 1"
        "match:class ^(nm-connection-editor)$, float 1"
        "match:title ^(Picture-in-Picture)$, float 1"
        "match:class ^(org.kde.polkit-kde-authentication-agent-1)$, float 1"
        "match:class ^(steam_app_).*$, immediate 1"
        "match:class ^(gamescope)$, immediate 1"
      ];

      # ── Autostart ─────────────────────────────────────────────
      exec-once = [
        "waybar"
        "mako"
        "hyprpaper"
        "fcitx5 -d"
      ];
    };
  };

  # ── Waybar (status bar) ─────────────────────────────────────
  programs.waybar = {
    enable = true;
    settings = {
      mainBar = {
        layer = "top";
        position = "top";
        height = 32;
        modules-left = [
          "hyprland/workspaces"
          "hyprland/window"
        ];
        modules-center = [ "clock" ];
        modules-right = [
          "pulseaudio"
          "network"
          "battery"
          "tray"
        ];

        clock = {
          format = "{:%H:%M}";
          tooltip-format = "{:%Y-%m-%d %A}";
        };
        battery = {
          format = "BAT {capacity}%";
          states = {
            warning = 20;
            critical = 10;
          };
        };
        network = {
          format-wifi = "WiFi {signalStrength}%";
          format-ethernet = "LAN {ifname}";
          format-disconnected = "NET down";
          tooltip-format = "{essid} ({signalStrength}%)";
        };
        pulseaudio = {
          format = "VOL {volume}%";
          format-muted = "VOL muted";
          tooltip-format = "{desc} ({volume}%)";
          on-click = "${pkgs.pavucontrol}/bin/pavucontrol";
        };
        tray = {
          spacing = 8;
        };
      };
    };
    style = ''
      * {
        font-family: "JetBrainsMono Nerd Font", sans-serif;
        font-size: 13px;
      }
      window#waybar {
        background-color: rgba(43, 48, 59, 0.85);
        color: #d8dee9;
        border-bottom: 2px solid rgba(136, 192, 208, 0.5);
      }
      #workspaces button {
        padding: 0 6px;
        color: #d8dee9;
        border-bottom: 2px solid transparent;
      }
      #workspaces button.active {
        color: #88c0d0;
        border-bottom: 2px solid #88c0d0;
      }
      #clock, #battery, #network, #pulseaudio, #tray {
        padding: 0 10px;
      }
      #battery.warning { color: #ebcb8b; }
      #battery.critical { color: #bf616a; }
    '';
  };

  # ── Notification daemon ─────────────────────────────────────
  services.mako = {
    enable = true;
    settings = {
      default-timeout = 5000;
      border-radius = 8;
      background-color = "#2e3440";
      text-color = "#d8dee9";
      border-color = "#88c0d0";
    };
  };

  # ── App launcher ────────────────────────────────────────────
  programs.wofi = {
    enable = true;
    settings = {
      show = "drun";
      allow_images = true;
      insensitive = true;
    };
    style = ''
      window {
        background-color: rgba(46, 52, 64, 0.95);
        border-radius: 10px;
        border: 2px solid #88c0d0;
      }
      #input {
        background-color: #3b4252;
        color: #d8dee9;
        border-radius: 8px;
        padding: 8px;
        margin: 8px;
      }
      #entry:selected {
        background-color: #88c0d0;
        color: #2e3440;
        border-radius: 6px;
      }
    '';
  };

  # ── Terminal emulator ───────────────────────────────────────
  programs.foot = {
    enable = true;
    settings = {
      main = {
        font = "JetBrainsMono Nerd Font:size=11";
      };
      colors = {
        # Nord theme
        background = "2e3440";
        foreground = "d8dee9";
        regular0 = "3b4252";
        regular1 = "bf616a";
        regular2 = "a3be8c";
        regular3 = "ebcb8b";
        regular4 = "81a1c1";
        regular5 = "b48ead";
        regular6 = "88c0d0";
        regular7 = "e5e9f0";
        bright0 = "4c566a";
        bright1 = "bf616a";
        bright2 = "a3be8c";
        bright3 = "ebcb8b";
        bright4 = "81a1c1";
        bright5 = "b48ead";
        bright6 = "8fbcbb";
        bright7 = "eceff4";
      };
    };
  };

  # ── Desktop utilities ───────────────────────────────────────
  home.packages = with pkgs; [
    # Screen lock
    hyprlock

    # Wallpaper
    hyprpaper
  ];

  # ── Input Method ────────────────────────────────────────────
  i18n.inputMethod = {
    enable = true;
    type = "fcitx5";
    fcitx5.waylandFrontend = true;
    fcitx5.addons = with pkgs; [
      qt6Packages.fcitx5-chinese-addons
      fcitx5-gtk
    ];
    fcitx5.settings = {
      globalOptions = {
        Behavior = {
          ShareInputState = "All";
        };
      };
      inputMethod = {
        "Groups/0" = {
          Name = "Default";
          "Default Layout" = "us";
          DefaultIM = "keyboard-us";
        };
        "Groups/0/Items/0" = {
          Name = "keyboard-us";
          Layout = "";
        };
        "Groups/0/Items/1" = {
          Name = "pinyin";
          Layout = "";
        };
        GroupOrder = {
          "0" = "Default";
        };
      };
    };
  };

}

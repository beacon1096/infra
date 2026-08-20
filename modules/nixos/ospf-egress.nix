{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.beacoworks.ospf-egress;

  renderRoute =
    route:
    let
      nextHop =
        if route.viaInterface != null then
          ''via "${route.viaInterface}"''
        else if route.via != null then
          "via ${route.via}"
        else
          route.kind;
    in
    "route ${route.prefix} ${nextHop};";

  renderOspfInterface = iface: ''
    interface "${iface.name}" {
      type ${iface.type};
      ${lib.optionalString (iface.txLength != null) "tx length ${toString iface.txLength};"}
      ${lib.optionalString (iface.authentication != "none") ''
        authentication ${iface.authentication};
        ${lib.optionalString (
          iface.passwordSnippetFile != null
        ) ''include "${iface.passwordSnippetFile}";''}
      ''}
    };
  '';
in
{
  options.beacoworks.ospf-egress = {
    enable = lib.mkEnableOption "bird2 OSPF route advertisement for sing-box/Tailscale egress nodes";

    routerId = lib.mkOption {
      type = lib.types.str;
      description = "BIRD router id, usually the node's stable IPv4 address.";
    };

    area = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
      description = "OSPF area id.";
    };

    ospfInterfaces = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "Interface participating in OSPF.";
            };
            type = lib.mkOption {
              type = lib.types.enum [
                "broadcast"
                "ptp"
                "ptmp"
                "nbma"
              ];
              default = "broadcast";
              description = "BIRD OSPF interface type.";
            };
            txLength = lib.mkOption {
              type = lib.types.nullOr (lib.types.ints.between 256 65535);
              default = null;
              example = 1500;
              description = "Soft ceiling for transmitted OSPF packet length.";
            };
            authentication = lib.mkOption {
              type = lib.types.enum [
                "none"
                "simple"
                "cryptographic"
              ];
              default = "none";
              description = "OSPF authentication mode.";
            };
            passwordSnippetFile = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "/run/secrets/bird/ospf-password.conf";
              description = ''
                Runtime BIRD config snippet containing the password directive,
                for example: password "secret";. Keep this outside the Nix store.
              '';
            };
          };
        }
      );
      default = [ ];
      description = "Interfaces where OSPF should advertise routes to the hard router/LAN.";
    };

    trustedInterfaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Interfaces trusted by the host firewall for OSPF adjacency and LAN proxy access.";
    };

    staticRoutes = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            prefix = lib.mkOption {
              type = lib.types.str;
              example = "100.64.0.0/10";
              description = "IPv4 prefix to advertise through OSPF.";
            };
            viaInterface = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "tailscale0";
              description = "Interface next hop for BIRD static routes.";
            };
            via = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "192.168.1.1";
              description = "Address next hop for BIRD static routes.";
            };
            kind = lib.mkOption {
              type = lib.types.enum [
                "blackhole"
                "unreachable"
                "prohibit"
              ];
              default = "blackhole";
              description = "Fallback static route kind when no next hop is set.";
            };
          };
        }
      );
      default = [ ];
      description = "Static IPv4 routes exported into OSPF.";
    };

    staticRouteIncludeFiles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "/etc/bird/cn-routes4.conf" ];
      description = "Additional BIRD static route snippets to include.";
    };

    exportKernelRoutes = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to export kernel-learned routes into OSPF.";
    };

    installRoutesInKernel = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether BIRD routes should be installed in the host kernel table.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.ospfInterfaces != [ ];
        message = "beacoworks.ospf-egress requires at least one OSPF interface.";
      }
      {
        assertion = lib.all (route: route.viaInterface == null || route.via == null) cfg.staticRoutes;
        message = "beacoworks.ospf-egress staticRoutes entries cannot set both viaInterface and via.";
      }
    ];

    environment.systemPackages = [ pkgs.bird2 ];

    networking.firewall.trustedInterfaces = cfg.trustedInterfaces;

    services.bird = {
      enable = true;
      package = pkgs.bird2;
      checkConfig = false;
      config = ''
        log syslog all;
        router id ${cfg.routerId};

        protocol device {
          scan time 5;
        }

        protocol kernel {
          ipv4 {
            import none;
            export ${if cfg.installRoutesInKernel then "all" else "none"};
          };
        }

        protocol static advertised_static_routes {
          ipv4;
          ${lib.concatMapStringsSep "\n          " renderRoute cfg.staticRoutes}
          ${lib.concatMapStringsSep "\n          " (
            file: ''include "${file}";''
          ) cfg.staticRouteIncludeFiles}
        }

        protocol ospf v2 ospf_lan {
          ipv4 {
            import none;
            export ${if cfg.exportKernelRoutes then "all" else "where source = RTS_STATIC"};
          };
          area ${cfg.area} {
            ${lib.concatMapStringsSep "\n" renderOspfInterface cfg.ospfInterfaces}
          };
        }
      '';
    };
  };
}

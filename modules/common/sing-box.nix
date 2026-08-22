# sing-box proxy configuration — shared across all platforms
#
# On darwin: requires modules/darwin/sing-box.nix (launchd module definition)
# On NixOS:  module definition is provided by nixpkgs upstream
#
# Secrets are managed via sops-nix:
#   - sops.secrets: decrypt individual values from secrets/shared/sing-box.yaml
#   - sops.templates: render full sing-box JSON with secrets injected at activation
#   - services.sing-box.configFile: points to the rendered template (not Nix store)
#
# To populate secrets:
#   sops secrets/shared/sing-box.yaml
#
# Expected YAML structure (nested):
#   sing-box:
#     clash:
#       secret: "..."
#     dns:
#       bootstrap: "10.x.x.x"
#       direct: "https://..."
#       global: "https://..."
#       rules:
#         tails_suffix:
#           "01": ".tailnet.example"
#         direct_suffix:
#           "01": ".example.invalid"
#           "02": ".alt.example.invalid"
#     nodes:
#       "01":
#         server: "..."
#         name: "..."
#         type: "vmess"
#         uuid: "..."
#         transport:
#           type: "ws"
#           path: "/..."
#       "02":
#         ...  (same fields, 01-08)
#     rule_set:
#       geoip-cn/url: "https://..."
#       geosite-cn/url: "https://..."
#       geosite-category-ads-all/url: "https://..."

{
  config,
  lib,
  pkgs,
  k8sTransparentProxy ? false,
  ...
}:

let
  cfg = config.beacoworks.sing-box;

  sopsFile = ../../secrets/shared/sing-box.yaml;
  mkSecret = (import ../../lib/mk-secret.nix) sopsFile;

  placeholder = config.sops.placeholder;

  # Pin sing-box rule-set inputs at build time so service startup does not
  # depend on fetching GitHub-hosted artifacts over the current network.
  # Each rule-set file is downloaded via fetchurl into the Nix store, and we
  # write the config to a store file so Nix tracks the dependency correctly.
  metaRulesRevision = "c4cd7af4915f57e678786e5feb961f8a716d987c";

  # Downloaded .srs rule-set files — Nix will include these in the system closure.
  geoip-cn-srs = pkgs.fetchurl {
    name = "geoip-cn.srs";
    url = "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/${metaRulesRevision}/geo/geoip/cn.srs";
    sha256 = "19xrsjin8f3120a77l4lmnxbxri5vcc1cyjxkp0b6a76ms30payj";
  };
  geoip-private-srs = pkgs.fetchurl {
    name = "geoip-private.srs";
    url = "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/${metaRulesRevision}/geo/geoip/private.srs";
    sha256 = "19vm79pc5cb7isydk2iw3d5aywsfhi70vwxwqkb1x0h5g08k2lxa";
  };
  geosite-cn-srs = pkgs.fetchurl {
    name = "geosite-cn.srs";
    url = "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/${metaRulesRevision}/geo/geosite/cn.srs";
    sha256 = "11vhmhms9ysa54d6x4j1rzp5p3h74h8igcihgflhma9s1kixhq0j";
  };
  geosite-category-ads-all-srs = pkgs.fetchurl {
    name = "geosite-category-ads-all.srs";
    url = "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/${metaRulesRevision}/geo/geosite/category-ads-all.srs";
    sha256 = "1lqjmc6i44s1wpcf6yg3h4bg5yfxqybbjlcyqmfdjwn1vqhp85lk";
  };
  geosite-google-srs = pkgs.fetchurl {
    name = "geosite-google.srs";
    url = "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/${metaRulesRevision}/geo/geosite/google.srs";
    sha256 = "1bs04kvrl9fap1j6vsim5445c0abhjaq4nifbp9bf18nfjlnqcn5";
  };
  geosite-steam-cn-srs = pkgs.fetchurl {
    name = "geosite-steam-cn.srs";
    url = "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/${metaRulesRevision}/geo/geosite/steam@cn.srs";
    sha256 = "0m14a4ryy6kmb90mvvz6pzvviasxs81ai2xnlcxlwh7180jrkqhp";
  };
  geosite-category-game-platforms-download-cn-srs = pkgs.fetchurl {
    name = "geosite-category-game-platforms-download-cn.srs";
    url = "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/${metaRulesRevision}/geo/geosite/category-game-platforms-download@cn.srs";
    sha256 = "1fdizcxp8v63yxqcxshjnvsxsk16knwlwca9wpq5z31d9cqpm931";
  };
  geosite-openai-srs = pkgs.fetchurl {
    name = "geosite-openai.srs";
    url = "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/${metaRulesRevision}/geo/geosite/openai.srs";
    sha256 = "05q8bilq70alfi4c9dh0zcs83kr68pdk8qcm9ly3vldr76cva5wl";
  };
  geosite-anthropic-srs = pkgs.fetchurl {
    name = "geosite-anthropic.srs";
    url = "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/${metaRulesRevision}/geo/geosite/anthropic.srs";
    sha256 = "0s6yr19nls9acky2gq72ih65p5sal5v2x5spsk37r8h2yh5zfq7v";
  };

  # All rule-set files bundled together — Nix tracks this as a single dependency.
  # Use runCommand instead of symlinkJoin because fetchurl returns files, not dirs.
  ruleSetBundle =
    pkgs.runCommand "sing-box-rule-sets"
      {
        preferLocalBuild = true;
      }
      ''
        mkdir -p $out
        ln -s ${geoip-cn-srs}             $out/geoip-cn.srs
        ln -s ${geoip-private-srs}        $out/geoip-private.srs
        ln -s ${geosite-cn-srs}           $out/geosite-cn.srs
        ln -s ${geosite-category-ads-all-srs} $out/geosite-category-ads-all.srs
        ln -s ${geosite-google-srs}       $out/geosite-google.srs
        ln -s ${geosite-steam-cn-srs}     $out/geosite-steam-cn.srs
        ln -s ${geosite-category-game-platforms-download-cn-srs} $out/geosite-category-game-platforms-download-cn.srs
        ln -s ${geosite-openai-srs}       $out/geosite-openai.srs
        ln -s ${geosite-anthropic-srs}    $out/geosite-anthropic.srs
      '';

  # Rule-set definitions — paths point into ruleSetBundle directory.
  # Nix will include ruleSetBundle in the system closure.
  mkPinnedRuleSet = tag: {
    inherit tag;
    type = "local";
    format = "binary";
    path = "${ruleSetBundle}/${tag}.srs";
  };

  # --- Node definitions ---
  # All proxy node IDs. Add/remove here to manage outbounds, secrets, and selector lists.
  allNodeIds = [
    "01"
    "02"
    "03"
    "04"
    "05"
    "06"
    "07"
    "08"
  ];
  autoNodeIds = [
    "01"
    "03"
    "05"
    "07"
  ];

  # Generate a proxy outbound attrset from a node ID.
  # All non-sensitive fields are shared; sensitive fields come from sops placeholders.
  mkNode = id: {
    type = placeholder."sing-box/nodes/${id}/type";
    uuid = placeholder."sing-box/nodes/${id}/uuid";
    alter_id = 0;
    security = "auto";
    server = placeholder."sing-box/nodes/${id}/server";
    server_port = 443;
    tag = placeholder."sing-box/nodes/${id}/name";
    packet_encoding = placeholder."sing-box/nodes/${id}/packet_encoding";
    tls = {
      disable_sni = false;
      enabled = true;
      insecure = false;
      utls = {
        enabled = false;
        fingerprint = "chrome";
      };
    };
    transport = {
      path = placeholder."sing-box/nodes/${id}/transport/path";
      type = placeholder."sing-box/nodes/${id}/transport/type";
      headers = { };
    };
    domain_resolver = {
      server = "dns_direct";
      rewrite_ttl = 60;
    };
  };

  nodeOutbounds = map mkNode allNodeIds;
  allNodeNames = map (id: placeholder."sing-box/nodes/${id}/name") allNodeIds;
  autoNodeNames = map (id: placeholder."sing-box/nodes/${id}/name") autoNodeIds;

  # Generate sops.secrets entries for all fields of a node.
  mkNodeSecrets =
    id:
    let
      fields = [
        "server"
        "name"
        "type"
        "uuid"
        "packet_encoding"
        "transport/type"
        "transport/path"
      ];
    in
    lib.listToAttrs (
      map (f: {
        name = "sing-box/nodes/${id}/${f}";
        value = mkSecret "sing-box/nodes/${id}/${f}";
      }) fields
    );

  allNodeSecrets = lib.foldl' (acc: id: acc // mkNodeSecrets id) { } allNodeIds;

  # Non-sensitive configuration lives here in Nix — reviewable, mergeable, type-checked.
  # Sensitive values use ${placeholder."..."} and are injected at activation.
  singBoxConfig = {
    experimental.clash_api = {
      external_controller = "127.0.0.1:9091";
      default_mode = "Rule";
      secret = placeholder."sing-box/clash/secret";
    }
    // lib.optionalAttrs cfg.enableDashboardUi {
      external_ui = builtins.unsafeDiscardStringContext "${pkgs.nur.repos.linyinfeng.yacd}";
    };

    log = {
      disabled = false;
      level = "info";
      timestamp = true;
    };

    ntp = {
      enabled = true;
      server = "ntp.aliyun.com";
      server_port = 123;
      interval = "30m";
    };

    endpoints = lib.optionals (cfg.enableTailscaleRouting && !cfg.useSystemTailscale) [
      {
        type = "tailscale";
        tag = "ts-ep";
        accept_routes = true;
        domain_resolver = "dns_direct";
      }
    ];

    dns = {
      #rules = [
      #  {
      #    rule_set = "geosite-google";
      #    server = "dns_global";
      #  }
      #  {
      #    rule_set = "geosite-cn";
      #    server = "dns_direct";
      #  }
      #  {
      #    domain_suffix = [
      #      placeholder."sing-box/dns/rules/direct_suffix/01"
      #      placeholder."sing-box/dns/rules/direct_suffix/02"
      #    ];
      #   server = "dns_direct";
      # }
      #];
      servers = [
        {
          tag = "dns_bootstrap";
          type = "udp";
          server = placeholder."sing-box/dns/bootstrap";
        }
      ]
      ++ lib.optionals cfg.enableTailscaleRouting [
        (
          if cfg.useSystemTailscale then
            {
              tag = "dns_ts";
              type = "tcp";
              server = "100.100.100.100";
              detour = "tailscale";
            }
          else
            {
              tag = "dns_ts";
              type = "tailscale";
              endpoint = "ts-ep";
              accept_default_resolvers = true;
            }
        )
      ]
      ++ [
        {
          tag = "dns_direct";
          type = "https";
          server = "223.5.5.5";
          detour = "direct";
        }
        {
          tag = "dns_global";
          type = "https";
          server = "8.8.4.4";
          detour = "select";
        }
      ]
      ++ lib.optionals (cfg.enableTailscaleRouting && cfg.tailscaleSocksDnsServer != null) [
        {
          tag = "dns_tailscale_socks";
          type = "udp";
          server = cfg.tailscaleSocksDnsServer;
          detour = "direct";
        }
      ]
      # In userspace-networking mode tailscaled does not answer MagicDNS at
      # 100.100.100.100 over the SOCKS proxy (dns_ts hangs). Resolve mesh names
      # via fake-ip instead: return a placeholder, then route the connection
      # (carrying the domain) to the `tailscale` SOCKS outbound, which does
      # proxy-side (socks5h) resolution.
      ++ lib.optionals (cfg.enableTailscaleRouting && cfg.useSystemTailscale) [
        {
          tag = "dns_fakeip";
          type = "fakeip";
          inet4_range = "198.18.0.0/15";
          inet6_range = "fc00::/18";
        }
      ];
      strategy = "ipv4_only";
      final = "dns_global";
      rules =
        lib.optionals cfg.enableTailscaleRouting [
          {
            domain_suffix = [
              placeholder."sing-box/dns/rules/tails_suffix/01"
            ];
            server = if cfg.useSystemTailscale then "dns_fakeip" else "dns_ts";
          }
        ]
        ++ [
          {
            domain_suffix = [
              placeholder."sing-box/dns/rules/direct_suffix/01"
              placeholder."sing-box/dns/rules/direct_suffix/02"
            ];
            server = "dns_direct";
          }
          {
            rule_set = [
              "geosite-google"
              "geosite-openai"
              "geosite-anthropic"
            ];
            server = "dns_global";
          }
          {
            rule_set = "geosite-cn";
            server = "dns_direct";
          }
          {
            domain_suffix = [
              placeholder."sing-box/dns/rules/direct_suffix/01"
              placeholder."sing-box/dns/rules/direct_suffix/02"
            ];
            server = "dns_direct";
          }
        ];
    };

    inbounds = [
    ]
    ++ lib.optionals (cfg.dnsListenAddress != null) [
      {
        type = "direct";
        tag = "dns-in-lan";
        listen = cfg.dnsListenAddress;
        listen_port = 53;
        override_address = "8.8.8.8";
        override_port = 53;
      }
    ]
    ++ lib.optionals pkgs.stdenv.isDarwin [
      {
        type = "direct";
        tag = "dns-in-v4";
        listen = "127.0.0.1";
        listen_port = 53;
        override_address = "8.8.8.8";
        override_port = 53;
      }
      {
        type = "direct";
        tag = "dns-in-v6";
        listen = "::1";
        listen_port = 53;
        override_address = "2001:4860:4860::8888";
        override_port = 53;
      }
    ]
    ++ (
      if k8sTransparentProxy then
        [
          # Cluster egress gateway shape — see
          # docs/k8s-sing-box-egress-gateway.md for design rationale
          # (strict_route=false, stack=system, route_exclude_address_set
          # bypass model). Flag is set only by flake.nix's
          # k8s-sing-box-image build site (x86_64-linux); host and darwin
          # paths default the flag to false and keep the host-mode shape.
          {
            type = "tun";
            tag = "tun-in";
            auto_route = true;
            auto_redirect = true;
            address = [
              "172.19.0.1/30"
              "fdfe:dcba:9876::1/126"
            ];
            strict_route = false;
            stack = "system";
            # Bypass list keeps RFC1918 / cluster CIDRs / loopback /
            # link-local off the TUN intercept path. Static form
            # (route_exclude_address) is used here because sing-box
            # 1.13.9 AND 1.13.11 auto_redirect's nftablesCreateAddressSets
            # fails with "create ipv4 route exclude address set: file
            # exists" whenever route_exclude_address_set has 2+ rule-set
            # entries (reproduced 2026-05-04 on talos-ii ms01-b on both
            # versions). This static list mirrors geoip-private.srs's
            # CIDRs MINUS the multicast/reserved ranges (224.0.0.0/3 +
            # ff00::/8). With those included the netlink batch in
            # sing-tun's setupNFTables final flush returns multiple
            # "file exists" — bisected to 224/3 specifically (likely
            # interacts with auto_route's default-route complement
            # computation). Multicast doesn't really matter for this
            # gateway use case. geoip-cn stays as a single rule-set
            # entry — that shape was verified working in the 04b spike.
            # When upstream fixes the multi-rule-set EEXIST + the
            # multicast-CIDR EEXIST we can collapse both back to
            # route_exclude_address_set = [geoip-private, geoip-cn].
            route_exclude_address = [
              "0.0.0.0/8"
              "10.0.0.0/8"
              "127.0.0.0/8"
              "169.254.0.0/16"
              "172.16.0.0/12"
              "192.0.0.0/24"
              "192.0.2.0/24"
              "192.88.99.0/24"
              "192.168.0.0/16"
              "198.18.0.0/15"
              "198.51.100.0/24"
              "203.0.113.0/24"
              "::/127"
              "fc00::/7"
              "fe80::/10"
            ];
            # `route_exclude_address_set` deliberately omitted (no geoip-cn
            # exclude). Original design copied the host (笔记本) shape where
            # geoip-cn is excluded from auto_redirect for LAN performance.
            # In the K8s host-mode that semantic is wrong: any consumer
            # running with hostNetwork=true on an egress node (sing-box DS
            # itself + forgejo-runner Pod, 2026-05-05) needs ALL non-private
            # egress to enter sing-box userspace so the in-config routing
            # rules (geoip-cn → direct, else → vmess) are the SOLE arbiter
            # of where packets land. With the exclude set, geoip-cn dst
            # bypassed sing-box entirely → host kernel direct → consumers
            # with no tooling-layer fallback (nix sandbox fixed-output curl,
            # Go fetcher in nix sandbox) had no proxy path. Removing this
            # makes the kernel intercept truly transparent for ALL non-RFC
            # destinations. sing-box's own outbound is excluded from
            # auto_redirect by UID (sing-tun built-in), no infinite loop.
          }
          # Mixed inbound retained during the deprecation cycle so
          # existing HTTPS_PROXY=...:7890 consumers (flux-instance,
          # tailscale, matrix, attic, zot) keep working until each is
          # migrated to a CiliumEgressGatewayPolicy. Drop this in a
          # follow-up image rebuild after swarm ADR shared/0004
          # Phase 4 burn-in.
          {
            type = "mixed";
            tag = "mixed-in";
            listen = "::";
            listen_port = 7890;
            users = [ ];
            set_system_proxy = false;
          }
        ]
      else
        [
          {
            type = "tun";
            tag = "tun-in";
            auto_route = true;
            auto_redirect = !pkgs.stdenv.isDarwin;
            address = [
              "172.19.0.1/30"
              "fdfe:dcba:9876::1/126"
            ];
            # inbound fields deprecated
            # sniff = true;
            strict_route = true;
            stack = if pkgs.stdenv.isDarwin then "mixed" else "gvisor";
            route_address = cfg.routeAddress;
            route_exclude_address = cfg.routeExcludeAddress;
            route_exclude_address_set = cfg.routeExcludeAddressSet;
          }
          {
            type = "mixed";
            tag = "mixed-in";
            listen = "::";
            listen_port = 7890;
            # inbound fields deprecated
            # sniff = true;
            users = [ ];
            set_system_proxy = false;
          }
        ]
    );

    outbounds = [
      {
        type = "selector";
        tag = "select";
        default = "auto";
        outbounds = [
          "auto"
          "direct"
        ]
        ++ allNodeNames;
      }
      {
        type = "urltest";
        tag = "auto";
        interval = "1m";
        tolerance = 50;
        url = "https://cache.nixos.org/nix-cache-info";
        outbounds = autoNodeNames;
      }
      {
        type = "direct";
        tag = "direct";
        domain_resolver = {
          server = "dns_direct";
          rewrite_ttl = 60;
        };
      }
    ]
    ++ lib.optionals (cfg.enableTailscaleRouting && cfg.useSystemTailscale) [
      (
        {
          type = "socks";
          tag = "tailscale";
          server = cfg.tailscaleSocksServer;
          server_port = cfg.tailscaleSocksPort;
        }
        // lib.optionalAttrs (cfg.tailscaleSocksDnsServer != null) {
          domain_resolver = {
            server = "dns_tailscale_socks";
            rewrite_ttl = 60;
          };
        }
      )
    ]
    ++ nodeOutbounds
    ++ [
      {
        type = "direct";
        tag = "direct-out";
        domain_resolver = {
          server = "dns_direct";
          rewrite_ttl = 60;
        };
      }
    ];

    route = {
      auto_detect_interface = true;
      default_domain_resolver = {
        server = "dns_global";
        rewrite_ttl = 60;
      };
      rules = [
        {
          action = "sniff";
        }
        {
          protocol = "dns";
          action = "hijack-dns";
        }
      ]
      ++ lib.optionals (cfg.enableTailscaleRouting && cfg.useSystemTailscale) [
        {
          process_name = [
            "tailscaled"
            ".tailscaled-wrapped"
            ".tailscaled-wra"
          ];
          network = "tcp";
          action = "route";
          outbound = "select";
        }
        {
          process_name = [
            "tailscaled"
            ".tailscaled-wrapped"
            ".tailscaled-wra"
          ];
          network = "udp";
          action = "bypass";
          outbound = "direct";
        }
      ]
      ++ lib.optionals cfg.enableTailscaleRouting [
        {
          ip_cidr = [
            placeholder."sing-box/endpoints/tailscale/subnet/01"
            placeholder."sing-box/endpoints/tailscale/subnet/02"
          ];
          action = "route";
          outbound = if cfg.useSystemTailscale then "tailscale" else "ts-ep";
        }
      ]
      ++ lib.optionals (cfg.enableTailscaleRouting && cfg.useSystemTailscale) [
        {
          domain_suffix = [
            "ts.net"
            placeholder."sing-box/dns/rules/tails_suffix/01"
          ];
          domain_regex = [ "^[^.]+$" ];
          action = "route";
          outbound = "tailscale";
        }
      ]
      ++ lib.optionals (cfg.directRouteAddress != [ ]) [
        {
          ip_cidr = cfg.directRouteAddress;
          outbound = "direct";
        }
      ]
      ++ [
        {
          ip_is_private = true;
          outbound = "direct";
        }
        {
          # beacoworks servers — bypass proxy
          ip_cidr = [
            placeholder."sing-box/endpoints/beacoworks/glacier"
            placeholder."sing-box/endpoints/beacoworks/octo"
            placeholder."sing-box/endpoints/beacoworks/flint"
            placeholder."sing-box/endpoints/beacoworks/shuttle"
            placeholder."sing-box/endpoints/beacoworks/courier"
            placeholder."sing-box/endpoints/beacoworks/cygnus"
            placeholder."sing-box/endpoints/beacoworks/navi"
            placeholder."sing-box/endpoints/beacoworks/speicher"
            placeholder."sing-box/endpoints/beacoworks/ark"
            "103.118.41.228/32"
          ];
          outbound = "direct";
        }
        {
          rule_set = [
            "geosite-google"
            "geosite-openai"
            "geosite-anthropic"
          ];
          outbound = "select";
        }
        {
          rule_set = [
            "geoip-cn"
            "geosite-cn"
          ];
          outbound = "direct";
        }
        {
          # Steam / Epic CN download CDNs — direct for faster game downloads
          rule_set = [
            "geosite-steam-cn"
            "geosite-category-game-platforms-download-cn"
          ];
          outbound = "direct";
        }
        {
          rule_set = [ "geosite-category-ads-all" ];
          action = "reject";
        }
      ];
      rule_set = [
        (mkPinnedRuleSet "geoip-cn")
        (mkPinnedRuleSet "geoip-private")
        (mkPinnedRuleSet "geosite-cn")
        (mkPinnedRuleSet "geosite-category-ads-all")
        (mkPinnedRuleSet "geosite-google")
        (mkPinnedRuleSet "geosite-steam-cn")
        (mkPinnedRuleSet "geosite-category-game-platforms-download-cn")
        (mkPinnedRuleSet "geosite-openai")
        (mkPinnedRuleSet "geosite-anthropic")
        # --- reserved (in sops, enable in route/dns rules when needed) ---
        # geosite-google-cn  (PaPerseller — Google CN-proxy subset, more targeted)
        # geosite-telegram   + geoip-telegram  (Telegram domains + IPs)
        # geosite-github     (GitHub)
        # geosite-apple      (Apple services)
        # geosite-private    (private domains, supplements ip_is_private)
        # geosite-docker     (MetaCubeX geo — Docker Hub)
      ];
    };
  };
in
{
  options.beacoworks.sing-box.enableTailscaleRouting = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Whether sing-box should provide Tailscale DNS and route handling.";
  };
  options.beacoworks.sing-box.useSystemTailscale = lib.mkEnableOption "using system tailscaled userspace SOCKS instead of sing-box's built-in Tailscale endpoint";
  options.beacoworks.sing-box.tailscaleSocksServer = lib.mkOption {
    type = lib.types.str;
    default = "127.0.0.1";
    description = "SOCKS5 server used for Tailscale routes when useSystemTailscale is enabled.";
  };
  options.beacoworks.sing-box.tailscaleSocksPort = lib.mkOption {
    type = lib.types.port;
    default = 1055;
    description = "SOCKS5 port used for Tailscale routes when useSystemTailscale is enabled.";
  };
  options.beacoworks.sing-box.tailscaleSocksDnsServer = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = "Optional DNS server used to resolve the Tailscale SOCKS5 server.";
  };
  options.beacoworks.sing-box.enableDashboardUi = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Whether to include yacd and expose it through sing-box's Clash API.";
  };
  options.beacoworks.sing-box.dnsListenAddress = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = "Optional address for a LAN-facing sing-box DNS listener.";
  };
  options.beacoworks.sing-box.routeExcludeAddress = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Host-reachable CIDRs excluded from sing-box transparent interception.";
  };
  options.beacoworks.sing-box.routeExcludeAddressSet = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "IP rule sets excluded from sing-box transparent interception.";
  };
  options.beacoworks.sing-box.routeAddress = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Destination CIDRs explicitly captured by the sing-box TUN.";
  };
  options.beacoworks.sing-box.directRouteAddress = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Destination CIDRs routed through the direct outbound before rule-set matching.";
  };

  config = {
    assertions = [
      {
        assertion = !cfg.useSystemTailscale || cfg.enableTailscaleRouting;
        message = "beacoworks.sing-box.useSystemTailscale requires enableTailscaleRouting.";
      }
    ];

    # Most hosts use the Tailscale integration in sing-box. Hosts can opt into
    # system tailscaled when CLI/debuggability matters more than one-process setup.
    services.tailscale.enable = lib.mkDefault false;

    # --- sops secrets (decrypted at activation, never in Nix store) ---
    sops.secrets = {
      "sing-box/clash/secret" = mkSecret "sing-box/clash/secret";
      "sing-box/dns/rules/tails_suffix/01" = mkSecret "sing-box/dns/rules/tails_suffix/01";
      "sing-box/dns/rules/direct_suffix/01" = mkSecret "sing-box/dns/rules/direct_suffix/01";
      "sing-box/dns/rules/direct_suffix/02" = mkSecret "sing-box/dns/rules/direct_suffix/02";
      "sing-box/dns/bootstrap" = mkSecret "sing-box/dns/bootstrap";
      "sing-box/dns/direct" = mkSecret "sing-box/dns/direct";
      "sing-box/dns/global" = mkSecret "sing-box/dns/global";
      "sing-box/endpoints/tailscale/subnet/01" = mkSecret "sing-box/endpoints/tailscale/subnet/01";
      "sing-box/endpoints/tailscale/subnet/02" = mkSecret "sing-box/endpoints/tailscale/subnet/02";
      # beacoworks servers — direct, never proxied
      "sing-box/endpoints/beacoworks/glacier" = mkSecret "sing-box/endpoints/beacoworks/glacier";
      "sing-box/endpoints/beacoworks/octo" = mkSecret "sing-box/endpoints/beacoworks/octo";
      "sing-box/endpoints/beacoworks/flint" = mkSecret "sing-box/endpoints/beacoworks/flint";
      "sing-box/endpoints/beacoworks/shuttle" = mkSecret "sing-box/endpoints/beacoworks/shuttle";
      "sing-box/endpoints/beacoworks/courier" = mkSecret "sing-box/endpoints/beacoworks/courier";
      "sing-box/endpoints/beacoworks/cygnus" = mkSecret "sing-box/endpoints/beacoworks/cygnus";
      "sing-box/endpoints/beacoworks/navi" = mkSecret "sing-box/endpoints/beacoworks/navi";
      "sing-box/endpoints/beacoworks/speicher" = mkSecret "sing-box/endpoints/beacoworks/speicher";
      "sing-box/endpoints/beacoworks/ark" = mkSecret "sing-box/endpoints/beacoworks/ark";
    }
    // allNodeSecrets;

    # --- sops template: renders full sing-box config JSON with secrets injected ---
    sops.templates."sing-box-config.json" = {
      content = builtins.toJSON singBoxConfig;
    }
    // lib.optionalAttrs pkgs.stdenv.isLinux {
      restartUnits = [ "sing-box.service" ];
    };

    # --- sing-box service ---
    services.sing-box.enable = true;

    # Ensure yacd is built and kept in the nix store, even though the sops
    # template discards its string context to avoid serialization issues.
    environment.systemPackages = lib.optionals cfg.enableDashboardUi [ pkgs.nur.repos.linyinfeng.yacd ];

    # Platform-specific config file binding is set in:
    #   darwin: modules/darwin/sing-box.nix sets services.sing-box.configFile
    #   NixOS:  modules/nixos/sing-box.nix overrides systemd ExecStartPre
  };
}

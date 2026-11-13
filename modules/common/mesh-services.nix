{ config, lib, ... }:

let
  cfg = config.beacoworks.mesh;
  providers = lib.attrByPath [ "socksProviders" ] { } cfg;
  services = lib.filterAttrs (_: service: service.enable) cfg.services;
  serviceList = lib.attrValues services;
  domains = service: map lib.toLower service.domains;
  matches = lib.concatMap (service: map (domain: "${domain}:${toString service.port}") (domains service)) serviceList;
  listeners = lib.filter (service: service.listen != null) serviceList;
  bindings = map (service: "${service.listen.address}:${toString service.listen.port}") listeners;
  route = service: {
    network = "tcp";
    action = "route";
    outbound = "mesh-${service.provider}";
    override_address = service.target.address;
    override_port = service.target.port;
  };
  domainPattern = "[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+";
in
{
  options.beacoworks.mesh = {
    services = lib.mkOption {
      default = { };
      description = "TCP service targets independent of a MeshVPN backend's naming scheme.";
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "this mesh service target";
          provider = lib.mkOption {
            type = lib.types.nonEmptyStr;
            description = "Enabled SOCKS provider registered by the deployment.";
          };
          domains = lib.mkOption {
            type = lib.types.listOf lib.types.nonEmptyStr;
            default = [ ];
            description = "Exact client-facing domain names; TLS SNI is preserved.";
          };
          port = lib.mkOption {
            type = lib.types.port;
            default = 443;
            description = "Client destination port matched with the domain names.";
          };
          target = {
            address = lib.mkOption {
              type = lib.types.nonEmptyStr;
              description = "Backend address passed to the selected SOCKS provider for resolution.";
            };
            port = lib.mkOption {
              type = lib.types.port;
              description = "Backend TCP port.";
            };
          };
          listen = lib.mkOption {
            default = null;
            description = "Optional local TCP endpoint for consumers such as a TLS passthrough proxy.";
            type = lib.types.nullOr (lib.types.submodule {
              options = {
                address = lib.mkOption {
                  type = lib.types.enum [ "127.0.0.1" "::1" ];
                  default = "127.0.0.1";
                };
                port = lib.mkOption { type = lib.types.port; };
              };
            });
          };
        };
      });
    };

    serviceRouting = lib.mkOption {
      type = lib.types.attrs;
      readOnly = true;
      description = "sing-box fragments consumed by the site's routing configuration.";
    };
  };

  config = {
    assertions = [
      {
        assertion = lib.all (service: lib.attrByPath [ service.provider "enable" ] false providers) serviceList;
        message = "Mesh services must reference an enabled SOCKS provider.";
      }
      {
        assertion = lib.all (name: builtins.match "[a-zA-Z0-9][a-zA-Z0-9._-]*" name != null) (lib.attrNames services);
        message = "Mesh service names must contain only letters, digits, dots, underscores and hyphens.";
      }
      {
        assertion = lib.all (service: service.domains != [ ] || service.listen != null) serviceList;
        message = "Mesh services need exact domain matches or a local TCP endpoint.";
      }
      {
        assertion = lib.all (domain: builtins.match domainPattern domain != null) (lib.concatMap domains serviceList);
        message = "Mesh service domains must be exact DNS names without wildcards, schemes or ports.";
      }
      {
        assertion = builtins.length matches == builtins.length (lib.unique matches);
        message = "A domain and TCP port may belong to only one mesh service.";
      }
      {
        assertion = builtins.length bindings == builtins.length (lib.unique bindings);
        message = "Mesh service TCP listeners must have unique loopback bindings.";
      }
      {
        assertion = lib.all
          (service:
            lib.all
              (provider:
                !(provider.enable or false)
                || (provider.port or null) != service.listen.port
                || !(lib.elem (provider.server or "127.0.0.1") [ service.listen.address "localhost" "::" "0.0.0.0" ])
              )
              (lib.attrValues providers)
          )
          listeners;
        message = "Mesh service listeners must not bind a local SOCKS provider's endpoint.";
      }
      {
        assertion = lib.all
          (service:
            !(lib.elem (lib.toLower service.target.address) (domains service))
            && !(lib.elem (lib.toLower service.target.address) [ "localhost" "::1" ])
            && builtins.match "127\\..*" service.target.address == null
            && !(lib.hasInfix "://" service.target.address)
          )
          serviceList;
        message = "Mesh service targets must be remote addresses distinct from their client-facing names.";
      }
    ];

    beacoworks.mesh.serviceRouting = {
      needsFakeIP = lib.any (service: service.domains != [ ]) serviceList;
      dnsRules = lib.optional (serviceList != [ ] && matches != [ ]) {
        domain = lib.unique (lib.concatMap domains serviceList);
        query_type = [ "A" "AAAA" ];
        server = "dns_fakeip";
      };
      inbounds = lib.mapAttrsToList
        (name: service: {
          type = "direct";
          tag = "mesh-service-${name}";
          network = "tcp";
          listen = service.listen.address;
          listen_port = service.listen.port;
        })
        (lib.filterAttrs (_: service: service.listen != null) services);
      routeRules = lib.mapAttrsToList
        (name: service:
          (route service) // {
            inbound = [ "mesh-service-${name}" ];
          }
        )
        (lib.filterAttrs (_: service: service.listen != null) services)
      ++ lib.mapAttrsToList
        (_: service:
          (route service) // {
            domain = domains service;
            port = service.port;
          }
        )
        (lib.filterAttrs (_: service: service.domains != [ ]) services);
    };
  };
}

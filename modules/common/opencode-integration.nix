# OpenCode web and MCP integration secrets for local AI clients.
{ lib, config, ... }:

let
  secretFile = ../../secrets/personal/opencode-integration.yaml;
  secretExists = builtins.pathExists secretFile;
  ownerHint =
    if builtins.hasAttr "beacon" config.users.users then
      "beacon"
    else if builtins.hasAttr "nixos" config.users.users then
      "nixos"
    else
      "root";
in
{
  sops.secrets = lib.mkIf secretExists {
    "personal/n8n-mcp/authorization" = {
      sopsFile = secretFile;
      owner = ownerHint;
      mode = "0400";
    };
    "personal/opencode-web/username" = {
      sopsFile = secretFile;
      owner = ownerHint;
      mode = "0400";
    };
    "personal/opencode-web/password" = {
      sopsFile = secretFile;
      owner = ownerHint;
      mode = "0400";
    };
    "personal/beacoworks-models/api_base" = {
      sopsFile = secretFile;
      owner = ownerHint;
      mode = "0400";
    };
    "personal/beacoworks-models/api_key" = {
      sopsFile = secretFile;
      owner = ownerHint;
      mode = "0400";
    };
    "personal/kingsoft-docs/token" = {
      sopsFile = secretFile;
      owner = ownerHint;
      mode = "0400";
    };
    "personal/tavily/api-key" = {
      sopsFile = secretFile;
      owner = ownerHint;
      mode = "0400";
    };
  };

  sops.templates = lib.mkIf secretExists {
    "opencode-web.env" = {
      owner = ownerHint;
      mode = "0400";
      content = ''
        N8N_MCP_AUTHORIZATION='${config.sops.placeholder."personal/n8n-mcp/authorization"}'
        OPENCODE_SERVER_USERNAME='${config.sops.placeholder."personal/opencode-web/username"}'
        OPENCODE_SERVER_PASSWORD='${config.sops.placeholder."personal/opencode-web/password"}'
        BEACOWORKS_MODELS_API_BASE='${config.sops.placeholder."personal/beacoworks-models/api_base"}'
        BEACOWORKS_MODELS_API_KEY='${config.sops.placeholder."personal/beacoworks-models/api_key"}'
        KINGSOFT_DOCS_TOKEN='${config.sops.placeholder."personal/kingsoft-docs/token"}'
      '';
    };
  };
}

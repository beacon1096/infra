{ config, lib, osConfig, pkgs, ... }:

let
  jsonFormat = pkgs.formats.json { };
  outlineMcpUrl = "https://docs.beacoworks.xyz/mcp";
  n8nSecretName = "personal/n8n-mcp/authorization";
  n8nSecretAttr = [ "sops" "secrets" n8nSecretName ];
  n8nSecretPath = (lib.attrByPath n8nSecretAttr null osConfig).path;

  outlineSecretName = "personal/outline/mcp-bearer";
  outlineSecretAttr = [ "sops" "secrets" outlineSecretName ];
  outlineSecretPath = (lib.attrByPath outlineSecretAttr null osConfig).path;

  tavilySecretName = "personal/tavily/api-key";
  tavilySecretAttr = [ "sops" "secrets" tavilySecretName ];
  tavilySecretPath = (lib.attrByPath tavilySecretAttr null osConfig).path;

  mkMcpSecretEnvActivation =
    {
      secretPath,
      envFile,
      envVar,
    }:
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      secret_path="${secretPath}"
      env_dir="$HOME/.config/environment.d"
      env_file="$env_dir/${envFile}"

      run install -d -m 0700 "$env_dir"

      if [ ! -r "$secret_path" ]; then
        echo "${envVar} secret is not readable at $secret_path" >&2
        exit 1
      fi

      run rm -f "$env_file"

      secret_value="$(tr -d '\n' < "$secret_path")"

      printf '${envVar}="%s"\n' "$secret_value" > "$env_file"

      run chmod 0600 "$env_file"

      if command -v systemctl >/dev/null 2>&1; then
        systemctl --user set-environment "${envVar}=$secret_value" || true
      fi

      if command -v dbus-update-activation-environment >/dev/null 2>&1; then
        ${envVar}="$secret_value" dbus-update-activation-environment --systemd ${envVar} || true
      fi
    '';

  # cursor-agent silently drops the entire ~/.cursor/mcp.json when any entry is
  # invalid (e.g. url + type "stdio", or explicit null fields). Omit `type` for
  # URL servers; Cursor infers transport from command vs url.
  cursorAgentMcpEntry =
    server:
    if server ? command then
      lib.filterAttrs (_: v: v != null && v != [ ] && v != { }) {
        command = server.command;
        args = server.args or [ ];
        env = server.env or { };
      }
    else
      lib.filterAttrs (_: v: v != null && v != [ ] && v != { }) {
        url = server.url;
        headers = server.headers or { };
      };
in

{
  programs.mcp.enable = true;

  programs.mcp.servers = {
    n8n-mcp = {
      url = "https://automaton.beaco.works/mcp-server/http";
      headers.Authorization = "{env:N8N_MCP_AUTHORIZATION}";
    };

    grep = {
      url = "https://mcp.grep.app";
    };

    outline = {
      url = outlineMcpUrl;
      headers.Authorization = "Bearer {env:OUTLINE_MCP_BEARER}";
    };

    playwright = {
      command = lib.getExe pkgs.playwright-mcp;
      args = [
        "--browser"
        "firefox"
      ];
    };
  }
  // lib.optionalAttrs (lib.hasAttrByPath tavilySecretAttr osConfig) {
    tavily = {
      url = "https://mcp.tavily.com/mcp/";
      headers.Authorization = "Bearer {env:TAVILY_API_KEY}";
    };
  };

  programs.vscode.profiles.default.enableMcpIntegration = true;
  programs.cursor.profiles.default.enableMcpIntegration = true;
  programs.claude-code.enableMcpIntegration = true;

  home.file.".cursor/mcp.json".source = jsonFormat.generate "cursor-mcp.json" {
    mcpServers = lib.mapAttrs (_: cursorAgentMcpEntry) config.programs.mcp.servers;
  };

  home.activation.outlineCodexMcp = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    codex_config="$HOME/.codex/config.toml"
    run install -d -m 0700 "$HOME/.codex"
    if [ ! -e "$codex_config" ]; then
      run install -m 0600 /dev/null "$codex_config"
    fi
    if [ -f "$codex_config" ] && ! grep -q '^\[mcp_servers\.outline\]$' "$codex_config"; then
      printf '\n[mcp_servers.outline]\nurl = "${outlineMcpUrl}"\n' | run tee -a "$codex_config" >/dev/null
    fi
  '';

  home.activation.n8nMcpAuthorizationEnv = lib.mkIf (lib.hasAttrByPath n8nSecretAttr osConfig) (
    mkMcpSecretEnvActivation {
      secretPath = n8nSecretPath;
      envFile = "21-n8n-mcp.conf";
      envVar = "N8N_MCP_AUTHORIZATION";
    }
  );

  home.activation.outlineMcpBearerEnv = lib.mkIf (lib.hasAttrByPath outlineSecretAttr osConfig) (
    mkMcpSecretEnvActivation {
      secretPath = outlineSecretPath;
      envFile = "22-outline-mcp.conf";
      envVar = "OUTLINE_MCP_BEARER";
    }
  );

  home.activation.tavilyMcpApiKeyEnv = lib.mkIf (lib.hasAttrByPath tavilySecretAttr osConfig) (
    mkMcpSecretEnvActivation {
      secretPath = tavilySecretPath;
      envFile = "20-tavily-mcp.conf";
      envVar = "TAVILY_API_KEY";
    }
  );
}

{ config, lib, osConfig, pkgs, ... }:

let
  jsonFormat = pkgs.formats.json { };
  tavilySecretName = "personal/tavily/api-key";
  tavilySecretAttr = [ "sops" "secrets" tavilySecretName ];
  tavilySecretPath = (lib.attrByPath tavilySecretAttr null osConfig).path;
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
    mcpServers = lib.mapAttrs
      (_: server:
        let
          addType = if server ? command then "stdio" else "sse";
        in
        server // { type = addType; }
      )
      config.programs.mcp.servers;
  };

  home.activation.tavilyMcpApiKeyEnv = lib.mkIf
    (lib.hasAttrByPath tavilySecretAttr osConfig)
    (lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      secret_path="${tavilySecretPath}"
      env_dir="$HOME/.config/environment.d"
      env_file="$env_dir/20-tavily-mcp.conf"

      run install -d -m 0700 "$env_dir"

      if [ ! -r "$secret_path" ]; then
        echo "tavily api key is not readable at $secret_path" >&2
        exit 1
      fi

      run rm -f "$env_file"

      tavily_api_key="$(tr -d '\n' < "$secret_path")"

      printf 'TAVILY_API_KEY="%s"\n' "$tavily_api_key" > "$env_file"

      run chmod 0600 "$env_file"

      if command -v systemctl >/dev/null 2>&1; then
        systemctl --user set-environment "TAVILY_API_KEY=$tavily_api_key" || true
      fi

      if command -v dbus-update-activation-environment >/dev/null 2>&1; then
        TAVILY_API_KEY="$tavily_api_key" dbus-update-activation-environment --systemd TAVILY_API_KEY || true
      fi
    '');
}

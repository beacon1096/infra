{ ... }:

{
  # Keep shared defaults below Codex's mutable user config.
  environment.etc."codex/config.toml".text = ''
    [mcp_servers.n8n-mcp]
    url = "https://automaton.beaco.works/mcp-server/http"

    [mcp_servers.n8n-mcp.env_http_headers]
    Authorization = "N8N_MCP_AUTHORIZATION"
  '';
}

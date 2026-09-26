{ config, inputs, lib, osConfig, pkgs, ... }:

let
  cfg = config.beacon.pi;
  piPkgs = import inputs.pi-nixpkgs {
    system = pkgs.stdenv.hostPlatform.system;
    config = pkgs.config;
  };
  piWebAccess = pkgs.callPackage ./pi-web-access/package.nix { };
  tavilySecretPath = osConfig.sops.secrets."personal/tavily/api-key".path or null;
  modelBasePath = osConfig.sops.secrets."personal/beacoworks-models/api_base".path or null;
  modelKeyPath = osConfig.sops.secrets."personal/beacoworks-models/api_key".path or null;
  piWebSearchConfig = pkgs.writeText "pi-web-search-defaults.json" (builtins.toJSON (lib.recursiveUpdate {
    searxngBaseUrl = cfg.searchBaseURL;
    searxngHeaders.User-Agent = "node";
    tavilyApiKey =
      if tavilySecretPath != null then
        "!${pkgs.coreutils}/bin/cat ${lib.escapeShellArg tavilySecretPath}"
      else
        "$TAVILY_API_KEY";
    searchRouting = {
      providers = [ "searxng" "tavily" ];
      fallbackOn = [ "unsupported" "transient" "quota" "network" "invalid-response" ];
    };
    workflow = "none";
    fetch.timeout = 30;
    fetchRouting = {
      providers = [ "http" ];
      allowRemoteHostedProviders = false;
    };
    tools = {
      webSearch.enabled = true;
      sourceCheck.enabled = false;
      fetchContent.enabled = true;
      getSearchContent.enabled = true;
    };
    commands = {
      websearch.enabled = true;
      curator.enabled = true;
      search.enabled = true;
    };
    allowBrowserCookies = false;
    image.enabled = true;
    githubClone = {
      enabled = true;
      maxRepoSizeMB = 350;
      cloneTimeoutSeconds = 30;
    };
    githubPrIssue.enabled = true;
    youtube.enabled = true;
    video = { enabled = true; maxSizeMB = 50; };
    pdf = { enabled = true; maxSizeMB = 20; provider = "unpdf"; };
  } cfg.webSearchExtraConfig));
  models = lib.mapAttrsToList
    (id: model: {
      inherit id;
      inherit (model) name;
      reasoning = model.reasoning or false;
      input = model.modalities.input;
      contextWindow = model.limit.context;
      maxTokens = model.limit.output;
      cost = {
        input = 0;
        output = 0;
        cacheRead = 0;
        cacheWrite = 0;
      };
    })
    cfg.models;
in
{
  options.beacon.pi = {
    enable = lib.mkEnableOption "Pi coding-agent harness";
    models = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Models registered with the optional OpenAI-compatible provider.";
    };
    modelBaseURL = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional provider base URL when no runtime environment override is set.";
    };
    searchBaseURL = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "SearXNG endpoint for Pi web access; null disables that extension.";
    };
    webSearchExtraConfig = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Deployment-specific pi-web-access settings.";
    };
    rulesFile = lib.mkOption {
      type = lib.types.path;
      default = ../../rules/AGENTS.md;
      description = "Shared agent rules included in Pi's AGENTS.md.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ piPkgs.pi-coding-agent ]
      ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.libsecret ];

    home.file.".pi/agent/AGENTS.md".text = builtins.readFile cfg.rulesFile + ''

      ## Pi task execution

      - Before reporting a review finding, re-read the exact relevant lines and verify that they support the claim. Distinguish observed failures from untested risks.
      - When asked to take over an agent or session, resolve the supplied ID and read its task and handoff first. A shared dirty working tree is not a task specification; distinguish existing changes from your own.
      - Preserve existing regression tests unless replacing them with equivalent verified coverage. Generate patch files from modified source using diff; do not hand-edit hunk counts.
      - Narrow searches to known files and exclude source maps and generated bundles. Read bounded ranges or structured summaries, not raw session JSONL or the whole Nix store. Check builder platform and runtime capabilities before starting large builds.
      - Background exec completion is automatic. Do independent work or finish the turn; do not loop through exec_status, sleep, ps or tail merely to wait. Inspect progress when the user asks or when diagnosing a concrete failure.
      - State the current objective and next step when starting work. During active work, give a concise update about once a minute or when the plan changes. Do not repeat an unchanged summary for every completion notification.
    '';

    home.file.".pi/agent/extensions/exec.ts".source = ./pi-exec/extension.ts;
    home.file.".pi/agent/extensions/turn-aborted.ts".source = ./pi-turn-aborted/extension.ts;
    home.file.".pi/agent/extensions/web-access.ts" = lib.mkIf (cfg.searchBaseURL != null) {
      text = ''
        export { default } from "${piWebAccess}/lib/node_modules/pi-web-access/index.ts";
      '';
    };
    home.file.".pi/agent/extensions/litellm.ts" = lib.mkIf (cfg.models != { }) {
      text = ''
        import { readFileSync } from "node:fs";

        export default function (pi) {
          const basePath = ${builtins.toJSON modelBasePath};
          const configuredBaseUrl = ${builtins.toJSON cfg.modelBaseURL};
          const baseUrl = process.env.BEACOWORKS_MODELS_API_BASE
            || configuredBaseUrl
            || (basePath ? readFileSync(basePath, "utf8").trim() : "");
          if (!baseUrl) return;
          pi.registerProvider("litellm", {
            baseUrl,
            api: "openai-completions",
            apiKey: process.env.BEACOWORKS_MODELS_API_KEY
              ? "$BEACOWORKS_MODELS_API_KEY"
              : ${builtins.toJSON (if modelKeyPath != null then "!${pkgs.coreutils}/bin/cat ${lib.escapeShellArg modelKeyPath}" else "$BEACOWORKS_MODELS_API_KEY")},
            models: ${builtins.toJSON models},
          });
        }
      '';
    };

    home.activation.piSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      settings=${lib.escapeShellArg "${config.home.homeDirectory}/.pi/agent/settings.json"}
      run mkdir -p "$(dirname "$settings")"
      if [ -z "''${DRY_RUN_CMD:-}" ]; then
        if [ ! -e "$settings" ]; then printf '{}\n' > "$settings"; fi
        temporary=$(mktemp "$(dirname "$settings")/.settings.XXXXXX")
        ${pkgs.jq}/bin/jq '. * {httpIdleTimeoutMs: 2400000, retry: {enabled: false, provider: {timeoutMs: 2400000, maxRetries: 0}}}' "$settings" > "$temporary"
        mv "$temporary" "$settings"
      fi
    '';
    home.activation.piWebSearchSettings = lib.mkIf (cfg.searchBaseURL != null)
      (lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        web_settings=${lib.escapeShellArg "${config.home.homeDirectory}/.pi/web-search.json"}
        run mkdir -p "$(dirname "$web_settings")"
        if [ -z "''${DRY_RUN_CMD:-}" ]; then
          if [ ! -e "$web_settings" ]; then printf '{}\n' > "$web_settings"; fi
          temporary=$(mktemp "$(dirname "$web_settings")/.web-search.XXXXXX")
          ${pkgs.jq}/bin/jq --slurpfile defaults ${piWebSearchConfig} 'del(.provider, .searchProvider, .fetch.answerProvider, .fetch.answerModel) * $defaults[0]' "$web_settings" > "$temporary"
          mv "$temporary" "$web_settings"
        fi
      '');
  };
}

# Headless coding-agent tools shared by local shells and Coder workspaces.
{
  inputs,
  pkgs,
  lib,
  osConfig,
  ...
}:

let
  unstablePkgs = import inputs.nixpkgs-unstable {
    system = pkgs.stdenv.hostPlatform.system;
    config = pkgs.config;
    overlays = [ inputs.llmAgents.overlays.shared-nixpkgs ];
  };
  agentRules = ../../rules/AGENTS.md;
  modelCredential = name: env:
    let
      path = osConfig.sops.secrets."personal/beacoworks-models/${name}".path or null;
    in
    if path != null then "{file:${path}}" else "{env:${env}}";
  textModel = name: context: output: {
    inherit name;
    limit = { inherit context output; };
    modalities = {
      input = [ "text" ];
      output = [ "text" ];
    };
  };
  visionTextModel = name: context: output: {
    inherit name;
    limit = { inherit context output; };
    modalities = {
      input = [
        "text"
        "image"
      ];
      output = [ "text" ];
    };
  };
  reasoningTextModel =
    name: context: output:
    (textModel name context output) // { reasoning = true; };
  reasoningVisionTextModel =
    name: context: output:
    (visionTextModel name context output) // { reasoning = true; };
  beacoworksModels = {
    "dashscope/qwen3.7-max" = reasoningTextModel "Qwen3.7 Max" 1000000 65536;
    "dashscope/qwen3.6-flash" = reasoningTextModel "Qwen3.6 Flash" 1000000 1000000;
    "deepseek/deepseek-v4-flash" = textModel "DeepSeek V4 Flash" 1048576 393216;
    "deepseek/deepseek-v4-pro" = textModel "DeepSeek V4 Pro" 1048576 393216;
    "minimax/MiniMax-M3" = reasoningVisionTextModel "MiniMax M3" 1000000 512000;
    "moonshot/kimi-k2.6" = reasoningVisionTextModel "Kimi K2.6" 262144 262144;
    "moonshot/kimi-k2.7-code" = reasoningVisionTextModel "Kimi K2.7 Code" 262144 32768;
    "xiaomi_mimo/mimo-v2.5" = reasoningVisionTextModel "MiMo V2.5" 1048576 131072;
    "xiaomi_mimo/mimo-v2.5-pro" = reasoningTextModel "MiMo V2.5 Pro" 1048576 131072;
    "zai/glm-5.2" = reasoningTextModel "GLM-5.2" 1048576 131072;
  };
  kdocsCliVersion = "2.5.17";
  kdocsCliTargets = {
    x86_64-linux = {
      platform = "linux-amd64";
      hash = "sha256-agmVuZiYGlEeEmgUTyFO6XiCreM13uKw8yyUzkZt/nM=";
    };
    aarch64-linux = {
      platform = "linux-arm64";
      hash = "sha256-PdiUsUtWEezCtMw88TQ9nY848UIIl1xT+e8vgSjDzZY=";
    };
    x86_64-darwin = {
      platform = "darwin-amd64";
      hash = "sha256-IYKqh/PAU0QqGvP91z0Nfb3fqOsonL6GrdsdMwwF2Qg=";
    };
    aarch64-darwin = {
      platform = "darwin-arm64";
      hash = "sha256-rB3ipTv8PhjLUr6mrtk4SPn3Wv9kJ9OzXBeAkEHNxek=";
    };
  };
  kdocsCliTarget =
    kdocsCliTargets.${pkgs.stdenv.hostPlatform.system}
      or (throw "kdocs-cli: unsupported platform ${pkgs.stdenv.hostPlatform.system}");
  kdocsCli = pkgs.stdenvNoCC.mkDerivation {
    pname = "kdocs-cli";
    version = kdocsCliVersion;
    src = pkgs.fetchurl {
      url = "https://wpsai.wpscdn.cn/skillhub/pro/v${kdocsCliVersion}/releases/kdocs-cli-${kdocsCliVersion}-${kdocsCliTarget.platform}.tar.gz";
      inherit (kdocsCliTarget) hash;
    };
    dontUnpack = true;
    installPhase = ''
      runHook preInstall
      tar xzf $src
      install -Dm755 kdocs-cli $out/bin/kdocs-cli
      printf kdocs > $out/bin/.source
      runHook postInstall
    '';
  };
  kdocsSkillZip = pkgs.fetchurl {
    url = "https://wpsai.wpscdn.cn/skillhub/pro/v${kdocsCliVersion}/kdocs.zip";
    hash = "sha256-opHHk4ymWLEiO1rNGD8z5kpO17EsVYvx4Koq7SnKZLQ=";
  };
  kdocsSkill =
    pkgs.runCommand "kdocs-skill-${kdocsCliVersion}"
      {
        nativeBuildInputs = [ pkgs.unzip ];
      }
      ''
        mkdir -p "$out"
        unzip -q "${kdocsSkillZip}" -d "$TMPDIR" || [ "$?" -eq 1 ]
        cp -R "$TMPDIR/kdocs/." "$out/"
      '';
  agentSkills = {
    kdocs = kdocsSkill;
    outsource = ./skills/outsource;
    web_search = ./skills/web_search;
  };
in
{
  imports = [
    inputs.codex-desktop-linux.homeManagerModules.default
    ./mcp.nix
    ./pi.nix
  ];

  beacon.pi = {
    enable = true;
    models = beacoworksModels;
    searchBaseURL = "https://search.beaco.works";
  };

  programs.claude-code = {
    enable = true;
    package = unstablePkgs.claude-code;
    context = agentRules;
    skills = agentSkills;
  };

  programs.codex = {
    enable = true;
    package = unstablePkgs.codex;
    context = agentRules;
    #enableMcpIntegration = true;
    skills = agentSkills;
  };

  programs.codexDesktopLinux = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
    enable = false;
    cliPackage = unstablePkgs.codex;
  };

  programs.opencode = {
    enable = true;
    package = unstablePkgs.llm-agents.opencode;
    context = agentRules;
    enableMcpIntegration = true;
    skills = agentSkills;
    web = {
      enable = true;
      environmentFile = "/run/secrets/rendered/opencode-web.env";
      extraArgs = [
        "--hostname"
        "0.0.0.0"
        "--port"
        "4096"
      ];
    };
    settings = {
      compaction.auto = true;
      plugin = [ "@warp-dot-dev/opencode-warp" ];
      permission = "allow";
      disabled_providers = [
        "zen"
        "opencode"
      ];
      provider = {
        beacoworks = {
          name = "Beacoworks";
          npm = "@ai-sdk/openai-compatible";
          options = {
            baseURL = modelCredential "api_base" "BEACOWORKS_MODELS_API_BASE";
            apiKey = modelCredential "api_key" "BEACOWORKS_MODELS_API_KEY";
          };
          models = beacoworksModels;
        };
      };
    };
  };

  home.packages =
    with unstablePkgs;
    [
      antigravity-cli
      claude-code-router
      kdocsCli
      findutils
      openssl
      sops
      spec-kit
      openspec
      gh
      #  llm-agents.kimi-code
    ]
    ++ lib.optionals (unstablePkgs ? happy-coder) [
      unstablePkgs.happy-coder
    ];
}

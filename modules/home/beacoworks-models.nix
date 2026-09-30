{ lib }:

let
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
    "thor/qwen3.8-27b" = reasoningVisionTextModel "Thor Qwen3.8 27B" 262144 65536;
    "xiaomi_mimo/mimo-v2.5" = reasoningVisionTextModel "MiMo V2.5" 1048576 131072;
    "xiaomi_mimo/mimo-v2.5-pro" = reasoningTextModel "MiMo V2.5 Pro" 1048576 131072;
    "zai/glm-5.2" = reasoningTextModel "GLM-5.2" 1048576 131072;
    "lcai/qwen-3.8-27b-uncensored" = reasoningTextModel "Qwen3.8 27B Uncensored" 512000 65536;
    "lcai/qwen-3.8-flash-next-uncensored" = reasoningTextModel "Qwen3.8 Flash Next Uncensored" 256000 65536;
    "thor/qwen3.8-auto" = reasoningTextModel "Thor Qwen3.8 Auto" 256000 65536;
  };
  # Pi's OpenAI-compatible adapter controls thinking only through `compat`. These
  # LiteLLM routes land on vLLM/SGLang, which read `chat_template_kwargs`, so the
  # default OpenAI `reasoning_effort` is ignored and "off" sends nothing at all.
  # The deployed Qwen3.8 chat template accepts reasoning_effort=xhigh|medium|low,
  # so map pi's levels onto those values instead of collapsing them to on/off.
  piModelCompat = {
    "thor/qwen3.8-27b" = {
      thinkingLevelMap = {
        minimal = "low";
        low = "low";
        medium = "medium";
        high = "xhigh";
        xhigh = "xhigh";
        max = "xhigh";
      };
      compat = {
        thinkingFormat = "chat-template";
        chatTemplateKwargs = {
          enable_thinking = { "$var" = "thinking.enabled"; };
          reasoning_effort = { "$var" = "thinking.effort"; omitWhenOff = true; };
          preserve_thinking = true;
        };
      };
    };
  };
  piModels = lib.mapAttrs (id: model: model // (piModelCompat.${id} or { })) beacoworksModels;
in
{
  inherit beacoworksModels piModels;
}

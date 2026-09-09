# Clerk "default" — per-clerk Home Manager configuration
{ ... }:

{
  # OpenClaw configuration
  # Uncomment and configure when ready:
  #
  # programs.openclaw = {
  #   enable = true;
  #   documents = ./documents;
  #   config = {
  #     gateway = {
  #       mode = "local";
  #       auth.token = "CHANGEME";
  #     };
  #     channels.telegram = {
  #       tokenFile = "/Users/openclaw/.secrets/telegram-bot-token";
  #       allowFrom = [ /* your Telegram user ID */ ];
  #     };
  #   };
  #   bundledPlugins = {
  #     peekaboo.enable = true;
  #     poltergeist.enable = true;
  #     summarize.enable = true;
  #   };
  # };
}

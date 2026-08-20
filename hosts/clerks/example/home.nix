# Clerk "example" — template for new clerk Home Manager configuration
{ lib, ... }:

{
  # Git identity for this clerk
  # programs.git.settings.user = {
  #   name = lib.mkForce "Clerk Name";
  #   email = lib.mkForce "clerk@example.com";
  # };

  # OpenClaw configuration
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

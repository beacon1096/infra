{ lib, ... }:

{
  options.beacoworks.agent.role = lib.mkOption {
    type = lib.types.enum [ "copilot" "autopilot" ];
    default = "copilot";
    description = "Identity fixed by the Home Manager deployment profile.";
  };
}

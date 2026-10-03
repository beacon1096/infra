{ nixpkgs }:
final: _prev:
let
  # Keep the package and Go toolchain independent of consumers such as Thor.
  pkgs = nixpkgs.legacyPackages.${final.stdenv.hostPlatform.system};
in
{
  tailscale = pkgs.tailscale.overrideAttrs (finalAttrs: _oldAttrs: {
    version = "1.102.1";
    src = pkgs.fetchFromGitHub {
      owner = "tailscale";
      repo = "tailscale";
      tag = "v${finalAttrs.version}";
      hash = "sha256-zsYFnk6QI1MAc8ROL3RPSoQTKtmINYWAbAsaDwom0WI=";
    };
    vendorHash = "sha256-amKkUPszyhG4N5ZtrB01swBACYq76raSS+SQRneLmwc=";
    ldflags = [
      "-w"
      "-s"
      "-X tailscale.com/version.longStamp=${finalAttrs.version}"
      "-X tailscale.com/version.shortStamp=${finalAttrs.version}"
    ];
  });
}

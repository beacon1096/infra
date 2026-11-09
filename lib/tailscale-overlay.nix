{ nixpkgs }:
final: _prev:
let
  # Keep the package and Go toolchain independent of consumers such as Thor.
  pkgs = nixpkgs.legacyPackages.${final.stdenv.hostPlatform.system};
in
{
  tailscale = pkgs.tailscale;
}

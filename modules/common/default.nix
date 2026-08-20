{ lib, ... }:
{
  imports = [
    ./nix.nix
    ./attic-cache.nix
    ./opencode-integration.nix
    ./packages.nix
    ./coding.nix
    ./sing-box.nix
  ];

  # k8sTransparentProxy is consumed by modules/common/sing-box.nix and
  # set to true via specialArgs in flake.nix for the k8s-sing-box-image
  # build. NixOS module evaluation does not honor function-arg
  # defaults (`arg ? value`) — it consults _module.args first — so we
  # provide a default here. specialArgs override this on the k8s build.
  _module.args.k8sTransparentProxy = lib.mkDefault false;
}

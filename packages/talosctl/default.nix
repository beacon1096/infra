{
  fetchurl,
  lib,
  stdenvNoCC,
}:

# talosctl pinned to the version the Wanxiang Talos nodes run
# (wanxiang/talos/talenv.yaml talosVersion). The nixos-26.05 pin ships an
# older talosctl, which makes every inspection report a client/server
# version drift (BEACO-140). Exposed as packages.<system>.talosctl so both
# the public and private flakes' coding-agent images (and any future host
# module) consume one definition.
let
  version = "1.13.10";
  targets = {
    x86_64-linux = {
      platform = "linux-amd64";
      hash = "sha256-KOnM2a69aQ+gPYzyWCIh2H6jiyoXBPQR11oDWJxY8qo=";
    };
    aarch64-linux = {
      platform = "linux-arm64";
      hash = "sha256-OGnJ+0EfNoCXbMCGs0LlF7z0vHIPflNxYR8+SdlfGZQ=";
    };
    x86_64-darwin = {
      platform = "darwin-amd64";
      hash = "sha256-TCoO8TLsOoiRokI0kkgcU9jVXA5cAUZ3njwz5sOI4fM=";
    };
    aarch64-darwin = {
      platform = "darwin-arm64";
      hash = "sha256-YFAXilpmhpZft+o/Wd/hcocqiIszVaT2KBTzqHJKecc=";
    };
  };
  target =
    targets.${stdenvNoCC.hostPlatform.system}
      or (throw "talosctl: unsupported platform ${stdenvNoCC.hostPlatform.system}");
in
stdenvNoCC.mkDerivation {
  pname = "talosctl";
  inherit version;

  src = fetchurl {
    url = "https://github.com/siderolabs/talos/releases/download/v${version}/talosctl-${target.platform}";
    inherit (target) hash;
  };

  dontUnpack = true;

  installPhase = ''
    runHook preInstall
    install -Dm0755 $src $out/bin/talosctl
    runHook postInstall
  '';

  meta = {
    description = "CLI for the Talos Kubernetes OS, pinned to the fleet node version";
    homepage = "https://github.com/siderolabs/talos";
    license = lib.licenses.mpl20;
    mainProgram = "talosctl";
    platforms = builtins.attrNames targets;
  };
}

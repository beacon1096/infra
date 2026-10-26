{ pkgs, lib, inputs, ... }:

let
  unstablePkgs = import inputs.nixpkgs-unstable {
    system = pkgs.stdenv.hostPlatform.system;
    config.allowUnfree = true;
  };
  qq = unstablePkgs.qq.override {
    commandLineArgs = "\${WAYLAND_DISPLAY:+--ozone-platform=wayland --enable-wayland-ime=true --wayland-text-input-version=3}";
  };
  wechat = unstablePkgs.wechat-uos.override {
    buildFHSEnv = args: unstablePkgs.buildFHSEnv (args // {
      runScript = pkgs.writeShellScript "wechat-uos-hidpi" ''
        if [[ -n "''${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] &&
          ${pkgs.hyprland}/bin/hyprctl getoption xwayland:force_zero_scaling -j |
            ${pkgs.jq}/bin/jq -e '.int == 1' >/dev/null; then
          export QT_SCALE_FACTOR="''${QT_SCALE_FACTOR:-$(${pkgs.hyprland}/bin/hyprctl monitors -j |
            ${pkgs.jq}/bin/jq -r 'first(.[] | select(.focused) | .scale) // 1')}"
          export QT_SCALE_FACTOR_ROUNDING_POLICY=PassThrough
        fi
        exec ${args.runScript} "$@"
      '';
    });
  };
in
{
  home.packages = lib.optionals pkgs.stdenv.isLinux [
    qq
    wechat
    pkgs.telegram-desktop
  ];
}

{ config, lib, pkgs, ... }:

{
  services.sunshine = {
    enable = true;
    # The non-CUDA package omits the driver RUNPATH; capability wrappers strip LD_LIBRARY_PATH.
    package = pkgs.symlinkJoin {
      name = "sunshine-nvidia-${pkgs.sunshine.version}";
      paths = [ pkgs.sunshine ];
      nativeBuildInputs = [ pkgs.patchelf ];
      inherit (pkgs.sunshine) meta;
      postBuild = ''
        rm $out/bin/sunshine
        cp ${lib.getExe pkgs.sunshine} $out/bin/sunshine
        chmod u+w $out/bin/sunshine
        patchelf --add-rpath /run/opengl-driver/lib $out/bin/sunshine
      '';
    };
    capSysAdmin = true;
    openFirewall = true;
    settings = {
      sunshine_name = lib.mkDefault config.networking.hostName;
      capture = "kms";
      encoder = "nvenc";
      upnp = "disabled";
      origin_web_ui_allowed = "pc";
    };
    applications.apps = [{ name = "Desktop"; }];
  };
}

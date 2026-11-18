{ inputs, pkgs }:
let
  upstream = inputs.paseo.packages.${pkgs.stdenv.hostPlatform.system};

  applyPatches = old: {
    preBuild = (old.preBuild or "") + ''
      npm run postinstall
    '';
  };

  paseo = upstream.default.overrideAttrs applyPatches;

  desktop = (upstream.desktop.override {
    inherit paseo;
  }).overrideAttrs (old: (applyPatches old) // {
    postInstall = (old.postInstall or "") + pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
      node -e '
        const desktopRequire = require("node:module").createRequire(process.argv[1]);
        for (const entry of ["@getpaseo/server", "@getpaseo/cli/bin/paseo", "@getpaseo/cli/dist/run.js"]) {
          desktopRequire.resolve(entry);
        }
        const serverRequire = require("node:module").createRequire(desktopRequire.resolve("@getpaseo/server"));
        serverRequire("node-pty");
      ' "$out/share/paseo-desktop/packages/desktop/dist/main.js"
    '';
  });
in
{
  inherit paseo desktop;
  withNodePty = paseo;
}

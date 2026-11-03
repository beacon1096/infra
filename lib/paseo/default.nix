# Single definition site for the Paseo packages, shared by this repo and by
# infra-private (which imports it as `"${inputs.infra}/lib/paseo"`). Keeping the
# NPM dependency hash and the node-pty prebuild injection here means an upstream
# bump touches one file instead of drifting between the two repos.
{ inputs, pkgs }:
let
  upstream = inputs.paseo.packages.${pkgs.stdenv.hostPlatform.system};

  # `npmDepsHash` is destructured out of buildNpmPackage's arguments, so it can
  # only be replaced via `.override`, not `overrideAttrs`. Upstream ships a
  # default in `nix/npm-deps.hash`, but `fetchNpmDeps` produces a different hash
  # under the nixpkgs revision these flakes follow, so we carry our own.
  paseo = upstream.default.override {
    npmDepsHash = "sha256-UXnB6q5tubKpTs+A5+u/NLSzc8ZK6rAsQs+kEphEKd8=";
  };

  desktop = (upstream.desktop.override {
    inherit paseo;
  }).overrideAttrs (old: {
    postPatch = (old.postPatch or "") + pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
      # The desktop resolves the server package dynamically, outside nft's graph.
      substituteInPlace scripts/trace-daemon.mjs \
        --replace-fail '"packages/desktop/dist/main.js",' \
          '"packages/server/dist/server/server/exports.js", "packages/desktop/dist/main.js",' \
        --replace-fail 'node_modules/node-pty/prebuilds/' \
          'packages/server/node_modules/node-pty/prebuilds/'
    '';
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

  # The npm tarball carries a prebuilt node-pty for linux-x64. Container images
  # that run the daemon need it dropped next to the bundled module, because the
  # image has no toolchain to rebuild the native addon at runtime.
  nodePtyPrebuild = pkgs.runCommand "node-pty-1.2.0-beta.15-linux-x64" {
    nativeBuildInputs = [ pkgs.gnutar pkgs.gzip ];
  } ''
    mkdir -p $out
    tar -xzf ${pkgs.fetchurl {
      url = "https://registry.npmjs.org/node-pty/-/node-pty-1.2.0-beta.15.tgz";
      hash = "sha256-EUrIDD/gde/3YhekEi0TVXZYJpX0nAOl2jg1zfwvicU=";
    }}
    cp -R package/prebuilds/linux-x64 $out/
  '';

  withNodePty = paseo.overrideAttrs (old: {
    postInstall = (old.postInstall or "") + ''
      ptyRoot=$out/lib/paseo/packages/server/node_modules/node-pty
      mkdir -p "$ptyRoot/prebuilds"
      cp -R ${nodePtyPrebuild}/linux-x64 "$ptyRoot/prebuilds/"
    '';
  });
in
{
  inherit paseo desktop withNodePty;
}

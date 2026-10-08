{
  buildFHSEnv,
  bash,
  cacert,
  cudaPackages_13_0,
  lib,
  stdenv,
}:

let
  runtimeLibraries = [
    cudaPackages_13_0.cuda_cudart
    cudaPackages_13_0.libcublas
    stdenv.cc.cc.lib
  ];
  libraryPath = lib.concatStringsSep ":" [
    "/run/opengl-driver/lib"
    (lib.makeLibraryPath runtimeLibraries)
  ];
in
buildFHSEnv {
  name = "strata-runtime";
  targetPkgs = pkgs: with pkgs; [
    bash
    coreutils
    python312
    git
    curl
    openssl
    zlib
    cacert
    cudaPackages_13_0.cuda_cudart
    cudaPackages_13_0.libcublas
    stdenv.cc.cc.lib
  ];
  profile = ''
    export LD_LIBRARY_PATH="${libraryPath}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export SSL_CERT_FILE="${cacert}/etc/ssl/certs/ca-bundle.crt"
    export REQUESTS_CA_BUNDLE="$SSL_CERT_FILE"
    export PATH="$PATH:/run/current-system/sw/bin"
  '';
  runScript = "bash";
}

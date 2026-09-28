# Forgejo Actions runner image with Nix, for the Wanxiang `nix-collector`.
#
# The stock `code.forgejo.org/forgejo/runner` image only carries the act_runner
# binary, so host-mode jobs cannot run `nix build`. This layers Nix and the
# CLI dependencies the release workflow needs (git, jq, curl, attic, ssh, ...)
# onto a single image. Topology- and secret-specific bits (build machines,
# Attic endpoint/token, builder SSH key) are injected at runtime via a mounted
# nix.conf, netrc, and SSH key — they are deliberately NOT baked here.
{
  lib,
  buildEnv,
  dockerTools,
  nix,
  forgejo-runner,
  attic-client,
  bashInteractive,
  cacert,
  coreutils,
  curl,
  findutils,
  gawk,
  gitMinimal,
  gnugrep,
  gnused,
  gnutar,
  gzip,
  jq,
  nodejs,
  openssh,
  python3,
  unzip,
  wget,
  xz,
  zstd,
}:

let
  tools = [
    nix
    forgejo-runner
    attic-client
    bashInteractive
    coreutils
    curl
    findutils
    gawk
    gitMinimal
    gnugrep
    gnused
    gnutar
    gzip
    jq
    nodejs
    openssh
    python3
    unzip
    wget
    xz
    zstd
  ];

  env = buildEnv {
    name = "forgejo-runner-nix-env";
    paths = tools;
    pathsToLink = [ "/bin" ];
    ignoreCollisions = true;
  };
in
dockerTools.buildLayeredImage {
  name = "forgejo-runner-nix";
  tag = "latest";
  contents = [
    env
    cacert
  ];
  config = {
    Env = [
      "PATH=/bin"
      "HOME=/home/runner"
      "SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt"
      "NIX_SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt"
    ];
    Entrypoint = [ "/bin/forgejo-runner" ];
    Cmd = [
      "daemon"
      "--config"
      "/etc/forgejo-runner/config.yaml"
    ];
    WorkingDir = "/home/runner";
  };
}

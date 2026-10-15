{ buildGoModule, fetchFromGitHub, dockerTools, cacert, tzdata }:

let
  revision = "ef7691ad18971c14b9bd1a306b4bd0cf20b6e411";
  shortRevision = "ef7691a";
  source = fetchFromGitHub {
    owner = "openstatusHQ";
    repo = "openstatus";
    rev = revision;
    hash = "sha256-PLZGKM3+3rxmyDXoztyIa2tJGTy4M2jcgUKv8XDhV3Q=";
  };
  probe = buildGoModule {
    pname = "openstatus-private-probe";
    version = shortRevision;
    src = source;
    sourceRoot = "${source.name}/apps/checker";
    vendorHash = "sha256-rP/3tOEMz9qrSjZo5zprKzrMNxRAxWTBkpG0+vvBouA=";
    subPackages = [ "cmd/private" ];
    env.CGO_ENABLED = 0;
    ldflags = [ "-s" "-w" ];
    postInstall = ''
      mv "$out/bin/private" "$out/bin/openstatus-private-probe"
    '';
  };
in
dockerTools.buildLayeredImage {
  name = "openstatus-private-probe";
  tag = shortRevision;
  contents = [ probe cacert tzdata ];
  config = {
    User = "65532:65532";
    Entrypoint = [ "${probe}/bin/openstatus-private-probe" ];
    Env = [
      "SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt"
      "TZ=UTC"
    ];
    Labels = {
      "org.opencontainers.image.title" = "OpenStatus private probe";
      "org.opencontainers.image.description" = "Active OpenStatus private-location checker";
      "org.opencontainers.image.source" = "https://github.com/openstatusHQ/openstatus";
      "org.opencontainers.image.revision" = revision;
      "org.opencontainers.image.version" = shortRevision;
    };
  };
}

{ lib, stdenv, buildGoModule, fetchFromGitHub, fetchurl, applyPatches, dockerTools
, nodejs_22, pnpm_10, pkg-config, python3, cairo, pango, libjpeg, giflib, librsvg
, busybox, cacert, curl, wget, bash, gitMinimal, openssl, openssh, tzdata, unzip }:

let
  version = "2.36.5";
  source = applyPatches {
    name = "coder-${version}-source";
    src = fetchFromGitHub {
      owner = "coder";
      repo = "coder";
      rev = "v${version}";
      hash = "sha256-nTGHxRZ4wZyWg90Z5Hrry6gVrbbTDPK7O9PEiOofxok=";
    };
    patches = [ ../../docs/ci-cd/patches/coder-resource-allowlist-sql.patch ];
  };
  pnpm = pnpm_10.override { nodejs = nodejs_22; };
  site = stdenv.mkDerivation (finalAttrs: {
    pname = "coder-site";
    inherit version;
    src = source;
    sourceRoot = "${source.name}/site";
    pnpmDeps = pnpm.fetchDeps {
      pname = finalAttrs.pname;
      inherit version;
      src = "${source}/site";
      fetcherVersion = 2;
      hash = "sha256-UuEZHHFInNZPxgi3y0UMm6VjhWeSkMaDZt+iGC9m1jo=";
    };
    nativeBuildInputs = [ nodejs_22 pnpm.configHook pkg-config python3 ];
    buildInputs = [ cairo pango libjpeg giflib librsvg ];
    buildPhase = ''
      runHook preBuild
      pnpm build
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      cp -r out $out
      runHook postInstall
    '';
  });
  coder = buildGoModule {
    pname = "coder-server";
    inherit version;
    src = source;
    vendorHash = "sha256-cdx8u4rjfA7Pbm9mRSuny2zgGIKphtpfRewDiRgDT/s=";
    proxyVendor = true;
    nativeBuildInputs = [ pkg-config ];
    preBuild = ''
      mkdir -p site/out
      cp -r ${site}/* site/out/
    '';
    subPackages = [ "enterprise/cmd/coder" ];
    tags = [ "embed" "ts_omit_aws" "ts_omit_bird" "ts_omit_tap" "ts_omit_kube" ];
    ldflags = [
      "-s"
      "-w"
      "-X github.com/coder/coder/v2/buildinfo.tag=${version}"
    ];
    env.CGO_ENABLED = 0;
    doCheck = true;
    checkPhase = ''
      runHook preCheck
      go test ./coderd/rbac/regosql -run 'TestRegoQueries/(TemplateAllowList|WorkspaceAllowList)$'
      runHook postCheck
    '';
  };
  terraform = stdenv.mkDerivation {
    pname = "terraform";
    version = "1.15.5";
    src = fetchurl {
      url = "https://releases.hashicorp.com/terraform/1.15.5/terraform_1.15.5_linux_amd64.zip";
      hash = "sha256-cCshNq9nKMj/A3+EPdLbzit62IeGtzgdHXKu+iUPYBw=";
    };
    nativeBuildInputs = [ unzip ];
    dontUnpack = true;
    installPhase = ''
      install -Dm755 <(unzip -p $src terraform) $out/bin/terraform
    '';
  };
  rootFiles = stdenv.mkDerivation {
    name = "coder-server-root-${version}";
    dontUnpack = true;
    installPhase = ''
      mkdir -p $out/home/coder $out/etc $out/opt
      install -m755 ${coder}/bin/coder $out/opt/coder
      cat > $out/etc/passwd <<'EOF'
      coder:x:1000:1000:Coder:/home/coder:/bin/bash
      EOF
      cat > $out/etc/group <<'EOF'
      coder:x:1000:
      EOF
    '';
  };
in
dockerTools.buildLayeredImage {
  name = "coder-server";
  tag = version;
  contents = [
    rootFiles terraform busybox cacert curl wget bash gitMinimal openssl openssh tzdata
  ];
  config = {
    User = "1000:1000";
    Env = [
      "HOME=/home/coder"
      "PATH=/bin:/opt"
      "SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt"
    ];
    WorkingDir = "/home/coder";
    Entrypoint = [ "/opt/coder" "server" ];
    ExposedPorts."3000/tcp" = { };
    Labels = {
      "org.opencontainers.image.title" = "Coder";
      "org.opencontainers.image.description" = "A tool for provisioning self-hosted development environments with Terraform.";
      "org.opencontainers.image.url" = "https://github.com/coder/coder";
      "org.opencontainers.image.source" = "https://github.com/coder/coder";
      "org.opencontainers.image.version" = version;
    };
  };
}

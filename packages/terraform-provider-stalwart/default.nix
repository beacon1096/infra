{ lib, buildGoModule, fetchFromGitHub, stdenv }:

let
  version = "0.2.4-beaco.1";
  providerSource = "registry.terraform.io/tahacodes/stalwart";
  platform = "${stdenv.hostPlatform.go.GOOS}_${stdenv.hostPlatform.go.GOARCH}";
in
buildGoModule {
  pname = "terraform-provider-stalwart";
  inherit version;

  src = fetchFromGitHub {
    owner = "tahacodes";
    repo = "terraform-provider-stalwart";
    rev = "f7d85b3c5b0c8b2fafd31320f0476464584c8b8a";
    hash = "sha256-QwYJdZ1IZz2hS+HC6wm4W6cfKhS0RCYgJzSbPgS3aFs=";
  };

  # Local revision: omitted user credentials are never sent back to Stalwart,
  # including masked or historical values retained by Terraform state.
  patches = [ ./unmanaged-credentials.patch ];
  vendorHash = "sha256-lrSV8cm6G8/FhvN9C/1wqozuxxcsBGypBdFZ18VQPdU=";
  subPackages = [ "." ];
  env.CGO_ENABLED = 0;
  ldflags = [ "-s" "-w" "-X main.version=${version}" ];

  # Go's GOTELEMETRY value is read-only. Keep telemetry disabled inside the
  # build directory instead of creating /homeless-shelter in unsandboxed Nix.
  preBuild = ''
    export TEST_TELEMETRY_DIR="$TMPDIR/go-telemetry"
    mkdir -p "$TEST_TELEMETRY_DIR"
    printf 'off\n' > "$TEST_TELEMETRY_DIR/mode"
  '';

  checkPhase = ''
    runHook preCheck
    go test ./...
    runHook postCheck
  '';

  postInstall = ''
    mirror="$out/share/terraform/providers/${providerSource}/${version}/${platform}"
    mkdir -p "$mirror"
    ln -s "$out/bin/terraform-provider-stalwart" \
      "$mirror/terraform-provider-stalwart_v${version}"
  '';

  passthru = {
    inherit providerSource;
    providerMirrorDirectory = "share/terraform/providers";
  };

  meta = {
    description = "Stalwart Terraform provider with local unmanaged-credentials fix";
    homepage = "https://github.com/tahacodes/terraform-provider-stalwart";
    license = lib.licenses.mit;
    mainProgram = "terraform-provider-stalwart";
    platforms = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
  };
}

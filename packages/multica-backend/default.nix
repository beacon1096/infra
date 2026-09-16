{ buildGoModule, fetchFromGitHub, applyPatches, dockerTools, runCommand, busybox, cacert, tzdata }:

let
  version = "0.4.24-beacon.1";
  source = applyPatches {
    name = "multica-${version}-source";
    src = fetchFromGitHub {
      owner = "multica-ai";
      repo = "multica";
      rev = "v0.4.24";
      hash = "sha256-yFplqLsJz+1xWtFAmNkTHq0YXT1g4oyp322hir89tpI=";
    };
    patches = [ ../../docs/ci-cd/patches/multica-webhook-issue-dedup.patch ];
  };
  backend = buildGoModule {
    pname = "multica-backend";
    inherit version;
    src = source;
    sourceRoot = "${source.name}/server";
    vendorHash = "sha256-SL//NLuzLV+faAjD7SR9f9j0AaDHel2haZajLJpsj5s=";
    subPackages = [
      "cmd/server"
      "cmd/multica"
      "cmd/migrate"
      "cmd/backfill_task_usage_hourly"
      "cmd/backfill_codex_usage_cache"
    ];
    env.CGO_ENABLED = 0;
    ldflags = [
      "-s"
      "-w"
      "-X main.version=v${version}"
      "-X main.commit=downstream-dedup"
    ];
  };
  runtime = runCommand "multica-backend-runtime-${version}" { } ''
    mkdir -p $out/app
    cp ${backend}/bin/* $out/app/
    cp -r ${source}/server/migrations $out/app/migrations
    cp ${source}/docker/entrypoint.sh $out/app/entrypoint.sh
    chmod +x $out/app/entrypoint.sh
  '';
in
dockerTools.buildLayeredImage {
  name = "multica-backend";
  tag = version;
  contents = [ runtime busybox cacert tzdata ];
  config = {
    WorkingDir = "/app";
    Entrypoint = [ "/app/entrypoint.sh" ];
    ExposedPorts."8080/tcp" = { };
  };
}

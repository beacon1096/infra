{
  fetchFromGitHub,
  lib,
  makeWrapper,
  python3,
  stdenvNoCC,
}:

let
  pythonEnv = python3.withPackages (
    ps: with ps; [
      flask
      gunicorn
      requests
    ]
  );
in
stdenvNoCC.mkDerivation {
  pname = "gh-proxy";
  version = "unstable-2024-02-18";

  src = fetchFromGitHub {
    owner = "hunshcn";
    repo = "gh-proxy";
    rev = "9bf5f34e75868491709541a72d0c58dcf20fdd87";
    hash = "sha256-HCld+W8lteiDt249zPfUTrusfVAmQLvSF+SLPU1R+lg=";
  };

  nativeBuildInputs = [ makeWrapper ];

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    install -Dm0444 app/main.py "$out/share/gh-proxy/main.py"
    makeWrapper "${pythonEnv}/bin/gunicorn" "$out/bin/gh-proxy" \
      --add-flags "--chdir $out/share/gh-proxy"

    runHook postInstall
  '';

  meta = {
    description = "GitHub release, archive, and repository file proxy";
    homepage = "https://github.com/hunshcn/gh-proxy";
    license = lib.licenses.mit;
    mainProgram = "gh-proxy";
    platforms = lib.platforms.linux;
  };
}

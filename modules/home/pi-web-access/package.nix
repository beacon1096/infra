{ lib, buildNpmPackage, fetchurl }:
buildNpmPackage rec {
  pname = "pi-web-access";
  version = "0.28.0";

  src = fetchurl {
    url = "https://registry.npmjs.org/pi-web-access/-/pi-web-access-${version}.tgz";
    hash = "sha256-jSe9FEDF0eKIXpe0Tvr+YPPYGiqeVsGKyLhNYIBxjrU=";
  };

  postPatch = ''
    cp ${./package-lock.json} package-lock.json
  '';
  npmDepsHash = "sha256-+VbYvFOjMUvI/tmR2jFG8lC4iu8v02mme7PREl68zvc=";
  npmFlags = [ "--legacy-peer-deps" ];
  npmInstallFlags = [ "--omit=dev" ];
  dontNpmBuild = true;

  meta = {
    description = "Web search and content fetching extension for Pi";
    homepage = "https://github.com/nicobailon/pi-web-access";
    license = lib.licenses.mit;
  };
}

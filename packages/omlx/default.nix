{ lib, stdenvNoCC, fetchurl, _7zz, macosVersion ? "26" }:

let
  variants = {
    "15" = {
      name = "macos15-sequoia";
      hash = "sha256-WpDHrko/TKi/ENzIPX9zlSgeL/sqhdYwyV6XIISOR80=";
    };
    "26" = {
      name = "macos26-27";
      hash = "sha256-U/FQbCOF6JIKZxmLctH+CTUcGzU4vpxr3reOUnfQbZM=";
    };
  };
  variant = variants.${macosVersion};
in
stdenvNoCC.mkDerivation rec {
  pname = "omlx";
  version = "0.6.4";
  src = fetchurl {
    url = "https://github.com/jundot/omlx/releases/download/v${version}/oMLX-${version}-${variant.name}.dmg";
    inherit (variant) hash;
  };
  nativeBuildInputs = [ _7zz ];
  unpackPhase = ''
    runHook preUnpack
    7zz x -y -snld -bsp0 "$src" -oimage
    runHook postUnpack
  '';
  # Preserve signatures and relative paths inside the bundled runtime.
  dontFixup = true;
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/Applications" "$out/bin"
    app=$(find image -type d -name oMLX.app -print -quit)
    test -n "$app"
    cp -R "$app" "$out/Applications/"
    ln -s "$out/Applications/oMLX.app/Contents/MacOS/omlx-cli" "$out/bin/omlx"
    runHook postInstall
  '';
  meta = {
    description = "Local MLX inference server with bundled Apple Silicon runtime";
    homepage = "https://github.com/jundot/omlx";
    license = lib.licenses.asl20;
    platforms = [ "aarch64-darwin" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "omlx";
  };
}

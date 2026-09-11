{ lib, stdenv, fetchurl, kernel, kernelModuleMakeFlags }:

stdenv.mkDerivation (finalAttrs: {
  pname = "r8127";
  version = "11.015.00";

  src = fetchurl {
    url = "https://github.com/openwrt/rtl8127/releases/download/${finalAttrs.version}/r8127-${finalAttrs.version}.tar.bz2";
    hash = "sha256-qyG/aTaPud5/WRsugc8agVmIu/CG7L9Br33peHsQWUs=";
  };

  hardeningDisable = [ "pic" ];
  nativeBuildInputs = kernel.moduleBuildDependencies;

  makeFlags = kernelModuleMakeFlags ++ [
    "-C"
    "${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
    "M=$(PWD)/src"
  ];
  buildFlags = [ "modules" ];

  installPhase = ''
    runHook preInstall
    install -Dm644 src/r8127.ko $out/lib/modules/${kernel.modDirVersion}/kernel/drivers/net/ethernet/realtek/r8127.ko
    runHook postInstall
  '';

  meta = {
    description = "Realtek RTL8127 10 Gigabit Ethernet driver";
    homepage = "https://github.com/openwrt/rtl8127";
    license = lib.licenses.gpl2Plus;
    platforms = lib.platforms.linux;
  };
})

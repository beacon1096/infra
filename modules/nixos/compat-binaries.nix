# Compatibility layer for dynamically linked Linux binaries/AppImage on NixOS.
{ pkgs, ... }:

{
  programs.appimage = {
    enable = true;
    binfmt = true;
  };

  # FUSE-backed /bin and /usr/bin that resolve binaries from PATH on demand.
  # Lets FHS-shebanged scripts (#!/bin/bash, #!/usr/bin/python, ...) just work
  # — e.g. Claude Code's Warp plugin hooks ship with #!/bin/bash baked in.
  services.envfs.enable = true;

  # Allows many prebuilt Linux binaries to run by providing a dynamic linker
  # and a curated runtime library search path.
  programs.nix-ld = {
    enable = true;
    libraries = with pkgs; [
      stdenv.cc.cc
      zlib
      openssl
      curl
      expat
      icu
      nss
      nspr
      glib
      gtk3
      alsa-lib
      libdrm
      mesa
      libglvnd
      libx11
      libxcomposite
      libxcursor
      libxdamage
      libxext
      libxfixes
      libxi
      libxrandr
      libxrender
      libxtst
      libxcb
      libxkbcommon
      at-spi2-atk
      at-spi2-core
      dbus
      cups
      pango
      cairo
      gdk-pixbuf
      freetype
      fontconfig
      udev
      fuse
      fuse3
    ];
  };

  # Preferred way to launch AppImage on NixOS:
  #   appimage-run ./foo.AppImage
  environment.systemPackages = with pkgs; [
    appimage-run
    fuse
  ];
}

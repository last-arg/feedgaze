{ pkgs ? import <nixpkgs> { } }:
with pkgs;
mkShell {
  buildInputs = [
    zig
    sqlite
    pkg-config

    libressl
    autoconf
    automake
    libtool
    ninja
    cmake
    # zlib.dev
  ];
  shellHook = ''
    NIX_CFLAGS_COMPILE="$(echo "$NIX_CFLAGS_COMPILE" | sed -e "s/-frandom-seed=[^-]*//")"
  '';
}

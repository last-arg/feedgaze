{ pkgs ? import <nixpkgs> { } }:
with pkgs;
mkShell {
  buildInputs = [
    zig
    sqlite
    pkg-config
    rlwrap
    # zlib.dev
  ];
  shellHook = ''
    NIX_CFLAGS_COMPILE="$(echo "$NIX_CFLAGS_COMPILE" | sed -e "s/-frandom-seed=[^-]*//")"
  '';
}

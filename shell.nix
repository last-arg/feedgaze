{ pkgs ? import <nixpkgs> { } }:
with pkgs;
mkShell {
  buildInputs = [
    zig-binary
    sqlite
    pkg-config
    rlwrap
  ];
}

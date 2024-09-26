{ pkgs ? import <nixpkgs> { } }:
with pkgs;
mkShell {
  buildInputs = [
    zig
    sqlite
    pkg-config
    curl
  ];
}

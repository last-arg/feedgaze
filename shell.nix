{ pkgs ? import <nixpkgs> { } }:
with pkgs;
mkShell {
  buildInputs = [
    zig-binary
    # zig-master
    # zig-latest
    sqlite
    pkg-config
    rlwrap
    # llvmPackages.clang-unwrapped
    # llvmPackages.llvm
    # llvmPackages.lld
    # libxml2
    # zlib
    zlib.dev
  ];
  shellHook = ''
    NIX_CFLAGS_COMPILE="$(echo "$NIX_CFLAGS_COMPILE" | sed -e "s/-frandom-seed=[^-]*//")"
  '';
}

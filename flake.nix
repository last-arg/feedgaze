{
  description = "project dev packages";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zig.url = "github:arqv/zig-overlay";
  };

  outputs = { self, nixpkgs, zig, flake-utils }@inputs:
    flake-utils.lib.eachDefaultSystem
      (system:
        let
          pkgs = import nixpkgs { inherit system; zig = zig.master.latest; };
        in
        {
          devShell = import ./shell.nix { inherit pkgs; };
        }
      );
}

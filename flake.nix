{
  description = "project dev packages";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zig.url = "github:mitchellh/zig-overlay";
  };

  outputs = { self, nixpkgs, zig, flake-utils }@inputs:
    flake-utils.lib.eachDefaultSystem
      (system:
        let
          # TODO: need to wait till zig-sqlite is updated to new build system
          pkgs = nixpkgs.legacyPackages.${system} // { zig = zig.packages.${system}."master-2024-01-03"; };
          # pkgs = nixpkgs.legacyPackages.${system} // { zig = zig.packages.${system}.master; };
        in
        {
          devShell = import ./shell.nix { inherit pkgs; };
        }
      );
}

{
  description = "project dev packages";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zig.url = "github:mitchellh/zig-overlay";
  };

  outputs = { self, nixpkgs, zig, flake-utils }:
    flake-utils.lib.eachDefaultSystem
      (system:
        let
          # pkgs = nixpkgs.legacyPackages.${system} // { zig = zig.packages.${system}."master-2024-03-26"; };
          pkgs = nixpkgs.legacyPackages.${system} // { zig = zig.packages.${system}.master; };
        in
        {
          devShell = import ./shell.nix { inherit pkgs; };
        }
      );
}

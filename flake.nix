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
          pkgs = nixpkgs.legacyPackages.${system} // { zig = zig.packages.${system}."master-2025-06-23"; };
          # pkgs = nixpkgs.legacyPackages.${system} // { zig = zig.packages.${system}.master; };
        in {
          devShell = pkgs.mkShell {
            packages = with pkgs; [
              pkgs.zig
              sqlite
              pkg-config
              curl
            ];
          };
        }
      );
}

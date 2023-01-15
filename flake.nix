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
          # pkgs = nixpkgs.legacyPackages.${system} // { zig = zig.packages.${system}.master."2022-01-24"; };
          # Because std.math.round fn doesn't exist anymore (zig-dateformat package)
          # pkgs = nixpkgs.legacyPackages.${system} // { zig = zig.packages.${system}.master."2022-04-15"; };
          pkgs = nixpkgs.legacyPackages.${system} // { zig = zig.packages.${system}.master; };
        in
        {
          devShell = import ./shell.nix { inherit pkgs; };
        }
      );
}

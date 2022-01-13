{
  description = "project dev packages";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zig.url = "github:roarkanize/zig-overlay";
  };

  outputs = { self, nixpkgs, zig, flake-utils }@inputs:
    flake-utils.lib.eachDefaultSystem
      (system:
        let
          pkgs = nixpkgs.legacyPackages.${system} // { zig = zig.packages.${system}.master.latest; };
        in
        {
          devShell = import ./shell.nix { inherit pkgs; };
        }
      );
}

{
  description = "berry2nix";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        berry2nix = pkgs.callPackage ./lib.nix {};

        inherit (pkgs.callPackage ./yarn {}) yarn-patched;
      in
      {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            nodejs
            yarn # yarn from upstream nixpkgs
          ];
        };
        devShells.patched = pkgs.mkShell {
          packages = [
            pkgs.nodejs
            yarn-patched
          ];
        };

        lib = rec {
          inherit berry2nix;
          default = berry2nix;
        };
      }
    );
}

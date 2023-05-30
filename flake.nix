{
  description = "berry2nix";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        berry2nix = pkgs.callPackage ./lib.nix {};

        yarn-patched = berry2nix.mkYarnBin {
          yarnPath = pkgs.callPackage yarn/yarn.nix {};
          isPatchedForGlobalCache = true;
        };
      in
      {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            nodejs
            yarn
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

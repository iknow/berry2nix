{ pkgs ? import <nixpkgs> {} }:
let
  berry2nix = pkgs.callPackage ./lib.nix {};

  inherit (berry2nix) mkBerryModules;
in
{
  github = berry2nix.mkBerryModules {
    name = "github";
    src = ./tests/github;
  };

  workspace = berry2nix.mkBerryWorkspace {
    name = "workspace";
    src = ./tests/workspace;
  };
}

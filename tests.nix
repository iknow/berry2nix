{ pkgs ? import <nixpkgs> {} }:
let
  berry2nix = pkgs.callPackage ./lib.nix {};

  inherit (berry2nix) mkBerryModules;
in
rec {
  github = berry2nix.mkBerryModules {
    name = "github";
    src = ./tests/github;
  };

  workspace = berry2nix.mkBerryWorkspace {
    name = "workspace";
    src = ./tests/workspace;
  };

  workspace-child1 = workspace.packages.child1;
  workspace-child2 = workspace.packages.child2;

  production = berry2nix.mkBerryModules {
    name = "production";
    src = ./tests/production;
    production = true;
  };
}

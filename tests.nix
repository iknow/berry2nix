{ pkgs ? import <nixpkgs> {} }:
let
  berry2nix = pkgs.callPackage ./lib.nix {};

  inherit (pkgs.callPackage ./yarn {}) yarn-patched;

  inherit (berry2nix) mkBerryModules;
in
rec {
  github = berry2nix.mkBerryModules {
    name = "github";
    src = ./tests/github;
  };

  github-patched-yarn = berry2nix.mkBerryModules {
    name = "github";
    src = ./tests/github;
    yarn = yarn-patched;
  };

  workspace = berry2nix.mkBerryWorkspace {
    name = "workspace";
    src = ./tests/workspace;
  };

  workspace-patched-yarn = berry2nix.mkBerryWorkspace {
    name = "workspace";
    src = ./tests/workspace;
    yarn = yarn-patched;
  };

  production = berry2nix.mkBerryModules {
    name = "production";
    src = ./tests/production;
    production = true;
  };

  esbuild = berry2nix.mkBerryModules {
    name = "esbuild";
    src = ./tests/esbuild;
  };

  esbuild-patched-yarn = berry2nix.mkBerryModules {
    name = "esbuild";
    src = ./tests/esbuild-patched;
    yarn = yarn-patched;
  };
}

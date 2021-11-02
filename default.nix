{ pkgs ? import <nixpkgs> {} }:

let
  yarn = pkgs.yarn;

  mkBerryCache = { name, yarn, packageJSON, yarnLock, yarnPath, yarnRcYml, hash }:
    let
      yarnReleasePath = ".yarn/releases/${builtins.baseNameOf yarnPath}";
    in
    pkgs.runCommand "${name}-yarn-cache" {
      buildInputs = [ yarn ];
      outputHash = hash;
      outputHashAlgo = "sha256";
      outputHashMode = "recursive";
    } ''
      export HOME=$(pwd)
      export YARN_ENABLE_TELEMETRY=false
      export YARN_ENABLE_COLORS=false

      mkdir -p work
      cd work

      cp ${packageJSON} package.json
      cp ${yarnLock} yarn.lock
      cp --no-preserve=mode ${builtins.path { path = yarnRcYml; name = "yarnrc.yml"; }} .yarnrc.yml

      mkdir -p .yarn/releases
      cp -r ${yarnPath} ${yarnReleasePath}
      yarn install --immutable

      mv "$HOME/.yarn/berry" $out
    '';

  mkBerryModules = { name, yarn, packageJSON, yarnLock, yarnRcYml, yarnPath, ... }@args:
    let
      cache = mkBerryCache args;
      yarnReleasePath = ".yarn/releases/${builtins.baseNameOf yarnPath}";
    in
    pkgs.runCommand "${name}-node-modules" {
      buildInputs = [ yarn ];
    } ''
      export HOME=$(pwd)
      export YARN_ENABLE_TELEMETRY=false
      export YARN_ENABLE_COLORS=false
      export YARN_NODE_LINKER=node-modules
      export YARN_GLOBAL_FOLDER="${cache}"

      cp ${packageJSON} package.json
      cp ${yarnLock} yarn.lock
      cp --no-preserve=mode ${builtins.path { path = yarnRcYml; name = "yarnrc.yml"; }} .yarnrc.yml

      mkdir -p .yarn/releases
      cp -r ${yarnPath} ${yarnReleasePath}

      yarn install
      mv node_modules $out
    '';
in

mkBerryModules {
  name = "typescript";
  inherit (pkgs) yarn;
  packageJSON = ./package.json;
  yarnLock = ./yarn.lock;
  yarnRcYml = ./.yarnrc.yml;
  yarnPath = ./.yarn/releases/yarn-3.1.0.cjs;
  hash = "06v3yk749dc7g4msjkiy8bkcsbjccpd222s4chypz6fcccs4r4zr";
}

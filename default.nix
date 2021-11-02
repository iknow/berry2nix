{ pkgs ? import <nixpkgs> {} }:

let
  yarn = pkgs.yarn;

  setupYarn = { yarnPath, project ? null }:
    let
      yarnReleasePath = ".yarn/releases/${builtins.baseNameOf yarnPath}";
    in
    ''
      export SKIP_BERRY_NIX=true
      export YARN_ENABLE_TELEMETRY=false
      export YARN_ENABLE_NETWORK=false
      export YARN_ENABLE_COLORS=false

      ${if project == null then "" else ''
      cp "${project.packageJSON}" package.json
      cp "${project.yarnLock}" yarn.lock
      ''}

      cp ${./plugin-nix.js} plugin-nix.js

      mkdir .yarn
      mkdir .yarn/releases
      cp ${yarnPath} ${yarnReleasePath}
      ${if (project.yarnPlugins or null) == null then "" else ''
      cp --no-preserve=mode -r ${project.yarnPlugins} .yarn/plugins
      ''}

      ${if project == null then ''
        cat > .yarnrc.yml <<EOF
        yarnPath: ${yarnReleasePath}
        plugins: [ plugin-nix.js ]
        EOF
      '' else ''
        cp --no-preserve=mode ${builtins.path { path = project.yarnRcYml; name = "yarnrc.yml"; }} .yarnrc.yml
        yarn plugin import ./plugin-nix.js
      ''}
    '';

  mkBerryNix = { name, yarn, yarnPath, project }:
    pkgs.runCommand "${name}-berry.nix" {
      buildInputs = [ yarn ];
    } ''
      ${setupYarn { inherit yarnPath project; }}
      export YARN_GLOBAL_FOLDER="tmp"

      yarn makeBerryNix
      cp berry.nix $out
    '';

  mkBerryCache = { name, yarn, yarnPath, project, berryNix }:
    let
      packages = import berryNix;
      fetch = opts: pkgs.runCommand opts.name {
        buildInputs = [ yarn ];
        outputHash = opts.source.sha512;
        outputHashAlgo = "sha512";
      } ''
        ${setupYarn { inherit yarnPath; }}
        yarn tgzToZip \
          "${builtins.fetchurl opts.source.url}" \
          "$out" \
          "${opts.convert.compressionLevel}" \
          "${opts.convert.prefixPath}"
      '';
      entries = builtins.map (p: { name = "cache/${p.name}"; path = fetch p; }) packages;
    in
    pkgs.runCommand "${name}-berry-cache" {
      buildInputs = [ yarn ];
    } ''
      mkdir -p $out/cache
      ${pkgs.lib.concatMapStrings (p: ''
        ln -s "${fetch p}" "$out/cache/${p.name}"
      '') packages}

      ${setupYarn { inherit yarnPath project; }}
      export YARN_GLOBAL_FOLDER="$out"

      # we do an install to fill the global cache with patch zips
      yarn install --immutable --mode skip-build | grep -v YN0013
    '';

  mkBerryModules = { name, yarn, yarnPath, project }@args:
    let
      cache = mkBerryCache (args // {
        berryNix = args.berryNix or (mkBerryNix args);
      });
    in
    pkgs.runCommand "${name}-node-modules" {
      buildInputs = [ yarn ];
    } ''
      ${setupYarn { inherit yarnPath project; }}
      export YARN_NODE_LINKER="node-modules"
      export YARN_GLOBAL_FOLDER="${cache}"

      # YN0013 is "will fetch"
      yarn install --immutable | grep -v YN0013
      mv node_modules $out
    '';
in

mkBerryModules {
  name = "typescript";
  inherit (pkgs) yarn;
  yarnPath = ./.yarn/releases/yarn-3.1.0.cjs;
  project = {
    packageJSON = ./package.json;
    yarnLock = ./yarn.lock;
    yarnRcYml = ./.yarnrc.yml;
  };
}

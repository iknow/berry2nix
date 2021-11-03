{ pkgs ? import <nixpkgs> {} }:

let
  setupYarn = { nodejs, yarnPath, project ? null }:
    ''
      export SKIP_BERRY_NIX=true
      export YARN_ENABLE_TELEMETRY=false
      export YARN_ENABLE_NETWORK=false
      export YARN_ENABLE_COLORS=false

      ${pkgs.lib.optionalString (project != null) ''
      cp "${project.packageJSON}" package.json
      cp "${project.yarnLock}" yarn.lock
      ''}

      cp ${./plugin-nix.js} plugin-nix.js

      function yarn {
        "${nodejs}/bin/node" "${yarnPath}" "$@"
      }

      mkdir .yarn
      ${if (project.yarnPlugins or null) == null then "" else ''
      cp --no-preserve=mode -r ${project.yarnPlugins} .yarn/plugins
      ''}

      ${if project == null then ''
        cat > .yarnrc.yml <<EOF
        plugins: [ plugin-nix.js ]
        EOF
      '' else ''
        grep -v "yarnPath:" ${builtins.path { path = project.yarnRcYml; name = "yarnrc.yml"; }} > .yarnrc.yml
        yarn plugin import ./plugin-nix.js > /dev/null
      ''}
    '';

  mkBerryNix = { name, nodejs, yarnPath, project }:
    pkgs.runCommand "${name}-berry.nix" {} ''
      ${setupYarn { inherit nodejs yarnPath project; }}
      export YARN_GLOBAL_FOLDER="tmp"

      yarn makeBerryNix
      cp berry.nix $out
    '';

  mkBerryCache = { name, nodejs, yarnPath, project }@args:
    let
      berryNix = args.berryNix or (mkBerryNix args);
      packages = import berryNix;
      fetchUrlPackage = opts: pkgs.runCommand opts.name {
        outputHash = opts.source.sha512;
        outputHashAlgo = "sha512";
      } ''
        ${setupYarn { inherit nodejs yarnPath; }}

        yarn tgzToZip \
          "${builtins.fetchurl opts.source.url}" \
          "$out" \
          "${builtins.toString opts.convert.compressionLevel}" \
          "${opts.convert.prefixPath}"
      '';

      urlPackages = builtins.filter (pkg: pkg.source.type == "url") packages;
      patchPackages = builtins.filter (pkg: pkg.source.type == "patch") packages;
      fetchPatchPackage = opts: pkgs.runCommand opts.name ({
        source = fetchUrlPackage (pkgs.lib.findFirst
          (pkg: pkg.name == opts.source.source)
          (throw "No source package found for ${opts.name}")
          urlPackages
        );
        locatorJson = builtins.toJSON opts.source.locator;
        passAsFile = [ "locatorJson" ];
      } // pkgs.lib.optionalAttrs (opts.source.sha512 != null) {
        outputHash = opts.source.sha512;
        outputHashAlgo = "sha512";
      }) ''
        ${setupYarn { inherit nodejs yarnPath project; }}

        # setup writable cache
        mkdir -p tmp/cache
        ln -s "$source" "tmp/cache/${opts.source.source}"
        export YARN_GLOBAL_FOLDER=tmp

        yarn fetchPatch < "$locatorJsonPath"
        mv "tmp/cache/${opts.name}" "$out"
      '';
    in
    pkgs.runCommand "${name}-berry-cache" {
      passthru = { inherit berryNix; };
    } ''
      mkdir -p $out/cache
      ${pkgs.lib.concatMapStrings (p: ''
        ln -s "${fetchUrlPackage p}" "$out/cache/${p.name}"
      '') urlPackages}
      ${pkgs.lib.concatMapStrings (p: ''
        ln -s "${fetchPatchPackage p}" "$out/cache/${p.name}"
      '') patchPackages}
    '';

  mkBerryModules = { name, nodejs, yarnPath, project }@args:
    let
      cache = mkBerryCache args;
    in
    pkgs.runCommand "${name}-node-modules" {
      passthru = { inherit cache; };
    } ''
      ${setupYarn { inherit nodejs yarnPath project; }}
      export YARN_NODE_LINKER="node-modules"
      export YARN_GLOBAL_FOLDER="${cache}"

      # YN0013 is "will fetch"
      yarn install --immutable | grep -v YN0013
      mkdir $out
      mv node_modules $out/node_modules
    '';
in

mkBerryModules {
  name = "typescript";
  inherit (pkgs) nodejs;
  yarnPath = ./.yarn/releases/yarn-3.1.0.cjs;
  project = {
    packageJSON = ./package.json;
    yarnLock = ./yarn.lock;
    yarnRcYml = ./.yarnrc.yml;
  };
}

{ pkgs ? import <nixpkgs> {} }:

let
  inherit (pkgs) lib stdenv;

  inherit (pkgs.callPackage ./yarn {}) wrapYarnWith;

  reformatPackageName = pname:
    let
      # regex adapted from `validate-npm-package-name`
      # will produce 3 parts e.g.
      # "@someorg/somepackage" -> [ "@someorg/" "someorg" "somepackage" ]
      # "somepackage" -> [ null null "somepackage" ]
      parts = builtins.tail (builtins.match "^(@([^/]+)/)?([^/]+)$" pname);
      # if there is no organisation we need to filter out null values.
      non-null = builtins.filter (x: x != null) parts;
    in builtins.concatStringsSep "-" non-null;

  /* Get a list of workspaces

     This returns a list of workspaces with the following attributes:

     name is the nix friendly package name

     packageName is the package name from the package.json

     packageJSON is the path to the package.json file

     path is the relative path to the workspace directory
  */
  getWorkspaces = src:
    let
      packageJSON = src + "/package.json";
      manifest = lib.importJSON packageJSON;

      workspaceGlobs =
        if builtins.isList (manifest.workspaces or null) then
          manifest.workspaces
        else
          [];

      globElemToRegex = lib.replaceStrings ["*"] [".*"];

      # PathGlob -> [PathGlobElem]
      splitGlob = lib.splitString "/";

      # Path -> [PathGlobElem] -> [Path]
      # Note: Only directories are included, everything else is filtered out
      expandGlobList = base: globElems:
        let
          elemRegex = globElemToRegex (lib.head globElems);
          rest = lib.tail globElems;
          children = lib.attrNames (lib.filterAttrs (name: type: type == "directory") (builtins.readDir base));
          matchingChildren = lib.filter (child: builtins.match elemRegex child != null) children;
        in if globElems == []
          then [ (lib.removePrefix (toString src + "/") (toString base)) ]
          else lib.concatMap (child: expandGlobList (base+("/"+child)) rest) matchingChildren;

      # Path -> PathGlob -> [Path]
      expandGlob = base: glob: expandGlobList base (splitGlob glob);

      workspacePaths = lib.concatMap (expandGlob src) workspaceGlobs;
    in
    builtins.concatMap (path:
      let
        packageJSON = src + ("/" + path + "/package.json");
        manifest = lib.importJSON packageJSON;
      in
      lib.optionals (builtins.pathExists packageJSON) [{
        name = reformatPackageName manifest.name;
        packageName = manifest.name;
        inherit path packageJSON;
      }]
    ) workspacePaths;

  /* Discover the yarnPath in src

     If there is only one file in .yarn/releases of src, then we use that as
     the yarnPath. Otherwise, we return null.

     This does not respect whatever yarnPath is defined in .yarnrc.yml
  */
  getYarnPath = src:
    let
      yarnReleases = src + "/.yarn/releases";
    in
    if builtins.pathExists yarnReleases then
      let
        entries = builtins.readDir yarnReleases;
        fileEntries = lib.filterAttrs
          (name: value: value == "regular" || value == "symlink")
          entries;

        fileNames = builtins.attrNames fileEntries;
      in
      if builtins.length fileNames == 1 then
        yarnReleases + ("/" + builtins.head fileNames)
      else
        null
    else
      null;

  /* Get the project object for use by internal functions

     This is used by mkBerryWorkspace and mkBerryModules to infer the relevant
     paths from src. These may also be specified manually in the case of a more
     custom setup. Though note that these will be copied into their "standard"
     paths in the build process.
  */
  getProject = {
    src,
    packageJSON ? src + "/package.json",
    yarnLock ? src + "/yarn.lock",
    yarnRcYml ? src + "/.yarnrc.yml",
    yarnPlugins ? src + "/.yarn/plugins",
    yarnPath ? getYarnPath src,
    yarn ? lib.mapNullable (yarn-js: wrapYarnWith { inherit yarn-js; }) yarnPath,
    workspaces ? getWorkspaces src,
    ...
  }: {
    inherit src packageJSON yarnLock yarnPlugins yarnPath workspaces;

    yarn = assert lib.assertMsg (yarn != null) "yarnPath could not be autodetected, please specify yarn or yarnPath"; yarn;

    yarnRcYml = builtins.path {
      path = yarnRcYml;
      name = "yarnrc.yml";
    };
  };

  yarnPlugin = ./bundles + "/@yarnpkg/plugin-berry2nix.js";

  yarnEnv = ''
    export SKIP_BERRY_NIX=true
    export YARN_ENABLE_TELEMETRY=false
    export YARN_ENABLE_NETWORK=false
    export YARN_ENABLE_COLORS=false
    export YARN_ENABLE_HYPERLINKS=false
  '';

  /* Copies the project into the build directory

     We only copy the bare minimum we need to create the lockfile and then
     setup our plugin for the build commands.
  */
  setupProject = project:
    let
      copyWorkspacePackage = package: ''
        mkdir -p ${package.path}
        cp ${package.packageJSON} ${package.path}/package.json
      '';

      copyPlugins = lib.optionalString (builtins.pathExists project.yarnPlugins) ''
        cp --no-preserve=mode -r ${project.yarnPlugins} .yarn/plugins
      '';
    in
    ''
      ${yarnEnv}
      export YARN_PLUGINS="${yarnPlugin}"

      cp "${project.packageJSON}" package.json
      cp "${project.yarnLock}" yarn.lock
      cp --no-preserve=mode "${project.yarnRcYml}" .yarnrc.yml

      ${lib.concatMapStringsSep "\n" copyWorkspacePackage project.workspaces}

      mkdir .yarn
      ${copyPlugins}

      # having a yarnPath sometimes interferes with building git dependencies
      # even if YARN_IGNORE_PATH is set
      yarn config unset yarnPath > /dev/null
    '';

  mkBerryNix = { name, project }:
    pkgs.runCommand "${name}-berry.nix" {
      buildInputs = [ project.yarn ];
    } ''
      ${setupProject project}
      export YARN_GLOBAL_FOLDER="tmp"

      yarn makeBerryNix
      cp berry.nix $out
    '';

  /* Create the yarn global folder containing the packages in the cache

     This accepts a fetchWithYarn option to switch to using yarn for fetching
     instead of nix (builtins.fetchurl and builtins.fetchGit).
  */
  mkBerryCache = { name, project, fetchWithYarn ? false, ... }@args:
    let
      berryNix = args.berryNix or (mkBerryNix {
        inherit name project;
      });

      allPackages = import berryNix;

      # patch packages may need to reference other packages so we filter those
      # out for lookup
      remotePackages = builtins.filter (pkg: pkg.source.type != "patch") allPackages;

      # Fetch the package over the network with yarn. This should be closer to
      # the standard behavior and can use the standard yarn authentication
      # methods.
      fetchRemotePackageWithYarn = opts: pkgs.runCommand opts.name {
        outputHash = opts.sha512;
        outputHashAlgo = "sha512";

        buildInputs = [ project.yarn project.yarn.nodejs pkgs.git ];
        nativeBuildInputs = [ pkgs.cacert ];
        passthru.cacheFilename = opts.name;

        locatorJson = builtins.toJSON opts.locator;
        passAsFile = [ "locatorJson" ];
      } ''
        ${setupProject project}
        export YARN_ENABLE_NETWORK=true
        export YARN_GLOBAL_FOLDER=tmp

        mkdir -p tmp/cache

        yarn fetchLocator "$locatorJsonPath" | sed /YN0013/d
        mv "tmp/cache/${opts.name}" "$out"
      '';

      # Fetch the package with nix using builtins.fetchurl and
      # builtins.fetchGit. This allows using authentication via .netrc or SSH.
      # Note that this requires the packages to be in the fetcher cache even if
      # this is an FOD. If they expire, the packages will have to be fetched
      # again so it would be good to increase the nix tarball-ttl setting.
      fetchRemotePackageWithNix = opts: pkgs.runCommand opts.name {
        outputHash = opts.sha512;
        outputHashAlgo = "sha512";

        nativeBuildInputs = [ pkgs.cacert ];

        buildInputs = [ project.yarn project.yarn.nodejs ];
        passthru.cacheFilename = opts.name;

        locatorJson = builtins.toJSON opts.locator;
        passAsFile = [ "locatorJson" ];
      } ''
        ${yarnEnv}
        export YARN_PLUGINS="${yarnPlugin}"

        ${if opts.source.type == "git" then ''
          # copy the git directory so it's writable
          cp -r "${builtins.fetchGit { inherit (opts.source) url rev; }}" repo
          chmod -R +w repo
          fetched=repo
        '' else if opts.source.type == "url" then ''
          fetched="${builtins.fetchurl opts.source.url}"
        '' else throw "Unknown source type ${opts.source.type}"}

        ${lib.optionalString (opts.prepare or false) ''
          # npm complains if HOME does not exist
          export HOME=$(pwd)

          # dependencies may need to be installed so we temporarily allow
          # network access
          export YARN_ENABLE_NETWORK=true

          yarn prepareDependency \
            "$fetched" \
            package.tgz \
            "$locatorJsonPath"

          export YARN_ENABLE_NETWORK=false

          fetched=package.tgz
        ''}

        yarn tgzToZip \
          "$fetched" \
          "$out" \
          "${opts.convert.prefixPath}" \
          --compressionLevel "${builtins.toString opts.convert.compressionLevel}"
      '';

      fetchRemotePackage = if fetchWithYarn
        then fetchRemotePackageWithYarn
        else fetchRemotePackageWithNix;

      fetchPatchPackage = opts: pkgs.runCommand opts.name ({
        source = fetchRemotePackage (lib.findFirst
          (pkg: pkg.name == opts.source.source)
          (throw "No source package found for ${opts.name}")
          remotePackages
        );

        outputHash = opts.sha512;
        outputHashAlgo = "sha512";

        buildInputs = [ project.yarn project.yarn.nodejs ];
        passthru.cacheFilename = opts.name;

        locatorJson = builtins.toJSON opts.locator;
        passAsFile = [ "locatorJson" ];
      }) ''
        ${setupProject project}
        export YARN_GLOBAL_FOLDER=tmp

        # setup writable cache and copy in any dependencies
        mkdir -p tmp/cache
        ln -s "$source" "tmp/cache/${opts.source.source}"

        yarn fetchLocator "$locatorJsonPath"
        mv "tmp/cache/${opts.name}" "$out"
      '';

      fetchedPackages = map (pkg:
        if pkg.source.type == "patch" then
          fetchPatchPackage pkg
        else
          fetchRemotePackage pkg
      ) allPackages;
    in
    pkgs.runCommand "${name}-berry-cache" {
      passthru = { inherit berryNix; };
    } ''
      mkdir -p $out/cache
      ${lib.concatMapStrings (p: ''
        ln -s "${p}" "$out/cache/${p.cacheFilename}"
      '') fetchedPackages}
    '';

  /* Create a node_modules directory from a yarn install

     production can be set to skip devDependencies but requires the
     workspace-tools plugin to be installed.

     This does not work for packages with workspaces since those contain
     multiple node_modules folders.
  */
  mkBerryModules = { name, production ? false, ... }@args:
    let
      project = getProject args;
      cache = mkBerryCache (args // {
        inherit project;
      });

      installCommand = if production
        then "yarn workspaces focus --production"
        else "yarn install --immutable";
    in
    assert lib.assertMsg (project.workspaces == []) "mkBerryModules cannot be used with workspaces";
    pkgs.runCommand "${name}-node-modules" {
      buildInputs = [ project.yarn ];

      # By default, when installing, yarn will copy zips from the global cache
      # into the project cache (.yarn/cache) and then do the linking (untar
      # into node_modules) from there.
      #
      # The intermediate copy can be skipped by setting `enableGlobalCache` BUT
      # yarn does not support zips that are symlinks (which is how we build the
      # global cache). This works with the global cache off because the zips
      # that yarn copies into the project cache are not symlinks.
      #
      # For this to work, we have to patch yarn to support symlinked zips and
      # only use the global cache if it is.
      YARN_ENABLE_GLOBAL_CACHE = builtins.toJSON (project.yarn.isPatchedForGlobalCache or false);

      passthru = {
        inherit cache;
        inherit (project) yarn;
      };
    } ''
      ${setupProject project}
      export YARN_NODE_LINKER="node-modules"
      export YARN_GLOBAL_FOLDER="${cache}"

      # YN0013 is "will fetch"
      ${installCommand} | sed /YN0013/d
      mkdir $out
      mv node_modules $out/node_modules
    '';

  /* Setup a yarn workspace

     Essentially does a yarn install in the src folder.

     packages also contains an attrset containing metadata about workspace
     subpackages. See also getWorkspaces
  */
  mkBerryWorkspace = {
    name,
    src,
    buildPhase ? "yarn install --immutable",
    installPhase ? "cp -r . $out",
    ...
  }@args:
    let
      project = getProject args;
      cache = mkBerryCache (args // {
        inherit project;
      });

      packages = builtins.listToAttrs (builtins.map (workspace: {
        inherit (workspace) name;
        value = workspace;
      }) project.workspaces);
    in
    stdenv.mkDerivation {
      inherit name src;

      buildInputs = [ project.yarn ];

      YARN_ENABLE_GLOBAL_CACHE = builtins.toJSON (project.yarn.isPatchedForGlobalCache or false);

      buildPhase = ''
        ${yarnEnv}
        export YARN_NODE_LINKER="node-modules"
        export YARN_GLOBAL_FOLDER="${cache}"

        ${buildPhase}
      '';

      inherit installPhase;

      passthru = {
        inherit cache packages;
        inherit (project) yarn;
      };
    };
in
{
  inherit mkBerryModules mkBerryWorkspace getWorkspaces wrapYarnWith;
}

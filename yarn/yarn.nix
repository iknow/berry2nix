{ stdenv
, lib
, callPackage
, fetchFromGitHub
, nodejs
, plugins ? []
, patches ? []
, applyBuiltinPatches ? false
}:

let
  yarnPath = stdenv.mkDerivation (finalAttrs: {
    pname = "yarn";
    version = "3.5.1";

    buildInputs = [ nodejs ];

    src = fetchFromGitHub {
      owner = "yarnpkg";
      repo = "berry";
      rev = "@yarnpkg/cli/${finalAttrs.version}";
      sha256 = "sha256-YqXeo7oTn2U0VmaOnXqa/9IF96IG0Hi2EsVWtx5Tp6w=";
    };

    patches = patches ++ lib.optionals applyBuiltinPatches [
      ./symlink-zip.patch
      ./architecture-purity.patch
    ];

    buildPhase = ''
      patchShebangs --build scripts/run-yarn.js
      scripts/run-yarn.js build:cli
    '';

    installPhase = ''
      cp packages/yarnpkg-cli/bundles/yarn.js $out
    '';
  });
in
callPackage ./wrapper.nix {
  inherit nodejs yarnPath plugins;
  passthru = {
    isPatchedForGlobalCache = applyBuiltinPatches;
  };
}

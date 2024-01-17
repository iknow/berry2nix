{ stdenv
, lib
, fetchFromGitHub
, nodejs
, patches ? []
, applyBuiltinPatches ? false
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "yarn.js";
  version = "4.0.2";
  name = "yarn-${finalAttrs.version}.js";

  buildInputs = [ nodejs ];

  src = fetchFromGitHub {
    owner = "yarnpkg";
    repo = "berry";
    rev = "@yarnpkg/cli/${finalAttrs.version}";
    sha256 = "sha256-CTz+wkNeMwyWhfu1KLoPVXJEA37esA5vhOQvqkLHn+c=";
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

  passthru = {
    isPatchedForGlobalCache = applyBuiltinPatches;
  };
})

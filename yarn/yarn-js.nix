{ stdenv
, lib
, fetchFromGitHub
, nodejs
, patches ? []
, applyBuiltinPatches ? false
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "yarn.js";
  version = "3.5.1";
  name = "yarn-${finalAttrs.version}.js";

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

  passthru = {
    isPatchedForGlobalCache = applyBuiltinPatches;
  };
})

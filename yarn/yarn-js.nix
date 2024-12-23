{ stdenv
, lib
, fetchFromGitHub
, nodejs
, patches ? []
, applyBuiltinPatches ? false
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "yarn.js";
  version = "4.5.3";
  name = "yarn-${finalAttrs.version}.js";

  buildInputs = [ nodejs ];

  src = fetchFromGitHub {
    owner = "yarnpkg";
    repo = "berry";
    rev = "@yarnpkg/cli/${finalAttrs.version}";
    sha256 = "sha256-ywg+SYjFlWUMQftw1eZE5UY3nfxn6xy1NIawgmH/4vY=";
  };

  patches = patches ++ lib.optionals applyBuiltinPatches [
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

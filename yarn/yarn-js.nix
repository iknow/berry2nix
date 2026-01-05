{ stdenv
, lib
, fetchFromGitHub
, nodejs
, patches ? []
, applyBuiltinPatches ? false
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "yarn.js";
  version = "4.12.0";
  name = "yarn-${finalAttrs.version}.js";

  buildInputs = [ nodejs ];

  src = fetchFromGitHub {
    owner = "yarnpkg";
    repo = "berry";
    rev = "@yarnpkg/cli/${finalAttrs.version}";
    sha256 = "sha256-HuUqk4g+MaDI7r1cKAwAtQeNrJ6G9T9IdPgybv2W2pU=";
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
})

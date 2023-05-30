{ stdenv
, lib
, runtimeShell
, fetchFromGitHub
, nodejs
}:

stdenv.mkDerivation rec {
  pname = "yarn";
  version = "3.5.1";

  buildInputs = [ nodejs ];

  src = fetchFromGitHub {
    owner = "yarnpkg";
    repo = "berry";
    rev = "@yarnpkg/cli/${version}";
    sha256 = "sha256-YqXeo7oTn2U0VmaOnXqa/9IF96IG0Hi2EsVWtx5Tp6w=";
  };

  patches = [
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
}

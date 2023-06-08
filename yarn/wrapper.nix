{ stdenv
, lib
, makeWrapper
, nodejs
, runtimeShell
, yarnPath ? ../.yarn/releases/yarn-3.5.1.cjs
, plugins ? []
, passthru ? {}
}:

stdenv.mkDerivation {
  pname = "yarn";
  version = if lib.isDerivation yarnPath then yarnPath.version else "";

  buildInputs = [ makeWrapper nodejs ];

  src = yarnPath;

  dontUnpack = true;
  dontBuild = true;

  installPhase = ''
    mkdir $out
    mkdir $out/bin
    mkdir $out/libexec

    cp $src $out/libexec/yarn.js

    makeWrapper "${nodejs}/bin/node" "$out/bin/yarn" \
      --add-flags "$out/libexec/yarn.js" \
      --set YARN_IGNORE_PATH true \
      --suffix YARN_PLUGINS : "${builtins.concatStringsSep ";" plugins}"
  '';

  passthru = passthru // {
    inherit nodejs yarnPath plugins;
  };
}

{ stdenv
, lib
, makeWrapper
, nodejs
, yarn-js ? ../.yarn/releases/yarn-3.5.1.cjs
, plugins ? []
, passthru ? {}
}:

stdenv.mkDerivation {
  pname = "yarn-wrapper";
  version = if lib.isDerivation yarn-js then yarn-js.version else "";

  buildInputs = [ makeWrapper nodejs ];

  src = yarn-js;

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
      --suffix YARN_PLUGINS ";" "${builtins.concatStringsSep ";" plugins}"
  '';

  passthru = passthru // {
    inherit nodejs yarn-js plugins;
  } // lib.optionalAttrs (lib.attrsets.isDerivation yarn-js) {
    isPatchedForGlobalCache = yarn-js.isPatchedForGlobalCache or false;
  };
}

{ callPackage }:

rec {
  yarn-js = callPackage ./yarn-js.nix {};

  wrapYarnWith = { yarn-js, ... } @ extraArgs: callPackage ./wrapper.nix ({
    inherit yarn-js;
  } // extraArgs);

  yarn = wrapYarnWith {
    inherit yarn-js;
  };

  yarn-patched = wrapYarnWith {
    yarn-js = yarn-js.override {
      applyBuiltinPatches = true;
    };
  };
}

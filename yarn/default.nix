{ callPackage }:

rec {
  yarn = callPackage ./yarn.nix {};
  yarn-patched = yarn.override {
    applyBuiltinPatches = true;
  };

  yarn-bin = callPackage ./wrapper.nix {};
}

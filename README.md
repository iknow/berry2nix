# berry2nix

This is yet another Yarn 3 (berry) nix library. You might also be interested in
the other following projects which have different pros and cons:

 * [yarnpnp2nix](https://github.com/madjam002/yarnpnp2nix)
 * [yarn-plugin-nixify](https://github.com/stephank/yarn-plugin-nixify)

Unlike the above, we primarily aim this as a replacement for our [fork of
yarn2nix](https://github.com/iknow/yarn2nix/tree/patched) which we use for our
projects. As such, we prioritize the following features:

 * support private registries by fetching with `builtins.fetchurl` and
   `builtins.fetchGit` (using user .netrc)
 * no generation or plugin integration is required
 * expose lower level functions to build just `node_modules`
 * workspace metadata in nix

On the other hand, we don't prioritize other features and hence they are
untested or just don't work:

 * packaging an application (planned)
 * building native dependencies
 * non-npm or non-git dependencies
 * `pnp` linker
 * corepack

This has only been tested with yarn 3.5.1, older versions might not work.

## Usage

```nix
{ pkgs }:
let
  berry2nix = pkgs.callPackage (pkgs.fetchFromGitHub {
    owner = "iknow";
    repo = "berry2nix";
    rev = "...";
    sha256 = "...";
  } + "/lib.nix") {};
in

berry2nix.mkBerryWorkspace {
  name = "packagename";
  src = ./.;
}
```

Will result in a derivation with your project and all dependencies installed.
The wrapped yarn is also available as `yarn` under the derivation.

### Modules

For more complicated setups, it's possible to just build the `node_modules`
folder. This is useful to just symlink it into other derivations rather than
having to have a full copy. It's also possible to install just the production
dependencies by passing in `production = true;` but this requires the project to
have the `workspace-tools` plugin installed.

```nix
berry2nix.mkBerryModules {
  name = "packagename";
  src = ./.;
  production = true;
}
```

### Fetching

By default, we use the nix builtin fetchers. This allows fetching from private
registries as well as private SSH repositories at *evaluation time*. This means
it inherits authentication from the user running `nix-build`. So this will
respect `netrc-file` in the user's `nix.conf` and use the user's ssh-agent if
present.

A downside to using the nix fetchers is that they are *always* evaluated, so
even though the packages are fixed-output derivations, nix will always make sure
that the fetched tars are in the user cache even if they won't be used. To avoid
excessive fetching, it might be good to increase `tarball-ttl` in the nix
settings.

If all packages come from public registries, it's also possible to do fetching
via yarn instead of nix by specifying `fetchWithYarn = true;`. The option can be
specified for both of `mkBerryWorkspace` and `mkBerryModules`.

#### Request has been blocked

If yarn fails with "Request has been blocked by configuration settings", this
means that a dependency:

 * is not an npm, patch or git dependency
 * does not have a checksum
 * is an optional conditional dependency

The only case we explicitly support is an optional conditional dependency, in
this case, yarn hides the checksum to avoid the lockfile from changing depending
on the system installing the package. To work around this, make the dependency
explicit.

For example, `esbuild` optionally depends on `@esbuild/linux-x64` and hence the
`@esbuild/linux-x64` package will not have a checksum in the lockfile. To ensure
yarn sets a checksum on it, put it in your `package.json` explicitly.

```json
{
  "devDependencies": {
    "@esbuild/linux-x64": "0.17.19",
    "esbuild": "0.17.19"
  }
}
```

### Yarn Path

We assume that the project uses the standard layout with yarn committed under
`.yarn/releases`. If it's not there (for example, if corepack is used), then the
user must have to manually provide it like so:

```nix
berry2nix.mkBerryWorkspace {
  yarnPath = pkgs.fetchurl {
    url = "https://repo.yarnpkg.com/3.5.1/packages/yarnpkg-cli/bin/yarn.js";
    sha256 = "sha256-ZMC2Pl+g4h81S17/fJobSG8yBGv8MoNnBWnjxqnK0QI=";
  };
}
```

### Workspaces

When building a project with workspaces, information about the sub-packages is
provided in the `packages` attrset. The name from the package.json is in
`packageName` while the relative path to the sub-package is available in `path`.

If `workspace-tools` is installed, it's also possible to build them as
derivations with the workspace focused, however there is not much benefit to
doing so now since the berry cache is always built with all packages.

module.exports = {
  name: 'plugin-nix',
  factory: require => {
    const path = require('path');
    const util = require('util');
    const fs = require('fs');

    const { Command, Option } = require(`clipanion`);
    const { structUtils, tgzUtils, Cache, Configuration, Project, ThrowReport } = require(`@yarnpkg/core`);
    const { npmConfigUtils } = require(`@yarnpkg/plugin-npm`);
    const { patchUtils } = require(`@yarnpkg/plugin-patch`);

    const writePromise = util.promisify(fs.write);

    function splitChecksum(checksum) {
      if (checksum === undefined) {
        return { cacheKey: null, hash: null };
      }
      const cacheKeyIndex = checksum.indexOf('/');
      if (cacheKeyIndex < 0) {
        throw new Error('Invalid checksum');
      }
      const cacheKey = checksum.substring(0, cacheKeyIndex);
      const hash = checksum.substring(cacheKeyIndex + 1);
      return { cacheKey, hash };
    }

    function serializeToNixAttrs(data, indentLevel = 0) {
      const result = [];
      const padding = ' '.repeat(indentLevel);
      for (const [key, value] of Object.entries(data)) {
        if (value === undefined) {
          continue;
        } else if (value === null) {
          result.push(`${padding}${key} = ${JSON.stringify(value)};`);
        } else if (Array.isArray(value)) {
          result.push(`${padding}${key} = ${JSON.stringify(value)};`);
        } else if (typeof value === 'object') {
          result.push(`${padding}${key} = {`);
          result.push(serializeToNixAttrs(value, indentLevel + 2));
          result.push(`${padding}};`);
        } else {
          result.push(`${padding}${key} = ${JSON.stringify(value)};`);
        }
      }
      return result.join('\n');
    }

    async function writeBerryNix(packages) {
      const file = await util.promisify(fs.open)('berry.nix', 'w');
      try {
        await writePromise(file, "[\n");
        for (const package of packages) {
          await writePromise(file, "  {\n");
          await writePromise(file, serializeToNixAttrs(package, 4));
          await writePromise(file, "\n  }\n");
        }
        await writePromise(file, "]\n");
      } finally {
        await util.promisify(fs.close)(file);
      }
    }

    async function collectPackages(project, cache) {
      const NpmSemverFetcher = project.configuration.plugins.get('@yarnpkg/plugin-npm').fetchers[1];
      const packages = [];
      for (const pkg of project.storedPackages.values()) {
        const { protocol } = structUtils.parseRange(pkg.reference);
        const name = path.basename(cache.getLocatorMirrorPath(pkg));
        const checksum = project.storedChecksums.get(pkg.locatorHash);
        if (protocol === 'npm:') {
          const registry = npmConfigUtils.getScopeRegistry(pkg.scope, { configuration: project.configuration });
          const packageUrl = `${registry}${NpmSemverFetcher.getLocatorUrl(pkg)}`;
          const { hash } = splitChecksum(checksum);
          packages.push({
            name,
            convert: {
              compressionLevel: project.configuration.get('compressionLevel'),
              prefixPath: structUtils.getIdentVendorPath(pkg),
            },
            source: {
              type: 'url',
              url: packageUrl,
              sha512: hash,
            }
          });
        } else if (protocol === 'patch:') {
          const { hash } = splitChecksum(checksum);
          packages.push({
            name,
            // no convert options needed as we're picking it up from the
            // project configuration directly
            source: {
              type: 'patch',
              locator: {
                name: pkg.name,
                scope: pkg.scope,
                identHash: pkg.identHash,
                locatorHash: pkg.locatorHash,
                reference: pkg.reference,
              },
              sha512: hash,
            }
          });
        }
      }
      return packages;
    }

    class MakeBerryNix extends Command {
      static paths = [['makeBerryNix']];

      async execute() {
        const configuration = await Configuration.find(this.context.cwd, this.context.plugins);
        const { project } = await Project.find(configuration, this.context.cwd);
        const cache = await Cache.find(configuration);
        await project.applyLightResolution();
        await writeBerryNix(await collectPackages(project, cache));
      }
    }

    class TgzToZip extends Command {
      static paths = [['tgzToZip']];

      source = Option.String();
      target = Option.String();
      compressionLevel = Option.String();
      prefixPath = Option.String();

      async execute() {
        const compressionLevel = this.compressionLevel === 'mixed'
          ? 'mixed'
          : parseInt(this.compressionLevel);
        const buffer = await util.promisify(fs.readFile)(this.source);
        const zip = await tgzUtils.convertToZip(buffer, {
          compressionLevel,
          prefixPath: this.prefixPath,
          stripComponents: 1,
        });
        const realPath = zip.getRealPath();
        zip.saveAndClose();
        await util.promisify(fs.copyFile)(realPath, this.target);
      }
    }

    class FetchPatch extends Command {
      static paths = [['fetchPatch']];

      async execute() {
        const locator = await util.promisify(fs.readFile)(this.context.stdin.fd, 'utf-8');
        const configuration = await Configuration.find(this.context.cwd, this.context.plugins);
        const { project } = await Project.find(configuration, this.context.cwd);
        const cache = await Cache.find(configuration);
        await project.applyLightResolution();
        const fetcher = configuration.makeFetcher();
        await fetcher.fetch(JSON.parse(locator), {
          checksums: project.storedChecksums,
          project,
          cache,
          fetcher,
          report: new ThrowReport(),
          cacheOptions: {
            mirrorWriteOnly: true,
          }
        });
      }
    }

    return {
      commands: [ TgzToZip, MakeBerryNix, FetchPatch ],
      hooks: {
        async afterAllInstalled(project, { cache }) {
          if (process.env.SKIP_BERRY_NIX !== undefined) {
            return;
          }

          await writeBerryNix(await collectPackages(project, cache));
        }
      }
    };
  }
}

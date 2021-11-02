module.exports = {
  name: 'plugin-nix',
  factory: require => {
    const path = require('path');
    const util = require('util');
    const fs = require('fs');

    const { Command, Option } = require(`clipanion`);
    const { structUtils, tgzUtils, Cache, Configuration, Project } = require(`@yarnpkg/core`);
    const { npmConfigUtils } = require(`@yarnpkg/plugin-npm`);

    const writePromise = util.promisify(fs.write);

    function splitChecksum(checksum) {
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
        if (protocol === 'npm:') {
          const registry = npmConfigUtils.getScopeRegistry(pkg.scope, { configuration: project.configuration });
          const packageUrl = `${registry}${NpmSemverFetcher.getLocatorUrl(pkg)}`;
          const checksum = project.storedChecksums.get(pkg.locatorHash);
          const { cacheKey, hash } = splitChecksum(checksum);
          packages.push({
            name: path.basename(cache.getLocatorMirrorPath(pkg)),
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
        const buffer = await util.promisify(fs.readFile)(this.source);
        const zip = await tgzUtils.convertToZip(buffer, {
          compressionLevel: this.compressionLevel,
          prefixPath: this.prefixPath,
          stripComponents: 1,
        });
        const realPath = zip.getRealPath();
        zip.saveAndClose();
        await util.promisify(fs.copyFile)(realPath, this.target);
      }
    }

    return {
      commands: [ TgzToZip, MakeBerryNix ],
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

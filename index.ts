import fs from 'fs/promises';

import { BaseCommand } from '@yarnpkg/cli';
import {
  Cache,
  Configuration,
  ConfigurationValueMap,
  Locator,
  Plugin,
  Project,
  StreamReport,
  scriptUtils,
  structUtils,
  tgzUtils,
} from '@yarnpkg/core';
import { InstallOptions } from '@yarnpkg/core/lib/Project';
import {
  CwdFS,
  PortablePath,
  ZipCompression,
  npath,
  ppath,
  xfs,
} from '@yarnpkg/fslib';
import { gitUtils } from '@yarnpkg/plugin-git';
import { npmConfigUtils } from '@yarnpkg/plugin-npm';
import type { NpmSemverFetcher } from '@yarnpkg/plugin-npm/lib/NpmSemverFetcher';
import { patchUtils } from '@yarnpkg/plugin-patch';
import { Option } from 'clipanion';


function splitChecksum(checksum: string | undefined) {
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

function serializeToNixAttrs(data: object, indentLevel = 0) {
  const result: string[] = [];
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

async function writeBerryNix(packages: object[]) {
  const file = await fs.open('berry.nix', 'w');
  await fs.appendFile(file, "[\n");
  for (const pkg of packages) {
    await fs.appendFile(file, "  {\n");
    await fs.appendFile(file, serializeToNixAttrs(pkg, 4));
    await fs.appendFile(file, "\n  }\n");
  }
  await fs.appendFile(file, "]\n");
}

interface UrlSource {
  type: 'url';
  url: string;
}

interface PatchSource {
  type: 'patch';
  source: string;
}

interface GitSource {
  type: 'git';
  url: string;
  rev: string;
}

interface ConvertSpec {
  compressionLevel: ConfigurationValueMap['compressionLevel'];
  prefixPath: PortablePath;
}

interface PackageSpec {
  /**
   * The filename of the zip in the yarn cache
   */
  name: string;
  /**
   * Indicates the compression options when converting from tgz to zip
   */
  convert?: ConvertSpec;
  /**
   * Indicates whether this is a dependency that has to be prepared
   */
  prepare?: boolean;
  /**
   * The source to be fetched by nix
   */
  source: UrlSource | PatchSource | GitSource;
  locator: Locator;
  /**
   * SHA512 hash of the resulting zip file (not of the sources)
   */
  sha512: string;
}

async function collectPackages(project: Project, cache: Cache) {
  // in yarn 4, this should be importable directly from @yarnpkg/plugin-npm
  // instead of having to dig it out of the configuration
  const npmFetcher = project.configuration.plugins.get('@yarnpkg/plugin-npm')?.fetchers?.find(f => {
    return 'getLocatorUrl' in f && typeof f.getLocatorUrl === 'function';
  })! as typeof NpmSemverFetcher;

  const packages: PackageSpec[] = [];
  for (const pkg of project.storedPackages.values()) {
    const { protocol } = structUtils.parseRange(pkg.reference);
    const name = cache.getVersionFilename(pkg);
    const checksum = project.storedChecksums.get(pkg.locatorHash);
    const { hash } = splitChecksum(checksum);

    if (hash === null) {
      continue;
    }

    const sha512 = hash;

    const locator: Locator = {
      name: pkg.name,
      scope: pkg.scope,
      identHash: pkg.identHash,
      locatorHash: pkg.locatorHash,
      reference: pkg.reference,
    }

    const convert: ConvertSpec = {
      compressionLevel: project.configuration.get('compressionLevel'),
      prefixPath: structUtils.getIdentVendorPath(pkg),
    };

    if (protocol === 'npm:') {
      const registry = npmConfigUtils.getScopeRegistry(pkg.scope, { configuration: project.configuration });
      const packageUrl = `${registry}${npmFetcher.getLocatorUrl(pkg)}`;
      packages.push({
        name,
        convert,
        source: {
          type: 'url',
          url: packageUrl,
        },
        locator,
        sha512,
      });
    } else if (protocol === 'patch:') {
      const { sourceLocator } = patchUtils.parseLocator(pkg);
      const sourceName = cache.getVersionFilename(sourceLocator);
      packages.push({
        name,
        // no convert options needed as we're picking it up from the
        // project configuration directly
        source: {
          type: 'patch',
          source: sourceName,
        },
        locator,
        sha512,
      });
    } else if (protocol === 'git+ssh:' || protocol === 'git+https:') {
      const { repo, treeish } = gitUtils.splitRepoUrl(pkg.reference);
      if (treeish.protocol !== gitUtils.TreeishProtocols.Commit) {
        throw new Error('Git URLs must be resolved to a commit');
      }

      packages.push({
        name,
        convert,
        source: {
          type: 'git',
          // strip git+
          url: repo.substring(4),
          rev: treeish.request,
        },
        prepare: true,
        locator,
        sha512,
      });
    } else if (pkg.reference.startsWith('https://github.com/')) {
      const { repo, treeish } = gitUtils.splitRepoUrl(pkg.reference);
      if (treeish.protocol !== gitUtils.TreeishProtocols.Commit) {
        throw new Error('Git URLs must be resolved to a commit');
      }

      const repoUrl = new URL(repo);

      const ownerRepo = repoUrl.pathname.replace(/.git$/, '');
      const packageUrl = `https://codeload.github.com${ownerRepo}/tar.gz/${treeish.request}`;

      packages.push({
        name,
        convert,
        source: {
          type: 'url',
          url: packageUrl,
        },
        prepare: true,
        locator,
        sha512,
      });
    }
  }
  return packages;
}

class MakeBerryNix extends BaseCommand {
  static override paths = [['makeBerryNix']];

  async execute() {
    const configuration = await Configuration.find(this.context.cwd, this.context.plugins);
    const { project } = await Project.find(configuration, this.context.cwd);
    const cache = await Cache.find(configuration);
    await project.applyLightResolution();
    await writeBerryNix(await collectPackages(project, cache));
  }
}

class PrepareDependency extends BaseCommand {
  static override paths = [['prepareDependency']];

  source = Option.String();
  target = Option.String();
  locator = Option.String();

  async execute() {
    const configuration = await Configuration.find(this.context.cwd, this.context.plugins);

    const locator: Locator = JSON.parse(
      await xfs.readFilePromise(npath.toPortablePath(this.locator), 'utf8')
    );
    const sourcePath = npath.toPortablePath(this.source);
    const targetPath = npath.toPortablePath(this.target);

    await xfs.mktempPromise(async (extractPath) => {
      let projectPath: PortablePath;

      const stat = await xfs.statPromise(sourcePath);
      if (stat.isDirectory()) {
        projectPath = sourcePath;
      } else {
        const extractTarget = new CwdFS(extractPath);

        const sourceBuffer = await xfs.readFilePromise(sourcePath);

        await tgzUtils.extractArchiveTo(sourceBuffer, extractTarget, {
          stripComponents: 1,
        });

        projectPath = extractPath;
      }

      const repoUrlParts = gitUtils.splitRepoUrl(locator.reference);
      const packagePath = ppath.join(this.context.cwd, targetPath);

      await scriptUtils.prepareExternalProject(projectPath, packagePath, {
        configuration,
        report: new StreamReport({
          configuration,
          stdout: this.context.stdout,
        }),
        workspace: repoUrlParts.extra['workspace'] ?? null,
        locator,
      });
    });
  }
}

class TgzToZip extends BaseCommand {
  static override paths = [['tgzToZip']];

  source = Option.String();
  target = Option.String();
  compressionLevel = Option.String('--compressionLevel', 'mixed');
  prefixPath = Option.String();

  async execute() {
    const sourcePath = npath.toPortablePath(this.source);
    const targetPath = npath.toPortablePath(this.target);

    const compressionLevel = this.compressionLevel === 'mixed'
      ? 'mixed'
      : parseInt(this.compressionLevel) as ZipCompression;

    const buffer = await xfs.readFilePromise(sourcePath);
    const zip = await tgzUtils.convertToZip(buffer, {
      compressionLevel,
      prefixPath: npath.toPortablePath(this.prefixPath),
      stripComponents: 1,
    });
    zip.saveAndClose();

    const realPath = zip.getRealPath();
    await xfs.copyFilePromise(realPath, targetPath);
  }
}

class FetchLocator extends BaseCommand {
  static override paths = [['fetchLocator']];

  locator = Option.String();

  async execute() {
    const locator: Locator = JSON.parse(
      await xfs.readFilePromise(npath.toPortablePath(this.locator), 'utf8')
    );

    const configuration = await Configuration.find(this.context.cwd, this.context.plugins);
    const { project } = await Project.find(configuration, this.context.cwd);
    const cache = await Cache.find(configuration);
    await project.applyLightResolution();

    const fetcher = configuration.makeFetcher();
    await fetcher.fetch(locator, {
      checksums: project.storedChecksums,
      project,
      cache,
      fetcher,
      report: new StreamReport({
        configuration,
        stdout: this.context.stdout,
      }),
      cacheOptions: {
        mirrorWriteOnly: true,
      }
    });
  }
}

const plugin: Plugin = {
  commands: [ TgzToZip, MakeBerryNix, FetchLocator, PrepareDependency ],
  hooks: {
    async afterAllInstalled(project: Project, { cache }: InstallOptions) {
      if (process.env['SKIP_BERRY_NIX'] !== undefined) {
        return;
      }

      await writeBerryNix(await collectPackages(project, cache));
    }
  }
};

export default plugin;

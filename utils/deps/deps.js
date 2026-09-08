#!/usr/bin/env node

const depcheck = require('depcheck');
const cp = require('child_process');
const fs = require('fs/promises');
const prettier = require('prettier');
const { fgReset, fgRed, fgGreen, fgYellow, fgCyan } = require('./lib/colors');
const { moonCommandsBySource, isUsedByMoon } = require('./lib/moon-usage');

const prettierOptions = JSON.parse(
  require('fs').readFileSync(`${__dirname}/../../.prettierrc`, 'utf8')
);

const isFix = process.argv.includes('--fix');

const options = {
  ignoreBinPackage: false, // ignore the packages with bin entry
  skipMissing: false, // skip calculation of missing dependencies
  ignorePatterns: [
    // files matching these patterns will be ignored
    'build',
    'coverage',
    'node_modules',
    'dist',
    'out',
    'tmp',
    'artifacts',
    'cache',
    'typechain-types',
    'test/generated',
  ],
  ignoreMatches: [
    // Must keep ts dependency so depcheck works over Typescript files
    'typescript',
    '@types/jest',
    'webpack-dev-server',
    '@synthetixio/core-contracts',
    '@synthetixio/core-modules',
  ],
  parsers: {
    '**/*.js': [depcheck.parser.es6, depcheck.parser.jsx],
    '**/*.jsx': depcheck.parser.jsx,
    '**/*.mjs': depcheck.parser.es6,
    '**/*.ts': depcheck.parser.typescript,
    '**/*.tsx': depcheck.parser.typescript,
  },
};

const ignoredPackages = ['synthetix-v3'];

let updatedPackages = 0;

async function run() {
  const workspacePackages = (await require('./lib/workspaces')())
    // filter out old unsupported dirs
    .filter(({ name }) => !ignoredPackages.includes(name));

  const workspaceDeps = workspacePackages.map(({ name }) => [name, 'workspace:*']);

  // Versions already in use across the workspace, so a missing dependency can
  // be suggested at a version that resolves. Was `yarn info --all --json`;
  // pnpm has no single-command equivalent, and the package.json files are the
  // same source of truth.
  const existingDeps = workspacePackages.flatMap(({ location }) => {
    const pkg = JSON.parse(require('fs').readFileSync(`${location}/package.json`, 'utf-8'));
    return Object.entries({ ...pkg.dependencies, ...pkg.devDependencies }).filter(
      ([, version]) => !version.startsWith('workspace:')
    );
  });

  const deps = Object.fromEntries([].concat(existingDeps).concat(workspaceDeps));

  // A moon task's command/args/script is a usage site depcheck cannot see —
  // it only reads a package's own `scripts` field. One call for the whole
  // workspace; see lib/moon-usage.js for why.
  const moonCommands = await moonCommandsBySource();

  await workspacePackages.reduce(async (promise, { location, name }) => {
    await promise;

    const packageJson = JSON.parse(await fs.readFile(`${location}/package.json`, 'utf-8'));

    let { dependencies, devDependencies, missing } = await depcheck(location, {
      ...options,
      ...packageJson.depcheck,
      package: packageJson,
    });
    dependencies = dependencies.filter((dep) => !isUsedByMoon(dep, location, moonCommands));
    devDependencies = devDependencies.filter((dep) => !isUsedByMoon(dep, location, moonCommands));
    dependencies.sort();
    devDependencies.sort();

    const missingDeps = Object.keys(missing);
    missingDeps.sort();

    if (!dependencies.length && !devDependencies.length && !missingDeps.length) {
      return;
    }

    updatedPackages = updatedPackages + 1;

    console.log('');
    console.log('');
    console.log(`${location}/package.json`);
    console.log(`${fgCyan}  "name": "${name}"${fgReset}`);

    if (dependencies.length || missingDeps.length) {
      console.log(`${fgCyan}  "dependencies": {${fgReset}`);
      dependencies.forEach((dep) => {
        console.log(`${fgRed}    "${dep}": "${packageJson.dependencies[dep]}"${fgReset}`);
        delete packageJson.dependencies[dep];
      });
      missingDeps.forEach((dep) => {
        if (dep in deps) {
          console.log(`${fgGreen}    "${dep}": "${deps[dep]}"${fgReset}`);
          if (!('dependencies' in packageJson)) {
            packageJson.devDependencies = {};
          }
          packageJson.devDependencies[dep] = deps[dep];
        } else {
          console.log(`${fgYellow}    "${dep}": "?" <-- ADD MANUALLY${fgReset}`);
        }
      });
    }
    if (devDependencies.length) {
      console.log(`${fgCyan}  "devDependencies": {${fgReset}`);
      devDependencies.forEach((dep) => {
        console.log(`${fgRed}    "${dep}": "${packageJson.devDependencies[dep]}"${fgReset}`);
        delete packageJson.devDependencies[dep];
      });
    }
    if (isFix) {
      console.log(`...FIXING ${fgYellow}${location}/package.json${fgReset}`);
      await fs.writeFile(
        `${location}/package.json`,
        await prettier.format(JSON.stringify(packageJson, null, '  '), {
          parser: 'json',
          ...prettierOptions,
        })
      );
    }
  }, Promise.resolve());

  if (updatedPackages > 0 && isFix) {
    console.log('');
    console.log('');
    console.log(`${fgGreen}Packages fixed: ${fgGreen}${updatedPackages}${fgReset}`);
    cp.execSync('pnpm install', { encoding: 'utf-8', stdio: 'inherit' });
    return;
  }

  if (updatedPackages > 0) {
    console.log('');
    console.log('');
    console.log(`${fgRed}Packages need fixing: ${fgGreen}${updatedPackages}${fgReset}`);
    throw new Error(`Packages need fixing: ${updatedPackages}`);
  }
}

run().catch((e) => {
  console.error(e);
  process.exit(1);
});

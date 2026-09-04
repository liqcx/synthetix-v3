const path = require('node:path');
const fs = require('node:fs');

// pnpm's equivalent of `yarn workspaces list --verbose --json`. pnpm reports
// absolute paths and no workspace graph, so we derive `location` (relative,
// what the callers index by) and `workspaceDependencies` (locations, matching
// Yarn's shape) from each package.json ourselves.
module.exports = async function workspaces() {
  const exec = require('./exec');
  const packages = JSON.parse(await exec('pnpm list -r --depth -1 --json'));

  const root = packages.find((pkg) => pkg.name === 'synthetix-v3');
  if (!root) {
    throw new Error('Could not find the workspace root package "synthetix-v3"');
  }

  const byName = new Map();
  const entries = packages.map((pkg) => {
    const location = path.relative(root.path, pkg.path) || '.';
    byName.set(pkg.name, location);
    return { name: pkg.name, location, absolutePath: pkg.path };
  });

  return entries.map((entry) => {
    const packageJson = JSON.parse(
      fs.readFileSync(path.join(entry.absolutePath, 'package.json'), 'utf-8')
    );
    const declared = Object.keys({
      ...packageJson.dependencies,
      ...packageJson.devDependencies,
    });
    return {
      name: entry.name,
      location: entry.location,
      workspaceDependencies: declared
        .filter((dep) => byName.has(dep) && dep !== entry.name)
        .map((dep) => byName.get(dep)),
    };
  });
};

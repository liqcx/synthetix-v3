const path = require('node:path');
const fs = require('node:fs');

// depcheck's own bin-usage detector (depcheck/dist/special/bin.js) only reads
// a package's `scripts` field. Since the lerna-to-moon migration moved every
// orchestrated verb's body out of `scripts` and into `.moon/tasks`/`moon.yml`,
// a dependency whose only usage was a CLI invocation from a script (e.g.
// `@usecannon/cli`'s `cannon build`) now reads as unused, even though the
// moon task for that exact package still runs it. This teaches deps.js the
// same trick depcheck already does for `scripts`, applied to moon task
// command/args/script strings instead.

// One `moon query projects` call for the whole workspace, not one per
// package: moon resolves inherited tag tasks for us, so a command that lives
// only in a shared `.moon/tasks/*.yml` file (not in the project's own
// moon.yml) is still seen here.
async function moonCommandsBySource() {
  const exec = require('./exec');
  const { projects } = JSON.parse(await exec('moon query projects'));

  const bySource = new Map();
  for (const project of projects) {
    const tokens = [];
    for (const task of Object.values(project.tasks ?? {})) {
      if (task.command) tokens.push(task.command);
      if (Array.isArray(task.args)) tokens.push(...task.args);
      if (task.script) tokens.push(task.script);
    }
    // Space-padded, mirroring depcheck's own `` `${script}` `` matching below
    // — a plain substring match would let "cannon" match inside "mccannonfoo".
    bySource.set(project.source, ` ${tokens.join(' ')} `);
  }
  return bySource;
}

// Same shape as depcheck's own `getBinaries`: a string `bin` field names a
// command after the package itself (scope stripped); an object `bin` field
// names a command per key, which is how a devDependency like `@usecannon/cli`
// (declared name "cli", real installed binary "cannon") is found at all.
function binNames(dep, location) {
  let pkgJsonPath;
  try {
    pkgJsonPath = require.resolve(`${dep}/package.json`, { paths: [path.resolve(location)] });
  } catch {
    return [];
  }

  const bin = JSON.parse(fs.readFileSync(pkgJsonPath, 'utf-8')).bin;
  if (!bin) {
    return [];
  }
  return typeof bin === 'string' ? [path.basename(dep)] : Object.keys(bin);
}

// "package name or bin name" per the fix's own brief: the declared dependency
// name itself is checked too, not only its resolved binaries, so a dependency
// invoked by its npm name (rare here, but cheap to cover) is not missed.
function isUsedByMoon(dep, location, commandsBySource) {
  const commands = commandsBySource.get(location);
  if (!commands) {
    return false;
  }

  const names = [dep, ...binNames(dep, location)];
  return names.some((name) => commands.includes(` ${name} `));
}

module.exports = { moonCommandsBySource, isUsedByMoon };

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
//
// `moon query projects`' JSON is 822,661 bytes today against Node's 1 MiB
// (1,048,576 byte) default `maxBuffer` — 78.5% of it, on a workspace that
// only grows moon tasks over time. 10 MiB is ~12.7x today's size: enough
// headroom that this workspace would have to grow an order of magnitude
// before it mattered again, without going so high that a truly runaway
// process is silently tolerated.
const MOON_QUERY_MAX_BUFFER = 10 * 1024 * 1024;

async function moonCommandsBySource() {
  const exec = require('./exec');
  const { projects } = JSON.parse(
    await exec('moon query projects', { maxBuffer: MOON_QUERY_MAX_BUFFER })
  );

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

// Bin names only, matching depcheck's own `special/bin.js` exactly — a raw
// package-name check was tried and measured wrong: it makes a bare word like
// "diff" or "test" a live whitelist entry for every project whose inherited
// task happens to contain that token, silently hiding an unused dependency
// that is merely *named* the same as a command another task runs.
function isUsedByMoon(dep, location, commandsBySource) {
  const commands = commandsBySource.get(location);
  if (!commands) {
    return false;
  }

  return binNames(dep, location).some((name) => commands.includes(` ${name} `));
}

module.exports = { moonCommandsBySource, isUsedByMoon };

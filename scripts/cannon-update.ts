#!/usr/bin/env bun
/**
 * Move the Cannon fork pin.
 *
 * Cannon is a fork: `@alxwlw/cannon-{builder,cli}` installed under the upstream
 * `@usecannon/*` names through `npm:` aliases. Since the catalog migration the
 * pin lives in exactly ONE place — the two entries of the `cannon` catalog in
 * `pnpm-workspace.yaml` — and `overrides` reaches them indirectly, through
 * `$@usecannon/builder` on the root manifest's `catalog:cannon` specifier.
 *
 * This script replaced `pnpm up -r @usecannon/builder@npm:…`, which cannot be
 * used any more: pnpm 11.1.2 has no catalog-aware update, and given an explicit
 * spec it REPLACES `catalog:cannon` with the literal alias in all 14 manifests
 * that name it, leaving the catalog entry behind unused and stale. Nothing
 * fails when that happens — `overrides` still reads a real version, because
 * pnpm updates the root manifest too — so it would surface only as drift, which
 * is exactly the failure mode the single pin exists to prevent.
 *
 * Usage: `pnpm cannon:update`; `CANNON_TAG` selects the dist-tag (default
 * `nonce`).
 *
 * One limit of that entry point: `pnpm run` verifies the dependency status
 * before it executes a script, and that check is an install. So `pnpm
 * cannon:update` cannot REPAIR a catalog whose current pin does not resolve —
 * pnpm fails first, and the script never starts. Run it as
 * `bun scripts/cannon-update.ts` in that case; forward bumps, the normal use,
 * are unaffected.
 */
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const ROOT = join(import.meta.dir, '..');
const WORKSPACE = join(ROOT, 'pnpm-workspace.yaml');
const TAG = process.env.CANNON_TAG ?? 'nonce';

/** upstream name → the fork actually published under it */
const FORK: Record<string, string> = {
  '@usecannon/builder': '@alxwlw/cannon-builder',
  '@usecannon/cli': '@alxwlw/cannon-cli',
};

function resolveVersion(pkg: string): string {
  const raw = execFileSync('pnpm', ['view', `${pkg}@${TAG}`, 'version'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  // `pnpm view` can precede its answer with a diagnostic line; the version is
  // the last non-empty one.
  const version = raw.trim().split('\n').at(-1)?.trim() ?? '';
  if (!/^\d+\.\d+\.\d+/.test(version)) {
    throw new Error(`Could not resolve ${pkg}@${TAG}; pnpm view said: ${JSON.stringify(raw)}`);
  }
  return version;
}

const lines = readFileSync(WORKSPACE, 'utf8').split('\n');

const catalogsAt = lines.indexOf('catalogs:');
if (catalogsAt < 0) throw new Error(`${WORKSPACE} has no \`catalogs:\` block`);
const cannonAt = lines.indexOf('  cannon:', catalogsAt);
if (cannonAt < 0) throw new Error(`${WORKSPACE} has no \`cannon:\` catalog`);

// Stay inside the `cannon:` catalog. Scoping matters: `overrides` names
// `"@usecannon/builder"` too, and rewriting THAT line would replace the
// `$@usecannon/builder` back-reference with a second literal — the exact
// duplication the single pin exists to prevent.
let end = cannonAt + 1;
while (end < lines.length && (lines[end].startsWith('    ') || lines[end].trim() === '')) end++;

const changed: string[] = [];
for (const [upstream, fork] of Object.entries(FORK)) {
  const spec = `npm:${fork}@${resolveVersion(fork)}`;
  const key = `    "${upstream}": `;
  const at = lines.findIndex((line, i) => i >= cannonAt && i < end && line.startsWith(key));
  if (at < 0) throw new Error(`No \`${upstream}\` entry in the \`cannon:\` catalog`);
  const before = lines[at].slice(key.length);
  lines[at] = key + spec;
  changed.push(`  ${upstream}: ${before === spec ? `${spec} (unchanged)` : `${before} → ${spec}`}`);
}

writeFileSync(WORKSPACE, lines.join('\n'));
console.log(`Cannon fork pin (dist-tag "${TAG}"):`);
for (const line of changed) console.log(line);

// `install` re-resolves the aliases the catalog now names; `dedupe` restores the
// lockfile's canonical peer-suffix keys, which an install alone can dislodge and
// `pnpm dedupe --check` (ci.yml, the lint job) then rejects.
execFileSync('pnpm', ['install'], { cwd: ROOT, stdio: 'inherit' });
execFileSync('pnpm', ['dedupe'], { cwd: ROOT, stdio: 'inherit' });

#!/usr/bin/env bun
import { existsSync } from 'node:fs';
import { mkdir } from 'node:fs/promises';
import path from 'node:path';

import { Glob } from 'bun';

import { type Mode, modeFor } from './suites';

const ROOT = path.resolve(import.meta.dir, '..', '..');

/**
 * The preload is read from source rather than from the built
 * `@synthetixio/core-utils/utils/bun/preload`: bun transpiles TypeScript on the
 * fly, so this keeps `moon run <pkg>:test` working on a tree that has not been
 * built yet, and keeps the path unambiguous.
 */
const PRELOAD = path.join(ROOT, 'utils/core-utils/src/utils/bun/preload.ts');

/** One process per file, or one for the whole package. */
export function unitsFor(files: string[], mode: Mode): string[][] {
  return mode === 'per-file' ? files.map((file) => [file]) : [files];
}

/** The JUnit file name for a unit; per-file units must not collide. */
export function slugFor(unit: string[], mode: Mode): string {
  if (mode === 'per-package') return 'all';
  return unit[0]
    .replace(/^test\//, '')
    .replace(/\.test\.[tj]s$/, '')
    .replaceAll('/', '-');
}

/**
 * Pids in `after` that were not in `before` — the ones a unit leaked. Pure so
 * the anvil-reaping logic below can be unit-tested without spawning anything.
 */
export function leakedPids(before: Set<string>, after: Set<string>): string[] {
  return [...after].filter((pid) => !before.has(pid));
}

/**
 * A snapshot of every anvil pid running right now, by exact process name.
 * `-x` (not `-f`) matches only processes whose name is literally `anvil` —
 * `-f` would also match this runner's own command line, which mentions
 * "anvil" nowhere but would be a foot-gun the moment it did.
 */
function anvilPids(): Set<string> {
  const { stdout } = Bun.spawnSync(['pgrep', '-x', 'anvil'], {
    stdout: 'pipe',
    stderr: 'ignore',
  });
  return new Set(
    stdout
      .toString()
      .split('\n')
      .map((line) => line.trim())
      .filter(Boolean)
  );
}

/**
 * `hardhat test` used to tear down the anvil instance(s) Cannon spawns for a
 * run; `bun test` does not, and in per-file mode that is one anvil leaked per
 * test file — 71 of them for `markets/perps-market` alone on a 2 CPU / 4 GB
 * runner. Reap only the pids that appeared during this unit: a developer's
 * own anvil (or anyone else's) is already in `before` and must never be
 * touched, so this is never a blanket `pkill anvil`.
 */
function reapLeaked(before: Set<string>, after: Set<string>): void {
  for (const pid of leakedPids(before, after)) {
    try {
      process.kill(Number(pid), 'SIGKILL');
    } catch {
      // Already gone by the time we got here — fine.
    }
  }
}

async function main() {
  const {
    TEST_TIMEOUT = '120000',
    TEST_ATTEMPTS = '2',
    TEST_WALL_CLOCK = '1200000',
    JUNIT_DIR = '/tmp/junit',
  } = process.env;

  const dir = path.resolve(process.argv[2] ?? process.cwd());
  const rel = path.relative(ROOT, dir);
  const mode = modeFor(rel);

  const files = [...new Glob('test/**/*.test.{ts,js}').scanSync({ cwd: dir })].sort();
  if (files.length === 0) {
    // Not an error here: several contracts-tagged packages carry no tests at
    // all. run-suites.sh keeps its own hard guard for the suites it lists,
    // where zero files means something moved rather than nothing to do.
    console.log(`${rel}: no test files, nothing to run`);
    return 0;
  }

  const preloads = [PRELOAD];
  if (existsSync(path.join(dir, 'hardhat.config.ts'))) preloads.push('hardhat/register');

  const junitDir = path.join(JUNIT_DIR, rel.replaceAll('/', '-'));
  await mkdir(junitDir, { recursive: true });

  const units = unitsFor(files, mode);
  let failed = 0;

  for (const unit of units) {
    const slug = slugFor(unit, mode);
    const args = [
      'test',
      ...preloads.flatMap((preload) => ['--preload', preload]),
      '--timeout',
      TEST_TIMEOUT,
      '--reporter=junit',
      `--reporter-outfile=${path.join(junitDir, `${slug}.xml`)}`,
      ...unit,
    ];

    let passed = false;
    for (let attempt = 1; attempt <= Number(TEST_ATTEMPTS) && !passed; attempt++) {
      console.log(`${rel} ${slug}: attempt ${attempt}/${TEST_ATTEMPTS}`);
      const before = anvilPids();
      const child = Bun.spawn(['bun', ...args], {
        cwd: dir,
        stdio: ['ignore', 'inherit', 'inherit'],
      });
      const killer = setTimeout(() => {
        console.error(
          `::error::${rel} ${slug} exceeded TEST_WALL_CLOCK (${TEST_WALL_CLOCK} ms); killing it`
        );
        child.kill('SIGKILL');
      }, Number(TEST_WALL_CLOCK));
      const code = await child.exited;
      clearTimeout(killer);
      reapLeaked(before, anvilPids());
      passed = code === 0;
    }

    if (!passed) failed++;
  }

  console.log(`${rel}: ${units.length - failed}/${units.length} units passed (${mode})`);
  return failed === 0 ? 0 : 1;
}

if (import.meta.main) process.exit(await main());

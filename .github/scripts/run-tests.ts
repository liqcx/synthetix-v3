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
 * Parses newline-delimited pid output (`pgrep`/`lsof -t`) into pid strings,
 * dropping blank lines and surrounding whitespace. Pure so the reaping logic
 * below can be unit-tested without spawning anything.
 */
export function parsePids(raw: string): string[] {
  return raw
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean);
}

/**
 * Reads a numeric env knob. `undefined` and `''` — the shape GitHub Actions
 * renders an unset `${{ inputs.x }}` as on a scheduled run, and
 * `nightly-contracts.yml` already passes some of those — mean "unset" and
 * return `fallback`. Anything else must be a finite positive integer, or
 * this throws loudly naming the variable and the bad value: silently
 * defaulting past a typo is exactly how `TEST_ATTEMPTS=''` used to turn "the
 * attempt loop never runs" into a passing fixture reporting `0/1 units
 * passed` with no line in the log distinguishing "never ran" from "ran and
 * failed".
 */
export function knob(name: string, raw: string | undefined, fallback: number): number {
  if (raw === undefined || raw === '') return fallback;
  const value = Number(raw);
  if (!Number.isInteger(value) || value <= 0) {
    throw new Error(`Invalid ${name}: ${JSON.stringify(raw)} (expected a positive integer)`);
  }
  return value;
}

/**
 * The anvil port a unit gets: a base plus the unit's index, so ports never
 * collide across units in the same run. Never 8545 — that is hardhat-cannon's
 * own default, so it is where a developer's own, unrelated anvil is likely to
 * already be listening, and that anvil is not this runner's to touch.
 *
 * The naive `base + index === 8545 ? +1 : as-is` shift re-collides: with
 * `base=8545`, both index 0 and index 1 land on 8546. Once the unshifted
 * port would be at or past 8545 (which only happens when `base` itself is at
 * or below 8545 — the default base 8600 never triggers this), every port
 * from there on shifts up by one, so the sequence stays strictly increasing
 * and 8545 is simply skipped rather than reused as a landing spot.
 */
export function portFor(base: number, index: number): number {
  const port = base + index;
  return base <= 8545 && port >= 8545 ? port + 1 : port;
}

/**
 * Pids currently bound to `port`, via `lsof -ti tcp:<port>`.
 */
function pidsOnPort(port: number): Set<string> {
  // `-sTCP:LISTEN` restricts this to sockets *bound to* `port`, not merely
  // mentioning it — without it, `-ti tcp:<port>` also matches a client
  // process whose *remote* end happens to be `<port>`, which is not this
  // unit's anvil and not this runner's to kill.
  const { stdout } = Bun.spawnSync(['lsof', '-ti', `tcp:${port}`, '-sTCP:LISTEN'], {
    stdout: 'pipe',
    stderr: 'ignore',
  });
  return new Set(parsePids(stdout.toString()));
}

/**
 * `hardhat test` used to tear down the anvil instance(s) Cannon spawns for a
 * run; `bun test` does not. Reap only what is bound to the port THIS unit was
 * assigned via `ANVIL_PORT` — ownership by construction, not by diffing every
 * `anvil` process on the machine. A scan-delta over process names cannot tell
 * "a unit's own leaked anvil" from "a bystander anvil that started somewhere
 * else during the same window" (moon runs project tasks in parallel by
 * default, so two runners can be alive at once); a port this runner itself
 * handed out has no such ambiguity — nothing else is supposed to be there.
 */
function reapPort(port: number): void {
  for (const pid of pidsOnPort(port)) {
    try {
      process.kill(Number(pid), 'SIGKILL');
    } catch {
      // Already gone by the time we got here — fine.
    }
  }
}

async function main() {
  const {
    TEST_TIMEOUT,
    TEST_ATTEMPTS,
    TEST_WALL_CLOCK,
    BASE_ANVIL_PORT,
    JUNIT_DIR = '/tmp/junit',
  } = process.env;

  const testTimeout = knob('TEST_TIMEOUT', TEST_TIMEOUT, 120_000);
  const testAttempts = knob('TEST_ATTEMPTS', TEST_ATTEMPTS, 2);
  const testWallClock = knob('TEST_WALL_CLOCK', TEST_WALL_CLOCK, 1_200_000);
  const baseAnvilPort = knob('BASE_ANVIL_PORT', BASE_ANVIL_PORT, 8600);

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

  for (const [index, unit] of units.entries()) {
    const slug = slugFor(unit, mode);
    const port = portFor(baseAnvilPort, index);
    const args = [
      'test',
      ...preloads.flatMap((preload) => ['--preload', preload]),
      '--timeout',
      String(testTimeout),
      '--reporter=junit',
      `--reporter-outfile=${path.join(junitDir, `${slug}.xml`)}`,
      ...unit,
    ];

    let passed = false;
    for (let attempt = 1; attempt <= testAttempts && !passed; attempt++) {
      console.log(`${rel} ${slug}: attempt ${attempt}/${testAttempts} (ANVIL_PORT=${port})`);
      const child = Bun.spawn(['bun', ...args], {
        cwd: dir,
        env: { ...process.env, ANVIL_PORT: String(port) },
        stdio: ['ignore', 'inherit', 'inherit'],
      });
      const killer = setTimeout(() => {
        console.error(
          `::error::${rel} ${slug} exceeded TEST_WALL_CLOCK (${testWallClock} ms); killing it`
        );
        child.kill('SIGKILL');
      }, testWallClock);
      const code = await child.exited;
      clearTimeout(killer);
      reapPort(port);
      passed = code === 0;
    }

    if (!passed) failed++;
  }

  console.log(`${rel}: ${units.length - failed}/${units.length} units passed (${mode})`);
  return failed === 0 ? 0 : 1;
}

if (import.meta.main) process.exit(await main());

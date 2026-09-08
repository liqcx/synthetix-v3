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

/** How many candidate ports `claimPort` will check before giving up. */
const MAX_PORT_CLAIM_TRIES = 20;

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
 * Parses newline-delimited pid output (`lsof -t`) into pid strings, dropping
 * blank lines and surrounding whitespace. Pure so the reaping logic below can
 * be unit-tested without spawning anything.
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
 * The string-valued sibling of `knob`: `undefined`/`''` mean unset and fold
 * to `fallback`, same as the numeric knobs — there is no format to validate
 * for a directory path, just the same "'' is not a real value" fold, so
 * `JUNIT_DIR=''` (the same GHA-unset shape the numeric knobs already guard
 * against) does not quietly turn into a cwd-relative `<pkg>` directory that
 * `run-suites.sh`-style callers never see and no JUnit XML ever lands in.
 */
export function stringKnob(raw: string | undefined, fallback: string): string {
  return raw === undefined || raw === '' ? fallback : raw;
}

/**
 * The anvil port a unit gets: a base plus an index, so a single runner's own
 * units don't collide with each other. Never 8545 — that is hardhat-cannon's
 * own default, so it is where a developer's own, unrelated anvil is likely to
 * already be listening, and that anvil is not this runner's to touch.
 *
 * The naive `base + index === 8545 ? +1 : as-is` shift re-collides: with
 * `base=8545`, both index 0 and index 1 land on 8546. Once the unshifted
 * port would be at or past 8545 (which only happens when `base` itself is at
 * or below 8545 — the default base 8600 never triggers this), every port
 * from there on shifts up by one, so the sequence stays strictly increasing
 * and 8545 is simply skipped rather than reused as a landing spot.
 *
 * This only produces *candidates* — it says nothing about whether a candidate
 * is actually free. `claimPort` below is what turns a candidate into an
 * owned port.
 */
export function portFor(base: number, index: number): number {
  const port = base + index;
  return base <= 8545 && port >= 8545 ? port + 1 : port;
}

/**
 * Pids with a socket bound (`-sTCP:LISTEN`, not merely mentioning the port on
 * either end) to `port`, via `lsof -ti tcp:<port>`.
 *
 * `lsof` exits non-zero both for "nothing matched" (the common, expected
 * case: empty stdout, empty stderr) and for a genuine failure — a bad
 * invocation, or insufficient privileges to read the socket table on this
 * image (empty stdout, but stderr says so). Those two are not the same
 * outcome: silently treating the second as "nothing is listening" is how a
 * reap can "succeed" at reaping nothing, and how a free-port check can wave a
 * port through that `lsof` never actually cleared. `stdout` being non-empty
 * is unambiguous either way; when it's empty, stderr is the only way to tell
 * them apart, so it is captured and inspected rather than discarded.
 */
function pidsOnPort(port: number): Set<string> {
  const { stdout, stderr, exitCode } = Bun.spawnSync(
    ['lsof', '-ti', `tcp:${port}`, '-sTCP:LISTEN'],
    { stdout: 'pipe', stderr: 'pipe' }
  );
  const err = stderr.toString().trim();
  if (exitCode !== 0 && err) {
    throw new Error(`lsof failed checking tcp:${port}: ${err}`);
  }
  return new Set(parsePids(stdout.toString()));
}

/**
 * Walks candidate ports starting at `portFor(base, startIndex)`, checking
 * each with `isFree`, and returns the first one `isFree` itself reports
 * empty. A port that is occupied — by a bystander, a developer's own anvil,
 * or anything else — is *never* returned, no matter how briefly it was
 * observed that way: ownership is established by seeing a port empty
 * immediately before claiming it, not by assuming a port is yours because you
 * intended to use it. Throws, naming every candidate tried, if none of the
 * first `maxTries` are free.
 *
 * `isFree` defaults to the real `pidsOnPort` check but is overridable so this
 * can be unit-tested without spawning a process (DP-017) — the real-process
 * proof lives in this task's acceptance evidence, not in the committed test
 * suite.
 */
export function claimPort(
  base: number,
  startIndex: number,
  maxTries: number,
  isFree: (port: number) => boolean = (port) => pidsOnPort(port).size === 0
): number {
  const tried: number[] = [];
  for (let i = 0; i < maxTries; i++) {
    const port = portFor(base, startIndex + i);
    tried.push(port);
    if (isFree(port)) return port;
  }
  throw new Error(`No free anvil port found after ${maxTries} tries: ${tried.join(', ')}`);
}

/**
 * `hardhat test` used to tear down the anvil instance(s) Cannon spawns for a
 * run; `bun test` does not. Reap only the port THIS unit `claimPort`ed and
 * handed to its child via `ANVIL_PORT` — a port observed free immediately
 * before this unit's own child was spawned into it is this unit's to reap;
 * a port anything else already held never becomes this unit's, no matter
 * what is on it by the time this runs. This is never called with a port that
 * was not first claimed this way — see `main`.
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
  const { TEST_TIMEOUT, TEST_ATTEMPTS, TEST_WALL_CLOCK, BASE_ANVIL_PORT, JUNIT_DIR } = process.env;

  const testTimeout = knob('TEST_TIMEOUT', TEST_TIMEOUT, 120_000);
  const testAttempts = knob('TEST_ATTEMPTS', TEST_ATTEMPTS, 2);
  const testWallClock = knob('TEST_WALL_CLOCK', TEST_WALL_CLOCK, 1_200_000);
  const baseAnvilPort = knob('BASE_ANVIL_PORT', BASE_ANVIL_PORT, 8600);
  const junitBase = stringKnob(JUNIT_DIR, '/tmp/junit');

  // `pidsOnPort`/`claimPort`/`reapPort` all shell out to `lsof`; fail once,
  // loudly, and before touching any unit, rather than letting the first
  // `Bun.spawnSync(['lsof', ...])` throw an ENOENT mid-run and abandon
  // whatever units had not started yet with an exit code indistinguishable
  // from "tests failed".
  if (!Bun.which('lsof')) {
    console.error('::error::lsof not found on PATH — required to claim and reap anvil ports');
    return 1;
  }

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

  const junitDir = path.join(junitBase, rel.replaceAll('/', '-'));
  await mkdir(junitDir, { recursive: true });

  const units = unitsFor(files, mode);
  let failed = 0;

  // A pid-derived offset so two runners started moments apart do not both
  // start their port search at the same candidate. This is a courtesy, not
  // the correctness guarantee: `claimPort`'s occupancy check is what
  // actually prevents two runners from ever sharing a port, this only makes
  // the common case (both landing on the very same first choice) less
  // likely to happen at all.
  const pidOffset = process.pid % 1000;

  for (const [index, unit] of units.entries()) {
    const slug = slugFor(unit, mode);
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
      const port = claimPort(baseAnvilPort, pidOffset + index, MAX_PORT_CLAIM_TRIES);
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

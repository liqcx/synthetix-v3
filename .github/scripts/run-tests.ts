#!/usr/bin/env bun
import { existsSync } from 'node:fs';
import { mkdir } from 'node:fs/promises';
import path from 'node:path';
import { type ChildProcess, spawn } from 'node:child_process';

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
 * Tries to bind `port` on `127.0.0.1`. `Bun.listen` throws synchronously
 * (`EADDRINUSE`) when the port is already taken; on success the listener is
 * closed immediately, releasing the port back for the child this runner is
 * about to spawn. This is the whole "is it free" check — no `lsof`, no
 * process table to read or misread.
 */
function canBind(port: number): boolean {
  try {
    const server = Bun.listen({ hostname: '127.0.0.1', port, socket: { data() {} } });
    server.stop();
    return true;
  } catch {
    return false;
  }
}

/**
 * Walks candidate ports starting at `portFor(base, startIndex)`, checking
 * each with `isFree`, and returns the first one `isFree` itself reports
 * free. A port that is occupied — by a bystander, a developer's own anvil,
 * or anything else — is *never* returned, no matter how briefly it was
 * observed that way: ownership is established by successfully binding a
 * port immediately before handing it to a child, not by assuming a port is
 * yours because you intended to use it. Throws, naming every candidate
 * tried, if none of the first `maxTries` are free.
 *
 * `isFree` defaults to the real `canBind` check but is overridable so this
 * can be unit-tested without spawning a process (DP-017) — the real-bind
 * proof lives in this task's acceptance evidence and in the one real-listener
 * test in `run-tests.test.ts`, not only in the injected-fake walk logic.
 *
 * This is check-then-act — the port could, in principle, be taken by
 * something else between this function returning and the caller's child
 * actually binding it. That window is accepted: the caller never reaps by
 * port (see `main`), so the worst case on this end is the *child's* own
 * anvil failing to bind, which `TEST_ATTEMPTS` already retries past — never
 * another process being killed for holding a port this runner merely
 * intended to use.
 */
export function claimPort(
  base: number,
  startIndex: number,
  maxTries: number,
  isFree: (port: number) => boolean = canBind
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
 * The child of the unit currently in flight, or `undefined` between units and
 * before the first one. The signal handlers `main` installs reach that child's
 * process group through this, so it is cleared on every exit from an attempt
 * — normal exit, spawn error, wall-clock kill — and a signal arriving between
 * units therefore never names a pid that has already been reused.
 */
let inFlight: ChildProcess | undefined;

/**
 * SIGKILL the whole process group `child` leads (the negative pid), which is
 * the child plus whatever it forked and did not tear down — `bun test` and
 * the anvil under it. Only ever called with a child this runner spawned
 * itself with `detached: true` a few lines earlier, so it can never name a
 * group this process merely inherited. Throwing means the group is already
 * gone, or nothing but the child was ever in it: both are the ordinary case.
 */
function reapGroup(child: ChildProcess | undefined): void {
  if (!child?.pid) return;
  try {
    process.kill(-child.pid, 'SIGKILL');
  } catch {
    // Group is already gone, or nothing else was ever in it — fine.
  }
}

async function main() {
  const { TEST_TIMEOUT, TEST_ATTEMPTS, TEST_WALL_CLOCK, BASE_ANVIL_PORT, JUNIT_DIR } = process.env;

  const testTimeout = knob('TEST_TIMEOUT', TEST_TIMEOUT, 120_000);
  const testAttempts = knob('TEST_ATTEMPTS', TEST_ATTEMPTS, 2);
  const testWallClock = knob('TEST_WALL_CLOCK', TEST_WALL_CLOCK, 1_200_000);
  const baseAnvilPort = knob('BASE_ANVIL_PORT', BASE_ANVIL_PORT, 8600);
  const junitBase = stringKnob(JUNIT_DIR, '/tmp/junit');

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
  // the correctness guarantee: `claimPort`'s bind check is what actually
  // prevents two runners from ever sharing a port, this only makes the
  // common case (both landing on the very same first choice) less likely to
  // happen at all.
  const pidOffset = process.pid % 1000;

  // `detached: true` below buys the reap but costs the interrupt: an
  // interrupted runner used to take `bun test` down with it, because they
  // shared a process group; now the child leads its own, and nothing signals
  // it unless this does. Without a handler the runner meets a signal one of
  // two ways, and both leak the child. It dies on the spot, the default
  // disposition — an interactive Ctrl-C goes to the foreground process group,
  // the runner goes with it, and the child in its own group never hears about
  // it. Or it ignores the signal outright, because a background job of a
  // non-interactive shell inherits SIGINT as SIG_IGN, which is why `kill -INT`
  // on a scripted run looks inert and sends the operator reaching for SIGTERM
  // — which kills the runner and reparents `bun test` and its anvil onto init,
  // still holding the claimed port, in a group nobody knows any more. Both
  // handlers therefore do the same group kill the normal path does and then
  // exit explicitly, by the shell's 128 + signal-number convention. A signal
  // arriving with no unit in flight still exits; it just has nothing to kill.
  for (const [signal, status] of [
    ['SIGINT', 130],
    ['SIGTERM', 143],
  ] as const) {
    process.on(signal, () => {
      console.error(`::error::${rel}: ${signal} received; killing the unit in flight`);
      reapGroup(inFlight);
      inFlight = undefined;
      process.exit(status);
    });
  }

  try {
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

        // `detached: true` makes this child the leader of its own process
        // group (POSIX `setsid`-alike), so whatever it forks — Cannon's
        // anvil, in particular — lands in that same group rather than this
        // runner's own. `hardhat test` used to tear that anvil down;
        // `bun test` does not, so once the child is gone this runner kills
        // the whole group instead of trying to work out which port the
        // orphan ended up on: a process-group kill needs no port reasoning,
        // and cannot mistake a bystander for its own leak the way reaping by
        // "whatever is bound to the port" or "whatever appeared since" both
        // could.
        const child = spawn('bun', args, {
          cwd: dir,
          env: { ...process.env, ANVIL_PORT: String(port) },
          detached: true,
          stdio: ['ignore', 'inherit', 'inherit'],
        });
        inFlight = child;

        const killer = setTimeout(() => {
          console.error(
            `::error::${rel} ${slug} exceeded TEST_WALL_CLOCK (${testWallClock} ms); killing it`
          );
          child.kill('SIGKILL');
        }, testWallClock);

        const code = await new Promise<number>((resolve) => {
          child.on('exit', (code) => resolve(code ?? 1));
          child.on('error', (err) => {
            console.error(`::error::${rel} ${slug} failed to start: ${err.message}`);
            resolve(1);
          });
        });
        clearTimeout(killer);

        reapGroup(child);
        inFlight = undefined;

        passed = code === 0;
      }

      if (!passed) failed++;
    }
  } catch (err) {
    console.error(`::error::${(err as Error).message}`);
    return 1;
  }

  console.log(`${rel}: ${units.length - failed}/${units.length} units passed (${mode})`);
  return failed === 0 ? 0 : 1;
}

if (import.meta.main) process.exit(await main());

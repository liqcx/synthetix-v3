import assert from 'assert/strict';
import { type ChildProcess, spawn } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';

import { modeFor } from './suites';
import { claimPort, knob, portFor, slugFor, stringKnob, unitsFor } from './run-tests';

describe('.github/scripts/run-tests.ts', function () {
  const files = [
    'test/integration/Account/CreateAccount.test.ts',
    'test/integration/Orders/BookOrder.test.ts',
  ];

  it('gives every file its own process in per-file mode', function () {
    assert.deepEqual(unitsFor(files, 'per-file'), [[files[0]], [files[1]]]);
  });

  it('runs a package as one unit in per-package mode', function () {
    assert.deepEqual(unitsFor(files, 'per-package'), [files]);
  });

  it('names a per-file unit after the file, so JUnit files do not collide', function () {
    assert.equal(slugFor([files[0]], 'per-file'), 'integration-Account-CreateAccount');
    assert.equal(slugFor([files[1]], 'per-file'), 'integration-Orders-BookOrder');
  });

  it('names the single per-package unit "all"', function () {
    assert.equal(slugFor(files, 'per-package'), 'all');
  });

  it('knows the mode of every nightly suite', function () {
    assert.equal(modeFor('markets/perps-market'), 'per-file');
    assert.equal(modeFor('utils/core-utils'), 'per-package');
  });

  it('defaults an unlisted package to the safe mode', function () {
    assert.equal(modeFor('markets/legacy-market'), 'per-file');
  });
});

describe('knob', function () {
  it('treats an empty string as unset and returns the fallback', function () {
    assert.equal(knob('TEST_ATTEMPTS', '', 2), 2);
  });

  it('rejects a non-numeric value loudly, naming the variable and the value', function () {
    assert.throws(() => knob('TEST_ATTEMPTS', 'abc', 2), /TEST_ATTEMPTS/);
    assert.throws(() => knob('TEST_ATTEMPTS', 'abc', 2), /"abc"/);
  });

  it('rejects zero: not a positive integer', function () {
    assert.throws(() => knob('TEST_ATTEMPTS', '0', 2), /TEST_ATTEMPTS/);
  });

  it('rejects a negative value', function () {
    assert.throws(() => knob('TEST_ATTEMPTS', '-1', 2), /TEST_ATTEMPTS/);
  });

  it('accepts a valid positive integer', function () {
    assert.equal(knob('TEST_ATTEMPTS', '2', 5), 2);
  });

  it('treats unset (undefined) as unset and returns the fallback', function () {
    assert.equal(knob('TEST_ATTEMPTS', undefined, 2), 2);
  });
});

describe('portFor', function () {
  it('assigns the default base its own index-0 port unshifted', function () {
    assert.equal(portFor(8600, 0), 8600);
  });

  it('never assigns 8545, even when the base is 8545', function () {
    assert.notEqual(portFor(8545, 0), 8545);
  });

  it('does not re-collide once the shift kicks in', function () {
    const a = portFor(8544, 1);
    const b = portFor(8544, 2);
    assert.notEqual(a, 8545);
    assert.notEqual(a, b);
  });
});

describe('stringKnob', function () {
  it('treats an empty string as unset and returns the fallback', function () {
    assert.equal(stringKnob('', '/tmp/junit'), '/tmp/junit');
  });

  it('treats unset (undefined) as unset and returns the fallback', function () {
    assert.equal(stringKnob(undefined, '/tmp/junit'), '/tmp/junit');
  });

  it('passes a real value through unchanged', function () {
    assert.equal(stringKnob('/tmp/junit-probe', '/tmp/junit'), '/tmp/junit-probe');
  });
});

describe('claimPort', function () {
  // Mirrors the property the old `leakedPids` suite pinned against the
  // scan-delta shape (round 1) — "something present before the unit is
  // never reaped" — against the current bind-probe shape: a port `isFree`
  // reports occupied is never the one `claimPort` hands back, and the
  // reaping this runner does (a process-group kill after the child exits)
  // never touches a port at all, so a port `claimPort` steps over can never
  // be reaped by construction, not only by `reapPort` no longer being
  // called with it.

  it('returns the first candidate when it is free', function () {
    assert.equal(
      claimPort(8600, 0, 5, () => true),
      8600
    );
  });

  it('skips an occupied candidate and returns the next free one', function () {
    const occupied = new Set([8600]);
    const port = claimPort(8600, 0, 5, (p) => !occupied.has(p));
    assert.equal(port, 8601);
  });

  it('never returns a port that stays occupied for the whole search — the mirror property: something already there is never claimed, and so never reaped', function () {
    const stranger = 8600; // e.g. a bystander anvil that was already there
    const port = claimPort(8600, 0, 5, (p) => p !== stranger);
    assert.notEqual(port, stranger);
  });

  it('throws, naming every port tried, when nothing is ever free', function () {
    assert.throws(() => claimPort(8600, 0, 3, () => false), /8600, 8601, 8602/);
  });

  it('skips a real listener and leaves it alive, using the real bind-probe check (no injected isFree)', function () {
    // Everything above tests the walk against a fake `isFree`; this is the
    // one test that exercises the real default — `canBind`'s actual
    // `Bun.listen` attempt — against a real bound socket, without needing a
    // real anvil. Only the property that matters is asserted: the occupied
    // port itself is never returned. Asserting the exact neighbour
    // (`server.port + 1`) would pin an OS-assigned ephemeral port happening
    // to be free, which is not a property this function promises.
    const server = Bun.listen({ hostname: '127.0.0.1', port: 0, socket: { data() {} } });
    try {
      const port = claimPort(server.port, 0, 3);
      assert.notEqual(port, server.port);

      // The "leaves it alive" half, which the name promised and only the
      // "skips" half used to assert: the stranger's socket is still bound
      // after `claimPort` stepped over it, so nothing on the claim path
      // closes what it declines to take. Matched on `code`, not on the
      // message — bun's EADDRINUSE error reads `Failed to listen at
      // 127.0.0.1` and never spells the code out in its text.
      assert.throws(
        () => {
          const rebind = Bun.listen({
            hostname: '127.0.0.1',
            port: server.port,
            socket: { data() {} },
          });
          rebind.stop();
        },
        (error: unknown) => (error as { code?: string }).code === 'EADDRINUSE'
      );
    } finally {
      server.stop();
    }
  });
});

const ROOT = path.resolve(import.meta.dir, '..', '..');
const RUNNER = path.join(import.meta.dir, 'run-tests.ts');

/**
 * A package whose one test spawns a grandchild and abandons it, standing in
 * for the anvil `bun test` orphans. See its own header for why it is not a
 * real anvil.
 */
const LEAK_FIXTURE = path.join(import.meta.dir, '__fixtures__', 'leaky-child');

/** Well clear of 8545, of the 8600 default, and of any ambient anvil. */
const FIXTURE_BASE_PORT = '21000';

interface Run {
  runner: ChildProcess;
  pidFile: string;
  /** Everything the runner and its child wrote, for assertion messages. */
  log: () => string;
}

function startRunner(env: Record<string, string> = {}): Run {
  const work = mkdtempSync(path.join(tmpdir(), 'run-tests-leak-'));
  const pidFile = path.join(work, 'pids');
  const runner = spawn('bun', [RUNNER, LEAK_FIXTURE], {
    cwd: ROOT,
    env: {
      ...process.env,
      LEAK_PID_FILE: pidFile,
      JUNIT_DIR: path.join(work, 'junit'),
      BASE_ANVIL_PORT: FIXTURE_BASE_PORT,
      TEST_ATTEMPTS: '1',
      TEST_TIMEOUT: '30000',
      ...env,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  // Drained rather than inherited: an undrained pipe would eventually block
  // the runner, and a hang there would be blamed on the mechanism under test.
  const chunks: string[] = [];
  runner.stdout?.on('data', (chunk) => chunks.push(String(chunk)));
  runner.stderr?.on('data', (chunk) => chunks.push(String(chunk)));
  return { runner, pidFile, log: () => chunks.join('') };
}

function exitOf(child: ChildProcess): Promise<number | null> {
  return new Promise((resolve) => {
    child.on('exit', (code) => resolve(code));
    child.on('error', () => resolve(null));
  });
}

function alive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

/**
 * Polls an OS fact — a process-table entry, a file appearing — until it holds
 * or the deadline passes. Bounded and cheap, but genuinely wall-clock: there
 * is no fake-timer equivalent for "the kernel has reaped that pid", so this is
 * the one place in this file that waits on real time.
 */
async function until(condition: () => boolean, deadlineMs: number): Promise<boolean> {
  const stopAt = Date.now() + deadlineMs;
  while (!condition() && Date.now() < stopAt) {
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  return condition();
}

/** `<bun test child pid> <abandoned grandchild pid>`, as the fixture wrote it. */
function readPids(pidFile: string): { child: number; grandchild: number } {
  const [child, grandchild] = readFileSync(pidFile, 'utf8').trim().split(/\s+/).map(Number);
  return { child, grandchild };
}

/** Never leave the fixture's processes behind, whatever the assertions did. */
function cleanUp(...pids: number[]): void {
  for (const pid of pids) {
    if (!Number.isInteger(pid) || pid <= 0) continue;
    try {
      process.kill(pid, 'SIGKILL');
    } catch {
      // Already gone — which is what the assertions wanted anyway.
    }
  }
}

describe('the runner reaps what bun test abandons', function () {
  // The two mechanisms that make this runner safe — `detached: true` on the
  // spawn, and the `process.kill(-child.pid, 'SIGKILL')` after it — are both
  // invisible to every other test in this file: delete either one and the
  // suite above stays fully green while a leaked anvil survives every run.
  // These tests run the real runner against a fixture that reproduces the
  // topology and look at the process table afterwards, which is the only
  // place the difference shows.

  it('group-kills the grandchild the fixture abandoned', async function () {
    const run = startRunner();
    const code = await exitOf(run.runner);
    assert.equal(code, 0, `the runner exited ${code}\n${run.log()}`);

    const { child, grandchild } = readPids(run.pidFile);
    try {
      assert.equal(
        await until(() => !alive(grandchild), 5_000),
        true,
        `the abandoned grandchild ${grandchild} is still alive after the run\n${run.log()}`
      );
      assert.equal(alive(child), false, `the bun test child ${child} is still alive`);
    } finally {
      cleanUp(grandchild, child);
    }
  }, 120_000);

  for (const [signal, status] of [
    ['SIGINT', 130],
    ['SIGTERM', 143],
  ] as const) {
    it(`group-kills the unit in flight on ${signal}, and exits ${status}`, async function () {
      const run = startRunner({ LEAK_HOLD: '1' });
      const exited = exitOf(run.runner);

      // The pid file appearing is the event that says a unit is genuinely
      // in flight — no timer guesses at when the child got far enough.
      assert.equal(
        await until(() => existsSync(run.pidFile), 60_000),
        true,
        `the fixture never reported its pids\n${run.log()}`
      );
      const { child, grandchild } = readPids(run.pidFile);

      try {
        run.runner.kill(signal);
        assert.equal(
          await exited,
          status,
          `the runner did not exit ${status} on ${signal}\n${run.log()}`
        );
        assert.equal(
          await until(() => !alive(child), 5_000),
          true,
          `the bun test child ${child} survived ${signal}\n${run.log()}`
        );
        assert.equal(
          await until(() => !alive(grandchild), 5_000),
          true,
          `the abandoned grandchild ${grandchild} survived ${signal}\n${run.log()}`
        );
      } finally {
        cleanUp(grandchild, child);
        if (run.runner.pid && alive(run.runner.pid)) run.runner.kill('SIGKILL');
      }
    }, 120_000);
  }
});

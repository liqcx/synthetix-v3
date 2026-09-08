import assert from 'assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { renameSync, writeFileSync } from 'node:fs';

/**
 * Stands in for the anvil `hardhat-cannon` starts inside a `bun test` process
 * and never tears down. The grandchild spawned here inherits this process's
 * group — which, because `run-tests.ts` spawns with `detached: true`, is a
 * group of the runner's own making — and survives this process, so the
 * runner's `process.kill(-child.pid, 'SIGKILL')` after the child exits is the
 * only thing that can reap it. Remove either half and the grandchild leaks.
 *
 * Deliberately not a real anvil and not a real port: the topology is what the
 * runner's two safety mechanisms are about, and a spare anvil here would be
 * indistinguishable from a developer's own in `pgrep -x anvil`.
 *
 * `LEAK_PID_FILE` receives `<this process's pid> <grandchild's pid>`, written
 * through a rename so a reader never sees half a line. With `LEAK_HOLD=1`
 * this process then blocks until the grandchild dies, which is what lets a
 * caller send a signal knowing a unit is genuinely in flight.
 */
describe('a bun test process that abandons a child', function () {
  it('leaves a grandchild running after the run', async function () {
    const grandchild = spawn('sleep', ['300'], { stdio: 'ignore' });
    grandchild.unref();
    assert.ok(grandchild.pid, 'the grandchild must have a pid');
    assert.doesNotThrow(
      () => process.kill(grandchild.pid as number, 0),
      'the grandchild must be running before its pid is published'
    );

    const pidFile = process.env.LEAK_PID_FILE;
    assert.ok(pidFile, 'LEAK_PID_FILE must be set by the caller');
    writeFileSync(`${pidFile}.tmp`, `${process.pid} ${grandchild.pid}\n`);
    renameSync(`${pidFile}.tmp`, pidFile);

    if (process.env.LEAK_HOLD === '1') await once(grandchild, 'exit');
  });
});

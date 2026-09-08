import assert from 'assert/strict';

import { modeFor } from './suites';
import { leakedPids, slugFor, unitsFor } from './run-tests';

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

describe('leakedPids', function () {
  // `hardhat test` used to tear down the anvil instance(s) Cannon spawns;
  // `bun test` does not, so the runner snapshots `pgrep -x anvil` before and
  // after each unit and reaps only what leakedPids reports here.

  it('reports nothing when nothing leaked', function () {
    const before = new Set(['1', '2']);
    const after = new Set(['1', '2']);
    assert.deepEqual(leakedPids(before, after), []);
  });

  it('reports a pid that appeared after the unit ran', function () {
    const before = new Set(['1', '2']);
    const after = new Set(['1', '2', '3']);
    assert.deepEqual(leakedPids(before, after), ['3']);
  });

  it('does not report a pid present both before and after', function () {
    // A developer's own anvil (or anyone else's), already running before the
    // unit started, stays running after it too: it must never be reported as
    // leaked, because the runner reaps exactly what leakedPids returns. '10'
    // exits during the unit (present before, gone after) and is also not a
    // leak; only '30', which is new, is reported.
    const before = new Set(['10', '20']);
    const after = new Set(['20', '30']);
    assert.deepEqual(leakedPids(before, after), ['30']);
  });
});

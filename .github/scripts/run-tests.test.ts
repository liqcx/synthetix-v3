import assert from 'assert/strict';

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
    } finally {
      server.stop();
    }
  });
});

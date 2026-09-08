import assert from 'assert/strict';

import { modeFor } from './suites';
import { knob, parsePids, portFor, slugFor, unitsFor } from './run-tests';

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

describe('parsePids', function () {
  it('splits a normal multi-line pid list', function () {
    assert.deepEqual(parsePids('111\n222\n333'), ['111', '222', '333']);
  });

  it('returns nothing for an empty string', function () {
    assert.deepEqual(parsePids(''), []);
  });

  it('drops blank lines and surrounding whitespace', function () {
    assert.deepEqual(parsePids('  111  \n\n222\n   \n333\n'), ['111', '222', '333']);
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

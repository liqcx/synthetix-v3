import assert from 'assert/strict';

import { mochaContext, withLabel } from '../../../src/utils/bun/preload';

describe('utils/bun/preload.ts', function () {
  const order: string[] = [];

  before('a labelled hook runs', function () {
    // mocha's `this` has to exist and swallow the call; bun has no equivalent.
    this.timeout(1);
    order.push('before');
  });

  it('installs the mocha vocabulary as globals', function () {
    const globals = globalThis as unknown as Record<string, unknown>;
    for (const name of [
      'describe',
      'context',
      'it',
      'specify',
      'before',
      'after',
      'beforeEach',
      'afterEach',
    ]) {
      assert.equal(typeof globals[name], 'function', `${name} is not installed`);
    }
  });

  it('keeps the mocha modifiers', function () {
    const globals = globalThis as unknown as Record<string, Record<string, unknown>>;
    assert.equal(typeof globals.describe.skip, 'function');
    assert.equal(typeof globals.it.skip, 'function');
    assert.equal(typeof globals.it.only, 'function');
  });

  it('ran the labelled before hook exactly once, ahead of the tests', function () {
    assert.equal(order[0], 'before');
    assert.equal(order.filter((step) => step === 'before').length, 1);
  });

  it('hands bodies a chainable mocha this', function () {
    assert.equal(mochaContext.timeout(5), mochaContext);
    assert.equal(mochaContext.retries(2), mochaContext);
    assert.equal(mochaContext.slow(1), mochaContext);
  });

  it('puts the hook label on a failure', async function () {
    const failing = withLabel('create the account', () => {
      throw new Error('boom');
    });
    await assert.rejects(failing, { message: '[create the account] boom' });
  });

  it('leaves an unlabelled failure alone', async function () {
    const failing = withLabel('', () => {
      throw new Error('boom');
    });
    await assert.rejects(failing, { message: 'boom' });
  });
});

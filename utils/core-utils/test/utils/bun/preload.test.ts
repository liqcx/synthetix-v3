import assert from 'assert/strict';

import { mochaContext, withLabel } from '../../../src/utils/bun/preload';

describe('utils/bun/preload.ts', function () {
  const order: string[] = [];
  let skippedTestRan = false;

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
    assert.equal(typeof globals.describe.todo, 'function');
    assert.equal(typeof globals.it.skip, 'function');
    assert.equal(typeof globals.it.only, 'function');
    assert.equal(typeof globals.it.todo, 'function');
  });

  it.skip('this skipped test should not run', function () {
    skippedTestRan = true;
  });

  it('verifies that skipped tests are not executed', function () {
    assert.equal(skippedTestRan, false, 'skipped test should not have run');
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

  // Bun's transpiler injects a lexical binding for every one of its OWN test
  // globals a file actually references. Of the eight names this shim assigns,
  // `bun:test` itself auto-globals exactly `describe`, `it`, `beforeEach` and
  // `afterEach` (it also auto-globals `test`, `expect` and others this shim
  // never touches), so a file calling any of those four gets bun's own
  // version, shadowing what this module assigned onto `globalThis`.
  // `before`/`after` are not bun globals at all — bun's own hooks are named
  // `beforeAll`/`afterAll` — so the bare identifier here still resolves to
  // the shim. Pinned so a bun release that changes which globals it injects
  // breaks loudly instead of silently: a shadowed `beforeEach`/`afterEach`
  // still runs (bun's runtime accepts a leading label, undocumented in its
  // own types — see the test below) but loses the shim's `[label]` error
  // prefix and `HOOK_TIMEOUT` budget; a `before`/`after` that started being
  // shadowed would lose the chainable `this` too, the way the three deleted
  // `describe`-body call sites did.
  it('bun shadows describe, it, beforeEach and afterEach: the shim reaches them only via globalThis', function () {
    const globals = globalThis as unknown as Record<string, unknown>;
    assert.notEqual(describe, globals.describe);
    assert.notEqual(it, globals.it);
    assert.notEqual(beforeEach, globals.beforeEach);
    assert.notEqual(afterEach, globals.afterEach);
  });

  it('bun does not shadow before or after: the bare identifier is the shim', function () {
    const globals = globalThis as unknown as Record<string, unknown>;
    assert.equal(before, globals.before);
    assert.equal(after, globals.after);
  });

  // `beforeEach` is shadowed by bun's own version in this file (see above),
  // so this call reaches bun's native `beforeEach`, not the shim's `asHook`
  // (no `[label]` prefix on a failure, no `HOOK_TIMEOUT` budget). It still
  // runs correctly ahead of every test below — bun's runtime accepts the
  // leading label and simply ignores it for ordering purposes — which is the
  // behaviour the fork's labelled `beforeEach(...)` call sites depend on even
  // though the shim never sees them.
  describe('a labelled beforeEach runs ahead of each test', function () {
    const beforeEachRuns: number[] = [];

    beforeEach('increments the shared counter', function () {
      beforeEachRuns.push(beforeEachRuns.length + 1);
    });

    it('has run once ahead of the first test', function () {
      assert.deepEqual(beforeEachRuns, [1]);
    });

    it('has run again ahead of the second test', function () {
      assert.deepEqual(beforeEachRuns, [1, 2]);
    });
  });
});

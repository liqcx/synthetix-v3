/// <reference types="bun-types" />

import {
  afterAll,
  afterEach,
  beforeAll,
  beforeEach,
  describe as bunDescribe,
  it as bunIt,
} from 'bun:test';

/**
 * `bun test` ships no globals and no mocha vocabulary: hooks are named
 * `beforeAll`/`afterAll`, they take no label, and there is no mocha `this`.
 * Loaded through `bun test --preload`, this module puts that surface back, so
 * the test files this fork shares with upstream stay byte-identical and
 * cherry-picks stay cheap.
 *
 * Four of the eight assigned globals are unreachable from a test file: bun's
 * transpiler injects a lexical binding for every one of its own test globals
 * a file actually references, so a file that calls `describe`/`it`/
 * `beforeEach`/`afterEach` gets bun's own version, shadowing what this module
 * assigned onto `globalThis` — of the eight names this module assigns,
 * `bun:test` itself auto-globals exactly these four (it also auto-globals
 * `test`, `expect` and others this module never touches). `before`/`after`
 * are NOT shadowed: bun's own hooks are named `beforeAll`/`afterAll`, so
 * there is no bun global by those names to inject, and the bare identifier
 * still resolves to this module's shim; `context`/`specify` reach the shim
 * for the same reason (bun defines neither). This is also why `this.timeout(n)`
 * no-ops correctly inside a `before`/`after` hook but throws (`this` is
 * `undefined`) inside a `describe`/`it` body. A shadowed `beforeEach`/
 * `afterEach` still runs correctly — bun's runtime accepts a leading label
 * string undocumented in its own types — but bypasses `asHook` below
 * entirely: a thrown error there loses the `[label]` prefix `before`/`after`
 * get, and the hook runs under bun's own default timeout rather than
 * `HOOK_TIMEOUT`.
 */

/**
 * `before`/`after` hooks get one budget; per-test time comes from the
 * runner's --timeout. A shadowed `beforeEach`/`afterEach` (see the docblock
 * above) never reaches this — it runs under bun's own hook default instead.
 */
const HOOK_TIMEOUT =
  process.env.BUN_HOOK_TIMEOUT !== undefined && process.env.BUN_HOOK_TIMEOUT !== ''
    ? Number(process.env.BUN_HOOK_TIMEOUT)
    : 600_000;

export interface MochaContext {
  timeout(ms?: number): MochaContext;
  retries(count?: number): MochaContext;
  slow(ms?: number): MochaContext;
  skip(): MochaContext;
}

/**
 * mocha's `this` inside a hook or a `describe` body. Every method is a no-op:
 * bun accepts a timeout only as a registration-time argument, before the value
 * `this.timeout(n)` would supply is known. A hook that hangs is caught by the
 * runner's wall clock instead.
 */
export const mochaContext: MochaContext = {
  timeout: () => mochaContext,
  retries: () => mochaContext,
  slow: () => mochaContext,
  skip: () => mochaContext,
};

type Body = (this: MochaContext) => unknown;

/**
 * bun attributes a failing hook to an `(unnamed)` testcase, so the mocha label
 * is the only thing left saying which hook broke. Keep it on the error.
 */
export function withLabel(label: string, body: Body) {
  return async function () {
    try {
      return await body.call(mochaContext);
    } catch (error) {
      if (label && error instanceof Error) {
        error.message = `[${label}] ${error.message}`;
      }
      throw error;
    }
  };
}

type Hook = (fn: () => unknown, timeout?: number) => void;

/** `before(fn)` and `before('label', fn)` both reach bun's `beforeAll(fn)`. */
function asHook(register: Hook) {
  return (first: string | Body, second?: Body) => {
    const label = typeof first === 'string' ? first : '';
    const body = (typeof first === 'function' ? first : second) as Body;
    register(withLabel(label, body), HOOK_TIMEOUT);
  };
}

type Suite = (name: string, body?: Body, timeout?: number) => unknown;

/** Bind mocha's `this` into a describe/it body, keeping .skip/.only/.todo. */
function asSuite(target: Suite): Suite {
  const bind = (registrar: Suite): Suite =>
    function (name: string, body?: Body, timeout?: number) {
      // `it.todo('name')` has no body; pass it through untouched.
      if (!body) return registrar(name);
      return registrar(
        name,
        function () {
          return body.call(mochaContext);
        },
        timeout
      );
    };

  const bound = bind(target) as Suite & Record<string, Suite>;
  const modifiers = target as unknown as Record<string, Suite | undefined>;
  for (const key of ['skip', 'only', 'todo']) {
    const modifier = modifiers[key];
    if (modifier) bound[key] = bind(modifier);
  }
  return bound;
}

const globals = globalThis as unknown as Record<string, unknown>;

globals.describe = asSuite(bunDescribe as unknown as Suite);
globals.context = globals.describe;
globals.it = asSuite(bunIt as unknown as Suite);
globals.specify = globals.it;
globals.before = asHook(beforeAll as Hook);
globals.after = asHook(afterAll as Hook);
globals.beforeEach = asHook(beforeEach as Hook);
globals.afterEach = asHook(afterEach as Hook);

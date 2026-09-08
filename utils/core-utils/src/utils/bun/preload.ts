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
 */

/** Hooks get one budget; per-test time comes from the runner's --timeout. */
const HOOK_TIMEOUT = Number(process.env.BUN_HOOK_TIMEOUT) || 600_000;

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

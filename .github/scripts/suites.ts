/**
 * The one place that says which package runs in which mode. `run-suites.sh`
 * reads it with `--list`; `run-tests.ts` and moon's `test` task call
 * `modeFor()`. A second copy of this list is how the nightly and moon drifted
 * apart in the first place.
 */

export type Mode = 'per-file' | 'per-package';

/**
 * `per-file` is for packages whose tests go through `coreBootstrap`;
 * `per-package` is for the two packages with no bootstrap.
 *
 * The per-file assignment's original justification is gone. It came from a
 * design-phase probe run against a throwaway shim, before the preload in
 * `utils/core-utils/src/utils/bun/preload.ts` and the `ses` patch existed:
 * one process per package supposedly lost most of a package's tests, because
 * `snapshotCheckpoint`'s hook fired before the bootstrap had assigned a
 * provider. Task 9 re-measured both modes with the shipped preload and the
 * patch in place (`9bae6dca`) and that is not what happens: on four of the
 * five `per-file` packages per-package collects and runs the *identical* test
 * set — reconciled unit by unit, on the total and on the pass/fail/skip split
 * — 6-20x faster (`protocol/synthetix` 681 s to 33 s per attempt,
 * `oracle-manager` 50 s to 7 s, `spot-market` 131 s to 21 s, `core-modules`
 * 58 s to 9 s).
 *
 * The fifth, `markets/perps-market`, does **not** complete under per-package:
 * wall-clock grows for tens of minutes with the `bun test` child barely
 * touching CPU until `TEST_WALL_CLOCK` kills it, twice. Nobody knows why yet.
 *
 * So the table below is left exactly as it was, deliberately: per-file is not
 * droppable for `perps-market` until that is root-caused, and for the other
 * four what it still buys is retry granularity (`TEST_ATTEMPTS` retries a
 * unit, so one flake costs a single file here and a whole package there) —
 * worth 2.5-11 s a flake against 43-648 s of premium paid on every green run.
 * Changing any mode is a separate decision, and it wants a baseline from the
 * contended CI runners rather than from one developer's laptop, which is what
 * every number above is.
 */
export const SUITES: { dir: string; mode: Mode }[] = [
  { dir: 'protocol/synthetix', mode: 'per-file' },
  { dir: 'protocol/oracle-manager', mode: 'per-file' },
  { dir: 'markets/spot-market', mode: 'per-file' },
  { dir: 'markets/perps-market', mode: 'per-file' },
  { dir: 'utils/core-modules', mode: 'per-file' },
  { dir: 'utils/core-contracts', mode: 'per-package' },
  { dir: 'utils/core-utils', mode: 'per-package' },
];

/** A package that is not listed gets the safe mode. */
export function modeFor(dir: string): Mode {
  return SUITES.find((suite) => suite.dir === dir)?.mode ?? 'per-file';
}

if (import.meta.main && process.argv.includes('--list')) {
  for (const { dir, mode } of SUITES) console.log(`${dir}:${mode}`);
}

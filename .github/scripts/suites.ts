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
 * The per-file assignment is provisional. Its original justification — bun
 * loading every file of a run into one process, so `snapshotCheckpoint`'s hook
 * fires before the bootstrap has assigned a provider — came from a design-phase
 * probe run against a throwaway shim, before the preload in
 * `utils/core-utils/src/utils/bun/preload.ts` and the `ses` patch existed. With
 * both in place per-package passes cleanly on `utils/core-modules`. What
 * per-file still buys is retry granularity: `TEST_ATTEMPTS` retries a unit, so
 * one flake costs a single file here and a whole package there. Task 9 of the
 * migration plan re-measures both modes; do not read this table as measured
 * until it has.
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

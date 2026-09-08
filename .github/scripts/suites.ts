/**
 * The one place that says which package runs in which mode. `run-suites.sh`
 * reads it with `--list`; `run-tests.ts` and moon's `test` task call
 * `modeFor()`. A second copy of this list is how the nightly and moon drifted
 * apart in the first place.
 */

export type Mode = 'per-file' | 'per-package';

/**
 * `per-file` is for packages whose tests go through `coreBootstrap`. bun loads
 * every file of a run into one process, and `snapshotCheckpoint`'s hook then
 * fires before the bootstrap has assigned a provider — nine core-modules files
 * in one process collected 13 tests and failed 8. `per-package` is for the two
 * packages with no bootstrap.
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

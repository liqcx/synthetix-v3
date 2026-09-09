#!/usr/bin/env bash
# Runs the hardhat integration suites one package at a time, in whichever
# mode (per-file or per-package) .github/scripts/suites.ts assigns it: one
# process per test file for packages whose tests go through coreBootstrap
# (bun loading many files into one process breaks snapshotCheckpoint's
# provider hookup), one process for the whole package otherwise. suites.ts is
# also what moon's own test task reads, so the nightly and moon cannot drift
# apart the way run-suites.sh and the old test-batch.js once did.
#
# A failing suite does not stop the ones after it — every suite's status is
# collected and reported, and the script exits non-zero at the end. Failing
# fast would hide the state of every other package until the next nightly run.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER="$ROOT/.github/scripts/run-tests.ts"

# The mode table lives in .github/scripts/suites.ts, which run-tests.ts and
# moon's test task also read. A second copy here is how the nightly and moon
# drifted apart before.
SUITES=()
while IFS= read -r line; do
  SUITES+=("$line")
done < <(bun "$ROOT/.github/scripts/suites.ts" --list)

FILTER="${SUITE_FILTER:-}"
OVERRIDE="${TEST_MODE_OVERRIDE:-}"

# run-tests.ts's own TEST_MODE_OVERRIDE check falls back to modeFor(rel) for
# anything that isn't exactly "per-file" or "per-package" — silently, with no
# error, under a group header that would still claim the bogus value. Reject
# it here instead, the same way SUITE_FILTER is rejected below.
if [ -n "$OVERRIDE" ] && [ "$OVERRIDE" != "per-file" ] && [ "$OVERRIDE" != "per-package" ]; then
  echo "::error::TEST_MODE_OVERRIDE '$OVERRIDE' is not a valid mode. Valid values: per-file per-package"
  exit 1
fi

# A SUITE_FILTER that matches nothing in SUITES would otherwise make every
# suite below skip, leaving `failures` at 0 and the job exiting green having
# run nothing at all. Validate against the known suite names up front and
# fail loudly, before doing any real work (installs already happened in the
# calling workflow, but no test has run and no JUnit dir has been touched).
valid_dirs=()
for suite in "${SUITES[@]}"; do
  valid_dirs+=("${suite%%:*}")
done
if [ -n "$FILTER" ]; then
  filter_ok=false
  for dir in "${valid_dirs[@]}"; do
    if [ "$FILTER" == "$dir" ]; then
      filter_ok=true
      break
    fi
  done
  if [ "$filter_ok" != true ]; then
    echo "::error::SUITE_FILTER '$FILTER' does not match any known suite. Valid values: ${valid_dirs[*]}"
    exit 1
  fi
fi

export PATH="$PATH:$ROOT/node_modules/.bin"
export CANNON_REGISTRY_PRIORITY=local
export REPORT_GAS=true
export TS_NODE_TRANSPILE_ONLY=true
export TS_NODE_TYPE_CHECK=false
export TEST_TIMEOUT="${TEST_TIMEOUT:-120000}"
export TEST_ATTEMPTS="${TEST_ATTEMPTS:-2}"
export TEST_WALL_CLOCK="${TEST_WALL_CLOCK:-1200000}"

# The self-hosted runner's filesystem persists between runs (unlike CircleCI,
# where each suite got a fresh container), so /tmp/junit can hold batches
# left over from a previous night. Start every run from a clean, empty tree —
# the upload step at the end of the workflow always points at this whole dir.
rm -rf /tmp/junit
mkdir -p /tmp/junit

failures=0
results=()

for suite in "${SUITES[@]}"; do
  dir="${suite%%:*}"
  mode="${suite##*:}"

  if [ -n "$FILTER" ] && [ "$FILTER" != "$dir" ]; then
    continue
  fi
  if [ -n "$OVERRIDE" ]; then
    mode="$OVERRIDE"
  fi

  files="$(cd "$ROOT/$dir" && find test \( -name '*.test.ts' -o -name '*.test.js' \) 2>/dev/null | sort | tr '\n' ' ')"
  if [ -z "$files" ]; then
    # Every entry in SUITES is here because it has tests; zero files means
    # something moved (renamed/deleted test dir), not that there is nothing
    # to do. Treat it as a failure so it can't pass silently as green.
    echo "::error::$dir has no test files (expected some — a package only appears in SUITES because it has tests)"
    results+=("failed|$dir|0")
    failures=$((failures + 1))
    continue
  fi

  count="$(echo "$files" | wc -w | tr -d ' ')"
  echo "::group::$dir ($count files, $mode)"
  started="$(date +%s)"
  # Each suite gets its own JUnit subdirectory so suites don't overwrite each
  # other's XML files; run-tests.ts names each unit's file after the test
  # file (per-file mode) or "all" (per-package mode).
  junit_dir="/tmp/junit/${dir//\//-}"
  mkdir -p "$junit_dir"
  if TEST_MODE_OVERRIDE="$mode" JUNIT_DIR="$junit_dir" bun "$RUNNER" "$ROOT/$dir"; then
    status=passed
  else
    status=failed
    failures=$((failures + 1))
  fi
  elapsed=$(( $(date +%s) - started ))
  echo "::endgroup::"
  echo "$dir: $status (${elapsed}s)"
  results+=("$status|$dir|$elapsed")
done

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "| Suite | Result | Duration |"
    echo "| --- | --- | --- |"
    for result in "${results[@]}"; do
      IFS='|' read -r status dir elapsed <<< "$result"
      case "$status" in
        passed) icon="✅" ;;
        failed) icon="❌" ;;
        *) icon="⏭️" ;;
      esac
      echo "| \`$dir\` | $icon $status | ${elapsed}s |"
    done
  } >> "$GITHUB_STEP_SUMMARY"
fi

if [ "$failures" -gt 0 ]; then
  echo "::error::$failures suite(s) failed"
  exit 1
fi

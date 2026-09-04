#!/usr/bin/env bash
# Runs the hardhat integration suites one package at a time, batching the test
# files within each package.
#
# Batching is not an optimisation: docs/TESTING.md records that Anvil degrades
# after ~30 test files in one process, which is why test-batch.js exists. The
# per-suite batch sizes are the ones CircleCI had tuned.
#
# A failing suite does not stop the ones after it — every suite's status is
# collected and reported, and the script exits non-zero at the end. Failing
# fast would hide the state of every other package until the next nightly run.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER="$ROOT/.github/scripts/test-batch.js"

SUITES=(
  "protocol/synthetix:8"
  "protocol/oracle-manager:5"
  "markets/spot-market:3"
  "markets/perps-market:1"
  "utils/core-modules:5"
  "utils/core-contracts:5"
  "utils/core-utils:5"
)

FILTER="${SUITE_FILTER:-}"
OVERRIDE="${BATCH_SIZE_OVERRIDE:-}"

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
export MOCHA_RETRIES="${MOCHA_RETRIES:-2}"
export BATCH_RETRIES="${BATCH_RETRIES:-5}"

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
  batch="${suite##*:}"

  if [ -n "$FILTER" ] && [ "$FILTER" != "$dir" ]; then
    continue
  fi
  if [ -n "$OVERRIDE" ]; then
    batch="$OVERRIDE"
  fi

  files="$(cd "$ROOT/$dir" && find test -name '*.test.ts' 2>/dev/null | sort | tr '\n' ' ')"
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
  echo "::group::$dir ($count files, batch size $batch)"
  started="$(date +%s)"
  # Each suite gets its own JUnit subdirectory so suites don't overwrite each
  # other's batch-N.xml files (test-batch.js numbers batches from 1 every run).
  junit_dir="/tmp/junit/${dir//\//-}"
  mkdir -p "$junit_dir"
  if (cd "$ROOT/$dir" && TEST_FILES="$files" BATCH_SIZE="$batch" JUNIT_DIR="$junit_dir" bun "$RUNNER"); then
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

#!/usr/bin/env bash

# Run each test directory in its own hardhat process with anvil restart between them

failed=()
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
count=0

run_test() {
  local label="$1"
  shift
  echo ""
  echo "=== Testing $label ==="

  # Pipe: tee saves raw output to log, console gets color via FORCE_COLOR
  FORCE_COLOR=1 CANNON_REGISTRY_PRIORITY=local npx hardhat test "$@" 2>&1 \
    | tee >(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' > "$tmpdir/$count.log")
  local exit_code=${PIPESTATUS[0]}

  if [ $exit_code -ne 0 ]; then
    failed+=("$count:$label")
  fi
  count=$((count + 1))
  rm -rf "$HOME/.foundry/anvil/tmp"
}

for dir in test/integration/*/; do
  files=$(find "$dir" -name "*.test.ts" 2>/dev/null)
  [ -z "$files" ] && continue
  run_test "$dir" $files
done

# Run root-level test files
for f in test/integration/*.test.ts; do
  [ -f "$f" ] || continue
  run_test "$f" "$f"
done

# Summary
echo ""
echo "========================================"
if [ ${#failed[@]} -eq 0 ]; then
  echo "All test suites passed."
else
  echo "FAILED: ${#failed[@]} suite(s)"
  echo "========================================"
  for entry in "${failed[@]}"; do
    idx="${entry%%:*}"
    label="${entry#*:}"
    echo ""
    echo "--- $label ---"
    sed -n '/[0-9] failing/,$p' "$tmpdir/$idx.log" | head -80
  done
  exit 1
fi

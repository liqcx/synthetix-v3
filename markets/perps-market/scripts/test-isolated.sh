#!/usr/bin/env bash

# Run each test directory in its own hardhat process with anvil restart between them

failed=()

for dir in test/integration/*/; do
  files=$(find "$dir" -name "*.test.ts" 2>/dev/null)
  [ -z "$files" ] && continue

  echo ""
  echo "=== Testing $dir ==="
  if ! CANNON_REGISTRY_PRIORITY=local npx hardhat test $files; then
    failed+=("$dir")
  fi
  rm -rf "$HOME/.foundry/anvil/tmp"
done

# Run root-level test files
for f in test/integration/*.test.ts; do
  [ -f "$f" ] || continue
  echo ""
  echo "=== Testing $f ==="
  if ! CANNON_REGISTRY_PRIORITY=local npx hardhat test "$f"; then
    failed+=("$f")
  fi
  rm -rf "$HOME/.foundry/anvil/tmp"
done

# Summary
echo ""
if [ ${#failed[@]} -eq 0 ]; then
  echo "All test suites passed."
else
  echo "=== FAILED (${#failed[@]}) ==="
  for f in "${failed[@]}"; do
    echo "  - $f"
  done
  exit 1
fi

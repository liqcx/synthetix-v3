#!/usr/bin/env python3
"""
Migrates old-format Anvil state dumps in Cannon IPFS cache to the new format.

Old format (pre-Foundry v1.0): { accounts, block }
New format (Foundry v1.0+):    { accounts, block, best_block_number, blocks, transactions, historical_states }

The old format causes "Failed to decode state dump" errors with Anvil >= v1.5.x
and "Best hash not found" errors with Anvil v1.0.x - v1.1.x.
"""

import json
import gzip
import binascii
import os
import shutil
import sys


def migrate_chain_dump(hex_dump: str) -> str:
    """Convert an old-format chainDump to new format."""
    raw = binascii.unhexlify(hex_dump[2:])
    state = json.loads(gzip.decompress(raw))

    if "best_block_number" in state:
        return hex_dump  # Already new format

    # Add missing fields
    state["best_block_number"] = "0x0"
    state["block"]["number"] = "0x0"
    state["blocks"] = []
    state["transactions"] = []
    state["historical_states"] = None

    compressed = gzip.compress(json.dumps(state).encode())
    return "0x" + binascii.hexlify(compressed).decode()


def migrate_file(fpath: str) -> int:
    """Migrate all old-format chainDumps in a cache file. Returns count of migrated dumps."""
    with open(fpath) as f:
        data = json.load(f)

    if "state" not in data:
        return 0

    migrated = 0
    for step_name, step_data in data["state"].items():
        if not isinstance(step_data, dict) or "chainDump" not in step_data:
            continue
        dump = step_data["chainDump"]
        if not dump or not dump.startswith("0x1f8b"):
            continue

        raw = binascii.unhexlify(dump[2:])
        state = json.loads(gzip.decompress(raw))
        if "best_block_number" in state:
            continue

        step_data["chainDump"] = migrate_chain_dump(dump)
        migrated += 1
        print(f"  Migrated: {step_name}")

    if migrated > 0:
        backup = fpath + ".bak"
        shutil.copy2(fpath, backup)
        print(f"  Backup saved: {backup}")
        with open(fpath, "w") as f:
            json.dump(data, f)

    return migrated


def main():
    cache_dir = os.path.expanduser("~/.local/share/cannon/ipfs_cache/")
    if not os.path.isdir(cache_dir):
        print(f"Cache directory not found: {cache_dir}")
        sys.exit(1)

    total = 0
    for fname in sorted(os.listdir(cache_dir)):
        if not fname.endswith(".json"):
            continue
        fpath = os.path.join(cache_dir, fname)
        try:
            count = migrate_file(fpath)
            if count > 0:
                print(f"  => {fname}: {count} chainDumps migrated")
                total += count
        except Exception as e:
            print(f"  Error processing {fname}: {e}")

    if total == 0:
        print("No old-format state dumps found.")
    else:
        print(f"\nDone. Migrated {total} chainDumps total.")


if __name__ == "__main__":
    main()
#!/usr/bin/env python3
# Continuity check for a bootstrap-snapshot collection: prove the data has >=2
# periodic snapshots with a hole-free run of book-diff blocks between a
# consecutive pair — exactly the interval the PoDC orderbook test needs.
#
# Usage: python3 verify_interval.py <data_root>   (non-zero exit on failure)
import glob
import json
import os
import sys

root = sys.argv[1]

snaps = sorted(
    int(os.path.basename(f)[:-4])
    for f in glob.glob(root + "/periodic_abci_states/*/*.rmp")
)
print("  snapshots:", snaps)
if len(snaps) < 2:
    print("  FAIL: <2 snapshots collected")
    sys.exit(3)

# every block_number that has book activity
blocks = set()
for f in glob.glob(root + "/node_raw_book_diffs_*/hourly/*/*"):
    with open(f, "rb") as fh:
        for line in fh:
            if line.strip():
                blocks.add(json.loads(line)["block_number"])
lo, hi = min(blocks), max(blocks)
print(f"  book activity blocks: {len(blocks):,} in range {lo}-{hi}")

# find a consecutive snapshot pair fully inside [lo, hi] with no real holes
ok_pair = None
for s1, s2 in zip(snaps, snaps[1:]):
    if not (lo <= s1 and s2 <= hi):
        continue
    present = sorted(b for b in blocks if s1 < b <= s2)
    if not present:
        continue
    maxgap, prev = 0, s1
    for b in present:
        maxgap = max(maxgap, b - prev)
        prev = b
    maxgap = max(maxgap, s2 - present[-1])
    print(f"  pair {s1}->{s2}: {len(present)} active blocks, largest gap {maxgap}")
    if maxgap <= 50:   # live HL has activity nearly every block
        ok_pair = (s1, s2)
        break

if ok_pair:
    print(f"  PASS: clean interval {ok_pair[0]} -> {ok_pair[1]}")
else:
    print("  FAIL: no consecutive snapshot pair with hole-free events")
    sys.exit(4)

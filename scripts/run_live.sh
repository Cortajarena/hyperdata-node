#!/usr/bin/env bash
# Live mode: run hl-visor as a non-validator node connected to the
# Hyperliquid mainnet. Produces four consumable output streams
# locally under /home/hluser/hl/data/, plus the always-on side effect
# of periodic_abci_states/<height>.rmp snapshots every ~10k blocks.
#
# Output paths (host: ${DATA_DIR}/hl-node-data/, mounted at /home/hluser/hl/data):
#   node_fills/hourly/<date>/<hour>            ← API-format fills (overrides --write-trades)
#   node_order_statuses/hourly/<date>/<hour>   ← per-order lifecycle events (L4)
#   node_raw_book_diffs/hourly/<date>/<hour>   ← per-event book deltas (L4 primary)
#   periodic_abci_states/<date>/<height>.rmp   ← always-on snapshot, ~17 min cadence
#
# The fills tmpfs at /mnt/hl_node_fills (mounted over node_fills/) gives
# the downstream mmap consumer sub-microsecond hand-off for the
# latency-critical trade stream. The other outputs go to NVMe (too big
# for tmpfs).
#
# Cores 0-7 (signature verify, P2P, state) are pinned via compose
# `cpuset:` — this script doesn't touch CPU affinity.
#
# Pruner sidecar (--prune) runs as a separate container on cores 8-9
# (see compose).
#
# Flag rationale (see the indexer spec §12 for full reference):
#   --write-fills           API-format fills (preferred over legacy --write-trades)
#   --write-order-statuses  per-order events, lifecycle-oriented L4 stream
#   --write-raw-book-diffs  per-event book deltas, state-oriented L4 stream (primary)
#   --batch-by-block        emit records wrapped {local_time, block_time, block_number, events}
#   --disable-output-file-buffering no kernel page-cache wait → live consumers see events ASAP
#   --serve-info                    required for the --write-* flags to cooperate
set -euo pipefail

exec /usr/local/bin/hl-visor run-non-validator \
    --write-fills \
    --write-order-statuses \
    --write-raw-book-diffs \
    --batch-by-block \
    --disable-output-file-buffering \
    --serve-info

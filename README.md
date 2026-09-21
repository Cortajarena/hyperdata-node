# hyperdata-node

Containerized **HyperLiquid non-validator node** (hl-visor + hl-node) for the HyperData Platform. Runs as a long-running daemon, streaming its raw L1 outputs to shared storage for the ingestion layer to consume. The platform's single source of HyperCore truth.

```
hl-visor (vendor binary, gpg-verified at runtime)
  └─ hl-node run-non-validator --write-fills --write-order-statuses
       --write-raw-book-diffs --stream-with-block-info --serve-info
       └─ appends JSONL to: ${DATA_DIR}/hl-node-data/data/...
```

## Image

Thin wrapper — **no business logic**: the vendor binary + system deps + gpg trust for runtime signature checks + s5cmd (S3 tooling) + the run scripts. Build-time pin via `HL_BINARY_URL` (defaults to Mainnet hl-visor; see Dockerfile).

- Runs as non-root `hluser` (UID/GID 1000, matching the bind-mount ownership preflight in `scripts/build-node.sh`).
- `visor.json` (chain = Mainnet) is read from `/usr/local/bin/` — overridden at runtime by compose mounts.
- No ENTRYPOINT: the compose `command:` picks the mode.

## Running (live)

```bash
./scripts/build-node.sh live     # preflight + up -d + backgrounded log tail
```

Brings up two services (see `compose.yaml`):

| Service | What |
| :--- | :--- |
| `hyperdata-node-live` | the node (`scripts/run_live.sh`): p2p-connected non-validator, host network, cpuset 0-7, 24g mem, fills tmpfs overlay (`/mnt/hl_node_fills`) for the latency-critical trade stream |
| `hyperdata-node-pruner` | daily 03:00 UTC cron deleting node outputs >48h (preserving crash logs) — built from HL's upstream `pruner/` |

Preflight (in the script, idempotent, sudo only when needed): creates `${DATA_DIR}/hl-node-data/{,data,tmp}` with 1000:1000 ownership and the 4G fills tmpfs.

## Node output layout (what we consume, measured)

```
${DATA_DIR}/hl-node-data/data/
  node_fills_streaming/hourly/<YYYYMMDD>/<HH>            one file per hour, appended continuously
  node_order_statuses_streaming/hourly/<YYYYMMDD>/<HH>     one file per hour, appended continuously
  node_raw_book_diffs_streaming/hourly/<YYYYMMDD>/<HH>     one file per hour, appended continuously
  periodic_abci_states/<YYYYMMDD>/<height>.rmp            full-state snapshots, every ~10k blocks (~6-10 min)
  (replica_cmds, node_logs, visor_*, ... — written too; log/metric cruft, not consumed by the platform)
```

Record shape (`--stream-with-block-info`): **one JSON event per line**, each line carrying `{local_time, block_time, block_number, events: [...]}`. `local_time` = node write time; `block_time` = chain time.

Measured (Jun-10 capture, mainnet): **~15.6 blocks/s**; per hour: order_statuses ~52 GB (~84.5M lines), raw book diffs ~15 GB (~1M lines), fills ~0.5 GB (~150-250 lines/s); snapshots ~1.36 GB each. Full schemas + field census: ingestion layer [README](../README.md).

## Replay

**The node does not replay history** — HL's L1 has no mechanism to feed past blocks back through the node (see git history for the deleted, impossible `run_replay.sh`). Replay in this platform is the **ingestion layer's replay tap**: it *progressively appends* recorded files into the watched output tree at a configurable cadence, mimicking live append growth exactly — the sidecar tailer cannot tell the difference. Historical corpus: `/nvme0n1-disk/data/hl-node-data/data_stream_with_block_info/` (two consecutive hours, all three tables + ten snapshots). See [../README.md](../README.md) Phase 1.

## Snapshot bootstrap (`scripts/bootstrap-snapshot/`)

Ephemeral AWS Tokyo EC2 that state-syncs a fresh node, `tar.zst`s `hyperliquid_data/`, ships it back, and terminates — bypassing HL's ~60s `abci_stream` deadline that makes bootstrap from a US/EU host impossible (diagnosis in `run.sh` header). Used for first bootstrap, weekly refresh, disaster recovery. Produces the `snapshots/` artifacts and the `data_stream_with_block_info` capture corpora.

- `run.sh` — launch, sync, (optionally) collect a stream window, verify hole-free, ship, terminate. `--auto-terminate` | inspect-left-running default.
- `finish.sh`, `pull-parallel.sh`, `verify_interval.py` — ship-back + hole-free interval verification helpers.

Requires: `aws` CLI + creds (ec2:RunInstances in ap-northeast-1), `rsync`, `zstd`, `jq`. Cost ~$0.10-0.20/run (sync-only) or ~$2-3 (with stream collection).

## Repository layout

```
hyperdata-node/
├── Dockerfile                    image: vendor binary + deps + scripts (no business logic)
├── compose.yaml                   live + pruner services (node ops stack)
├── visor.json                    chain config (Mainnet)
├── override_gossip_config_live.json
└── scripts/
    ├── run_live.sh               node entrypoint (live mode flag set)
    ├── build-node.sh             preflight + compose up + log tailing (live mode)
    └── bootstrap-snapshot/       snapshot bootstrap + capture tooling (AWS)
```

## Notes

- `--stream-with-block-info` over `--batch-by-block`: events written as processed (lowest latency) while still carrying full block metadata — matches the sidecar's line-tailing model.
- Pruner keeps 48h of node output: the sidecar's seal events + backup sink are what make data durable beyond that; the ingestion pipeline (Iceberg) is the real archive.
- Snapshots (`.rmp`) are intentionally **not parsed** by the platform in v0 — archive-only; their role (book seals / health-check oracles, backfill validation) is a separate, pending design discussion.
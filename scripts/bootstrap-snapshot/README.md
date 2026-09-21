# bootstrap-snapshot

One-shot AWS Tokyo bootstrap to get a fresh HL state snapshot and ship
it back to local NVMe. Bypasses HL's 60s `abci_stream` deadline that
makes bootstrap from our US/EU host impossible (see `run.sh` header for
the diagnosis).

## When to use

- **First-ever bootstrap.** Local `hyperdata-node-live` can't complete
  state-sync (937 MB / 60s × 11 MB/s = doesn't fit).
- **Weekly snapshot refresh** (recommended cadence per plan.md).
- **Disaster recovery.** State DB corrupted, OOM kill mid-write, etc.
- **Before HL binary upgrade.** Pristine rollback point.

## How it works

1. Launches `c6id.2xlarge` on-demand in `ap-northeast-1` (Tokyo).
2. Installs Docker via cloud-init.
3. SCPs the `hyperdata-node/` source.
4. Builds + runs hl-visor with no `--write-*` flags (sync only).
5. Polls every 30s for `hyperliquid_data/visor_abci_state.json` to appear.
6. `tar.zst`s the `hyperliquid_data/` dir.
7. `rsync`s the archive back over SSH.
8. Extracts into `${DATA_DIR}/hl-node-data/` on this host.
9. Terminates the EC2 instance.

The archive is also kept at `${DATA_DIR}/hl-node-data/snapshots/`
for fast re-use.

## Cost

- `c6id.2xlarge` on-demand: ~$0.43/hr in ap-northeast-1.
- Typical run: ~15 min (cloud-init + docker pull + sync + transfer).
- ~$0.10-0.20 per bootstrap.

## Usage

```bash
# Default: bootstrap, ship snapshot, terminate
./scripts/bootstrap-snapshot/run.sh

# Debug: leave the EC2 alive after (SSH yourself in to poke around)
./scripts/bootstrap-snapshot/run.sh --keep-instance

# Override defaults via env:
INSTANCE_TYPE=c6id.4xlarge REGION=ap-northeast-1 ./run.sh
```

## Requirements on this host

- `aws` CLI with creds for an account that can `ec2:run-instances` in
  `ap-northeast-1`.
- SSH key at `~/.ssh/id_ed25519` (or override via `SSH_KEY=`).
- `rsync`, `zstd`, `jq` (script will fail early if missing).
- `sudo` for the final extract (paths are owned by UID 1000).

## What the script creates in AWS

| Resource | Name | Cleanup |
|---|---|---|
| Key pair | `hl-bootstrap` | Manual (one-time setup, reused) |
| Security group | `hl-bootstrap-sg` | Manual (reused; SSH ingress refreshed each run) |
| EC2 instance | `hl-bootstrap-<ts>` | Auto-terminated unless `--keep-instance` |

The key pair + SG are intentionally left around between runs (idempotent
reuse) — the only ongoing cost is zero (SGs are free, keys are free).

## Recovery if something goes wrong

If the script dies mid-run, the EC2 instance is terminated automatically
via the `cleanup` trap (unless `--keep-instance`). To verify nothing's
left running:

```bash
aws --region ap-northeast-1 ec2 describe-instances \
    --filters 'Name=tag:purpose,Values=hl-snapshot-bootstrap' \
              'Name=instance-state-name,Values=running,pending' \
    --query 'Reservations[].Instances[].[InstanceId,State.Name,LaunchTime]' \
    --output table
```

If the local extract step fails but the archive landed, you can re-extract manually:

```bash
sudo tar --use-compress-program=zstd \
    -xf ${DATA_DIR}/hl-node-data/snapshots/hl_state_*.tar.zst \
    -C ${DATA_DIR}/hl-node-data/
sudo chown -R 1000:1000 ${DATA_DIR}/hl-node-data/hyperliquid_data
```

## After it runs

```bash
# Restart the local node — it'll skip abci_stream and catch up via block gossip
docker compose --env-file .env \
    -f docker-compose.yml \
    restart hyperdata-node-live

# Watch for the first applied block (means catch-up is working)
tail -f log/hyperdata-node-live.log | grep "applied block"
```

You should see `applied block X` lines within seconds. Once it catches
up to chain head (a few minutes, depending on snapshot age), the
`node_raw_book_diffs_by_block/`, `replica_cmds/`, and
`periodic_abci_states/` streams start producing real data.

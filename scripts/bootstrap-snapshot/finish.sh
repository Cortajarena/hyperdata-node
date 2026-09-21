#!/usr/bin/env bash
# finish.sh — resume/finish a bootstrap-snapshot run whose orchestrator died.
# Drives an ALREADY-SYNCED, caught-up box: wait for TARGET snapshots, freeze,
# verify hole-free, archive the kept streams, ship back, extract, terminate.
# Run detached (setsid) so the harness can't reap it.
set -euo pipefail

REGION="${REGION:-ap-northeast-1}"
INSTANCE_ID="${INSTANCE_ID:?set INSTANCE_ID}"
PUB_IP="${PUB_IP:?set PUB_IP}"
TARGET="${TARGET:-10}"                 # stop once this many snapshots exist
MAX_WAIT_MIN="${MAX_WAIT_MIN:-120}"    # safety cap on the wait
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
OUT_DIR=data_stream_with_block_info
STREAMS=(node_raw_book_diffs_streaming node_order_statuses_streaming
         node_fills_streaming periodic_abci_states)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
DATA_DIR="${DATA_DIR:-$(grep -oE '^DATA_DIR=.*' "${REPO_ROOT}/.env" | cut -d= -f2-)}"
LOCAL_TARGET="${DATA_DIR}/hl-node-data"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=30 -o ServerAliveInterval=15 -o ServerAliveCountMax=8 \
    -o LogLevel=ERROR"

log() { echo ">> [$(date +%H:%M:%S)] $*"; }
aws_() { aws --region "$REGION" "$@"; }
rsh() { ssh $SSH_OPTS ubuntu@"$PUB_IP" "$@"; }

snap_count() {
    rsh 'ls -1 /mnt/hl-data/data/periodic_abci_states/*/*.rmp 2>/dev/null | wc -l' \
        2>/dev/null || echo 0
}

# ─── 1. wait for TARGET snapshots ──────────────────────────────────────
deadline=$(( $(date +%s) + MAX_WAIT_MIN * 60 ))
log "waiting for >= $TARGET snapshots (max ${MAX_WAIT_MIN}m)"
while :; do
    n=$(snap_count)
    log "  snapshots=$n / $TARGET"
    (( n >= TARGET )) && break
    (( $(date +%s) > deadline )) && { log "  WAIT TIMED OUT at $n — finishing anyway"; break; }
    sleep 60
done

# ─── 2. freeze node + rename data dir ──────────────────────────────────
log "freezing node + renaming data -> $OUT_DIR"
rsh "set -e; docker stop hlsync >/dev/null; \
     sudo mv /mnt/hl-data/data /mnt/hl-data/$OUT_DIR; \
     sudo du -sh /mnt/hl-data/$OUT_DIR"

# ─── 3. verify hole-free interval ──────────────────────────────────────
log "verifying >=2 snapshots + hole-free events between them"
ssh $SSH_OPTS ubuntu@"$PUB_IP" "sudo python3 - /mnt/hl-data/$OUT_DIR" \
    < "$SCRIPT_DIR/verify_interval.py" \
    || { log "VERIFY FAILED — leaving instance ALIVE for inspection"; exit 2; }

# ─── 4. archive kept streams on the box ────────────────────────────────
ARCHIVE="/mnt/hl-data/hl_${STAMP}.tar.zst"
TARPATHS=("${STREAMS[@]/#/$OUT_DIR/}")
log "archiving streams -> $ARCHIVE"
rsh "set -e; \
     sudo tar --use-compress-program='zstd -T0' -cf $ARCHIVE -C /mnt/hl-data ${TARPATHS[*]}; \
     sudo chown ubuntu:ubuntu $ARCHIVE; ls -lh $ARCHIVE"

# ─── 5. ship compressed archive back (no extract — keep manual control) ─
mkdir -p "${LOCAL_TARGET}/snapshots"
LOCAL_ARCHIVE="${LOCAL_TARGET}/snapshots/$(basename "$ARCHIVE")"
log "downloading compressed archive -> $LOCAL_ARCHIVE"
rsync -aP -e "ssh $SSH_OPTS" "ubuntu@$PUB_IP:$ARCHIVE" "$LOCAL_ARCHIVE"
ls -lh "$LOCAL_ARCHIVE"

# Intentionally NO local extract (would clobber the existing
# data_stream_with_block_info/) and NO auto-terminate (manual teardown).
log "DONE — archive on NVMe, box left ALIVE."
log "  archive:   $LOCAL_ARCHIVE"
log "  terminate: aws --region $REGION ec2 terminate-instances --instance-ids $INSTANCE_ID"

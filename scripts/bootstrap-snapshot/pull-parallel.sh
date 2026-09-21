#!/usr/bin/env bash
# pull-parallel.sh — fetch one big file from a remote host over N parallel SSH
# streams (single-stream rsync can't fill the bandwidth-delay product over a
# trans-Pacific RTT). Splits on the remote, pulls concurrently, reassembles,
# verifies sha256, cleans up. Idempotent-ish: re-run resumes via rsync --partial.
#
# Usage: PUB_IP=1.2.3.4 REMOTE=/path/file LOCAL_DIR=/dest [N=16] ./pull-parallel.sh
set -euo pipefail

PUB_IP="${PUB_IP:?set PUB_IP}"
REMOTE="${REMOTE:?set REMOTE (absolute path on box)}"
LOCAL_DIR="${LOCAL_DIR:?set LOCAL_DIR}"
N="${N:-16}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
NAME="$(basename "$REMOTE")"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=30 -o ServerAliveInterval=15 -o ServerAliveCountMax=8 -o LogLevel=ERROR"
log() { echo ">> [$(date +%H:%M:%S)] $*"; }
rsh() { ssh $SSH_OPTS ubuntu@"$PUB_IP" "$@"; }

mkdir -p "$LOCAL_DIR/parts"

# split on the box + kick off the remote checksum in the background
log "splitting $NAME into $N parts on box + starting remote sha256"
rsh "set -e; cd \$(dirname $REMOTE); \
     sha256sum $NAME > $NAME.sha256 & \
     rm -f ${NAME}.part*; split -d -a 2 -n $N $NAME ${NAME}.part; \
     ls -1 ${NAME}.part* | wc -l"

# pull all parts concurrently
log "pulling $N parts in parallel"
pids=()
for i in $(seq -w 0 $((N - 1))); do
    rsync -aP --partial -e "ssh $SSH_OPTS" \
        "ubuntu@$PUB_IP:${REMOTE}.part${i}" "$LOCAL_DIR/parts/" >/dev/null 2>&1 &
    pids+=($!)
done
fail=0
for p in "${pids[@]}"; do wait "$p" || fail=1; done
(( fail )) && { log "a part transfer FAILED — parts kept for resume"; exit 1; }

# reassemble in order
log "reassembling -> $LOCAL_DIR/$NAME"
cat "$LOCAL_DIR/parts/${NAME}.part"* > "$LOCAL_DIR/$NAME"

# verify against the remote checksum
log "verifying sha256"
remote_sum=$(rsh "cat \$(dirname $REMOTE)/$NAME.sha256" | awk '{print $1}')
local_sum=$(sha256sum "$LOCAL_DIR/$NAME" | awk '{print $1}')
log "  remote=$remote_sum"
log "  local =$local_sum"
if [[ "$remote_sum" == "$local_sum" ]]; then
    log "CHECKSUM OK — cleaning up parts"
    rm -rf "$LOCAL_DIR/parts"
    rsh "rm -f ${REMOTE}.part* $(dirname "$REMOTE")/$NAME.sha256" || true
    log "DONE: $LOCAL_DIR/$NAME"
else
    log "CHECKSUM MISMATCH — keeping local parts + reassembled file"
    exit 2
fi

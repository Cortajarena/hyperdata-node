#!/usr/bin/env bash
# bootstrap-snapshot/run.sh
# Launch an ephemeral EC2 in Tokyo, sync the HL state snapshot, collect
# COLLECT_MIN minutes of caught-up L4 stream data, verify it is hole-free, and
# ship it back to local NVMe.
#
# Usage:
#   ./run.sh                    # leave the EC2 running on ANY exit (inspect)
#   ./run.sh --auto-terminate   # terminate the EC2 only on clean success
#
# Why Tokyo: HL's abci_stream has a ~60s wall-clock deadline. From our US/EU
# host, TCP throughput (~11 MB/s at 141ms RTT) caps us at ~660 MB inside it —
# snapshots are ~940 MB. Intra-Tokyo RTT (~1-3ms) finishes the transfer in
# seconds.
#
# Cost: ~$2-3 (r6id.4xlarge on-demand ~$1.27/hr, ~1.5-2h end to end).
set -euo pipefail

# ─── config ────────────────────────────────────────────────────────────
REGION="${REGION:-ap-northeast-1}"
INSTANCE_TYPE="${INSTANCE_TYPE:-r6id.4xlarge}"   # 16 vCPU/128 GB = HL min spec
COLLECT_MIN="${COLLECT_MIN:-60}"                 # collect window after catch-up
CATCHUP_LAG_S="${CATCHUP_LAG_S:-20}"             # caught up = block_time within this
CATCHUP_MAX_MIN="${CATCHUP_MAX_MIN:-45}"         # catch-up timeout
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
PULL_STREAMS="${PULL_STREAMS:-16}"               # parallel streams for ship-back
KEY_NAME="${KEY_NAME:-hl-bootstrap}"
SG_NAME="${SG_NAME:-hl-bootstrap-sg}"
TAG="hl-bootstrap-$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR=data_stream_with_block_info

# Streams we keep. The node also writes latency_*, tcp_*, tokio_*, node_logs,
# replica_cmds, visor_*, evm_* etc. — metrics/log cruft we don't ship.
STREAMS=(node_raw_book_diffs_streaming node_order_statuses_streaming
         node_fills_streaming periodic_abci_states)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"  # submodule root (hyperdata-node/)
NODE_REPO="${REPO_ROOT}"
DATA_DIR="${DATA_DIR:-$(
    grep -oE '^DATA_DIR=.*' "${REPO_ROOT}/.env" 2>/dev/null | cut -d= -f2-)}"
: "${DATA_DIR:?DATA_DIR not set in env or .env}"
LOCAL_TARGET="${DATA_DIR}/hl-node-data"

AUTO_TERMINATE=0
[[ "${1:-}" == "--auto-terminate" ]] && AUTO_TERMINATE=1

# ─── helpers ───────────────────────────────────────────────────────────
log() { echo ">> [$(date +%H:%M:%S)] $*"; }
aws_() { aws --region "$REGION" "$@"; }

# Retry ssh up to 3x (15s gap). Needs PUB_IP + SSH_OPTS set.
ssh_safe() {
    local i
    for i in 1 2 3; do
        ssh $SSH_OPTS ubuntu@"$PUB_IP" "$@" && return 0
        (( i < 3 )) && { log "  ssh $i/3 failed; retrying"; sleep 15; }
    done
    return 1
}

# Like ssh_safe but runs a bash script read from stdin (re-sent on each retry).
ssh_heredoc_safe() {
    local script i; script=$(cat)
    for i in 1 2 3; do
        echo "$script" | ssh $SSH_OPTS ubuntu@"$PUB_IP" bash && return 0
        (( i < 3 )) && { log "  ssh-heredoc $i/3 failed; retrying"; sleep 15; }
    done
    return 1
}

# Pull a big remote file over N parallel SSH streams — a single rsync can't fill
# the bandwidth-delay product over the ~141ms trans-Pacific RTT (saw ~0.7 MB/s).
# Splits on the box, pulls concurrently, reassembles, verifies sha256.
pull_parallel() {
    local remote="$1" dest_dir="$2"
    local name rdir pids=() fail=0 i remote_sum local_sum
    name="$(basename "$remote")"
    rdir="$(dirname "$remote")"
    mkdir -p "$dest_dir/parts"
    log "  splitting $name into $PULL_STREAMS parts on box + remote sha256"
    ssh_heredoc_safe <<REMOTE
set -euo pipefail
cd "$rdir"
sha256sum "$name" > "$name.sha256" &
rm -f "$name".part*
split -d -a 2 -n $PULL_STREAMS "$name" "$name".part
REMOTE
    log "  pulling $PULL_STREAMS parts in parallel"
    for i in $(seq -w 0 $((PULL_STREAMS - 1))); do
        rsync -aP --partial -e "ssh $SSH_OPTS" \
            "ubuntu@$PUB_IP:${remote}.part${i}" "$dest_dir/parts/" \
            >/dev/null 2>&1 &
        pids+=($!)
    done
    for i in "${pids[@]}"; do wait "$i" || fail=1; done
    (( fail )) && { log "  parallel pull FAILED — parts kept for resume"; return 1; }
    log "  reassembling + verifying sha256"
    cat "$dest_dir/parts/${name}.part"* > "$dest_dir/$name"
    remote_sum=$(ssh_safe "cat '$rdir/$name.sha256'" | awk '{print $1}')
    local_sum=$(sha256sum "$dest_dir/$name" | awk '{print $1}')
    [[ -n "$remote_sum" && "$remote_sum" == "$local_sum" ]] \
        || { log "  CHECKSUM MISMATCH (remote=$remote_sum local=$local_sum)"; return 1; }
    log "  checksum OK"
    rm -rf "$dest_dir/parts"
    ssh_safe "rm -f ${remote}.part* '$rdir/$name.sha256'" || true
}

# Newest meaningful node-log line (download %, peer greeting, applied block) so
# the wait loops show real progress, not a blind "(probe in progress)".
node_status() {
    local probe='docker logs hlsync --since 30s 2>&1'
    probe+=' | grep -aoE "reading bytes|greeting from [0-9.]+|applied block [0-9]+"'
    probe+=' | tail -1'
    ssh_safe "$probe" 2>/dev/null || echo "(ssh probe failed — box busy)"
}

# Launch the hlsync container with the L4 writers enabled.
# --replica-cmds-style left at default (Hash-only): we rebuild L4 from
# raw_book_diffs (byte-identical per PoDC), never by parsing replica_cmds.
# --disable-output-file-buffering OMITTED on purpose: per-line flush at ~22M
# order-status lines/hr drags block processing below real-time, so the node
# never catches live head (the bug that holed our first dataset).
launch_writers() {
    log "  launching hlsync (writers)"
    cat <<REMOTE | ssh_heredoc_safe
set -euo pipefail
cd /home/ubuntu/hyperdata-node
docker rm -f hlsync 2>/dev/null || true
docker run -d --name hlsync \\
    --network host --restart unless-stopped \\
    -v /mnt/hl-data:/home/hluser/hl \\
    -v \$(pwd)/override_gossip_config_live.json:/home/hluser/override_gossip_config.json:ro \\
    -v \$(pwd)/visor.json:/usr/local/bin/visor.json:ro \\
    hyperdata-node-bootstrap \\
    /usr/local/bin/hl-visor run-non-validator \\
        --write-fills --write-order-statuses --write-raw-book-diffs \\
        --write-hip3-oracle-updates --write-misc-events \\
        --write-system-and-core-writer-actions \\
        --stream-with-block-info --serve-info >/dev/null
REMOTE
}

# Wait until the node is caught up to live head before trusting its output: a
# catching-up node lags and takes block-skipping shortcuts that hole the
# stream. Caught up = newest written block_time within CATCHUP_LAG_S of now.
wait_caught_up() {
    local deadline lag bt now bt_epoch
    deadline=$(( $(date +%s) + CATCHUP_MAX_MIN * 60 ))
    log "  waiting for catch-up to live head (lag < ${CATCHUP_LAG_S}s)"
    while :; do
        (( $(date +%s) > deadline )) && { log "  CATCH-UP TIMED OUT"; return 1; }
        bt=$(ssh_safe '
            f=$(ls -t /mnt/hl-data/data/node_raw_book_diffs_*/hourly/*/* \
                2>/dev/null | head -1)
            [ -n "$f" ] && tail -c 200000 "$f" 2>/dev/null \
                | grep -o "\"block_time\":\"[^\"]*\"" | tail -1 | cut -d\" -f4
        ' || true)
        if [ -n "$bt" ]; then
            now=$(date -u +%s)
            bt_epoch=$(date -u -d "${bt%.*}" +%s 2>/dev/null || echo 0)
            lag=$(( now - bt_epoch ))
            log "    block_time=$bt lag=${lag}s"
            (( bt_epoch > 0 && lag < CATCHUP_LAG_S )) && { log "    CAUGHT UP"; return 0; }
        else
            log "    $(node_status)"   # not writing diffs yet — show sync progress
        fi
        sleep 20
    done
}

# Post-collection continuity check. FAILS LOUDLY unless the data has >=2
# periodic snapshots with hole-free book activity between a consecutive pair —
# exactly the dataset the PoDC orderbook test needs.
verify_interval() {
    log "  verifying >=2 snapshots + hole-free events between them"
    local i
    for i in 1 2 3; do
        ssh $SSH_OPTS ubuntu@"$PUB_IP" "sudo python3 - /mnt/hl-data/$OUT_DIR" \
            < "$SCRIPT_DIR/verify_interval.py" && return 0
        (( i < 3 )) && { log "  verify ssh $i/3 failed; retrying"; sleep 15; }
    done
    return 1
}

# Launch writers, wait for catch-up, collect COLLECT_MIN, freeze + verify.
collect() {
    launch_writers
    wait_caught_up || { log "catch-up failed — leaving instance"; exit 2; }
    log "  collecting ${COLLECT_MIN} min of caught-up data"
    sleep $((COLLECT_MIN * 60))
    log "  done; freezing node + renaming data -> $OUT_DIR"
    cat <<REMOTE | ssh_heredoc_safe
set -euo pipefail
docker stop hlsync >/dev/null
sudo mv /mnt/hl-data/data /mnt/hl-data/$OUT_DIR
sudo du -sh /mnt/hl-data/$OUT_DIR
REMOTE
    verify_interval || { log "VERIFY FAILED — data has holes, leaving instance"; exit 2; }
}

# ─── 1. preflight ──────────────────────────────────────────────────────
log "preflight"
[[ -f "$SSH_KEY" && -f "${SSH_KEY}.pub" ]] \
    || { echo "missing SSH key: $SSH_KEY" >&2; exit 1; }
[[ -f "${NODE_REPO}/Dockerfile" ]] \
    || { echo "missing $NODE_REPO/Dockerfile" >&2; exit 1; }
[[ -f "${NODE_REPO}/override_gossip_config_live.json" ]] \
    || { echo "missing override_gossip_config_live.json" >&2; exit 1; }
aws_ sts get-caller-identity >/dev/null

# ─── 2. key pair (idempotent import) ───────────────────────────────────
log "key pair: $KEY_NAME"
aws_ ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1 \
    || aws_ ec2 import-key-pair --key-name "$KEY_NAME" \
           --public-key-material "fileb://${SSH_KEY}.pub" >/dev/null

# ─── 3. security group: SSH from our IP only ───────────────────────────
log "security group: $SG_NAME"
MY_IP=$(curl -s --max-time 5 https://ifconfig.io)
SG_ID=$(aws_ ec2 describe-security-groups --group-names "$SG_NAME" \
            --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
if [[ -z "$SG_ID" || "$SG_ID" == "None" ]]; then
    SG_ID=$(aws_ ec2 create-security-group --group-name "$SG_NAME" \
                --description "HL bootstrap" --query 'GroupId' --output text)
fi
aws_ ec2 authorize-security-group-ingress --group-id "$SG_ID" \
    --protocol tcp --port 22 --cidr "${MY_IP}/32" 2>/dev/null || true
log "  $SG_ID, SSH from ${MY_IP}/32"

# ─── 4. resolve latest Ubuntu 24.04 AMI ────────────────────────────────
AMI_FILTER="ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
AMI_ID=$(aws_ ec2 describe-images --owners 099720109477 \
    --filters "Name=name,Values=$AMI_FILTER" "Name=state,Values=available" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text)
log "AMI: $AMI_ID"

# ─── 5. launch instance ────────────────────────────────────────────────
# cloud-init formats + mounts the instance-store NVMe at /mnt/hl-data so the
# heavy I/O lands on local NVMe, not the 20 GB root EBS.
log "launching $INSTANCE_TYPE"
USER_DATA=$(cat <<'EOF'
#cloud-config
package_update: true
packages: [docker.io, zstd]
runcmd:
  - systemctl enable --now docker
  - usermod -aG docker ubuntu
  - mkfs.ext4 -F -O ^has_journal -L hl-data /dev/nvme1n1
  - mkdir -p /mnt/hl-data
  - mount /dev/nvme1n1 /mnt/hl-data
  - chown 1000:1000 /mnt/hl-data
  - echo "/dev/nvme1n1 /mnt/hl-data ext4 defaults,nofail 0 0" >> /etc/fstab
  - touch /var/lib/cloud/instance/boot-finished
EOF
)
TAGS="ResourceType=instance,Tags=[{Key=Name,Value=$TAG},\
{Key=purpose,Value=hl-snapshot-bootstrap}]"
INSTANCE_ID=$(aws_ ec2 run-instances --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" --user-data "$USER_DATA" \
    --tag-specifications "$TAGS" \
    --block-device-mappings \
        'DeviceName=/dev/sda1,Ebs={VolumeSize=20,VolumeType=gp3}' \
    --query 'Instances[0].InstanceId' --output text)
log "  instance: $INSTANCE_ID"

# Exit trap: auto-terminate ONLY on clean success + --auto-terminate. Any other
# exit leaves the EC2 alive for inspection — losing collected data to a
# transient SSH hiccup was a real incident.
SUCCESS=0
cleanup() {
    local code=$?
    if (( SUCCESS == 1 && AUTO_TERMINATE == 1 )); then
        log "clean success + --auto-terminate: terminating $INSTANCE_ID"
        aws_ ec2 terminate-instances --instance-ids "$INSTANCE_ID" >/dev/null || true
    elif (( SUCCESS == 1 )); then
        log "clean success — leaving $INSTANCE_ID running. Terminate with:"
        log "  aws --region $REGION ec2 terminate-instances --instance-ids $INSTANCE_ID"
    else
        log "EXIT before completion (code $code) — leaving $INSTANCE_ID ALIVE."
        log "  ssh:       ssh -i $SSH_KEY ubuntu@${PUB_IP:-<no-ip-yet>}"
        log "  terminate: aws --region $REGION ec2 terminate-instances \
--instance-ids $INSTANCE_ID"
    fi
}
trap cleanup EXIT

# ─── 6. wait for running + SSH + cloud-init ────────────────────────────
log "waiting for instance running + cloud-init complete"
aws_ ec2 wait instance-running --instance-ids "$INSTANCE_ID"
PUB_IP=$(aws_ ec2 describe-instances --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
log "  public IP: $PUB_IP"

SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=30 -o ServerAliveInterval=15 -o ServerAliveCountMax=8 \
    -o LogLevel=ERROR"
until ssh $SSH_OPTS ubuntu@"$PUB_IP" \
        'test -f /var/lib/cloud/instance/boot-finished' 2>/dev/null; do
    sleep 5
done
log "  cloud-init done"

# ─── 7. ship source + build image ──────────────────────────────────────
log "shipping hyperdata-node source + building image"
tar -C "$NODE_REPO" -czf - . | ssh $SSH_OPTS ubuntu@"$PUB_IP" \
    'mkdir -p hyperdata-node && tar -xzf - -C hyperdata-node'
ssh_heredoc_safe <<'REMOTE'
cd hyperdata-node
docker build -t hyperdata-node-bootstrap . >/dev/null
REMOTE

# ─── 8. bootstrap container (no writers, pure state-sync) ──────────────
log "launching bootstrap container (no writers; pure sync)"
cat <<'REMOTE' | ssh_heredoc_safe
cd hyperdata-node
docker rm -f hlsync 2>/dev/null || true
docker run -d --name hlsync \
    --network host --restart unless-stopped \
    -v /mnt/hl-data:/home/hluser/hl \
    -v $(pwd)/override_gossip_config_live.json:/home/hluser/override_gossip_config.json:ro \
    -v $(pwd)/visor.json:/usr/local/bin/visor.json:ro \
    hyperdata-node-bootstrap \
    /usr/local/bin/hl-visor run-non-validator --disable-output-file-buffering >/dev/null
REMOTE

# ─── 9. wait for state-sync (visor_abci_state.json marker) ─────────────
log "waiting for visor_abci_state.json (intra-Tokyo sync ~30s, hydrate ~5min)"
SYNC_DEADLINE=$(( $(date +%s) + 3600 ))
while :; do
    (( $(date +%s) > SYNC_DEADLINE )) && { log "sync TIMED OUT after 60 min"; exit 2; }
    ssh_safe 'test -f /mnt/hl-data/hyperliquid_data/visor_abci_state.json' && break
    log "  $(node_status)"
    sleep 30
done
log "sync complete"

# ─── 10. collect ───────────────────────────────────────────────────────
collect

# ─── 11. archive the kept streams on EC2 (zstd -T0) ────────────────────
log "archiving streams on EC2"
ARCHIVE="/mnt/hl-data/hl_${TAG#hl-bootstrap-}.tar.zst"
TARPATHS=("${STREAMS[@]/#/$OUT_DIR/}")
cat <<REMOTE | ssh_heredoc_safe
set -euo pipefail
sudo tar --use-compress-program='zstd -T0' -cf $ARCHIVE \\
    -C /mnt/hl-data ${TARPATHS[*]}
sudo chown ubuntu:ubuntu $ARCHIVE
ls -lh $ARCHIVE
REMOTE

# ─── 12. ship archive back (parallel multi-stream) ─────────────────────
log "downloading archive (~7-12 GB) over $PULL_STREAMS parallel streams"
mkdir -p "${LOCAL_TARGET}/snapshots"
LOCAL_ARCHIVE="${LOCAL_TARGET}/snapshots/$(basename "$ARCHIVE")"
pull_parallel "$ARCHIVE" "${LOCAL_TARGET}/snapshots"

# ─── 13. extract locally ───────────────────────────────────────────────
log "extracting into $LOCAL_TARGET/"
sudo tar --use-compress-program='zstd -T0' -xf "$LOCAL_ARCHIVE" -C "$LOCAL_TARGET"
sudo chown -R 1000:1000 "$LOCAL_TARGET/$OUT_DIR"
sudo du -sh "$LOCAL_TARGET/$OUT_DIR"

SUCCESS=1
log ""
log "DONE."
log "  archive: $LOCAL_ARCHIVE"
log "  streams: $LOCAL_TARGET/$OUT_DIR/"

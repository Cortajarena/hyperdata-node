#!/usr/bin/env bash
# build-node.sh — bring up the HL node container(s) in the
# background and tail logs into log/ under the repo root.
#
# Usage:
#   ./scripts/build-node.sh live
#       Long-running non-validator + pruner. Tails until killed.
#
# What it does:
#   1. Preflight — ensure host paths exist with hluser (UID 1000)
#      ownership so the container can write. Idempotent; sudo only when
#      something actually needs creating/chowning.
#   2. Kill any lingering host-side `docker compose logs -f` from a
#      previous invocation (they don't EOF when the container stops).
#   3. `docker compose up --build -d` the live services.
#   4. `docker compose logs -f` in a backgrounded subshell, output
#      redirected to log/hyperdata-node-<mode>-<UTC>.log with a
#      hyperdata-node-<mode>.log symlink pointing at the latest.
#   5. Print pid + log path; exit.
#
# Replay note: historical replay is NOT run through the node — HL cannot
# replay past replica_cmds. Replay is the platform ingestion layer's
# replay tap (file copy into the watched tree); see the ingestion README
# in the parent monorepo. Snapshot capture lives in
# scripts/bootstrap-snapshot/.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:?usage: ./scripts/build-node.sh live}"
shift

# ─── 1. preflight ────────────────────────────────────────────────────
# Host directories that must exist with UID 1000 ownership:
#   ${DATA_DIR}/hl-node-data/         ← bind-mounted to /home/hluser/hl
#   ${DATA_DIR}/hl-node-data/data/    ← docker would auto-create as root
#                                       for the nested tmpfs overlay
#   ${DATA_DIR}/hl-node-data/tmp/     ← hl-visor shell-out scratch
#   /mnt/hl_node_fills (tmpfs)        ← live mode only, fills hot path
preflight() {
    local data_dir
    data_dir="${DATA_DIR:-$(grep -oE '^DATA_DIR=.*' .env 2>/dev/null | cut -d= -f2-)}"
    : "${data_dir:?DATA_DIR not set in env or .env}"

    local nvme="${data_dir}/hl-node-data"
    for d in "$nvme" "$nvme/data" "$nvme/tmp"; do
        if [[ ! -d "$d" ]] || [[ "$(stat -c '%u:%g' "$d")" != "1000:1000" ]]; then
            echo ">> preflight: $d (mkdir + chown 1000:1000)"
            sudo mkdir -p "$d" && sudo chown 1000:1000 "$d"
        fi
    done

    local tmpfs="/mnt/hl_node_fills"
    [[ -d "$tmpfs" ]] || sudo mkdir -p "$tmpfs"
    if ! findmnt -n "$tmpfs" >/dev/null 2>&1; then
        echo ">> preflight: mounting 4G tmpfs at $tmpfs"
        sudo mount -t tmpfs -o size=4G,uid=1000,gid=1000 tmpfs "$tmpfs"
    fi
    [[ "$(stat -c '%u:%g' "$tmpfs")" == "1000:1000" ]] || sudo chown 1000:1000 "$tmpfs"
}
preflight

# ─── 2. clean up lingering host-side compose processes ──────────────
pkill -f 'docker compose .*compose.yaml' 2>/dev/null || true

# ─── 3. mode → services ─────────────────────────────────────────────
case "$MODE" in
    live)
        SERVICES=(hyperdata-node-live hyperdata-node-pruner)
        ;;
    *)
        echo "unknown mode: $MODE (only 'live'; replay is the ingestion-layer tap)" >&2
        exit 2
        ;;
esac

# ─── 4. log file + symlink (matches the platform log convention)
mkdir -p log
LOG="log/hyperdata-node-${MODE}-$(date -u +%Y%m%dT%H%M%SZ).log"
ln -sfn "$(basename "$LOG")" "log/hyperdata-node-${MODE}.log"

COMPOSE=(docker compose --env-file .env -f compose.yaml)

# ─── 5. bring up + tail in background ───────────────────────────────
(
    NO_COLOR=1 "${COMPOSE[@]}" up --build -d "${SERVICES[@]}"
    "${COMPOSE[@]}" logs -f --no-color "${SERVICES[@]}"
) >"$LOG" 2>&1 &
disown

echo "pid=$! mode=$MODE services=${SERVICES[*]} log=$LOG"
echo "  tail -f $LOG"

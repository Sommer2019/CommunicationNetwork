#!/usr/bin/env bash
# =============================================================================
# failback.sh – restore Node A as MASTER after it has been repaired
# =============================================================================
# Run ON NODE A once it is back online and healthy.
# Steps:
#   1. Re-sync Redis – Node A becomes replica of Node B (current master)
#   2. Wait for full replication catch-up
#   3. Report GlusterFS self-heal status
#   4. keepalived will automatically reclaim the VIP when Node A's
#      health-check starts passing again (no manual action needed)
# =============================================================================
set -euo pipefail
# shellcheck source=/dev/null
source /etc/minecraft-ha/config.env
LOG=/var/log/keepalived-minecraft.log
exec >> "$LOG" 2>&1
log() { echo "[$(date -Iseconds)] [failback] $*"; }
SYNC_TIMEOUT=30

log "=== Starting failback – re-syncing Node A with Node B ==="

# ── 1. Point Redis at Node B (current master) ────────────────────────────────
redis-cli -p "${REDIS_PORT}" -a "${REDIS_PASSWORD}" \
    CONFIG SET masterauth "${REDIS_PASSWORD}" >/dev/null
redis-cli -p "${REDIS_PORT}" -a "${REDIS_PASSWORD}" \
    REPLICAOF "${NODE_B_IP}" "${REDIS_PORT}" >/dev/null
log "Redis now replicating from Node B (${NODE_B_IP})."

# ── 2. Wait for replication to catch up ──────────────────────────────────────
log "Waiting for Redis sync (timeout: ${SYNC_TIMEOUT}s)..."
START=$(date +%s)
while true; do
    MASTER_OFF=$(redis-cli -h "${NODE_B_IP}" -p "${REDIS_PORT}" -a "${REDIS_PASSWORD}" \
        INFO replication 2>/dev/null | grep "master_repl_offset" | cut -d: -f2 | tr -d '[:space:]') || MASTER_OFF="?"
    LOCAL_OFF=$(redis-cli -p "${REDIS_PORT}" -a "${REDIS_PASSWORD}" \
        INFO replication 2>/dev/null | grep -E "master_repl_offset|slave_repl_offset" | head -1 | cut -d: -f2 | tr -d '[:space:]') || LOCAL_OFF="?"
    if [[ "$MASTER_OFF" == "$LOCAL_OFF" && "$MASTER_OFF" != "?" ]]; then
        log "Redis in sync (offset: ${MASTER_OFF})."
        break
    fi
    ELAPSED=$(( $(date +%s) - START ))
    if (( ELAPSED > SYNC_TIMEOUT )); then
        log "WARNING: Redis sync timed out (master=${MASTER_OFF}, local=${LOCAL_OFF})."
        break
    fi
    log "  Syncing… master=${MASTER_OFF}, local=${LOCAL_OFF}"
    sleep 2
done

# ── 3. GlusterFS self-heal status ────────────────────────────────────────────
log "GlusterFS self-heal status:"
gluster volume heal "${GLUSTER_VOLUME}" info 2>/dev/null || log "(gluster not available on this host)"

log "=== Failback prep complete. Keepalived will reclaim the VIP automatically. ==="
log "    Monitor: journalctl -u keepalived -f"

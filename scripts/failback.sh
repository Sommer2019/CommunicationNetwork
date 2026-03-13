#!/usr/bin/env bash
# =============================================================================
# Manual failback script (Node A returning to service)
# =============================================================================
# After Node A has been repaired and brought back online, run this script ON
# NODE A to:
#   1. Re-sync Redis: Node A becomes replica of Node B (now master).
#   2. Wait for Redis replication to catch up.
#   3. Re-sync GlusterFS (happens automatically via self-heal).
#   4. Gracefully hand the VIP back to Node A (optional – keepalived will do
#      this automatically when Node A's priority overtakes Node B's; this
#      script just validates readiness first).
#
# Run on Node A after it has been repaired.
# =============================================================================

set -euo pipefail
LOG=/var/log/minecraft-failover.log
exec >> "$LOG" 2>&1

NODE_B_IP="192.168.1.102"
REDIS_PORT=6379
REDIS_PASSWORD="CHANGE_ME_STRONG_REDIS_PASSWORD"
REDIS_CLI="redis-cli"
SYNC_TIMEOUT=30   # seconds to wait for Redis replication to catch up

log() { echo "[$(date -Iseconds)] [failback] $*"; }

log "=== Starting failback of Node A ==="

# ── 1. Configure Node A's Redis as replica of Node B ────────────────────────
log "Configuring Redis to replicate from Node B ($NODE_B_IP)..."
$REDIS_CLI -p "$REDIS_PORT" -a "$REDIS_PASSWORD" \
    CONFIG SET masterauth "$REDIS_PASSWORD"
$REDIS_CLI -p "$REDIS_PORT" -a "$REDIS_PASSWORD" \
    REPLICAOF "$NODE_B_IP" "$REDIS_PORT"
log "REPLICAOF ${NODE_B_IP}:${REDIS_PORT} issued."

# ── 2. Wait for replication to catch up ─────────────────────────────────────
log "Waiting for Redis replication to catch up (timeout: ${SYNC_TIMEOUT}s)..."
START=$(date +%s)
while true; do
    OFFSET_MASTER=$($REDIS_CLI -h "$NODE_B_IP" -p "$REDIS_PORT" -a "$REDIS_PASSWORD" \
                    INFO replication 2>/dev/null \
                    | grep "master_repl_offset" | tr -d '[:space:]' | cut -d: -f2)
    OFFSET_REPLICA=$($REDIS_CLI -p "$REDIS_PORT" -a "$REDIS_PASSWORD" \
                     INFO replication 2>/dev/null \
                     | grep "master_repl_offset\|slave_repl_offset" \
                     | head -1 | tr -d '[:space:]' | cut -d: -f2)

    if [[ "$OFFSET_MASTER" == "$OFFSET_REPLICA" ]]; then
        log "Redis replication in sync (offset: ${OFFSET_MASTER})."
        break
    fi

    ELAPSED=$(( $(date +%s) - START ))
    if (( ELAPSED > SYNC_TIMEOUT )); then
        log "WARNING: Redis sync timed out after ${SYNC_TIMEOUT}s."
        log "         Offsets: master=${OFFSET_MASTER}, replica=${OFFSET_REPLICA}"
        log "         Proceeding anyway – monitor replication manually."
        break
    fi
    log "  Waiting... master=${OFFSET_MASTER}, replica=${OFFSET_REPLICA}"
    sleep 2
done

# ── 3. GlusterFS self-heal (runs automatically, just report status) ──────────
log "GlusterFS self-heal status:"
gluster volume heal worlds info 2>/dev/null || log "(gluster CLI not available here)"

# ── 4. Keepalived will automatically reclaim the VIP when Node A's priority
#       overtakes Node B's.  No manual action needed unless you want to force
#       an immediate failback.
log ""
log "=== Failback preparation complete ==="
log "Keepalived will automatically reclaim the VIP once Node A's health-check passes."
log "Monitor with: journalctl -u keepalived -f"

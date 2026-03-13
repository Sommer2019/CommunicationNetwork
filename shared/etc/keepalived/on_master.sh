#!/usr/bin/env bash
# =============================================================================
# on_master.sh – called by keepalived when this node acquires the VIP
# =============================================================================
# Order of operations (split-brain + session.lock safe):
#   1. Quorum check  – bail out if Witness says another node already runs
#   2. GlusterFS     – remount read-write
#   3. session.lock  – remove stale locks so Minecraft can open worlds
#   4. Redis         – promote replica to master if needed
#   5. Velocity      – start proxy
#   6. Minecraft     – start backend servers
# =============================================================================
set -euo pipefail
# shellcheck source=/dev/null
source /etc/minecraft-ha/config.env
LOG=/var/log/keepalived-minecraft.log
exec >> "$LOG" 2>&1
log() { echo "[$(date -Iseconds)] [on_master] $*"; }

log "This node is now MASTER."

# ── 1. Quorum check (split-brain prevention) ─────────────────────────────────
if ! /etc/keepalived/quorum-check.sh; then
    log "ERROR: Quorum denied – another node already holds the master lock."
    log "       Aborting activation to prevent split-brain / world corruption."
    exit 1
fi
log "Quorum granted."

# ── 2. GlusterFS – remount read-write ────────────────────────────────────────
if mountpoint -q "${WORLD_MOUNT}"; then
    mount -o remount,rw "${WORLD_MOUNT}" && \
        log "World volume remounted RW." || \
        log "WARNING: remount RW failed – check GlusterFS!"
else
    mount "${WORLD_MOUNT}" && \
        log "World volume mounted." || \
        log "WARNING: mount failed – check /etc/fstab!"
fi

# ── 3. session.lock – remove stale lock files ────────────────────────────────
# Minecraft writes session.lock into every world directory it opens.
# A stale lock left by a crashed process prevents the new master from starting.
LOCK_COUNT=$(find "${WORLD_MOUNT}" -name "session.lock" 2>/dev/null | wc -l)
if (( LOCK_COUNT > 0 )); then
    log "Found ${LOCK_COUNT} stale session.lock file(s) – removing:"
    find "${WORLD_MOUNT}" -name "session.lock" -print -delete
    log "All stale session.lock files removed."
else
    log "No stale session.lock files – world directories are clean."
fi

# ── 4. Redis – promote replica to master if Sentinel hasn't done it yet ───────
REDIS_ROLE=$(redis-cli -p "${REDIS_PORT}" -a "${REDIS_PASSWORD}" \
    INFO replication 2>&1 | grep "^role:" | tr -d '[:space:]' | cut -d: -f2 || true)
REDIS_ROLE="${REDIS_ROLE:-unknown}"
if [[ "$REDIS_ROLE" == "unknown" ]]; then
    log "WARNING: Could not determine Redis role – redis-cli connection failed. Check Redis service and password."
fi
if [[ "$REDIS_ROLE" != "master" ]]; then
    if redis-cli -p "${REDIS_PORT}" -a "${REDIS_PASSWORD}" REPLICAOF NO ONE >/dev/null 2>&1; then
        log "Redis promoted to master (was: ${REDIS_ROLE})."
    else
        log "WARNING: Redis promotion command failed – check /var/log/redis/redis.log"
    fi
else
    log "Redis already master."
fi

# ── 5. Start Velocity proxy ───────────────────────────────────────────────────
systemctl start velocity && log "Velocity started." || \
    log "WARNING: Velocity start failed – check 'journalctl -u velocity'."

# ── 6. Start Minecraft backends ───────────────────────────────────────────────
for SVC in minecraft@survival minecraft@lobby; do
    systemctl start "$SVC" && log "$SVC started." || \
        log "WARNING: $SVC start failed."
done

log "MASTER activation complete."

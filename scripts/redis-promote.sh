#!/usr/bin/env bash
# =============================================================================
# Redis promotion script
# =============================================================================
# Called during failover to promote the Redis replica on Node B to master.
# This is also called automatically by Redis Sentinel, but this script
# provides a manual override / confirmation step.
#
# Run on Node B AFTER keepalived has moved the VIP here.
# =============================================================================

set -euo pipefail
LOG=/var/log/minecraft-failover.log
exec >> "$LOG" 2>&1

REDIS_CLI="redis-cli"
REDIS_PORT=6379
REDIS_PASSWORD="CHANGE_ME_STRONG_REDIS_PASSWORD"

log() { echo "[$(date -Iseconds)] [redis-promote] $*"; }

log "Promoting Redis replica to master..."

# Check current replication role
ROLE=$($REDIS_CLI -p "$REDIS_PORT" -a "$REDIS_PASSWORD" INFO replication 2>/dev/null \
       | grep "^role:" | tr -d '[:space:]' | cut -d: -f2)

if [[ "$ROLE" == "master" ]]; then
    log "Redis is already master – no action needed."
    exit 0
fi

# Promote: break replication link
$REDIS_CLI -p "$REDIS_PORT" -a "$REDIS_PASSWORD" REPLICAOF NO ONE
log "REPLICAOF NO ONE issued."

# Verify
sleep 1
NEW_ROLE=$($REDIS_CLI -p "$REDIS_PORT" -a "$REDIS_PASSWORD" INFO replication 2>/dev/null \
           | grep "^role:" | tr -d '[:space:]' | cut -d: -f2)
if [[ "$NEW_ROLE" == "master" ]]; then
    log "Redis successfully promoted to master."
else
    log "ERROR: Redis role is still '${NEW_ROLE}' – investigate manually!"
    exit 1
fi

#!/usr/bin/env bash
# redis-promote.sh – manuell Redis-Replikat auf Node B zum Master befördern
# Wird automatisch von on_master.sh aufgerufen; kann auch manuell ausgeführt werden.
set -euo pipefail
# shellcheck source=/dev/null
source /etc/minecraft-ha/config.env
LOG=/var/log/minecraft-failover.log
exec >> "$LOG" 2>&1
log() { echo "[$(date -Iseconds)] [redis-promote] $*"; }

ROLE=$(redis-cli -p "${REDIS_PORT}" -a "${REDIS_PASSWORD}" \
    INFO replication 2>/dev/null | grep "^role:" | tr -d '[:space:]' | cut -d: -f2)

if [[ "$ROLE" == "master" ]]; then
    log "Redis ist bereits Master – keine Aktion nötig."; exit 0
fi

log "Beförderung von Redis (war: ${ROLE})..."
redis-cli -p "${REDIS_PORT}" -a "${REDIS_PASSWORD}" REPLICAOF NO ONE >/dev/null
sleep 1

NEW_ROLE=$(redis-cli -p "${REDIS_PORT}" -a "${REDIS_PASSWORD}" \
    INFO replication 2>/dev/null | grep "^role:" | tr -d '[:space:]' | cut -d: -f2)
if [[ "$NEW_ROLE" == "master" ]]; then
    log "Redis erfolgreich zum Master befördert."
else
    log "FEHLER: Redis-Rolle ist immer noch '${NEW_ROLE}' – bitte manuell prüfen!"; exit 1
fi

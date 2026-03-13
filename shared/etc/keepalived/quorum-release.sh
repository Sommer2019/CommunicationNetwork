#!/usr/bin/env bash
# quorum-release.sh – release the Witness master lock when stepping down.
set -euo pipefail
# shellcheck source=/dev/null
source /etc/minecraft-ha/config.env
LOG=/var/log/keepalived-minecraft.log
log() { echo "[$(date -Iseconds)] [quorum-release] $*" >> "$LOG"; }

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time 3 -X DELETE \
    "http://${WITNESS_IP}:${WITNESS_PORT}/vote?node=${HOSTNAME}" 2>/dev/null) || HTTP_CODE="000"

[[ "$HTTP_CODE" == "200" ]] && log "Lock released." || \
    log "WARNING: release failed (HTTP ${HTTP_CODE})."

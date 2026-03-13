#!/usr/bin/env bash
# =============================================================================
# Quorum lock release script
# =============================================================================
# Called from keepalived's on_backup.sh and on_fault.sh when a node steps down.
# Tells the Witness server to release the master lock so the other node can
# acquire it cleanly.
# =============================================================================

set -euo pipefail

WITNESS_HOST="witness.example.com"
WITNESS_PORT=8080
NODE_NAME="${HOSTNAME}"
TIMEOUT=3
LOG=/var/log/keepalived-minecraft.log

log() { echo "[$(date -Iseconds)] [quorum-release] $*" >> "$LOG"; }

log "Releasing quorum lock for node '${NODE_NAME}'..."

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time "$TIMEOUT" \
    -X DELETE \
    "http://${WITNESS_HOST}:${WITNESS_PORT}/vote?node=${NODE_NAME}" 2>/dev/null) \
    || HTTP_CODE="000"

if [[ "$HTTP_CODE" == "200" ]]; then
    log "Quorum lock released successfully."
else
    log "WARNING: Could not release quorum lock (HTTP ${HTTP_CODE}). Witness may be down."
fi

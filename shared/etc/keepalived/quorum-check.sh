#!/usr/bin/env bash
# =============================================================================
# quorum-check.sh – ask the Witness before taking/holding MASTER role
# =============================================================================
# Called by keepalived's vrrp_script chk_quorum every 2 s.
# Exit 0 = quorum granted → node may stay/become MASTER.
# Exit 1 = quorum denied  → keepalived priority drops → node steps down.
#
# Split-brain scenario prevented:
#   When Node A ↔ Node B link breaks but both still reach the internet:
#   • First caller → Witness grants lock.
#   • Second caller → Witness returns 409 → that node's priority drops → it
#     loses the VRRP election and its on_backup.sh stops its Minecraft stack.
# =============================================================================
set -euo pipefail
# shellcheck source=/dev/null
source /etc/minecraft-ha/config.env
LOG=/var/log/keepalived-minecraft.log
log() { echo "[$(date -Iseconds)] [quorum-check] $*" >> "$LOG"; }

NODE_NAME="${HOSTNAME}"
TIMEOUT=3
URL="http://${WITNESS_IP}:${WITNESS_PORT}/vote?node=${NODE_NAME}&role=master"

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time "$TIMEOUT" --retry 1 "$URL" 2>/dev/null) || HTTP_CODE="000"

case "$HTTP_CODE" in
    200) log "Quorum GRANTED."; exit 0 ;;
    409) log "Quorum DENIED – another node holds the lock."; exit 1 ;;
    *)
        log "WARNING: Witness unreachable (HTTP ${HTTP_CODE}). SAFE_MODE=${QUORUM_SAFE_MODE}."
        [[ "$QUORUM_SAFE_MODE" == "deny" ]] && exit 1 || exit 0
        ;;
esac

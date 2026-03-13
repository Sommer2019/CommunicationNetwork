#!/usr/bin/env bash
# =============================================================================
# Quorum check script – runs on Node A and Node B before taking MASTER role
# =============================================================================
# This script is called from:
#   1. keepalived's vrrp_script chk_quorum  (every 2 s – to HOLD the lock)
#   2. on_master.sh                          (once – to ACQUIRE the lock)
#
# It asks the Witness server for permission to be MASTER.
# Exit 0 = quorum granted (node may be / remain MASTER).
# Exit 1 = quorum denied  (another node holds the lock → step down).
#
# Why this prevents split-brain:
#   When Node A and Node B lose their private link but both still reach the
#   internet/Witness:
#     - Whichever node asks the Witness FIRST gets the lock.
#     - The second node gets HTTP 409 → its keepalived priority drops → it
#       transitions to BACKUP and stops its Minecraft stack.
#   If the Witness itself is unreachable (e.g. its network is down):
#     - SAFE_MODE determines behaviour:
#         "allow"  – both nodes may run (prefer availability over consistency)
#         "deny"   – both nodes stop   (prefer consistency over availability)
#       For a Minecraft HA network "allow" is usually the right default because
#       world corruption only happens if BOTH nodes write world files, and the
#       GlusterFS read-only mount on the BACKUP node already prevents that.
# =============================================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
WITNESS_HOST="witness.example.com"   # Witness server hostname or IP
WITNESS_PORT=8080
NODE_NAME="${HOSTNAME}"              # or set explicitly: NODE_NAME="node-a"
SAFE_MODE="allow"                    # "allow" or "deny" when witness unreachable
TIMEOUT=3                            # HTTP request timeout in seconds
LOG=/var/log/keepalived-minecraft.log

# ── Helpers ───────────────────────────────────────────────────────────────────
log() { echo "[$(date -Iseconds)] [quorum-check] $*" >> "$LOG"; }

witness_url="http://${WITNESS_HOST}:${WITNESS_PORT}/vote?node=${NODE_NAME}&role=master"

# ── Ask the Witness ───────────────────────────────────────────────────────────
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time "$TIMEOUT" \
    --retry 1 \
    "$witness_url" 2>/dev/null) || HTTP_CODE="000"

case "$HTTP_CODE" in
    200)
        log "Quorum GRANTED by witness."
        exit 0
        ;;
    409)
        log "Quorum DENIED by witness – another node already holds the master lock."
        exit 1
        ;;
    000|5*)
        # Witness unreachable
        log "WARNING: Witness unreachable (HTTP ${HTTP_CODE}). SAFE_MODE=${SAFE_MODE}."
        if [[ "$SAFE_MODE" == "deny" ]]; then
            exit 1
        else
            exit 0   # allow – rely on GlusterFS read-only protection
        fi
        ;;
    *)
        log "WARNING: Unexpected response from witness (HTTP ${HTTP_CODE}). Allowing."
        exit 0
        ;;
esac

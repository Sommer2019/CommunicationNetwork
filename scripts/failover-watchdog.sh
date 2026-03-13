#!/usr/bin/env bash
# =============================================================================
# Failover health-check daemon
# =============================================================================
# This daemon runs continuously on Node B and monitors Node A.
# It acts as a secondary safety net on top of keepalived:
#   - keepalived handles VIP failover (network layer, ~2 s)
#   - This script handles Minecraft service activation on Node B (~2–3 s after
#     keepalived has already moved the VIP)
#
# USAGE:
#   Start as a systemd service (see: scripts/minecraft-failover.service)
#   Or run manually: nohup ./failover-watchdog.sh &
#
# LOGIC:
#   Every CHECK_INTERVAL seconds this script checks if Node A's Minecraft port
#   is reachable.  After FAILURE_THRESHOLD consecutive failures it concludes
#   that Node A is down and activates the local (Node B) Minecraft stack –
#   but ONLY if this node currently holds the VIP (i.e. keepalived has already
#   moved it here).
# =============================================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
NODE_A_IP="192.168.1.101"
MINECRAFT_PORT=25565
CHECK_INTERVAL=1          # seconds between each health-check
FAILURE_THRESHOLD=3       # consecutive failures before declaring Node A dead
VIP="203.0.113.10"
LOG=/var/log/minecraft-failover.log

exec >> "$LOG" 2>&1

# ── Helpers ───────────────────────────────────────────────────────────────────
log() { echo "[$(date -Iseconds)] $*"; }

node_a_alive() {
    # TCP connection test; times out after 1 second
    (echo >/dev/tcp/"$NODE_A_IP"/"$MINECRAFT_PORT") >/dev/null 2>&1
}

this_node_holds_vip() {
    ip addr show | grep -q "$VIP"
}

activate_local_stack() {
    log "ACTIVATING local Minecraft stack (Node B → MASTER)."

    # 1. Ensure world volume is mounted read-write
    /etc/keepalived/on_master.sh

    log "Local stack activation complete."
}

# ── Main loop ─────────────────────────────────────────────────────────────────
log "Failover watchdog started. Monitoring Node A at ${NODE_A_IP}:${MINECRAFT_PORT}."

failure_count=0
node_a_was_alive=true

while true; do
    if node_a_alive; then
        if ! $node_a_was_alive; then
            log "Node A is back online – resetting failure counter."
        fi
        failure_count=0
        node_a_was_alive=true
    else
        failure_count=$(( failure_count + 1 ))
        log "Node A unreachable (attempt ${failure_count}/${FAILURE_THRESHOLD})."
        node_a_was_alive=false

        if (( failure_count >= FAILURE_THRESHOLD )); then
            if this_node_holds_vip; then
                log "FAILOVER triggered: Node A appears dead and this node holds the VIP."
                activate_local_stack
                # Reset counter – we've acted; wait for manual failback
                failure_count=0
            else
                log "Node A appears dead but this node does NOT hold the VIP yet."
                log "Keepalived should move the VIP shortly – waiting..."
            fi
        fi
    fi

    sleep "$CHECK_INTERVAL"
done

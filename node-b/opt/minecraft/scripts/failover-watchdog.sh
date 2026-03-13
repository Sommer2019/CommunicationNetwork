#!/usr/bin/env bash
# =============================================================================
# failover-watchdog.sh – runs continuously on Node B
# =============================================================================
# Secondary safety net on top of keepalived.
# keepalived moves the VIP (~2 s); this daemon activates the Minecraft stack
# as soon as this node holds the VIP.
# =============================================================================
set -euo pipefail
# shellcheck source=/dev/null
source /etc/minecraft-ha/config.env
LOG=/var/log/minecraft-failover.log
exec >> "$LOG" 2>&1
log() { echo "[$(date -Iseconds)] [watchdog] $*"; }

CHECK_INTERVAL=1
FAILURE_THRESHOLD=3

this_node_holds_vip() { ip addr show | grep -qF "${FLOATING_IP}"; }
node_a_alive()        { nc -zw2 "${NODE_A_IP}" "${PROXY_PORT}" >/dev/null 2>&1; }

log "Watchdog gestartet – überwache Node A (${NODE_A_IP}:${PROXY_PORT})."

fail=0
was_alive=true

while true; do
    if node_a_alive; then
        $was_alive || log "Node A ist wieder erreichbar – Zähler zurückgesetzt."
        fail=0; was_alive=true
    else
        fail=$(( fail + 1 ))
        log "Node A nicht erreichbar (Versuch ${fail}/${FAILURE_THRESHOLD})."
        was_alive=false

        if (( fail >= FAILURE_THRESHOLD )); then
            if this_node_holds_vip; then
                log "FAILOVER: Node A ausgefallen, diese Node hält die VIP → Stack aktivieren."
                /etc/keepalived/on_master.sh
                fail=0
            else
                log "Node A ausgefallen, aber VIP noch nicht hier – keepalived sollte sie gleich verschieben."
            fi
        fi
    fi
    sleep "$CHECK_INTERVAL"
done

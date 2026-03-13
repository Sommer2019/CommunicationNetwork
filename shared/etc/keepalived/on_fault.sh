#!/usr/bin/env bash
# on_fault.sh – called by keepalived when health-check enters FAULT state.
# Identical behaviour to on_backup: stop everything and go read-only.
set -euo pipefail
# shellcheck source=/dev/null
source /etc/minecraft-ha/config.env
LOG=/var/log/keepalived-minecraft.log
exec >> "$LOG" 2>&1
log() { echo "[$(date -Iseconds)] [on_fault] $*"; }

log "Health-check FAULT – stopping Minecraft stack."

for SVC in minecraft@survival minecraft@lobby velocity; do
    systemctl stop "$SVC" 2>/dev/null && log "$SVC stopped." || true
done

/etc/keepalived/quorum-release.sh 2>/dev/null || true

if mountpoint -q "${WORLD_MOUNT}"; then
    mount -o remount,ro "${WORLD_MOUNT}" 2>/dev/null && \
        log "World volume remounted RO." || true
fi

log "FAULT handler complete."

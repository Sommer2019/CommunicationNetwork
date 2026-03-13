#!/usr/bin/env bash
# =============================================================================
# Called by keepalived when the health-check enters FAULT state on this node.
# Identical to on_backup – stop everything and go read-only.
# =============================================================================

set -euo pipefail
LOG=/var/log/keepalived-minecraft.log
exec >> "$LOG" 2>&1

echo "[$(date -Iseconds)] [on_fault] Health-check FAULT – stopping Minecraft stack."

for SVC in minecraft-survival minecraft-lobby velocity; do
    systemctl stop "$SVC" 2>/dev/null && \
        echo "[on_fault] $SVC stopped." || true
done

WORLD_MOUNT=/mnt/minecraft/worlds
if mountpoint -q "$WORLD_MOUNT"; then
    mount -o remount,ro "$WORLD_MOUNT" 2>/dev/null && \
        echo "[on_fault] World volume remounted RO." || true
fi

echo "[$(date -Iseconds)] [on_fault] Done."

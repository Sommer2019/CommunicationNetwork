#!/usr/bin/env bash
# =============================================================================
# Called by keepalived when THIS node transitions to BACKUP
# (i.e. it loses the VIP – either at start-up or after a failback)
# =============================================================================
# This script makes sure that the Minecraft servers on the standby node are
# NOT writing to the world files simultaneously with the master node.
# Failing to do this is the #1 cause of world corruption in HA setups.
#
# Place at: /etc/keepalived/on_backup.sh   (chmod +x)
# =============================================================================

set -euo pipefail
LOG=/var/log/keepalived-minecraft.log
exec >> "$LOG" 2>&1

echo "[$(date -Iseconds)] [on_backup] This node is now BACKUP – stopping Minecraft stack."

# ── 1. Stop Minecraft server(s) first (graceful save) ───────────────────────
for SVC in minecraft-survival minecraft-lobby; do
    systemctl stop "$SVC" && \
        echo "[on_backup] $SVC stopped." || \
        echo "[on_backup] WARNING: $SVC stop failed."
done

# ── 2. Stop Velocity proxy ───────────────────────────────────────────────────
systemctl stop velocity && \
    echo "[on_backup] Velocity stopped." || \
    echo "[on_backup] WARNING: Velocity stop failed."

# ── 3. Remount world volume read-only to prevent accidental writes ───────────
WORLD_MOUNT=/mnt/minecraft/worlds
if mountpoint -q "$WORLD_MOUNT"; then
    mount -o remount,ro "$WORLD_MOUNT" && \
        echo "[on_backup] World volume remounted RO." || \
        echo "[on_backup] WARNING: remount RO failed."
fi

echo "[$(date -Iseconds)] [on_backup] Done."

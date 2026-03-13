#!/usr/bin/env bash
# =============================================================================
# Called by keepalived when THIS node becomes MASTER (i.e. it acquires the VIP)
# =============================================================================
# This script is the "hot-standby activation" step:
#   1. Ensure the GlusterFS world volume is mounted read-write.
#   2. Remove any stale session.lock files so Minecraft can start cleanly.
#   3. Start (or restart) the Minecraft / Velocity process.
#
# Place at: /etc/keepalived/on_master.sh   (chmod +x)
# =============================================================================

set -euo pipefail
LOG=/var/log/keepalived-minecraft.log
exec >> "$LOG" 2>&1

echo "[$(date -Iseconds)] [on_master] This node is now MASTER – starting Minecraft stack."

# ── 1. Mount world volume read-write (GlusterFS) ────────────────────────────
WORLD_MOUNT=/mnt/minecraft/worlds
if mountpoint -q "$WORLD_MOUNT"; then
    # Remount read-write in case it was previously mounted read-only
    mount -o remount,rw "$WORLD_MOUNT" && \
        echo "[on_master] World volume remounted RW." || \
        echo "[on_master] WARNING: remount RW failed – check GlusterFS!"
else
    mount "$WORLD_MOUNT" && \
        echo "[on_master] World volume mounted." || \
        echo "[on_master] WARNING: mount failed – check /etc/fstab!"
fi

# ── 2. Remove stale session.lock files ──────────────────────────────────────
find "$WORLD_MOUNT" -name "session.lock" -print -delete && \
    echo "[on_master] Stale session.lock files removed."

# ── 3. Start Velocity proxy (systemd) ───────────────────────────────────────
systemctl start velocity && \
    echo "[on_master] Velocity started." || \
    echo "[on_master] WARNING: failed to start Velocity – check 'journalctl -u velocity'."

# ── 4. Start Minecraft server(s) (systemd) ──────────────────────────────────
# Adjust service names to match your setup (e.g. minecraft@survival, minecraft@creative)
for SVC in minecraft-survival minecraft-lobby; do
    systemctl start "$SVC" && \
        echo "[on_master] $SVC started." || \
        echo "[on_master] WARNING: failed to start $SVC."
done

echo "[$(date -Iseconds)] [on_master] Done."

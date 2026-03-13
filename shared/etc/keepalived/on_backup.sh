#!/usr/bin/env bash
# =============================================================================
# on_backup.sh – called by keepalived when this node loses the VIP
# =============================================================================
# CRITICAL: Stop Minecraft BEFORE remounting the world volume read-only.
# Failing to do this is the #1 cause of world corruption in HA setups.
# =============================================================================
set -euo pipefail
# shellcheck source=/dev/null
source /etc/minecraft-ha/config.env
LOG=/var/log/keepalived-minecraft.log
exec >> "$LOG" 2>&1
log() { echo "[$(date -Iseconds)] [on_backup] $*"; }

log "This node is now BACKUP – stopping Minecraft stack."

# ── 1. Stop Minecraft backends (triggers save-all) ───────────────────────────
for SVC in minecraft@survival minecraft@lobby; do
    systemctl stop "$SVC" 2>/dev/null && log "$SVC stopped." || \
        log "WARNING: $SVC stop failed (may not have been running)."
done

# ── 2. Stop Velocity proxy ────────────────────────────────────────────────────
systemctl stop velocity 2>/dev/null && log "Velocity stopped." || \
    log "WARNING: Velocity stop failed."

# ── 3. Release quorum lock so the other node can acquire it ──────────────────
/etc/keepalived/quorum-release.sh || log "WARNING: quorum release failed."

# ── 4. Remount world volume read-only (prevents accidental writes) ────────────
if mountpoint -q "${WORLD_MOUNT}"; then
    mount -o remount,ro "${WORLD_MOUNT}" && \
        log "World volume remounted RO." || \
        log "WARNING: remount RO failed."
fi

log "BACKUP mode active."

#!/usr/bin/env bash
# =============================================================================
# session.lock guard
# =============================================================================
# Minecraft writes a session.lock file into every world directory it opens.
# If both nodes have a running Minecraft process pointing at the same world
# directory (GlusterFS), both will try to lock the file, causing immediate
# world corruption.
#
# This script:
#   1. Checks for active session.lock files.
#   2. Verifies that only the MASTER node (VIP holder) has them open.
#   3. Exits with error code 1 if a session.lock is found on a BACKUP node,
#      so that the startup sequence is aborted.
#
# Call from on_master.sh BEFORE starting Minecraft.
# =============================================================================

set -euo pipefail

WORLD_MOUNT=/mnt/minecraft/worlds
VIP="203.0.113.10"

# ── Is this node currently the VIP holder (MASTER)? ─────────────────────────
if ! ip addr show | grep -q "$VIP"; then
    echo "[session-lock-guard] ERROR: This node does NOT hold the VIP ($VIP)."
    echo "                     Refusing to start Minecraft to prevent world corruption."
    exit 1
fi

# ── Remove stale lock files (left by a previously crashed process) ───────────
STALE_LOCKS=$(find "$WORLD_MOUNT" -name "session.lock" 2>/dev/null)
if [[ -n "$STALE_LOCKS" ]]; then
    echo "[session-lock-guard] Found stale session.lock files – removing:"
    echo "$STALE_LOCKS"
    find "$WORLD_MOUNT" -name "session.lock" -delete
    echo "[session-lock-guard] Done."
else
    echo "[session-lock-guard] No stale session.lock files found."
fi

echo "[session-lock-guard] Guard passed – safe to start Minecraft."
exit 0

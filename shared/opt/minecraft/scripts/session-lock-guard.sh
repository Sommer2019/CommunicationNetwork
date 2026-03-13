#!/usr/bin/env bash
# =============================================================================
# session-lock-guard.sh – ExecStartPre for minecraft@.service
# =============================================================================
# Minecraft writes a "session.lock" file into every world directory it opens.
# If two server processes write to the same world simultaneously (split-brain),
# the world gets corrupted within minutes.
#
# This script is called by systemd BEFORE the Minecraft JVM starts.
# It performs three checks:
#   1. VIP ownership  – is this node the current MASTER?
#      If not: abort startup (exit 1) so the BACKUP never touches world files.
#   2. World mount    – is the GlusterFS volume mounted read-write?
#      If not: abort startup (the volume may still be in RO backup mode).
#   3. session.lock   – remove any stale lock files left by a previous crash.
#      A stale lock would cause Minecraft to refuse starting with
#      "The world is already opened by another instance of Minecraft".
#
# Arguments:
#   $1  server-instance name (e.g. "survival", "lobby") – used to locate the
#       world directory under WORLD_MOUNT.
# =============================================================================
set -euo pipefail
# shellcheck source=/dev/null
source /etc/minecraft-ha/config.env

INSTANCE="${1:?Error: Instance name required (e.g. 'survival'). Usage: $0 <instance>}"
WORLD_DIR="${WORLD_MOUNT}/${INSTANCE}"
LOG=/var/log/keepalived-minecraft.log
log() { echo "[$(date -Iseconds)] [session-lock-guard:${INSTANCE}] $*" | tee -a "$LOG"; }

log "Pre-start check for Minecraft instance '${INSTANCE}'."

# ── 1. VIP ownership check ────────────────────────────────────────────────────
if ! ip addr show | grep -qF "${FLOATING_IP}"; then
    log "ABORT: This node does NOT hold the Floating-IP (${FLOATING_IP})."
    log "       This node is still BACKUP – refusing to start Minecraft to"
    log "       prevent split-brain world corruption."
    exit 1
fi
log "VIP check passed – this node holds ${FLOATING_IP}."

# ── 2. World mount read-write check ──────────────────────────────────────────
if ! mountpoint -q "${WORLD_MOUNT}"; then
    log "ABORT: World volume not mounted at ${WORLD_MOUNT}."
    log "       Run: mount ${WORLD_MOUNT}"
    exit 1
fi
# Verify the mount is read-write (not read-only, which is BACKUP mode)
if ! touch "${WORLD_MOUNT}/.rw-test" 2>/dev/null; then
    log "ABORT: World volume at ${WORLD_MOUNT} is mounted READ-ONLY."
    log "       Run: mount -o remount,rw ${WORLD_MOUNT}"
    exit 1
fi
rm -f "${WORLD_MOUNT}/.rw-test"
log "World volume is mounted RW – OK."

# ── 3. session.lock cleanup ───────────────────────────────────────────────────
# Search for session.lock in the instance's world folder (all dimensions).
if [[ -d "$WORLD_DIR" ]]; then
    mapfile -t STALE_LOCKS < <(find "$WORLD_DIR" -name "session.lock" 2>/dev/null)
    if (( ${#STALE_LOCKS[@]} > 0 )); then
        log "Found ${#STALE_LOCKS[@]} stale session.lock file(s) – removing:"
        for f in "${STALE_LOCKS[@]}"; do
            log "  Removing: $f"
            rm -f "$f"
        done
        log "All stale session.lock files removed."
    else
        log "No stale session.lock files – world directory is clean."
    fi
else
    log "World directory '${WORLD_DIR}' does not exist yet – will be created by Minecraft on first start."
fi

log "All pre-start checks passed – Minecraft may start."
exit 0

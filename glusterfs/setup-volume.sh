#!/usr/bin/env bash
# =============================================================================
# GlusterFS – Initial setup script for the replicated world volume
# =============================================================================
# Run once on Node A AFTER installing GlusterFS on both nodes.
# Prerequisites:
#   apt install glusterfs-server   (on both nodes)
#   systemctl enable --now glusterd  (on both nodes)
#
# Architecture:
#   - Replicated volume (replica 2) across Node A and Node B
#   - Each node keeps a full copy of all world files
#   - Writes go to both bricks synchronously → zero data loss on failover
#   - The active (MASTER) node mounts read-write; the BACKUP mounts read-only
#
# Run this script ONLY ON NODE A after glusterd is running on both nodes.
# =============================================================================

set -euo pipefail

NODE_A_IP="192.168.1.101"
NODE_B_IP="192.168.1.102"
VOLUME_NAME="worlds"
BRICK_DIR="/data/glusterfs/worlds/brick"
MOUNT_DIR="/mnt/minecraft/worlds"

echo "==> Peering with Node B..."
gluster peer probe "$NODE_B_IP"
sleep 3

echo "==> Creating brick directories on both nodes..."
ssh "$NODE_B_IP" "mkdir -p ${BRICK_DIR}"
mkdir -p "$BRICK_DIR"

echo "==> Creating replicated GlusterFS volume '${VOLUME_NAME}'..."
gluster volume create "$VOLUME_NAME" \
    replica 2 \
    transport tcp \
    "${NODE_A_IP}:${BRICK_DIR}" \
    "${NODE_B_IP}:${BRICK_DIR}" \
    force

echo "==> Enabling self-heal and setting performance options..."
gluster volume set "$VOLUME_NAME" cluster.self-heal-daemon enable
gluster volume set "$VOLUME_NAME" cluster.heal-timeout 5
# Disable client-side caching so Minecraft's region file writes are visible
# immediately on both nodes (avoids stale-read race conditions).
gluster volume set "$VOLUME_NAME" performance.cache-size 0
gluster volume set "$VOLUME_NAME" performance.write-behind off
gluster volume set "$VOLUME_NAME" performance.read-ahead off
gluster volume set "$VOLUME_NAME" performance.io-cache off

echo "==> Starting volume..."
gluster volume start "$VOLUME_NAME"

echo "==> Mounting volume on Node A (read-write, this is the MASTER)..."
mkdir -p "$MOUNT_DIR"
mount -t glusterfs "localhost:/${VOLUME_NAME}" "$MOUNT_DIR"

# Persist the mount in fstab
FSTAB_ENTRY="localhost:/${VOLUME_NAME}  ${MOUNT_DIR}  glusterfs  defaults,_netdev,log-level=WARNING,log-file=/var/log/gluster-client.log  0 0"
if ! grep -qF "$VOLUME_NAME" /etc/fstab; then
    echo "$FSTAB_ENTRY" >> /etc/fstab
    echo "==> fstab entry added."
fi

echo ""
echo "==> GlusterFS volume '${VOLUME_NAME}' is ready."
echo "    Mount point: ${MOUNT_DIR}"
echo ""
echo "    Next steps:"
echo "    1. On Node B, add the same fstab entry and mount read-only:"
echo "       mount -t glusterfs -o ro localhost:/${VOLUME_NAME} ${MOUNT_DIR}"
echo "    2. Copy existing world files into ${MOUNT_DIR}/ on Node A."
echo "    3. Point your Minecraft server's level-dir to ${MOUNT_DIR}/worlds/<name>."

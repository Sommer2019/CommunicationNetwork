#!/usr/bin/env bash
# =============================================================================
# glusterfs-setup.sh – one-time GlusterFS volume creation
# =============================================================================
# Run ONCE on Node A after glusterd is running on BOTH nodes.
# Prerequisites:
#   apt install glusterfs-server   (both nodes)
#   systemctl enable --now glusterd (both nodes)
# =============================================================================
set -euo pipefail
# shellcheck source=/dev/null
source /etc/minecraft-ha/config.env

BRICK_DIR="/data/glusterfs/${GLUSTER_VOLUME}/brick"

echo "==> Peering with Node B (${NODE_B_IP})..."
gluster peer probe "${NODE_B_IP}"
sleep 3

echo "==> Creating brick directories..."
ssh "${NODE_B_IP}" "mkdir -p ${BRICK_DIR}"
mkdir -p "$BRICK_DIR"

echo "==> Creating replicated volume '${GLUSTER_VOLUME}'..."
gluster volume create "${GLUSTER_VOLUME}" \
    replica 2 transport tcp \
    "${NODE_A_IP}:${BRICK_DIR}" \
    "${NODE_B_IP}:${BRICK_DIR}" \
    force

echo "==> Tuning volume options..."
gluster volume set "${GLUSTER_VOLUME}" cluster.self-heal-daemon enable
gluster volume set "${GLUSTER_VOLUME}" cluster.heal-timeout 5
# Disable all caching – region file writes must be immediately visible on both nodes
gluster volume set "${GLUSTER_VOLUME}" performance.cache-size 0
gluster volume set "${GLUSTER_VOLUME}" performance.write-behind off
gluster volume set "${GLUSTER_VOLUME}" performance.read-ahead off
gluster volume set "${GLUSTER_VOLUME}" performance.io-cache off

echo "==> Starting volume..."
gluster volume start "${GLUSTER_VOLUME}"

echo "==> Mounting read-write on Node A (MASTER)..."
mkdir -p "${WORLD_MOUNT}"
mount -t glusterfs "localhost:/${GLUSTER_VOLUME}" "${WORLD_MOUNT}"

FSTAB="localhost:/${GLUSTER_VOLUME}  ${WORLD_MOUNT}  glusterfs  defaults,_netdev,log-level=WARNING,log-file=/var/log/gluster-client.log  0 0"
# Note: log-file writes GlusterFS client events to a dedicated file instead of
# flooding syslog. Adjust the path or replace with 'log-level=ERROR' if you
# prefer syslog-only output.
grep -qF "${GLUSTER_VOLUME}" /etc/fstab || echo "$FSTAB" >> /etc/fstab
echo "==> fstab entry added on Node A."

echo ""
echo "Next: On Node B, add the same fstab line and mount read-only:"
echo "  echo '${FSTAB/defaults/defaults,ro}' >> /etc/fstab"
echo "  mount ${WORLD_MOUNT}"
echo ""
echo "Then copy world files into ${WORLD_MOUNT}/ and point server.properties"
echo "level-path to \${WORLD_MOUNT}/<world-name>."

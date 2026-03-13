#!/usr/bin/env bash
# =============================================================================
# install.sh – Node B  (run as root on the target machine)
# =============================================================================
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Fehler: Bitte als root ausführen (sudo ./install.sh)"; exit 1; }

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "=== Node B – Installation startet ==="

mkdir -p /etc/minecraft-ha
cp "${DEPLOY_DIR}/etc/minecraft-ha/config.env" /etc/minecraft-ha/config.env
chmod 600 /etc/minecraft-ha/config.env
echo "[OK] config.env → /etc/minecraft-ha/config.env"

mkdir -p /etc/keepalived
cp "${DEPLOY_DIR}/etc/keepalived/"* /etc/keepalived/
chmod +x /etc/keepalived/*.sh
echo "[OK] keepalived-Dateien → /etc/keepalived/"

mkdir -p /etc/redis
cp "${DEPLOY_DIR}/etc/redis/redis.conf"    /etc/redis/redis.conf
cp "${DEPLOY_DIR}/etc/redis/sentinel.conf" /etc/redis/sentinel.conf
echo "[OK] Redis-Konfiguration → /etc/redis/"

mkdir -p /opt/velocity
cp "${DEPLOY_DIR}/opt/velocity/velocity.toml"     /opt/velocity/velocity.toml
cp "${DEPLOY_DIR}/opt/velocity/forwarding.secret" /opt/velocity/forwarding.secret
chmod 600 /opt/velocity/forwarding.secret
echo "[OK] Velocity-Konfiguration → /opt/velocity/"

mkdir -p /opt/minecraft/plugins/HuskSync
cp "${DEPLOY_DIR}/opt/minecraft/plugins/HuskSync/config.yml" \
    /opt/minecraft/plugins/HuskSync/config.yml
echo "[OK] HuskSync config → /opt/minecraft/plugins/HuskSync/"

mkdir -p /opt/minecraft/scripts
cp "${DEPLOY_DIR}/opt/minecraft/scripts/"* /opt/minecraft/scripts/
chmod +x /opt/minecraft/scripts/*.sh
echo "[OK] Minecraft-Skripte → /opt/minecraft/scripts/"

cp "${DEPLOY_DIR}/etc/systemd/system/"* /etc/systemd/system/
systemctl daemon-reload
echo "[OK] Systemd-Units installiert."

systemctl enable keepalived
systemctl enable redis-server
systemctl enable redis-sentinel
systemctl enable minecraft-failover
echo "[OK] Dienste aktiviert."

systemctl restart keepalived
systemctl restart redis-server
systemctl restart redis-sentinel
systemctl enable --now minecraft-failover
echo "[OK] Dienste gestartet."

echo ""
echo "=== Node B – Installation abgeschlossen ==="
echo ""
echo "Nächste Schritte:"
echo "  1. Velocity-JAR herunterladen → /opt/velocity/velocity.jar"
echo "  2. GlusterFS-Weltvolume einbinden (read-only bis Failover):"
echo "     mount -t glusterfs -o ro localhost:/worlds /mnt/minecraft/worlds"
echo "  3. Teste Replikation: redis-cli INFO replication (master_link_status: up)"
echo "  4. Teste Watchdog:    journalctl -u minecraft-failover -f"

#!/usr/bin/env bash
# =============================================================================
# install.sh – Node A  (run as root on the target machine)
# =============================================================================
# Kopiert alle Dateien an die richtigen Systempfade und aktiviert die Dienste.
# Dieses Skript befindet sich im generierten dist/node-a/ Verzeichnis.
# =============================================================================
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Fehler: Bitte als root ausführen (sudo ./install.sh)"; exit 1; }

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "=== Node A – Installation startet ==="
echo "    Quellverzeichnis: ${DEPLOY_DIR}"

# ── config.env an Systempfad kopieren (von hier lesen alle Skripte zur Laufzeit)
mkdir -p /etc/minecraft-ha
cp "${DEPLOY_DIR}/etc/minecraft-ha/config.env" /etc/minecraft-ha/config.env
chmod 600 /etc/minecraft-ha/config.env
echo "[OK] config.env → /etc/minecraft-ha/config.env"

# ── Keepalived-Skripte und Konfiguration ─────────────────────────────────────
mkdir -p /etc/keepalived
cp "${DEPLOY_DIR}/etc/keepalived/"* /etc/keepalived/
chmod +x /etc/keepalived/*.sh
echo "[OK] keepalived-Dateien → /etc/keepalived/"

# ── Redis ─────────────────────────────────────────────────────────────────────
mkdir -p /etc/redis
cp "${DEPLOY_DIR}/etc/redis/redis.conf"    /etc/redis/redis.conf
cp "${DEPLOY_DIR}/etc/redis/sentinel.conf" /etc/redis/sentinel.conf
echo "[OK] Redis-Konfiguration → /etc/redis/"

# ── Velocity ──────────────────────────────────────────────────────────────────
mkdir -p /opt/velocity
cp "${DEPLOY_DIR}/opt/velocity/velocity.toml"     /opt/velocity/velocity.toml
cp "${DEPLOY_DIR}/opt/velocity/forwarding.secret" /opt/velocity/forwarding.secret
chmod 600 /opt/velocity/forwarding.secret
echo "[OK] Velocity-Konfiguration → /opt/velocity/"

# ── HuskSync-Plugin-Konfiguration ─────────────────────────────────────────────
mkdir -p /opt/minecraft/plugins/HuskSync
cp "${DEPLOY_DIR}/opt/minecraft/plugins/HuskSync/config.yml" \
    /opt/minecraft/plugins/HuskSync/config.yml
echo "[OK] HuskSync config → /opt/minecraft/plugins/HuskSync/"

# ── Minecraft-Skripte ─────────────────────────────────────────────────────────
mkdir -p /opt/minecraft/scripts
cp "${DEPLOY_DIR}/opt/minecraft/scripts/"* /opt/minecraft/scripts/
chmod +x /opt/minecraft/scripts/*.sh
echo "[OK] Minecraft-Skripte → /opt/minecraft/scripts/"

# ── Systemd-Units ─────────────────────────────────────────────────────────────
cp "${DEPLOY_DIR}/etc/systemd/system/"* /etc/systemd/system/
systemctl daemon-reload
echo "[OK] Systemd-Units installiert und neu geladen."

# ── Dienste aktivieren (aber NICHT starten – keepalived übernimmt das) ────────
systemctl enable keepalived
systemctl enable redis-server
systemctl enable redis-sentinel
echo "[OK] keepalived, redis-server, redis-sentinel aktiviert."

# ── Keepalived starten ────────────────────────────────────────────────────────
systemctl restart keepalived
echo "[OK] keepalived gestartet."

# ── Redis starten ─────────────────────────────────────────────────────────────
systemctl restart redis-server
systemctl restart redis-sentinel
echo "[OK] Redis gestartet."

echo ""
echo "=== Node A – Installation abgeschlossen ==="
echo ""
echo "Nächste Schritte:"
echo "  1. Velocity-JAR herunterladen: https://papermc.io/downloads/velocity"
echo "     → /opt/velocity/velocity.jar"
echo "  2. Paper-Backends einrichten – Ports entnehmen aus /etc/minecraft-ha/config.env (SURVIVAL_PORT, LOBBY_PORT)"
echo "  3. HuskSync-Plugin in jeden Backend-Server-Plugin-Ordner legen"
echo "  4. GlusterFS-Volume einrichten (einmalig): /opt/minecraft/scripts/glusterfs-setup.sh"
echo "  5. Teste: systemctl status keepalived"

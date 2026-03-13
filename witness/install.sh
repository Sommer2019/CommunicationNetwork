#!/usr/bin/env bash
# =============================================================================
# install.sh – Witness-Server  (run as root)
# =============================================================================
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Fehler: Bitte als root ausführen (sudo ./install.sh)"; exit 1; }

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "=== Witness – Installation startet ==="

# Voraussetzungen prüfen
command -v socat >/dev/null 2>&1 || { apt-get install -y socat; echo "[OK] socat installiert."; }

mkdir -p /etc/minecraft-ha
cp "${DEPLOY_DIR}/etc/minecraft-ha/config.env" /etc/minecraft-ha/config.env
chmod 600 /etc/minecraft-ha/config.env
echo "[OK] config.env → /etc/minecraft-ha/config.env"

mkdir -p /opt/witness
cp "${DEPLOY_DIR}/opt/witness/witness-server.sh" /opt/witness/witness-server.sh
chmod +x /opt/witness/witness-server.sh
echo "[OK] witness-server.sh → /opt/witness/"

cp "${DEPLOY_DIR}/etc/systemd/system/minecraft-witness.service" \
    /etc/systemd/system/minecraft-witness.service
systemctl daemon-reload
systemctl enable --now minecraft-witness
echo "[OK] minecraft-witness-Dienst aktiviert und gestartet."

echo ""
echo "=== Witness – Installation abgeschlossen ==="
echo "Prüfe den Dienst: systemctl status minecraft-witness"
echo "Health-Check:     curl http://localhost:$(grep WITNESS_PORT /etc/minecraft-ha/config.env | cut -d= -f2 | tr -d '\"')/health"

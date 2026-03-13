# Gesamtanleitung – Minecraft High-Availability-Netzwerk

Diese Anleitung beschreibt den vollständigen Aufbau eines Minecraft-HA-Netzwerks mit automatischem Failover auf zwei physisch getrennten Linux-Servern und einem Quorum-Zeugen (Witness).

---

## Übersicht der Architektur

```
Spieler
  │  (verbinden sich mit der Floating-IP @@FLOATING_IP@@:@@PROXY_PORT@@)
  ▼
┌─────────────────────────────────────────────────────────┐
│  Keepalived (VRRP) – Floating-IP / VIP                  │
│  Node A (@@NODE_A_IP@@) ←→ Node B (@@NODE_B_IP@@)       │
└──────────────────────┬──────────────────────────────────┘
                       │
           ┌───────────▼───────────┐
           │  Velocity Proxy       │  ← Fallback: Spieler landen auf Lobby,
           │  Port @@PROXY_PORT@@  │    kein Disconnect beim Failover
           └───────────┬───────────┘
                       │
          ┌────────────┴────────────┐
          ▼                         ▼
  ┌──────────────┐         ┌──────────────┐
  │  Survival    │         │  Lobby       │
  │  :@@SURVIVAL_PORT@@    │  :@@LOBBY_PORT@@
  └──────────────┘         └──────────────┘
          │
          ▼
  ┌──────────────────────┐
  │  GlusterFS-Volumen   │  Echtzeit-Replikation der Weltdateien
  │  @@WORLD_MOUNT@@     │  MASTER: read-write | BACKUP: read-only
  └──────────────────────┘

  ┌──────────────────────┐
  │  Redis Master→Replik │  Spieler-Inventar, Position, Session (HuskSync)
  │  + Redis Sentinel    │
  └──────────────────────┘

  ┌──────────────────────┐
  │  Quorum-Witness      │  Entscheidet bei Split-Brain, wer Master ist
  │  @@WITNESS_IP@@      │
  └──────────────────────┘
```

**Failover-Ablauf:** Node A fällt aus → Keepalived erkennt es in ~2 s → VIP wechselt zu Node B → `on_master.sh` startet auf Node B → Spieler werden transparent weitergeleitet → **≤ 5 Sekunden Ausfallzeit**.

---

## Schritt 0 – Voraussetzungen

Auf **allen** Maschinen (Node A, Node B, Witness):

```bash
# Systempakete aktualisieren
apt update && apt upgrade -y
```

| Paket | Node A | Node B | Witness |
|-------|--------|--------|---------|
| `keepalived` | ✓ | ✓ | – |
| `redis-server` | ✓ | ✓ | – |
| `glusterfs-server` | ✓ | ✓ | – |
| `socat` | – | – | ✓ |
| `curl` | ✓ | ✓ | – |
| Java 17+ | ✓ | ✓ | – |

```bash
# Node A + Node B
apt install -y keepalived redis-server glusterfs-server curl

# Witness
apt install -y socat
```

---

## Schritt 1 – config.env bearbeiten (einmalig)

```bash
# Repository klonen
git clone https://github.com/Sommer2019/CommunicationNetwork.git
cd CommunicationNetwork

# Die EINZIGE Datei, die du bearbeitest:
nano config.env
```

**Mindeständerungen in `config.env`:**

| Variable | Bedeutung | Beispiel |
|----------|-----------|---------|
| `NODE_A_IP` | Physische IP Node A | `192.168.1.101` |
| `NODE_B_IP` | Physische IP Node B | `192.168.1.102` |
| `WITNESS_IP` | IP des Witness-Servers | `203.0.113.20` |
| `FLOATING_IP` | VIP – Spieler verbinden sich hier | `203.0.113.10` |
| `NIC` | Netzwerkinterface (Ausgabe: `ip a`) | `eth0` |
| `VRRP_AUTH_PASS` | VRRP-Passwort (max. 8 Zeichen) | `MeinPass1` |
| `REDIS_PASSWORD` | Redis-Passwort | `SicheresRedis!` |
| `VELOCITY_FORWARDING_SECRET` | Velocity-Geheimnis | *(zufällig generieren)* |

```bash
# Velocity-Forwarding-Secret generieren:
python3 -c "import secrets; print(secrets.token_hex(32))"
```

---

## Schritt 2 – Deployment-Dateien generieren

```bash
chmod +x deploy.sh
./deploy.sh
```

Ergebnis:
```
dist/
├── node-a/    ← alles für Node A
├── node-b/    ← alles für Node B
└── witness/   ← alles für den Witness
```

---

## Schritt 3 – Dateien auf die Server übertragen

```bash
# Node A
rsync -av dist/node-a/ root@@@NODE_A_IP@@:/opt/minecraft-ha-deploy/

# Node B
rsync -av dist/node-b/ root@@@NODE_B_IP@@:/opt/minecraft-ha-deploy/

# Witness
rsync -av dist/witness/ root@@@WITNESS_IP@@:/opt/minecraft-ha-deploy/
```

---

## Schritt 4 – Installation auf jedem Server

```bash
# Node A (SSH-Session auf Node A)
ssh root@@@NODE_A_IP@@
cd /opt/minecraft-ha-deploy
chmod +x install.sh
sudo ./install.sh

# Node B
ssh root@@@NODE_B_IP@@
cd /opt/minecraft-ha-deploy
chmod +x install.sh
sudo ./install.sh

# Witness
ssh root@@@WITNESS_IP@@
cd /opt/minecraft-ha-deploy
chmod +x install.sh
sudo ./install.sh
```

Detaillierte Anweisungen pro Server → siehe jeweilige `ANLEITUNG.md` im `node-a/`, `node-b/` und `witness/` Ordner.

---

## Schritt 5 – GlusterFS-Volumen einrichten (einmalig, nur auf Node A)

```bash
ssh root@@@NODE_A_IP@@
sudo /opt/minecraft/scripts/glusterfs-setup.sh
```

Anschließend auf Node B das Volumen read-only einbinden:

```bash
ssh root@@@NODE_B_IP@@
echo "localhost:/@@GLUSTER_VOLUME@@  @@WORLD_MOUNT@@  glusterfs  defaults,ro,_netdev  0 0" >> /etc/fstab
mkdir -p @@WORLD_MOUNT@@
mount @@WORLD_MOUNT@@
```

---

## Schritt 6 – Velocity & Paper-Backends einrichten

```bash
# Auf BEIDEN Nodes (Node A und Node B):
mkdir -p /opt/velocity
# Velocity-JAR herunterladen:
# https://papermc.io/downloads/velocity  → /opt/velocity/velocity.jar

# Paper-Backends für jede Welt erstellen:
mkdir -p /opt/minecraft/servers/survival
mkdir -p /opt/minecraft/servers/lobby
# Paper-JAR in jeden Ordner legen und einmalig starten (EULA akzeptieren)

# HuskSync-Plugin in jeden Backend-Plugin-Ordner legen:
# https://william278.net/project/husksync
# Die config.yml wurde bereits von install.sh in /opt/minecraft/plugins/HuskSync/ abgelegt.

# In jeder server.properties:
#   online-mode=false          (Velocity übernimmt die Authentifizierung)
#   server-port=@@SURVIVAL_PORT@@  (bzw. @@LOBBY_PORT@@)

# In jeder config/paper-global.yml:
#   proxies.velocity.enabled: true
#   proxies.velocity.secret: <Inhalt von /opt/velocity/forwarding.secret>
```

---

## Schritt 7 – Systemd-Dienste aktivieren

```bash
# Auf BEIDEN Nodes:
systemctl daemon-reload

# Velocity und Minecraft manuell als systemd-Unit registrieren
# (keepalived start/stoppt sie – nicht WantedBy multi-user.target)
systemctl enable velocity
systemctl enable "minecraft@survival"
systemctl enable "minecraft@lobby"
```

---

## Schritt 8 – Failover testen

```bash
# Keepalived-Status auf Node A prüfen
journalctl -u keepalived -f

# Simulierter Ausfall: Keepalived auf Node A stoppen
ssh root@@@NODE_A_IP@@ systemctl stop keepalived

# Auf Node B beobachten (VIP sollte innerhalb von 5 s erscheinen):
ssh root@@@NODE_B_IP@@ watch -n1 "ip addr show @@NIC@@ | grep @@FLOATING_IP@@"

# Quorum-Witness prüfen:
curl http://@@WITNESS_IP@@:@@WITNESS_PORT@@/health
```

---

## Split-Brain – Was passiert?

| Szenario | Ergebnis |
|----------|---------|
| Node A fällt aus (Hardware) | Keepalived auf Node B gewinnt VRRP-Wahl (~2 s), VIP wechselt, Witness erteilt Lock → Node B wird Master |
| Node A ↔ Node B-Link bricht (beide haben Internet) | Beide rufen Witness an → **Erstanruf** bekommt Lock → Zweiter Knoten verliert VRRP-Wahl → on_backup.sh stoppt dessen Stack |
| Witness ist nicht erreichbar | `QUORUM_SAFE_MODE=allow`: beide dürfen laufen (GlusterFS read-only schützt vor Korruption); `deny`: beide stoppen |
| Node A kommt zurück | Keepalived erhält VRRP-Wahl zurück (höhere Priorität) → failback.sh re-synct Redis → VIP wandert zurück |

---

## Verzeichnisstruktur im Repository

```
config.env                  ← EINZIGE Datei, die du bearbeitest
deploy.sh                   ← generiert dist/node-a, dist/node-b, dist/witness
ANLEITUNG.md                ← diese Gesamtanleitung
shared/                     ← Dateien für Node A und Node B
node-a/                     ← Node-A-spezifische Dateien + ANLEITUNG.md
node-b/                     ← Node-B-spezifische Dateien + ANLEITUNG.md
witness/                    ← Witness-spezifische Dateien + ANLEITUNG.md
dist/                       ← generiert (in .gitignore, nicht einchecken!)
```

---

## Häufige Fehler

| Symptom | Ursache | Lösung |
|---------|---------|--------|
| Beide Nodes halten die VIP | Split-Brain durch falsches `VRRP_AUTH_PASS` | Passwort auf beiden Nodes angleichen, keepalived neu starten |
| „World is already opened" | Stale `session.lock` | `session-lock-guard.sh` läuft als ExecStartPre – prüfe Logs: `journalctl -u minecraft@survival` |
| Redis-Replikation bricht ab | Replica zeigt auf Floating-IP statt physische IP | In `redis.conf` muss `replicaof` die physische IP von Node A enthalten |
| Spieler bekommen leeres Inventar | HuskSync-Lock-Timeout zu kurz | `lock_duration` in `HuskSync/config.yml` auf 3–5 s erhöhen |

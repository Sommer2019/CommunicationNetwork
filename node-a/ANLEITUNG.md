# Anleitung – Node A (Haupt-Server / MASTER)

Node A ist unter normalen Umständen der **MASTER**: Er hält die Floating-IP, betreibt Velocity und alle Paper-Backends.

---

## Voraussetzungen

```bash
apt update && apt install -y keepalived redis-server glusterfs-server curl openjdk-17-jre-headless
```

---

## Schritt 1 – Dateien deployen

Führe `deploy.sh` auf deinem lokalen Rechner aus (nachdem du `config.env` bearbeitet hast), dann:

```bash
rsync -av dist/node-a/ root@<NODE_A_IP>:/opt/minecraft-ha-deploy/
ssh root@<NODE_A_IP>
cd /opt/minecraft-ha-deploy
sudo ./install.sh
```

`install.sh` erledigt automatisch:
- `config.env` → `/etc/minecraft-ha/config.env` (600 Rechte)
- Keepalived-Skripte → `/etc/keepalived/`
- Redis-Konfiguration (Master) → `/etc/redis/`
- Velocity-Konfiguration → `/opt/velocity/`
- HuskSync config → `/opt/minecraft/plugins/HuskSync/`
- Systemd-Units → `/etc/systemd/system/`
- keepalived + Redis starten und aktivieren

---

## Schritt 2 – GlusterFS-Volumen erstellen (einmalig)

Nur auf Node A ausführen, **nachdem** glusterd auf Node B läuft:

```bash
sudo /opt/minecraft/scripts/glusterfs-setup.sh
```

Das Skript:
1. Verbindet sich mit Node B via `gluster peer probe`
2. Erstellt ein repliziertes Volumen (`replica 2`)
3. Deaktiviert alle Caches (verhindert veraltete Lesevorgänge)
4. Bindet das Volumen auf Node A als **read-write** ein

---

## Schritt 3 – Velocity & Paper-Backends einrichten

```bash
# Velocity-JAR herunterladen (https://papermc.io/downloads/velocity)
wget -O /opt/velocity/velocity.jar <download-url>

# Systemd-User anlegen
useradd -r -m -d /opt/minecraft -s /bin/false minecraft
chown -R minecraft:minecraft /opt/velocity /opt/minecraft

# Dienste ohne auto-start registrieren (keepalived übernimmt das)
systemctl enable velocity
systemctl enable "minecraft@survival"
systemctl enable "minecraft@lobby"
```

Für jeden Paper-Backend-Server:

```bash
mkdir -p /opt/minecraft/servers/survival
cd /opt/minecraft/servers/survival
# Paper-JAR herunterladen und einmalig starten um EULA zu akzeptieren
echo "eula=true" > eula.txt

# In server.properties:
#   online-mode=false
#   server-port=<SURVIVAL_PORT aus config.env>
#   level-path=/mnt/minecraft/worlds/survival

# In config/paper-global.yml:
#   proxies.velocity.enabled: true
#   proxies.velocity.secret: <Inhalt von /opt/velocity/forwarding.secret>
```

---

## Schritt 4 – HuskSync-Plugin installieren

```bash
# HuskSync-JAR herunterladen: https://william278.net/project/husksync
# In jeden Backend-Plugin-Ordner legen:
cp husksync-*.jar /opt/minecraft/servers/survival/plugins/
cp husksync-*.jar /opt/minecraft/servers/lobby/plugins/

# Die config.yml wurde bereits von install.sh vorbereitet:
ls /opt/minecraft/plugins/HuskSync/config.yml

# Kopiere sie in jeden Backend:
cp /opt/minecraft/plugins/HuskSync/config.yml \
   /opt/minecraft/servers/survival/plugins/HuskSync/config.yml
cp /opt/minecraft/plugins/HuskSync/config.yml \
   /opt/minecraft/servers/lobby/plugins/HuskSync/config.yml

# Den server-Namen in jeder Instanz anpassen:
# survival: server.name: "survival-1"
# lobby:    server.name: "lobby-1"
```

---

## Schritt 5 – MySQL für HuskSync einrichten

```bash
apt install -y mariadb-server
mysql -u root -e "
  CREATE DATABASE husksync;
  CREATE USER 'husksync'@'localhost' IDENTIFIED BY '<MYSQL_PASSWORD aus config.env>';
  GRANT ALL PRIVILEGES ON husksync.* TO 'husksync'@'localhost';
  FLUSH PRIVILEGES;
"
```

---

## Schritt 6 – Failover-Test

```bash
# Keepalived-Status prüfen (sollte MASTER anzeigen)
journalctl -u keepalived -f

# VIP prüfen:
ip addr show | grep <FLOATING_IP>

# Redis-Status:
redis-cli -a <REDIS_PASSWORD> INFO replication
# → role:master

# Witness von Node A aus testen:
curl http://<WITNESS_IP>:<WITNESS_PORT>/health
```

---

## Schritt 7 – Nach einem Ausfall zurückkehren (Failback)

Wenn Node A repariert wurde und Node B aktuell MASTER ist:

```bash
sudo /opt/minecraft/scripts/failback.sh
```

Das Skript:
1. Schaltet Redis auf Node A in Replikationsmodus zu Node B
2. Wartet auf vollständige Synchronisation
3. Keepalived übernimmt die VIP automatisch zurück (höhere Priorität)

---

## Wichtige Dateipfade auf Node A

| Pfad | Inhalt |
|------|--------|
| `/etc/minecraft-ha/config.env` | Zentrale Konfiguration (alle IPs/Passwörter) |
| `/etc/keepalived/keepalived.conf` | VRRP-Konfiguration (MASTER, Prio @@NODE_A_PRIORITY@@) |
| `/etc/keepalived/on_master.sh` | Wird aufgerufen wenn VIP hier landet |
| `/etc/keepalived/on_backup.sh` | Wird aufgerufen wenn VIP verloren geht |
| `/etc/redis/redis.conf` | Redis-Master-Konfiguration |
| `/opt/velocity/velocity.toml` | Velocity-Proxy-Konfiguration |
| `/opt/minecraft/scripts/session-lock-guard.sh` | Schützt vor doppeltem World-Zugriff |
| `/opt/minecraft/scripts/failback.sh` | Nach Reparatur: zurück zum Master |
| `/var/log/keepalived-minecraft.log` | Keepalived + Failover-Logdatei |

---

## Logs überwachen

```bash
# Keepalived (VRRP-Ereignisse, on_master/on_backup Ausgabe)
journalctl -u keepalived -f

# Redis
tail -f /var/log/redis/redis.log

# Velocity
journalctl -u velocity -f

# Minecraft-Backend (z. B. survival)
journalctl -u minecraft@survival -f

# Kombiniert:
tail -f /var/log/keepalived-minecraft.log
```

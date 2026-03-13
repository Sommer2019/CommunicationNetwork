# Anleitung – Node B (Standby-Server / BACKUP)

Node B läuft im **Hot-Standby**: Redis repliziert in Echtzeit, GlusterFS ist eingebunden (read-only), Velocity und Minecraft sind registriert aber **gestoppt** – sie starten automatisch wenn die VIP von Node A hierher wechselt.

---

## Voraussetzungen

```bash
apt update && apt install -y keepalived redis-server glusterfs-server curl openjdk-17-jre-headless
```

---

## Schritt 1 – Dateien deployen

```bash
rsync -av dist/node-b/ root@<NODE_B_IP>:/opt/minecraft-ha-deploy/
ssh root@<NODE_B_IP>
cd /opt/minecraft-ha-deploy
sudo ./install.sh
```

`install.sh` erledigt automatisch:
- `config.env` → `/etc/minecraft-ha/config.env`
- Keepalived-Skripte → `/etc/keepalived/` (Konfiguration: BACKUP, Prio @@NODE_B_PRIORITY@@)
- Redis-Konfiguration (Replikat) → `/etc/redis/`
- Velocity-Konfiguration → `/opt/velocity/`
- HuskSync config → `/opt/minecraft/plugins/HuskSync/`
- Failover-Watchdog-Dienst → `/etc/systemd/system/minecraft-failover.service`
- Alle Dienste aktivieren & starten

---

## Schritt 2 – GlusterFS-Volumen einbinden (read-only)

Das Volumen wurde bereits auf Node A erstellt. Hier nur einbinden:

```bash
echo "localhost:/@@GLUSTER_VOLUME@@  @@WORLD_MOUNT@@  glusterfs  defaults,ro,_netdev,log-level=WARNING  0 0" >> /etc/fstab
mkdir -p @@WORLD_MOUNT@@
mount @@WORLD_MOUNT@@

# Überprüfen (sollte "ro" anzeigen):
findmnt @@WORLD_MOUNT@@
```

> **Wichtig:** Node B bindet die Welt immer read-only ein. Wenn keepalived die VIP hierher verschiebt, führt `on_master.sh` automatisch ein `mount -o remount,rw` aus, **bevor** Minecraft gestartet wird.

---

## Schritt 3 – Velocity & Paper-Backends einrichten

**Identisch zu Node A** – gleiche Ordnerstruktur, gleiche Konfiguration, gleiche Plugins:

```bash
useradd -r -m -d /opt/minecraft -s /bin/false minecraft
# Velocity-JAR → /opt/velocity/velocity.jar
# Paper-JARs → /opt/minecraft/servers/survival/server.jar usw.
# EULA, server.properties, Paper-Global-Config → identisch zu Node A

systemctl enable velocity
systemctl enable "minecraft@survival"
systemctl enable "minecraft@lobby"
# NICHT starten! keepalived startet sie bei Failover automatisch.
```

---

## Schritt 4 – Redis-Replikation prüfen

```bash
redis-cli -a @@REDIS_PASSWORD@@ INFO replication
```

Erwartete Ausgabe:
```
role:slave
master_host:@@NODE_A_IP@@
master_port:@@REDIS_PORT@@
master_link_status:up          ← Muss "up" sein!
master_last_io_seconds_ago:0
```

Falls `master_link_status:down`:
```bash
# Netzwerkverbindung zu Node A prüfen:
redis-cli -h @@NODE_A_IP@@ -p @@REDIS_PORT@@ -a @@REDIS_PASSWORD@@ PING
# Muss PONG zurückgeben
```

---

## Schritt 5 – Failover-Watchdog prüfen

```bash
systemctl status minecraft-failover
journalctl -u minecraft-failover -f
```

Erwartete Log-Ausgabe (normal):
```
[...] Watchdog gestartet – überwache Node A (@@NODE_A_IP@@:@@PROXY_PORT@@).
```

Bei simuliertem Ausfall (Node A stoppen):
```
[...] Node A nicht erreichbar (Versuch 1/3).
[...] Node A nicht erreichbar (Versuch 2/3).
[...] Node A nicht erreichbar (Versuch 3/3).
[...] FAILOVER: Node A ausgefallen, diese Node hält die VIP → Stack aktivieren.
```

---

## Schritt 6 – Failover-Test

```bash
# Auf Node A: keepalived stoppen (simulierter Ausfall)
ssh root@@@NODE_A_IP@@ systemctl stop keepalived

# Auf Node B beobachten:
watch -n1 "ip addr show @@NIC@@ | grep @@FLOATING_IP@@"

# Nach ~2 s sollte die VIP hier erscheinen
# Nach ~5 s sollten Velocity und Minecraft laufen:
systemctl status velocity
systemctl status "minecraft@survival"

# Redis muss jetzt Master sein:
redis-cli -a @@REDIS_PASSWORD@@ INFO replication | grep role
# → role:master
```

---

## Was passiert bei einem echten Failover?

1. **T+0 s** – Node A fällt aus
2. **T+2 s** – Keepalived auf Node B gewinnt VRRP-Wahl → VIP erscheint hier
3. **T+2 s** – `on_master.sh` wird aufgerufen:
   - Quorum-Witness bestätigt Lock
   - GlusterFS wird read-write neu eingehängt
   - Stale `session.lock`-Dateien werden entfernt
   - Redis wird zum Master befördert (`REPLICAOF NO ONE`)
   - Velocity wird gestartet
   - Minecraft-Backends werden gestartet
4. **T+3 s** – `minecraft@.service` führt `session-lock-guard.sh` als `ExecStartPre` aus:
   - Prüft: Hält dieser Node die VIP? ✓
   - Prüft: GlusterFS read-write? ✓
   - Entfernt verbleibende `session.lock`-Dateien
5. **T+5 s** – Spieler sind auf Node B, mit korrektem Inventar (dank HuskSync + Redis)

---

## Wichtige Dateipfade auf Node B

| Pfad | Inhalt |
|------|--------|
| `/etc/minecraft-ha/config.env` | Zentrale Konfiguration |
| `/etc/keepalived/keepalived.conf` | VRRP-Konfiguration (BACKUP, Prio @@NODE_B_PRIORITY@@) |
| `/etc/redis/redis.conf` | Redis-Replikat-Konfiguration |
| `/opt/minecraft/scripts/failover-watchdog.sh` | Überwacht Node A, aktiviert Stack bei Failover |
| `/opt/minecraft/scripts/redis-promote.sh` | Befördert Redis manuell zum Master |
| `/opt/minecraft/scripts/session-lock-guard.sh` | ExecStartPre – schützt vor doppeltem Weltzugriff |
| `/var/log/minecraft-failover.log` | Watchdog-Logdatei |
| `/var/log/keepalived-minecraft.log` | Keepalived-Ereignisse |

---

## Logs überwachen

```bash
# Failover-Watchdog
journalctl -u minecraft-failover -f

# Keepalived
journalctl -u keepalived -f

# Redis-Replikation
tail -f /var/log/redis/redis.log

# Gesamtübersicht
tail -f /var/log/keepalived-minecraft.log /var/log/minecraft-failover.log
```

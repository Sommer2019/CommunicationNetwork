# Anleitung – Witness-Server (Quorum-Schiedsrichter)

Der Witness-Server ist ein **dritter, unabhängiger Server** (z. B. ein günstiger VPS), der bei einem Split-Brain entscheidet, welcher Node Master sein darf.

---

## Was ist Split-Brain und warum brauche ich einen Witness?

**Split-Brain-Szenario:**
- Node A und Node B verlieren ihre Verbindung untereinander
- Beide haben aber noch Internetzugang
- Beide denken: „Mein Partner ist tot, ich bin der neue Chef"
- Beide starten Minecraft → **beide schreiben in dieselbe Weltdatenbank** → Welt kaputt

**Lösung – Quorum-Witness:**
- Wer MASTER werden will, muss zuerst beim Witness einen Lock anfordern
- Der Erste bekommt den Lock → darf MASTER sein
- Der Zweite bekommt HTTP 409 → seine Keepalived-Priorität sinkt → er verliert die VRRP-Wahl → er bleibt BACKUP
- **Nur eine Node darf gleichzeitig schreiben**

---

## Anforderungen an den Witness-Server

- Kleinstmöglich: 1 vCPU, 512 MB RAM reichen aus
- **Physisch getrennt** von Node A und Node B (anderes Rechenzentrum / anderer Provider)
- Muss von beiden Nodes per HTTP erreichbar sein (Port `@@WITNESS_PORT@@`)
- Benötigt nur `socat` (kein Java, kein Redis, kein Minecraft)

---

## Schritt 1 – Dateien deployen

```bash
rsync -av dist/witness/ root@<WITNESS_IP>:/opt/minecraft-ha-deploy/
ssh root@<WITNESS_IP>
cd /opt/minecraft-ha-deploy
sudo ./install.sh
```

`install.sh` erledigt:
- `config.env` → `/etc/minecraft-ha/config.env`
- `witness-server.sh` → `/opt/witness/witness-server.sh`
- Systemd-Unit `minecraft-witness.service` installieren und starten
- `socat` installieren (falls nicht vorhanden)

---

## Schritt 2 – Dienst prüfen

```bash
systemctl status minecraft-witness

# Health-Check:
curl http://localhost:@@WITNESS_PORT@@/health
# Antwort: {"status":"ok"}
```

---

## Schritt 3 – Von Node A und Node B aus testen

```bash
# Von Node A:
curl "http://@@WITNESS_IP@@:@@WITNESS_PORT@@/vote?node=node-a&role=master"
# Antwort: {"granted":true}

# Von Node B (sofort danach):
curl "http://@@WITNESS_IP@@:@@WITNESS_PORT@@/vote?node=node-b&role=master"
# Antwort: {"granted":false,"current_master":"node-a"}  ← Split-Brain verhindert!

# Lock freigeben (wird von on_backup.sh automatisch gemacht):
curl -X DELETE "http://@@WITNESS_IP@@:@@WITNESS_PORT@@/vote?node=node-a"
# Antwort: {"released":true}
```

---

## Schritt 4 – Firewall einrichten

```bash
# Nur Node A und Node B dürfen auf den Witness zugreifen:
ufw default deny incoming
ufw allow from @@NODE_A_IP@@ to any port @@WITNESS_PORT@@
ufw allow from @@NODE_B_IP@@ to any port @@WITNESS_PORT@@
ufw allow ssh
ufw enable
```

---

## Was passiert wenn der Witness nicht erreichbar ist?

Das wird durch `QUORUM_SAFE_MODE` in `config.env` gesteuert:

| Wert | Verhalten |
|------|---------|
| `allow` *(Standard)* | Beide Nodes dürfen laufen. GlusterFS read-only auf BACKUP verhindert Korruption trotzdem. |
| `deny` | Keine Node startet als Master, bis der Witness wieder erreichbar ist. Maximale Sicherheit, aber auch Ausfallzeit. |

---

## Lock-Timeout

Der Witness-Lock läuft nach **30 Sekunden** automatisch ab, wenn er nicht erneuert wird. Keepalived ruft `quorum-check.sh` alle 2 Sekunden auf und verlängert dabei den Lock automatisch.

---

## Wichtige Dateipfade auf dem Witness

| Pfad | Inhalt |
|------|--------|
| `/etc/minecraft-ha/config.env` | Konfiguration (WITNESS_PORT, NODE_A_IP, NODE_B_IP) |
| `/opt/witness/witness-server.sh` | Der Witness-HTTP-Daemon |
| `/tmp/minecraft-master.lock` | Aktueller Lock-Inhaber (temporäre Datei) |
| `/var/log/minecraft-witness.log` | Lock-Ereignisse (wer bekommt/verliert den Lock) |

---

## Logs überwachen

```bash
# Alle Lock-Ereignisse in Echtzeit
tail -f /var/log/minecraft-witness.log

# Erwartetes Aussehen im Normalbetrieb:
# [...] GET /vote?node=node-a&role=master
# [...] Lock ERTEILT an 'node-a'.
# (alle 2 s, solange Node A MASTER ist)

# Bei Failover:
# [...] GET /vote?node=node-a&role=master
# [...] Witness unreachable / node-a offline...
# [...] GET /vote?node=node-b&role=master
# [...] Lock ERTEILT an 'node-b'.
```

---

## Neustart des Witness

```bash
systemctl restart minecraft-witness

# Alle bestehenden Locks werden beim Neustart gelöscht,
# da /tmp/minecraft-master.lock verschwindet.
# Keepalived auf beiden Nodes erneuert die Locks automatisch
# innerhalb von 2 Sekunden.
```

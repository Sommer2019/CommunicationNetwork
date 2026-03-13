# CommunicationNetwork – Seamless Failover für Minecraft

Dieses Repository enthält die vollständige Infrastruktur-Konfiguration für ein **Seamless Failover**-System für Minecraft-Server. Spieler verlieren auch bei einem harten Server-Absturz keine Verbindung und werden nahtlos auf einen Standby-Server umgeleitet.

---

## Architektur-Übersicht

```
Internet
    │
    ▼
┌─────────────────────────────────────────────────────────┐
│  HAProxy  (Port 25565, Stats: 8404)                     │
│  – Load Balancer & Floating Entry Point                 │
└────────────────────────┬────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────┐
│  Velocity Proxy  (Port 25577)                           │
│  – Hält Spieler-Sessions aktiv                          │
│  – ReconnectHandler: kein Kick bei Backend-Ausfall      │
│  – try: [server-a, server-b]                            │
└──────────────┬──────────────────────────┬───────────────┘
               │                          │
               ▼                          ▼
┌──────────────────────┐   ┌──────────────────────────────┐
│  Server-A (aktiv)    │   │  Server-B (Hot Standby)      │
│  Port 25501          │   │  Port 25502                  │
│  PaperMC 1.21.1      │   │  PaperMC 1.21.1              │
└──────────────┬───────┘   └───────────────┬──────────────┘
               │  Shared World Storage     │
               └────────────┬─────────────┘
                            │
              ┌─────────────▼──────────────┐
              │  Docker Volume: world_data  │
              │  (NVMe / GlusterFS / NAS)   │
              └─────────────┬──────────────┘
                            │
              ┌─────────────▼──────────────┐
              │  Redis  (Port 6379)         │
              │  Inventar, Position, XP     │
              │  HuskSync Echtzeit-Sync     │
              └────────────────────────────┘

        ┌────────────────────────────────────┐
        │  Failover Watchdog                 │
        │  – Überwacht Server-A via TCP-Ping │
        │  – Setzt Redis-State bei Ausfall   │
        └────────────────────────────────────┘
```

| Komponente        | Technologie           | Aufgabe                                        |
|-------------------|-----------------------|------------------------------------------------|
| Eingang           | HAProxy 2.9           | Load Balancing & Floating Entry Point          |
| Proxy             | Velocity 3.3          | Spieler-Session aktiv halten, Failover-Routing |
| Sync              | Redis 7.2 + HuskSync  | Inventar, Position, XP sekundengenau speichern |
| Storage           | Docker Volume         | Geteilte Welt für beide Server-Instanzen       |
| Server            | PaperMC 1.21.1 (×2)  | Hot Standby – beide laufen dauerhaft           |
| Monitoring        | Python Watchdog       | Erkennt Ausfall in < FAILURE_THRESHOLD × Intervall |

---

## Verzeichnisstruktur

```
CommunicationNetwork/
├── docker-compose.yml              # Alle Dienste in einem File
├── .env.example                    # Umgebungsvariablen (Vorlage)
├── haproxy/
│   └── haproxy.cfg                 # HAProxy-Konfiguration
├── velocity/
│   ├── velocity.toml               # Velocity-Proxy-Konfiguration
│   ├── forwarding.secret           # Modern Forwarding Secret (NICHT committen!)
│   └── plugins/
│       └── reconnect-handler/
│           └── config.yml          # ReconnectHandler Plugin-Konfiguration
├── redis/
│   └── redis.conf                  # Redis-Konfiguration (AOF + RDB Persistenz)
├── minecraft/
│   ├── server-a/plugins/
│   │   └── husksync-config.yml     # HuskSync Spieler-Datensynchronisation
│   └── server-b/plugins/
│       └── husksync-config.yml
└── scripts/
    ├── failover_watchdog.py        # Failover-Watchdog (Python)
    ├── Dockerfile.watchdog         # Docker-Image für den Watchdog
    ├── requirements.txt
    └── tests/
        └── test_failover_watchdog.py  # Unit-Tests
```

---

## Schnellstart

### 1. Voraussetzungen

- Docker ≥ 24 + Docker Compose v2
- Mindestens 6 GB freier RAM (2 × 2 GB Minecraft + Velocity + Redis + Overhead)

### 2. Konfiguration

```bash
# Umgebungsvariablen anpassen
cp .env.example .env
nano .env

# Velocity Forwarding Secret generieren (zufälliger String, mind. 16 Zeichen)
echo "$(openssl rand -hex 32)" > velocity/forwarding.secret
```

### 3. Plugins installieren

Lade folgende Plugins herunter und lege die `.jar`-Dateien in die entsprechenden Ordner:

| Plugin | Ordner | Zweck |
|--------|--------|-------|
| [HuskSync](https://github.com/WiIIiam278/HuskSync/releases) | `minecraft/server-a/plugins/` & `minecraft/server-b/plugins/` | Inventar/Position-Sync via Redis |
| [VelocityReconnectHandler](https://github.com/4drian3d/VPacketEvents) oder [ReJoin](https://www.spigotmc.org/) | `velocity/plugins/` | Kein Kick bei Server-Absturz |

### 4. Starten

```bash
docker compose up -d

# Logs live verfolgen
docker compose logs -f

# Status prüfen
docker compose ps
```

### 5. Testen

```bash
# Failover manuell testen – Server-A stoppen:
docker compose stop server-a

# Watchdog-Log beobachten:
docker compose logs -f failover-watchdog

# Redis-State prüfen:
docker compose exec redis redis-cli get failover:active_server
# → "server-b"

# Server-A wieder starten (Failback):
docker compose start server-a
```

---

## Failover-Ablauf

1. **Überwachung**: Der Watchdog prüft alle 5 Sekunden, ob Server-A per TCP erreichbar ist.
2. **Erkennung**: Nach `FAILURE_THRESHOLD` (Standard: 3) aufeinanderfolgenden Fehlern gilt Server-A als ausgefallen.
3. **Redis-Update**: Der Watchdog schreibt `failover:active_server = server-b` in Redis.
4. **Velocity-Routing**: Der Proxy leitet neue/reconnecting Spieler automatisch zu Server-B (dank `try = ["server-a", "server-b"]` in `velocity.toml`).
5. **HuskSync**: Server-B liest Inventar, Position und XP des Spielers aus Redis.
6. **Failback**: Sobald Server-A wieder erreichbar ist, wird automatisch auf Server-A zurückgewechselt.

---

## Tests ausführen

```bash
cd scripts
pip install -r requirements.txt pytest
python -m pytest tests/ -v
```

---

## Sicherheitshinweise

- Die Datei `velocity/forwarding.secret` und `.env` dürfen **nicht** in die Versionskontrolle!
- Setze starke Passwörter in `.env` (RCON, Redis, HAProxy Stats).
- Im Produktivbetrieb sollte Redis mit `requirepass` abgesichert sein.
- Die Ports 25501 und 25502 (Backend-Server) sollten **nicht** öffentlich erreichbar sein.

#!/usr/bin/env python3
"""
Failover Watchdog – Minecraft Seamless Failover
================================================
Überwacht den primären Minecraft-Server (Server-A) und löst bei Ausfall
automatisch den Failover auf den Standby-Server (Server-B) aus.

Ablauf:
  1. Alle CHECK_INTERVAL_SECONDS Sekunden wird Server-A per TCP-Ping geprüft.
  2. Schlägt der Ping FAILURE_THRESHOLD-mal in Folge fehl, gilt Server-A als ausgefallen.
  3. Der Watchdog setzt in Redis ein Flag, das Velocity/Plugins ausliest.
  4. Optional: RCON-Befehl an Server-B, um es als primären Server zu markieren.
  5. Sobald Server-A wieder erreichbar ist, kann der Failback ausgelöst werden.
"""

import os
import socket
import time
import logging
import redis

# ─────────────────────────────────────────────
# Konfiguration (aus Umgebungsvariablen)
# ─────────────────────────────────────────────
PRIMARY_HOST = os.environ.get("PRIMARY_HOST", "172.20.0.10")
PRIMARY_PORT = int(os.environ.get("PRIMARY_PORT", 25501))
STANDBY_HOST = os.environ.get("STANDBY_HOST", "172.20.0.11")
STANDBY_PORT = int(os.environ.get("STANDBY_PORT", 25502))
REDIS_HOST = os.environ.get("REDIS_HOST", "172.20.0.20")
REDIS_PORT = int(os.environ.get("REDIS_PORT", 6379))
REDIS_PASSWORD = os.environ.get("REDIS_PASSWORD", "")
CHECK_INTERVAL = int(os.environ.get("CHECK_INTERVAL_SECONDS", 5))
FAILURE_THRESHOLD = int(os.environ.get("FAILURE_THRESHOLD", 3))
TCP_TIMEOUT = float(os.environ.get("TCP_TIMEOUT", 3.0))

# Redis-Keys
REDIS_KEY_ACTIVE_SERVER = "failover:active_server"
REDIS_KEY_STATUS = "failover:status"
REDIS_KEY_LAST_FAILOVER = "failover:last_failover_ts"
REDIS_KEY_FAILURE_COUNT = "failover:primary_failure_count"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("failover-watchdog")


# ─────────────────────────────────────────────
# TCP-Ping
# ─────────────────────────────────────────────
def tcp_ping(host: str, port: int, timeout: float = 3.0) -> bool:
    """Prüft, ob ein TCP-Port erreichbar ist."""
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except (socket.timeout, ConnectionRefusedError, OSError):
        return False


# ─────────────────────────────────────────────
# Redis-Verbindung
# ─────────────────────────────────────────────
def get_redis_client() -> redis.Redis:
    """Erstellt einen Redis-Client mit Retry-Logik."""
    kwargs = {"host": REDIS_HOST, "port": REDIS_PORT, "decode_responses": True}
    if REDIS_PASSWORD:
        kwargs["password"] = REDIS_PASSWORD
    while True:
        try:
            client = redis.Redis(**kwargs)
            client.ping()
            log.info("Redis-Verbindung erfolgreich: %s:%d", REDIS_HOST, REDIS_PORT)
            return client
        except redis.exceptions.ConnectionError as exc:
            log.warning("Redis nicht erreichbar, erneuter Versuch in 5s: %s", exc)
            time.sleep(5)


# ─────────────────────────────────────────────
# Failover-Logik
# ─────────────────────────────────────────────
def trigger_failover(r: redis.Redis) -> None:
    """Löst den Failover auf Server-B aus."""
    log.warning(
        "FAILOVER AUSGELÖST: Server-A (%s:%d) ist nicht erreichbar. "
        "Wechsel auf Server-B (%s:%d).",
        PRIMARY_HOST, PRIMARY_PORT,
        STANDBY_HOST, STANDBY_PORT,
    )
    r.set(REDIS_KEY_ACTIVE_SERVER, "server-b")
    r.set(REDIS_KEY_STATUS, "failover")
    r.set(REDIS_KEY_LAST_FAILOVER, int(time.time()))


def trigger_failback(r: redis.Redis) -> None:
    """Löst den Failback auf Server-A aus, wenn dieser wieder verfügbar ist."""
    log.info(
        "FAILBACK: Server-A (%s:%d) ist wieder erreichbar. "
        "Wechsel zurück auf Server-A.",
        PRIMARY_HOST, PRIMARY_PORT,
    )
    r.set(REDIS_KEY_ACTIVE_SERVER, "server-a")
    r.set(REDIS_KEY_STATUS, "normal")
    r.delete(REDIS_KEY_FAILURE_COUNT)


# ─────────────────────────────────────────────
# Haupt-Schleife
# ─────────────────────────────────────────────
def main() -> None:
    log.info(
        "Failover-Watchdog gestartet | Primary: %s:%d | Standby: %s:%d | "
        "Interval: %ds | Threshold: %d",
        PRIMARY_HOST, PRIMARY_PORT,
        STANDBY_HOST, STANDBY_PORT,
        CHECK_INTERVAL, FAILURE_THRESHOLD,
    )

    r = get_redis_client()

    # Initialen Zustand setzen
    r.set(REDIS_KEY_ACTIVE_SERVER, "server-a")
    r.set(REDIS_KEY_STATUS, "normal")
    r.set(REDIS_KEY_FAILURE_COUNT, 0)

    consecutive_failures = 0
    failover_active = False

    while True:
        primary_up = tcp_ping(PRIMARY_HOST, PRIMARY_PORT, TCP_TIMEOUT)

        if primary_up:
            if consecutive_failures > 0:
                log.info("Server-A ist wieder erreichbar (nach %d Fehlern).", consecutive_failures)
            consecutive_failures = 0
            r.set(REDIS_KEY_FAILURE_COUNT, 0)

            if failover_active:
                standby_up = tcp_ping(STANDBY_HOST, STANDBY_PORT, TCP_TIMEOUT)
                if standby_up:
                    trigger_failback(r)
                    failover_active = False
        else:
            consecutive_failures += 1
            r.set(REDIS_KEY_FAILURE_COUNT, consecutive_failures)
            log.warning(
                "Server-A nicht erreichbar (Versuch %d/%d).",
                consecutive_failures, FAILURE_THRESHOLD,
            )

            if consecutive_failures >= FAILURE_THRESHOLD and not failover_active:
                standby_up = tcp_ping(STANDBY_HOST, STANDBY_PORT, TCP_TIMEOUT)
                if standby_up:
                    trigger_failover(r)
                    failover_active = True
                else:
                    log.error(
                        "KRITISCH: Weder Server-A noch Server-B sind erreichbar!"
                    )

        time.sleep(CHECK_INTERVAL)


if __name__ == "__main__":
    main()

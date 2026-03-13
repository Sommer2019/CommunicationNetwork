#!/usr/bin/env bash
# =============================================================================
# witness-server.sh – Quorum Witness HTTP-Daemon
# =============================================================================
# Läuft auf einem DRITTEN Server (z. B. billiger VPS).
# Entscheidet bei Split-Brain, welcher Node Master sein darf.
#
# Endpunkte:
#   GET  /vote?node=<name>&role=master  → Lock anfordern
#   DELETE /vote?node=<name>             → Lock freigeben
#   GET  /health                         → Liveness-Check
#
# Voraussetzungen: socat  (apt install socat)
# =============================================================================
set -euo pipefail
# shellcheck source=/dev/null
source /etc/minecraft-ha/config.env

LOG=/var/log/minecraft-witness.log
LOCK_FILE=/tmp/minecraft-master.lock
LOCK_TIMEOUT=30

exec >> "$LOG" 2>&1
log() { echo "[$(date -Iseconds)] [witness] $*"; }

# ── Lock-Hilfsfunktionen ──────────────────────────────────────────────────────
read_lock()      { [[ -f "$LOCK_FILE" ]] && cat "$LOCK_FILE" || echo ""; }
lock_owner()     { echo "$1" | cut -d: -f1; }
lock_timestamp() { echo "$1" | cut -d: -f2; }
lock_expired() {
    local d="$1"
    [[ -z "$d" ]] && return 0
    (( $(date +%s) - $(lock_timestamp "$d") > LOCK_TIMEOUT ))
}
write_lock()  { echo "${1}:$(date +%s)" > "$LOCK_FILE"; }
delete_lock() { rm -f "$LOCK_FILE"; }

# ── HTTP-Antwort ──────────────────────────────────────────────────────────────
http_response() {
    local code="$1" body="$2"
    printf "HTTP/1.1 %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" \
        "$code" "${#body}" "$body"
}

# ── Anfrage-Handler ───────────────────────────────────────────────────────────
handle_request() {
    local req method path endpoint query node role
    read -r req; req="${req%%$'\r'}"
    method=$(awk '{print $1}' <<< "$req")
    path=$(awk '{print $2}'   <<< "$req")
    while IFS= read -r h; do h="${h%%$'\r'}"; [[ -z "$h" ]] && break; done
    endpoint="${path%%\?*}"
    query="${path#*\?}"
    node=$(grep -oP '(?<=node=)[^&]*' <<< "$query" || true)
    role=$(grep -oP '(?<=role=)[^&]*' <<< "$query" || true)
    log "${method} ${path}"

    case "$endpoint" in
        /health)
            http_response "200 OK" '{"status":"ok"}' ;;
        /vote)
            local data owner
            data=$(read_lock)
            if [[ "$method" == "DELETE" ]]; then
                if [[ -n "$data" && "$(lock_owner "$data")" == "$node" ]]; then
                    delete_lock
                    log "Lock von '${node}' freigegeben."
                    http_response "200 OK" '{"released":true}'
                else
                    http_response "200 OK" '{"released":false}'
                fi
            elif [[ "$method" == "GET" && "$role" == "master" ]]; then
                if [[ -z "$data" ]] || lock_expired "$data"; then
                    write_lock "$node"
                    log "Lock ERTEILT an '${node}'."
                    http_response "200 OK" '{"granted":true}'
                else
                    owner=$(lock_owner "$data")
                    if [[ "$owner" == "$node" ]]; then
                        write_lock "$node"   # Refresh
                        http_response "200 OK" '{"granted":true}'
                    else
                        log "Lock VERWEIGERT für '${node}' – Inhaber: '${owner}'."
                        http_response "409 Conflict" "{\"granted\":false,\"current_master\":\"${owner}\"}"
                    fi
                fi
            else
                http_response "400 Bad Request" '{"error":"bad_request"}'
            fi ;;
        *)
            http_response "404 Not Found" '{"error":"not_found"}' ;;
    esac
}

log "Quorum-Witness startet auf Port ${WITNESS_PORT}."
SELF="$(realpath "${BASH_SOURCE[0]}")"
exec socat TCP-LISTEN:"${WITNESS_PORT}",reuseaddr,fork \
    EXEC:"bash -c 'source \"${SELF}\"; handle_request'"

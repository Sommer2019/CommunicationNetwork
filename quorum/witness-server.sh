#!/usr/bin/env bash
# =============================================================================
# Quorum Witness – lightweight HTTP daemon
# =============================================================================
# Deploy this on a THIRD, physically separate server (a cheap VPS is fine).
# It listens on port 8080 and answers two endpoints:
#
#   GET /vote?node=<name>&role=master
#       A node asks for permission to become MASTER.
#       Returns HTTP 200 {"granted":true}  if no other node holds the lock.
#       Returns HTTP 409 {"granted":false} if another node already holds it.
#
#   DELETE /vote?node=<name>
#       A node releases its master lock (called from on_backup.sh / on_fault.sh).
#       Returns HTTP 200 {"released":true}.
#
#   GET /health
#       Simple liveness probe.
#
# Dependencies: bash, socat (apt install socat)
#
# Place at: /opt/witness/witness-server.sh   (chmod +x)
# Start:    systemctl enable --now minecraft-witness
#           (see: quorum/minecraft-witness.service)
# =============================================================================

set -euo pipefail

PORT=8080
LOG=/var/log/minecraft-witness.log
LOCK_FILE=/tmp/minecraft-master.lock   # contains the name of the current master
LOCK_TIMEOUT=30                        # seconds before an unrefreshed lock expires

exec >> "$LOG" 2>&1

log() { echo "[$(date -Iseconds)] [witness] $*"; }

# ── Helpers ───────────────────────────────────────────────────────────────────

# Return the current lock owner and its timestamp, or empty strings if no lock.
read_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        cat "$LOCK_FILE"
    else
        echo ""
    fi
}

lock_is_expired() {
    local lock_data="$1"
    [[ -z "$lock_data" ]] && return 0          # no lock → treat as expired
    local lock_ts
    lock_ts=$(echo "$lock_data" | cut -d: -f2)
    local now
    now=$(date +%s)
    (( now - lock_ts > LOCK_TIMEOUT ))
}

lock_owner() {
    local lock_data="$1"
    echo "$lock_data" | cut -d: -f1
}

write_lock() {
    local node="$1"
    echo "${node}:$(date +%s)" > "$LOCK_FILE"
}

delete_lock() {
    rm -f "$LOCK_FILE"
}

# ── HTTP response helpers ─────────────────────────────────────────────────────

http_response() {
    local code="$1" body="$2"
    printf "HTTP/1.1 %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" \
        "$code" "${#body}" "$body"
}

# ── Request handler ───────────────────────────────────────────────────────────

handle_request() {
    local request_line method path

    # Read the request line
    read -r request_line
    request_line="${request_line%%$'\r'}"
    method=$(echo "$request_line" | awk '{print $1}')
    path=$(echo "$request_line"   | awk '{print $2}')

    # Drain headers (we don't need them)
    while IFS= read -r header; do
        header="${header%%$'\r'}"
        [[ -z "$header" ]] && break
    done

    # Parse path and query string
    local endpoint query node role
    endpoint="${path%%\?*}"
    query="${path#*\?}"
    node=$(echo "$query"  | grep -oP '(?<=node=)[^&]*' || true)
    role=$(echo "$query"  | grep -oP '(?<=role=)[^&]*' || true)

    log "${method} ${path}  (node='${node}' role='${role}')"

    case "$endpoint" in
        /health)
            http_response "200 OK" '{"status":"ok"}'
            ;;

        /vote)
            if [[ "$method" == "DELETE" ]]; then
                # Release the master lock
                local lock_data
                lock_data=$(read_lock)
                if [[ -n "$lock_data" && "$(lock_owner "$lock_data")" == "$node" ]]; then
                    delete_lock
                    log "Lock released by ${node}."
                    http_response "200 OK" '{"released":true}'
                else
                    http_response "200 OK" '{"released":false,"reason":"not_owner"}'
                fi

            elif [[ "$method" == "GET" && "$role" == "master" ]]; then
                # A node wants to become master
                local lock_data owner
                lock_data=$(read_lock)

                if [[ -z "$lock_data" ]] || lock_is_expired "$lock_data"; then
                    write_lock "$node"
                    log "Lock GRANTED to ${node}."
                    http_response "200 OK" '{"granted":true}'
                else
                    owner=$(lock_owner "$lock_data")
                    if [[ "$owner" == "$node" ]]; then
                        # Same node refreshing its lock
                        write_lock "$node"
                        http_response "200 OK" '{"granted":true}'
                    else
                        log "Lock DENIED for ${node} – current owner: ${owner}."
                        http_response "409 Conflict" "{\"granted\":false,\"current_master\":\"${owner}\"}"
                    fi
                fi
            else
                http_response "400 Bad Request" '{"error":"invalid_request"}'
            fi
            ;;

        *)
            http_response "404 Not Found" '{"error":"not_found"}'
            ;;
    esac
}

# ── Main: accept connections with socat ──────────────────────────────────────
log "Quorum Witness starting on port ${PORT}."
exec socat TCP-LISTEN:${PORT},reuseaddr,fork \
    EXEC:"bash -c 'source ${BASH_SOURCE[0]}; handle_request'"

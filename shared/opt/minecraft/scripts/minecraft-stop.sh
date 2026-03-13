#!/usr/bin/env bash
# minecraft-stop.sh – called by ExecStop in minecraft@.service
# Sends "stop" to the server's stdin via screen/tmux, waits for clean shutdown.
# Argument: $1 = instance name (e.g. "survival")
set -euo pipefail
INSTANCE="${1:-unknown}"
SCREEN="mc-${INSTANCE}"

if screen -list | grep -q "${SCREEN}"; then
    screen -S "${SCREEN}" -p 0 -X stuff "stop$(printf '\r')"
    echo "stop command sent to ${SCREEN}. Waiting for shutdown..."
    # Give Minecraft up to 55 s to save and exit (TimeoutStopSec=60 in unit)
    for i in $(seq 1 55); do
        screen -list | grep -q "${SCREEN}" || { echo "${INSTANCE} stopped cleanly."; exit 0; }
        sleep 1
    done
    echo "WARNING: ${INSTANCE} did not stop cleanly within 55 s – systemd will SIGKILL."
else
    echo "No screen session '${SCREEN}' found – server may already be stopped."
fi

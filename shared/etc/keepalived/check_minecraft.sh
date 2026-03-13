#!/usr/bin/env bash
# keepalived health-check – verifies Velocity is accepting TCP connections.
# Returns 0 (OK) or 1 (fail → keepalived lowers priority → possible failover).
# shellcheck source=/dev/null
source /etc/minecraft-ha/config.env

(echo >/dev/tcp/127.0.0.1/"${PROXY_PORT}") >/dev/null 2>&1
exit $?

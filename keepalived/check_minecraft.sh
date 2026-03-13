#!/usr/bin/env bash
# =============================================================================
# Keepalived health-check script
# Called every 2 s by keepalived on both nodes.
# Returns 0 (success) when the Velocity proxy is accepting TCP connections.
# Returns 1 (failure) when the proxy is unreachable → keepalived lowers the
# priority of this node and (if it becomes the lowest) triggers a failover.
# =============================================================================

PROXY_PORT=25565   # Velocity listen port
TIMEOUT=2          # seconds to wait for TCP connection

# Use bash's built-in TCP pseudo-device for a dependency-free check
(echo >/dev/tcp/127.0.0.1/${PROXY_PORT}) >/dev/null 2>&1
exit $?

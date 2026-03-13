#!/usr/bin/env bash
# ==============================================================================
# deploy.sh  –  Generates per-node directories from config.env
# ==============================================================================
# Usage:
#   ./deploy.sh
#
# Output:
#   dist/node-a/    – ready to rsync to Node A,   then run: sudo ./install.sh
#   dist/node-b/    – ready to rsync to Node B,   then run: sudo ./install.sh
#   dist/witness/   – ready to rsync to Witness,  then run: sudo ./install.sh
#
# All @@VAR@@ placeholders in config files are replaced with values from
# config.env.  Bash scripts are copied unchanged – they source config.env
# at runtime from /etc/minecraft-ha/config.env (installed by install.sh).
# ==============================================================================

set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${REPO}/config.env"
DIST="${REPO}/dist"

# ── Load config ───────────────────────────────────────────────────────────────
[[ -f "$CONFIG" ]] || { echo "ERROR: config.env not found at $CONFIG"; exit 1; }
# shellcheck source=/dev/null
source "$CONFIG"

echo "==> Loaded config.env"
echo "    NODE_A_IP   = $NODE_A_IP"
echo "    NODE_B_IP   = $NODE_B_IP"
echo "    WITNESS_IP  = $WITNESS_IP"
echo "    FLOATING_IP = $FLOATING_IP"
echo ""

# ── Build sed substitution expression ────────────────────────────────────────
build_sed() {
    local s=""
    s+="s|@@NODE_A_IP@@|${NODE_A_IP}|g;"
    s+="s|@@NODE_B_IP@@|${NODE_B_IP}|g;"
    s+="s|@@WITNESS_IP@@|${WITNESS_IP}|g;"
    s+="s|@@FLOATING_IP@@|${FLOATING_IP}|g;"
    s+="s|@@NIC@@|${NIC}|g;"
    s+="s|@@VRRP_ROUTER_ID@@|${VRRP_ROUTER_ID}|g;"
    s+="s|@@VRRP_AUTH_PASS@@|${VRRP_AUTH_PASS}|g;"
    s+="s|@@NODE_A_PRIORITY@@|${NODE_A_PRIORITY}|g;"
    s+="s|@@NODE_B_PRIORITY@@|${NODE_B_PRIORITY}|g;"
    s+="s|@@PROXY_PORT@@|${PROXY_PORT}|g;"
    s+="s|@@SURVIVAL_PORT@@|${SURVIVAL_PORT}|g;"
    s+="s|@@LOBBY_PORT@@|${LOBBY_PORT}|g;"
    s+="s|@@CREATIVE_PORT@@|${CREATIVE_PORT}|g;"
    s+="s|@@REDIS_PORT@@|${REDIS_PORT}|g;"
    s+="s|@@REDIS_PASSWORD@@|${REDIS_PASSWORD}|g;"
    s+="s|@@WITNESS_PORT@@|${WITNESS_PORT}|g;"
    s+="s|@@QUORUM_SAFE_MODE@@|${QUORUM_SAFE_MODE}|g;"
    s+="s|@@WORLD_MOUNT@@|${WORLD_MOUNT}|g;"
    s+="s|@@GLUSTER_VOLUME@@|${GLUSTER_VOLUME}|g;"
    s+="s|@@VELOCITY_FORWARDING_SECRET@@|${VELOCITY_FORWARDING_SECRET}|g;"
    s+="s|@@MYSQL_HOST@@|${MYSQL_HOST}|g;"
    s+="s|@@MYSQL_PORT@@|${MYSQL_PORT}|g;"
    s+="s|@@MYSQL_DATABASE@@|${MYSQL_DATABASE}|g;"
    s+="s|@@MYSQL_USER@@|${MYSQL_USER}|g;"
    s+="s|@@MYSQL_PASSWORD@@|${MYSQL_PASSWORD}|g;"
    s+="s|@@OPS_EMAIL@@|${OPS_EMAIL}|g;"
    echo "$s"
}

SED_EXPR="$(build_sed)"

# ── Helper: copy a source tree into a destination, substituting @@VAR@@ ──────
deploy_tree() {
    local src="$1" dst="$2"
    [[ -d "$src" ]] || return 0
    mkdir -p "$dst"
    # Copy all files preserving relative paths (process substitution avoids subshell)
    while IFS= read -r rel; do
        local src_file="${src}/${rel}"
        local dst_file="${dst}/${rel}"
        mkdir -p "$(dirname "$dst_file")"
        sed "$SED_EXPR" "$src_file" > "$dst_file"
        # Preserve executable bit
        if [[ -x "$src_file" ]]; then chmod +x "$dst_file"; fi
    done < <(cd "$src" && find . -type f)
}

# ── Wipe and recreate dist/ ───────────────────────────────────────────────────
rm -rf "$DIST"
mkdir -p "$DIST"

# ── Generate each node ────────────────────────────────────────────────────────
for NODE in node-a node-b witness; do
    echo "==> Generating dist/${NODE}/ ..."
    TARGET="${DIST}/${NODE}"
    mkdir -p "$TARGET"

    # 1. Shared files (common to node-a and node-b; witness gets only config.env)
    if [[ "$NODE" != "witness" ]]; then
        deploy_tree "${REPO}/shared" "$TARGET"
    fi

    # 2. Node-specific files (override / extend shared)
    deploy_tree "${REPO}/${NODE}" "$TARGET"

    # 3. Place a copy of config.env so install.sh and runtime scripts can find it
    mkdir -p "${TARGET}/etc/minecraft-ha"
    cp "$CONFIG" "${TARGET}/etc/minecraft-ha/config.env"

    # 4. Make all scripts executable
    find "$TARGET" -name "*.sh" -exec chmod +x {} \;

    echo "    done → ${TARGET}"
done

echo ""
echo "==> All nodes generated in dist/"
echo ""
echo "Next steps:"
echo "  # Copy to Node A and install:"
echo "  rsync -av dist/node-a/  root@${NODE_A_IP}:/opt/minecraft-ha-deploy/"
echo "  ssh root@${NODE_A_IP} 'bash /opt/minecraft-ha-deploy/install.sh'"
echo ""
echo "  # Copy to Node B and install:"
echo "  rsync -av dist/node-b/  root@${NODE_B_IP}:/opt/minecraft-ha-deploy/"
echo "  ssh root@${NODE_B_IP} 'bash /opt/minecraft-ha-deploy/install.sh'"
echo ""
echo "  # Copy to Witness and install:"
echo "  rsync -av dist/witness/ root@${WITNESS_IP}:/opt/minecraft-ha-deploy/"
echo "  ssh root@${WITNESS_IP} 'bash /opt/minecraft-ha-deploy/install.sh'"

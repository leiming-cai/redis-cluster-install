#!/usr/bin/env bash
# add-node.sh — Add a new Redis instance to an existing cluster.
# Usage: bash add-node.sh NEW_HOST NEW_PORT EXISTING_HOST EXISTING_PORT
# Where NEW_PORT becomes a new master or replica of EXISTING_PORT's master.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$REPO_ROOT/lib/common.sh"
. "$REPO_ROOT/lib/ssh.sh"
. "$REPO_ROOT/lib/config_gen.sh"
. "$REPO_ROOT/lib/systemd.sh"
. "$REPO_ROOT/lib/password.sh"

REDIS_PREFIX="${REDIS_PREFIX:-/opt/software/redis}"
REDIS_BIN="$REDIS_PREFIX/bin"

NEW_HOST="${1:-}"; NEW_PORT="${2:-}"
EXIST_HOST="${3:-}"; EXIST_PORT="${4:-}"

if [ -z "$NEW_HOST" ] || [ -z "$EXIST_HOST" ]; then
    sed -n '2,5p' "$0"
    exit 1
fi

NEW_USER="${NEW_USER:-$(whoami)}"
NEW_SSH_PORT="${NEW_SSH_PORT:-22}"
EXIST_USER="${EXIST_USER:-$(whoami)}"
EXIST_SSH_PORT="${EXIST_SSH_PORT:-22}"
NEW_PASS="${NEW_PASS:-}"
EXIST_PASS="${EXIST_PASS:-}"

PASSWORD_FILE="$REPO_ROOT/secrets/cluster_password.txt"
[ -f "$PASSWORD_FILE" ] || die "missing $PASSWORD_FILE"
CLUSTER_PASS=$(cat "$PASSWORD_FILE")

log_info "Adding $NEW_HOST:$NEW_PORT to cluster (joining via $EXIST_HOST:$EXIST_PORT)..."

# Push the auth file
ssh_run "$NEW_USER" "$NEW_PASS" "$NEW_HOST" "$NEW_SSH_PORT" bash -s "$NEW_PASS" "$CLUSTER_PASS" <<'REMOTE'
set -e
SUDO_PASS="$1"
AUTH_CONTENT="$2"
_sudo() {
    if sudo -n true 2>/dev/null; then
        sudo -n "$@"
    elif [ -n "$SUDO_PASS" ]; then
        echo "$SUDO_PASS" | sudo -S -p '' "$@" 2>/dev/null
    else
        sudo "$@"
    fi
}
_sudo mkdir -p /etc/redis/cluster
_sudo tee /etc/redis/cluster/auth.conf >/dev/null <<<"$AUTH_CONTENT"
_sudo chown redis:redis /etc/redis/cluster/auth.conf
_sudo chmod 600 /etc/redis/cluster/auth.conf
REMOTE

# Push the redis.conf
out=$(render_redis_conf "$REPO_ROOT/config/redis.conf.template" "$NEW_PORT" "$CLUSTER_PASS" "node-${NEW_PORT}" "0.0.0.0")
ssh_run "$NEW_USER" "$NEW_PASS" "$NEW_HOST" "$NEW_SSH_PORT" bash -s "$NEW_PASS" "$NEW_PORT" "$out" <<'REMOTE'
set -e
SUDO_PASS="$1"
PORT="$2"
CONF_CONTENT="$3"
_sudo() {
    if sudo -n true 2>/dev/null; then
        sudo -n "$@"
    elif [ -n "$SUDO_PASS" ]; then
        echo "$SUDO_PASS" | sudo -S -p '' "$@" 2>/dev/null
    else
        sudo "$@"
    fi
}
_sudo mkdir -p /etc/redis/cluster
_sudo tee "/etc/redis/cluster/redis-${PORT}.conf" >/dev/null <<<"$CONF_CONTENT"
_sudo chown redis:redis "/etc/redis/cluster/redis-${PORT}.conf"
_sudo chmod 640 "/etc/redis/cluster/redis-${PORT}.conf"
REMOTE

# Push the systemd unit
unit=$(render_systemd_unit "$REPO_ROOT/config/redis-cluster.service.template" "$NEW_PORT" "node-${NEW_PORT}" "$CLUSTER_PASS")
ssh_run "$NEW_USER" "$NEW_PASS" "$NEW_HOST" "$NEW_SSH_PORT" bash -s "$NEW_PASS" "$NEW_PORT" "$unit" <<'REMOTE'
set -e
SUDO_PASS="$1"
PORT="$2"
UNIT_CONTENT="$3"
_sudo() {
    if sudo -n true 2>/dev/null; then
        sudo -n "$@"
    elif [ -n "$SUDO_PASS" ]; then
        echo "$SUDO_PASS" | sudo -S -p '' "$@" 2>/dev/null
    else
        sudo "$@"
    fi
}
_sudo tee "/etc/systemd/system/redis-${PORT}.service" >/dev/null <<<"$UNIT_CONTENT"
_sudo chmod 644 "/etc/systemd/system/redis-${PORT}.service"
REMOTE

# Ensure the per-port data dir exists and start the service
ssh_run "$NEW_USER" "$NEW_PASS" "$NEW_HOST" "$NEW_SSH_PORT" bash -s "$NEW_PASS" "$NEW_PORT" <<'REMOTE'
set -e
SUDO_PASS="$1"
PORT="$2"
_sudo() {
    if sudo -n true 2>/dev/null; then
        sudo -n "$@"
    elif [ -n "$SUDO_PASS" ]; then
        echo "$SUDO_PASS" | sudo -S -p '' "$@" 2>/dev/null
    else
        sudo "$@"
    fi
}
_sudo mkdir -p "/var/lib/redis/cluster/${PORT}" "/var/run/redis/cluster/${PORT}"
_sudo chown -R redis:redis /var/lib/redis /var/log/redis /var/run/redis
_sudo systemctl daemon-reload
_sudo systemctl enable "redis-${PORT}"
_sudo systemctl restart "redis-${PORT}"
REMOTE

# Join the cluster
ssh_run "$EXIST_USER" "$EXIST_PASS" "$EXIST_HOST" "$EXIST_SSH_PORT" bash -s "$EXIST_PASS" "$CLUSTER_PASS" "$NEW_HOST" "$NEW_PORT" "$EXIST_HOST" "$EXIST_PORT" <<'REMOTE'
set -e
SUDO_PASS="$1"
CLUSTER_PASS="$2"
NEW_HOST="$3"
NEW_PORT="$4"
EXIST_HOST="$5"
EXIST_PORT="$6"
_sudo() {
    if sudo -n true 2>/dev/null; then
        sudo -n "$@"
    elif [ -n "$SUDO_PASS" ]; then
        echo "$SUDO_PASS" | sudo -S -p '' "$@" 2>/dev/null
    else
        sudo "$@"
    fi
}
# redis-cli lives wherever install.sh put it (default /opt/software/redis/bin)
REDIS_BIN=${REDIS_PREFIX:-/opt/software/redis}/bin
_sudo "$REDIS_BIN/redis-cli" -a "$CLUSTER_PASS" --cluster add-node "$NEW_HOST:$NEW_PORT" "$EXIST_HOST:$EXIST_PORT"
REMOTE

log_ok "Node $NEW_HOST:$NEW_PORT added. Use 'redis-cli --cluster rebalance' to redistribute slots."

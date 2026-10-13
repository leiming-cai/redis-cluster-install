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

# IMPORTANT: all file content travels via scp (single-line paths), never as
# positional args to bash. Multi-line args via ssh trigger a parser bug on
# some sshd versions where newlines in args get re-injected as stdin to
# the bash script — which then interprets the file content as commands.

# === Push auth.conf via scp ===
local_tmpf=$(mktemp)
printf '%s' "$CLUSTER_PASS" > "$local_tmpf"
ssh_copy "$NEW_USER" "$NEW_PASS" "$NEW_HOST" "$NEW_SSH_PORT" "$local_tmpf" "/tmp/redis-cluster-auth.conf" \
    || { rm -f "$local_tmpf"; die "scp auth.conf to $NEW_HOST failed"; }
rm -f "$local_tmpf"

ssh_run "$NEW_USER" "$NEW_PASS" "$NEW_HOST" "$NEW_SSH_PORT" bash -s "$NEW_PASS" <<'REMOTE'
set -e
SUDO_PASS="$1"
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
_sudo cp /tmp/redis-cluster-auth.conf /etc/redis/cluster/auth.conf
_sudo chown redis:redis /etc/redis/cluster/auth.conf
_sudo chmod 600 /etc/redis/cluster/auth.conf
rm -f /tmp/redis-cluster-auth.conf
REMOTE

# === Push redis.conf via scp ===
local_tmpf=$(mktemp)
render_redis_conf "$REPO_ROOT/config/redis.conf.template" "$NEW_PORT" "$CLUSTER_PASS" "node-${NEW_PORT}" "0.0.0.0" "$REDIS_PREFIX" > "$local_tmpf"
ssh_copy "$NEW_USER" "$NEW_PASS" "$NEW_HOST" "$NEW_SSH_PORT" "$local_tmpf" "/tmp/redis-${NEW_PORT}.conf" \
    || { rm -f "$local_tmpf"; die "scp redis.conf to $NEW_HOST failed"; }
rm -f "$local_tmpf"

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
_sudo mkdir -p /etc/redis/cluster
_sudo cp "/tmp/redis-${PORT}.conf" "/etc/redis/cluster/redis-${PORT}.conf"
_sudo chown redis:redis "/etc/redis/cluster/redis-${PORT}.conf"
_sudo chmod 640 "/etc/redis/cluster/redis-${PORT}.conf"
rm -f "/tmp/redis-${PORT}.conf"
REMOTE

# === Push systemd unit via scp ===
local_tmpf=$(mktemp)
render_systemd_unit "$REPO_ROOT/config/redis-cluster.service.template" "$NEW_PORT" "node-${NEW_PORT}" "$CLUSTER_PASS" "$REDIS_PREFIX" > "$local_tmpf"
ssh_copy "$NEW_USER" "$NEW_PASS" "$NEW_HOST" "$NEW_SSH_PORT" "$local_tmpf" "/tmp/redis-${NEW_PORT}.service" \
    || { rm -f "$local_tmpf"; die "scp systemd unit to $NEW_HOST failed"; }
rm -f "$local_tmpf"

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
_sudo cp "/tmp/redis-${PORT}.service" "/etc/systemd/system/redis-${PORT}.service"
_sudo chmod 644 "/etc/systemd/system/redis-${PORT}.service"
rm -f "/tmp/redis-${PORT}.service"
REMOTE

# === Start the service ===
ssh_run "$NEW_USER" "$NEW_PASS" "$NEW_HOST" "$NEW_SSH_PORT" bash -s "$NEW_PASS" "$NEW_PORT" "$REDIS_PREFIX" <<'REMOTE'
set -e
SUDO_PASS="$1"
PORT="$2"
# Must match the prefix install.sh used, otherwise the generated unit and
# config point at different directories and redis cannot write its state.
REDIS_PREFIX="${3:-/opt/software/redis}"
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
_sudo mkdir -p "$REDIS_PREFIX/cluster/${PORT}" "$REDIS_PREFIX/log"
_sudo chown -R redis:redis /var/lib/redis /var/log/redis /var/run/redis "$REDIS_PREFIX/cluster" "$REDIS_PREFIX/log"
_sudo systemctl daemon-reload
_sudo systemctl enable "redis-${PORT}"
_sudo systemctl restart "redis-${PORT}"
REMOTE

# === Join the cluster (redis-cli --cluster add-node) ===
# This is a SINGLE-LINE arg, safe to pass as a positional argument.
ssh_run "$EXIST_USER" "$EXIST_PASS" "$EXIST_HOST" "$EXIST_SSH_PORT" bash -s "$EXIST_PASS" "$NEW_HOST" "$NEW_PORT" "$EXIST_HOST" "$EXIST_PORT" "$REDIS_PREFIX" <<'REMOTE'
set -e
SUDO_PASS="$1"
NEW_HOST="$2"
NEW_PORT="$3"
EXIST_HOST="$4"
EXIST_PORT="$5"
# REDIS_PREFIX must be forwarded explicitly: $1..$5 are already taken by the
# args above, so relying on the remote environment silently fell back to
# /opt/software/redis even when the operator set a custom REDIS_PREFIX.
REDIS_PREFIX="${6:-/opt/software/redis}"
REDIS_BIN="$REDIS_PREFIX/bin"
_sudo() {
    if sudo -n true 2>/dev/null; then
        sudo -n "$@"
    elif [ -n "$SUDO_PASS" ]; then
        echo "$SUDO_PASS" | sudo -S -p '' "$@" 2>/dev/null
    else
        sudo "$@"
    fi
}
# Pass password via -a (single short string) — no multi-line content here.
_sudo "$REDIS_BIN/redis-cli" -a "$(cat /etc/redis/cluster/auth.conf 2>/dev/null || echo '')" --cluster add-node "$NEW_HOST:$NEW_PORT" "$EXIST_HOST:$EXIST_PORT"
REMOTE

log_ok "Node $NEW_HOST:$NEW_PORT added. Use 'redis-cli --cluster rebalance' to redistribute slots."
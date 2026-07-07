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

NEW_HOST="${1:-}"; NEW_PORT="${2:-}"
EXIST_HOST="${3:-}"; EXIST_PORT="${4:-}"

if [ -z "$NEW_HOST" ] || [ -z "$EXIST_HOST" ]; then
    sed -n '2,5p' "$0"
    exit 1
fi

NEW_USER="${NEW_USER:-root}"
NEW_SSH_PORT="${NEW_SSH_PORT:-22}"
EXIST_USER="${EXIST_USER:-root}"
EXIST_SSH_PORT="${EXIST_SSH_PORT:-22}"
NEW_PASS="${NEW_PASS:-}"
EXIST_PASS="${EXIST_PASS:-}"

PASSWORD_FILE="$REPO_ROOT/secrets/cluster_password.txt"
[ -f "$PASSWORD_FILE" ] || die "missing $PASSWORD_FILE"
CLUSTER_PASS=$(cat "$PASSWORD_FILE")

log_info "Adding $NEW_HOST:$NEW_PORT to cluster (joining via $EXIST_HOST:$EXIST_PORT)..."

# Push the auth file
SSHPASS="$NEW_PASS" sshpass -e ssh -o StrictHostKeyChecking=accept-new -p "$NEW_SSH_PORT" "${NEW_USER}@${NEW_HOST}" \
    "cat > /etc/redis/cluster/auth.conf" <<<"$CLUSTER_PASS"
ssh_run "$NEW_USER" "$NEW_PASS" "$NEW_HOST" "$NEW_SSH_PORT" \
    "chown redis:redis /etc/redis/cluster/auth.conf && chmod 600 /etc/redis/cluster/auth.conf"

# Push the redis.conf
out=$(render_redis_conf "$REPO_ROOT/config/redis.conf.template" "$NEW_PORT" "$CLUSTER_PASS" "node-${NEW_PORT}" "0.0.0.0")
SSHPASS="$NEW_PASS" sshpass -e ssh -o StrictHostKeyChecking=accept-new -p "$NEW_SSH_PORT" "${NEW_USER}@${NEW_HOST}" \
    "cat > /etc/redis/cluster/redis-${NEW_PORT}.conf" <<<"$out"

# Push the systemd unit
unit=$(render_systemd_unit "$REPO_ROOT/config/redis-cluster.service.template" "$NEW_PORT" "node-${NEW_PORT}" "$CLUSTER_PASS")
SSHPASS="$NEW_PASS" sshpass -e ssh -o StrictHostKeyChecking=accept-new -p "$NEW_SSH_PORT" "${NEW_USER}@${NEW_HOST}" \
    "cat > /etc/systemd/system/redis-${NEW_PORT}.service" <<<"$unit"

# Ensure the per-port data dir exists
ssh_run "$NEW_USER" "$NEW_PASS" "$NEW_HOST" "$NEW_SSH_PORT" \
    "mkdir -p /var/lib/redis/cluster/${NEW_PORT} /var/run/redis/cluster/${NEW_PORT} && \
     chown -R redis:redis /var/lib/redis /var/log/redis /var/run/redis"

# Start the new instance
ssh_run "$NEW_USER" "$NEW_PASS" "$NEW_HOST" "$NEW_SSH_PORT" \
    "systemctl daemon-reload && systemctl enable redis-${NEW_PORT} && systemctl restart redis-${NEW_PORT}"

# Join the cluster
ssh_run "$EXIST_USER" "$EXIST_PASS" "$EXIST_HOST" "$EXIST_SSH_PORT" \
    "/usr/local/bin/redis-cli -a '$CLUSTER_PASS' --cluster add-node $NEW_HOST:$NEW_PORT $EXIST_HOST:$EXIST_PORT" \
    || die "cluster add-node failed"

log_ok "Node $NEW_HOST:$NEW_PORT added. Use 'redis-cli --cluster rebalance' to redistribute slots."
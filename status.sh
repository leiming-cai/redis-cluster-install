#!/usr/bin/env bash
# status.sh — Print cluster health, role table, slot distribution.
# Reads cluster password from secrets/cluster_password.txt and connects to A:6379.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$REPO_ROOT/lib/common.sh"
. "$REPO_ROOT/lib/cluster.sh"

PASSWORD_FILE="$REPO_ROOT/secrets/cluster_password.txt"
[ -f "$PASSWORD_FILE" ] || die "missing $PASSWORD_FILE — has install.sh been run?"
PASS=$(cat "$PASSWORD_FILE")

A_HOST="${A_HOST:-127.0.0.1}"
A_PORT="${A_PORT:-6379}"

log_info "Querying cluster info at $A_HOST:$A_PORT..."
info=$(redis-cli -a "$PASS" -h "$A_HOST" -p "$A_PORT" cluster info 2>/dev/null || true)

if ! echo "$info" > /tmp/cluster_info_status_$$ && is_cluster_healthy < /tmp/cluster_info_status_$$; then
    rm -f /tmp/cluster_info_status_$$
    log_error "cluster not healthy"
    echo "$info"
    exit 1
fi
rm -f /tmp/cluster_info_status_$$

echo
echo "== Cluster Info =="
echo "$info"
echo
echo "== Cluster Nodes =="
redis-cli -a "$PASS" -h "$A_HOST" -p "$A_PORT" cluster nodes 2>/dev/null
echo
echo "== Slot Distribution (first 20 ranges) =="
redis-cli -a "$PASS" -h "$A_HOST" -p "$A_PORT" cluster slots 2>/dev/null \
    | awk 'NR%2==1 {start=$1; end=$2} NR%2==0 {print start, end, $0}' \
    | head -20
echo
log_ok "Status check complete"
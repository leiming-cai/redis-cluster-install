#!/usr/bin/env bash
# uninstall.sh — Stop services, back up data, remove configs.
# Default: dry-run, prints what would happen.
# --force: actually delete.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$REPO_ROOT/lib/common.sh"
. "$REPO_ROOT/lib/prompt.sh"
. "$REPO_ROOT/lib/ssh.sh"

FORCE=0
case "${1:-}" in
    --force|-f) FORCE=1 ;;
    --help|-h)
        sed -n '2,8p' "$0"
        exit 0
        ;;
esac

PASSWORD_FILE="$REPO_ROOT/secrets/cluster_password.txt"

prompt_credentials() {
    A_HOST=$(read_default "  A host or IP" "")
    A_USER=$(read_default "  A SSH user" "root")
    A_PORT=$(read_default "  A SSH port" "22")
    A_PASS=$(read_secret "  A SSH password")
    B_HOST=$(read_default "  B host or IP" "")
    B_USER=$(read_default "  B SSH user" "root")
    B_PORT=$(read_default "  B SSH port" "22")
    B_PASS=$(read_secret "  B SSH password")
}
[ -z "${A_HOST:-}" ] && prompt_credentials

teardown() {
    local user="$1" pass="$2" host="$3" port="$4"
    if [ "$FORCE" = 1 ]; then
        log_info "tearing down $host..."
        ssh_run "$user" "$pass" "$host" "$port" bash -s <<'REMOTE' || true
set +e
for p in 6379 6380 6381 6382 6383 6384; do
    systemctl stop redis-$p 2>/dev/null
    systemctl disable redis-$p 2>/dev/null
    rm -f /etc/systemd/system/redis-$p.service
done
systemctl daemon-reload
if [ -d /var/lib/redis/cluster ]; then
    tar czf /tmp/redis-cluster-backup-$(date +%s).tar.gz /var/lib/redis/cluster
    rm -rf /var/lib/redis/cluster
fi
rm -rf /etc/redis/cluster /var/log/redis/cluster /var/run/redis/cluster
echo "torn down $host"
REMOTE
    else
        log_info "[dry-run] would tear down $host"
    fi
}

teardown "$A_USER" "$A_PASS" "$A_HOST" "$A_PORT"
teardown "$B_USER" "$B_PASS" "$B_HOST" "$B_PORT"

if [ "$FORCE" = 1 ]; then
    rm -f "$PASSWORD_FILE"
    log_ok "Local password file removed"
fi

#!/usr/bin/env bash
# uninstall.sh — Stop services, back up data, remove configs and binaries.
#
# Usage:
#   bash uninstall.sh              # dry-run (default): prints what would happen
#   bash uninstall.sh --force      # actually stop, back up and delete
#
# Requires: bash 4+, sshpass, openssh-client.
# Note: there is no --dry-run flag; dry-run is the behaviour when no flag is given.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$REPO_ROOT/lib/common.sh"
. "$REPO_ROOT/lib/prompt.sh"
. "$REPO_ROOT/lib/ssh.sh"

REDIS_PREFIX="${REDIS_PREFIX:-/opt/software/redis}"
REDIS_BIN="$REDIS_PREFIX/bin"

FORCE=0
case "${1:-}" in
    --force|-f) FORCE=1 ;;
    --help|-h)
        # Lines 2-9 are the usage comment block (kept in sync by hand).
        sed -n '2,9p' "$0"
        exit 0
        ;;
esac

PASSWORD_FILE="$REPO_ROOT/secrets/cluster_password.txt"

prompt_credentials() {
    A_HOST=$(read_default "  A host or IP" "")
    A_USER=$(read_default "  A SSH user" "$(whoami)")
    A_PORT=$(read_default "  A SSH port" "22")
    A_PASS=$(read_secret "  A SSH password")
    B_HOST=$(read_default "  B host or IP" "")
    B_USER=$(read_default "  B SSH user" "$(whoami)")
    B_PORT=$(read_default "  B SSH port" "22")
    B_PASS=$(read_secret "  B SSH password")
}
[ -z "${A_HOST:-}" ] && prompt_credentials

teardown() {
    local user="$1" pass="$2" host="$3" port="$4"
    if [ "$FORCE" = 1 ]; then
        log_info "tearing down $host..."
        ssh_run "$user" "$pass" "$host" "$port" bash -s "$pass" "$REDIS_PREFIX" <<'REMOTE' || true
set +e
SUDO_PASS="$1"
REDIS_PREFIX="$2"
_sudo() {
    if sudo -n true 2>/dev/null; then
        sudo -n "$@"
    elif [ -n "$SUDO_PASS" ]; then
        echo "$SUDO_PASS" | sudo -S -p '' "$@" 2>/dev/null
    else
        sudo "$@"
    fi
}
for p in 6379 6380 6381 6382 6383 6384; do
    _sudo systemctl stop redis-$p 2>/dev/null
    _sudo systemctl disable redis-$p 2>/dev/null
    _sudo rm -f /etc/systemd/system/redis-$p.service
done
_sudo systemctl daemon-reload
# Back up data
if [ -d /var/lib/redis/cluster ]; then
    _sudo tar czf /tmp/redis-cluster-backup-$(date +%s).tar.gz -C /var/lib/redis/cluster .
fi
# Remove config + data + logs + run
_sudo rm -rf /etc/redis/cluster
_sudo rm -rf /var/lib/redis/cluster
_sudo rm -rf /var/log/redis/cluster
_sudo rm -rf /var/run/redis/cluster
# Remove installed binaries
if [ -d "$REDIS_PREFIX" ]; then
    _sudo rm -rf "$REDIS_PREFIX"
fi
echo "torn down $host"
REMOTE
    else
        log_info "[dry-run] would tear down $host (services, configs, data, $REDIS_PREFIX)"
    fi
}

teardown "$A_USER" "$A_PASS" "$A_HOST" "$A_PORT"
teardown "$B_USER" "$B_PASS" "$B_HOST" "$B_PORT"

if [ "$FORCE" = 1 ]; then
    rm -f "$PASSWORD_FILE"
    log_ok "Local password file removed"
fi

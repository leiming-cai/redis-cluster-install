#!/usr/bin/env bash
# smoke-test.sh — End-to-end test in two Docker containers.
# Spins up sshd-enabled containers, runs an "apt-installed Redis" variant
# of install.sh logic, and verifies cluster is healthy.
#
# Requirements: docker, sshpass on the host.
# Usage: bash scripts/smoke-test.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_ROOT/lib/common.sh"
. "$REPO_ROOT/lib/password.sh"

require_cmd docker sshpass

# Cleanup any prior smoke test containers
cleanup() {
    docker rm -f smoke-a smoke-b >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

log_info "Starting smoke-a and smoke-b..."
docker run -d --name smoke-a -h smoke-a \
    -e SSH_USER=root -e SSH_PASSWORD=smokepw \
    -p 2222:22 rastasheep/ubuntu-sshd:18.04 >/dev/null
docker run -d --name smoke-b -h smoke-b \
    -e SSH_USER=root -e SSH_PASSWORD=smokepw \
    -p 2223:22 rastasheep/ubuntu-sshd:18.04 >/dev/null

# Wait for sshd to be ready
for i in $(seq 1 30); do
    if SSHPASS=smokepw sshpass -e ssh -o StrictHostKeyChecking=no -p 2222 root@127.0.0.1 true 2>/dev/null \
        && SSHPASS=smokepw sshpass -e ssh -o StrictHostKeyChecking=no -p 2223 root@127.0.0.1 true 2>/dev/null; then
        break
    fi
    sleep 1
done

log_info "Installing redis-server on both containers..."
for port in 2222 2223; do
    SSHPASS=smokepw sshpass -e ssh -p "$port" -o StrictHostKeyChecking=no root@127.0.0.1 \
        "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq redis-server redis-tools gcc make" \
        || die "apt-get install failed on port $port"
done

log_info "Setting up cluster manually (apt-installed variant)..."
# Provision dirs and user
for port in 2222 2223; do
    SSHPASS=smokepw sshpass -e ssh -p "$port" -o StrictHostKeyChecking=no root@127.0.0.1 \
        "id redis || useradd -r -s /usr/sbin/nologin redis
         mkdir -p /var/lib/redis/cluster /var/log/redis/cluster /etc/redis/cluster /var/run/redis/cluster
         chown -R redis:redis /var/lib/redis /var/log/redis /etc/redis /var/run/redis"
done

# Generate a shared password
# gen_password, not an inline `tr ... </dev/urandom | head -c 32`: that pipes
# an INFINITE stream into head, so the writer is killed by SIGPIPE and the
# pipeline's status is 141 -- which, under this script's `set -euo pipefail`,
# aborted the whole smoke test right here. On some coreutils builds tr also
# reports "tr: write error: Broken pipe" on stderr, which then lands in
# whatever captured the output.
PASS="$(gen_password 32)"
echo "$PASS" > "$REPO_ROOT/secrets/cluster_password.txt"
chmod 600 "$REPO_ROOT/secrets/cluster_password.txt"

# Render configs and start 3 instances on each container
for pair in "2222:127.0.0.1:6379:6380:6381" "2223:127.0.0.1:6382:6383:6384"; do
    IFS=: read -r ssh_port _ p1 p2 p3 <<<"$pair"
    for p in "$p1" "$p2" "$p3"; do
        mkdir -p "/tmp/redis-smoke/$p"
        cat > "/tmp/redis-smoke/$p/redis-$p.conf" <<CONF
port $p
cluster-enabled yes
cluster-config-file /var/lib/redis/cluster/$p/nodes.conf
cluster-node-timeout 5000
requirepass $PASS
masterauth $PASS
appendonly yes
dir /var/lib/redis/cluster/$p
logfile /var/log/redis/cluster/redis-$p.log
daemonize yes
pidfile /var/run/redis/cluster/redis-$p.pid
protected-mode no
bind 0.0.0.0
CONF
        SSHPASS=smokepw sshpass -e scp -P "$ssh_port" -o StrictHostKeyChecking=no \
            "/tmp/redis-smoke/$p/redis-$p.conf" "root@127.0.0.1:/etc/redis/cluster/redis-$p.conf"
        SSHPASS=smokepw sshpass -e ssh -p "$ssh_port" -o StrictHostKeyChecking=no root@127.0.0.1 \
            "mkdir -p /var/lib/redis/cluster/$p /var/run/redis/cluster
             chown -R redis:redis /var/lib/redis /var/log/redis /etc/redis /var/run/redis
             sudo -u redis redis-server /etc/redis/cluster/redis-$p.conf"
    done
done

# Create cluster
log_info "Creating cluster..."
SSHPASS=smokepw sshpass -e ssh -p 2222 -o StrictHostKeyChecking=no root@127.0.0.1 \
    "redis-cli --cluster create 127.0.0.1:6379 127.0.0.1:6380 127.0.0.1:6381 127.0.0.1:6382 127.0.0.1:6383 127.0.0.1:6384 --cluster-replicas 1 --cluster-yes -a '$PASS'"

# Verify
log_info "Verifying cluster health..."
info=$(SSHPASS=smokepw sshpass -e ssh -p 2222 -o StrictHostKeyChecking=no root@127.0.0.1 \
    "redis-cli -a '$PASS' cluster info")
if ! echo "$info" | grep -q "cluster_state:ok"; then
    die "cluster not healthy:\n$info"
fi
if ! echo "$info" | grep -q "cluster_known_nodes:6"; then
    die "expected 6 known nodes:\n$info"
fi

# Set/Get sanity
log_info "Testing set/get across nodes..."
SSHPASS=smokepw sshpass -e ssh -p 2222 -o StrictHostKeyChecking=no root@127.0.0.1 \
    "redis-cli -a '$PASS' -c SET smoke-test:hello world"
readback=$(SSHPASS=smokepw sshpass -e ssh -p 2223 -o StrictHostKeyChecking=no root@127.0.0.1 \
    "redis-cli -a '$PASS' -c GET smoke-test:hello" | tr -d '\r')
[ "$readback" = "world" ] || die "GET returned '$readback', expected 'world'"

log_ok "Smoke test PASSED"
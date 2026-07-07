#!/usr/bin/env bash
# install.sh — Deploy a 6-node Redis 8.8.0 cluster across 2 Linux machines.
#
# Usage:
#   bash install.sh                       # interactive (default)
#   bash install.sh --yes                 # non-interactive: re-use cached state if any
#   bash install.sh --uninstall           # same as running uninstall.sh --force
#
# Requires: bash 4+, sshpass, redis-cli (optional, for create step), openssh-client.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$REPO_ROOT/lib/common.sh"
# shellcheck source=lib/password.sh
. "$REPO_ROOT/lib/password.sh"
# shellcheck source=lib/prompt.sh
. "$REPO_ROOT/lib/prompt.sh"
# shellcheck source=lib/ssh.sh
. "$REPO_ROOT/lib/ssh.sh"
# shellcheck source=lib/config_gen.sh
. "$REPO_ROOT/lib/config_gen.sh"
# shellcheck source=lib/systemd.sh
. "$REPO_ROOT/lib/systemd.sh"
# shellcheck source=lib/cluster.sh
. "$REPO_ROOT/lib/cluster.sh"

# === Configuration ===
TARBALL="$REPO_ROOT/redis-8.8.0.tar.gz"
CONF_TEMPLATE="$REPO_ROOT/config/redis.conf.template"
SERVICE_TEMPLATE="$REPO_ROOT/config/redis-cluster.service.template"
SECRETS_DIR="$REPO_ROOT/secrets"
PASSWORD_FILE="$SECRETS_DIR/cluster_password.txt"

# A machine (3 instances)
A_HOST="" A_PORT="22" A_USER="" A_PASS=""
# B machine (3 instances)
B_HOST="" B_PORT="22" B_USER="" B_PASS=""

# A: 6379, 6380, 6381
# B: 6382, 6383, 6384
A_PORTS=(6379 6380 6381)
B_PORTS=(6382 6383 6384)

# === CLI parsing ===
ASSUME_YES=0
case "${1:-}" in
    --yes|-y) ASSUME_YES=1 ;;
    --uninstall) exec "$REPO_ROOT/uninstall.sh" --force ;;
    --help|-h)
        sed -n '2,12p' "$0"
        exit 0
        ;;
esac

# === Step 1: Generate cluster password ===
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"
if [ -f "$PASSWORD_FILE" ]; then
    CLUSTER_PASS=$(cat "$PASSWORD_FILE")
    log_info "Reusing existing cluster password from $PASSWORD_FILE"
else
    CLUSTER_PASS=$(gen_password 32)
    printf '%s' "$CLUSTER_PASS" > "$PASSWORD_FILE"
    chmod 600 "$PASSWORD_FILE"
    log_ok "Generated new cluster password"
fi

# === Step 2: Interactive prompt for SSH credentials ===
prompt_credentials() {
    log_info "Configure SSH access to node A (3 instances: 6379, 6380, 6381)"
    A_HOST=$(read_default "  A host or IP" "")
    [ -n "$A_HOST" ] || die "A host is required"
    A_USER=$(read_default "  A SSH user" "root")
    A_PORT=$(read_default "  A SSH port" "22")
    A_PASS=$(read_secret "  A SSH password")

    log_info "Configure SSH access to node B (3 instances: 6382, 6383, 6384)"
    B_HOST=$(read_default "  B host or IP" "")
    [ -n "$B_HOST" ] || die "B host is required"
    B_USER=$(read_default "  B SSH user" "root")
    B_PORT=$(read_default "  B SSH port" "22")
    B_PASS=$(read_secret "  B SSH password")

    if [ "$(read_confirm "Proceed with $A_USER@$A_HOST and $B_USER@$B_HOST?")" != "y" ]; then
        die "aborted by user"
    fi
}
if [ "$ASSUME_YES" = 0 ]; then
    prompt_credentials
else
    die "--yes mode requires credentials via env: A_USER A_HOST A_PORT A_PASS B_USER B_HOST B_PORT B_PASS"
fi

# === Step 3: Verify SSH connectivity ===
log_info "[3] Verifying SSH connectivity..."
ssh_check "$A_USER" "$A_PASS" "$A_HOST" "$A_PORT" || die "cannot reach $A_USER@$A_HOST:$A_PORT"
ssh_check "$B_USER" "$B_PASS" "$B_HOST" "$B_PORT" || die "cannot reach $B_USER@$B_HOST:$B_PORT"
log_ok "SSH connectivity verified"

# === Step 4: Verify toolchain on remote ===
log_info "[4] Verifying toolchain on remotes..."
verify_remote() {
    local user="$1" pass="$2" host="$3" port="$4"
    ssh_run "$user" "$pass" "$host" "$port" bash -s <<'REMOTE'
set -e
command -v gcc    >/dev/null || { echo "missing gcc"; exit 11; }
command -v make   >/dev/null || { echo "missing make"; exit 12; }
command -v tar    >/dev/null || { echo "missing tar"; exit 13; }
gcc_version=$(gcc -dumpversion | cut -d. -f1)
[ "$gcc_version" -ge 11 ] 2>/dev/null || { echo "gcc $gcc_version too old, need >= 11"; exit 14; }
ulimit -n | awk '{ if ($1 < 10001) { print "ulimit -n too low: " $1; exit 15; } }'
echo "toolchain OK"
REMOTE
}
verify_remote "$A_USER" "$A_PASS" "$A_HOST" "$A_PORT" || die "node A toolchain check failed"
verify_remote "$B_USER" "$B_PASS" "$B_HOST" "$B_PORT" || die "node B toolchain check failed"
log_ok "Toolchain verified on both nodes"

# === Step 5: scp tarball to both nodes ===
log_info "[5] Copying $TARBALL to both nodes..."
[ -f "$TARBALL" ] || die "tarball not found: $TARBALL"
ssh_copy "$A_USER" "$A_PASS" "$A_HOST" "$A_PORT" "$TARBALL" "/tmp/redis-8.8.0.tar.gz" || die "scp to A failed"
ssh_copy "$B_USER" "$B_PASS" "$B_HOST" "$B_PORT" "$TARBALL" "/tmp/redis-8.8.0.tar.gz" || die "scp to B failed"
log_ok "Tarball copied"

# === Step 6: Build on both nodes in parallel ===
log_info "[6] Building Redis on both nodes..."
build_remote() {
    local user="$1" pass="$2" host="$3" port="$4"
    ssh_run "$user" "$pass" "$host" "$port" bash -s <<'REMOTE'
set -e
cd /tmp
tar xzf redis-8.8.0.tar.gz
cd redis-8.8.0
make -C src BUILD_TLS=no USE_SYSTEMD=no -j"$(nproc)"
make -C src install PREFIX=/usr/local
echo "build OK"
REMOTE
}
build_remote "$A_USER" "$A_PASS" "$A_HOST" "$A_PORT" &
pid_a=$!
build_remote "$B_USER" "$B_PASS" "$B_HOST" "$B_PORT" &
pid_b=$!
wait "$pid_a" || die "build on A failed"
wait "$pid_b" || die "build on B failed"
log_ok "Build complete on both nodes"

# === Step 7: Create user and directories on both nodes ===
log_info "[7] Creating redis user and directories..."
provision_dirs() {
    local user="$1" pass="$2" host="$3" port="$4"
    ssh_run "$user" "$pass" "$host" "$port" bash -s <<'REMOTE'
set -e
id redis >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin redis
mkdir -p /etc/redis/cluster
mkdir -p /var/lib/redis/cluster
mkdir -p /var/log/redis/cluster
mkdir -p /var/run/redis/cluster
chown -R redis:redis /var/lib/redis /var/log/redis /var/run/redis /etc/redis
echo "dirs OK"
REMOTE
}
provision_dirs "$A_USER" "$A_PASS" "$A_HOST" "$A_PORT" &
pid_a=$!
provision_dirs "$B_USER" "$B_PASS" "$B_HOST" "$B_PORT" &
pid_b=$!
wait "$pid_a" || die "dirs on A failed"
wait "$pid_b" || die "dirs on B failed"
log_ok "Directories provisioned"

# === Step 8: Push cluster auth file ===
log_info "[8] Pushing cluster auth file..."
push_auth() {
    local user="$1" pass="$2" host="$3" port="$4"
    # Use a here-doc to stream a single line via ssh, then chown on remote.
    SSHPASS="$pass" sshpass -e ssh -o StrictHostKeyChecking=accept-new -p "$port" "${user}@${host}" \
        "bash -c 'mkdir -p /etc/redis/cluster && cat > /etc/redis/cluster/auth.conf && chown redis:redis /etc/redis/cluster/auth.conf && chmod 600 /etc/redis/cluster/auth.conf'" \
        <<<"$CLUSTER_PASS"
}
push_auth "$A_USER" "$A_PASS" "$A_HOST" "$A_PORT" || die "auth file to A failed"
push_auth "$B_USER" "$B_PASS" "$B_HOST" "$B_PORT" || die "auth file to B failed"
log_ok "Auth file deployed"

# === Step 9: Render per-instance redis.conf ===
log_info "[9] Rendering 6 instance configs..."
render_and_push() {
    local user="$1" pass="$2" host="$3" port="$4" p
    for p in "${@:5}"; do
        local out
        out=$(render_redis_conf "$CONF_TEMPLATE" "$p" "$CLUSTER_PASS" "node-${p}" "0.0.0.0")
        SSHPASS="$pass" sshpass -e ssh -o StrictHostKeyChecking=accept-new -p "$port" "${user}@${host}" \
            "cat > /etc/redis/cluster/redis-${p}.conf && chown redis:redis /etc/redis/cluster/redis-${p}.conf && chmod 640 /etc/redis/cluster/redis-${p}.conf" \
            <<<"$out"
    done
}
render_and_push "$A_USER" "$A_PASS" "$A_HOST" "$A_PORT" "${A_PORTS[@]}" || die "config render/push to A failed"
render_and_push "$B_USER" "$B_PASS" "$B_HOST" "$B_PORT" "${B_PORTS[@]}" || die "config render/push to B failed"
log_ok "Instance configs rendered"

# === Step 10: Render systemd unit ===
log_info "[10] Rendering and pushing systemd units..."
push_units() {
    local user="$1" pass="$2" host="$3" port="$4" p
    for p in "${@:5}"; do
        local out
        out=$(render_systemd_unit "$SERVICE_TEMPLATE" "$p" "node-${p}" "$CLUSTER_PASS")
        SSHPASS="$pass" sshpass -e ssh -o StrictHostKeyChecking=accept-new -p "$port" "${user}@${host}" \
            "cat > /etc/systemd/system/redis-${p}.service" \
            <<<"$out"
    done
}
push_units "$A_USER" "$A_PASS" "$A_HOST" "$A_PORT" "${A_PORTS[@]}" || die "units to A failed"
push_units "$B_USER" "$B_PASS" "$B_HOST" "$B_PORT" "${B_PORTS[@]}" || die "units to B failed"
log_ok "systemd units rendered"

# === Step 11: Start services ===
log_info "[11] Starting services on both nodes..."
start_services() {
    local user="$1" pass="$2" host="$3" port="$4" p
    for p in "${@:5}"; do
        ssh_run "$user" "$pass" "$host" "$port" \
            "systemctl daemon-reload && systemctl enable redis-${p} && systemctl restart redis-${p}" \
            || { echo "start failed on $host:$p" >&2; return 1; }
    done
}
start_services "$A_USER" "$A_PASS" "$A_HOST" "$A_PORT" "${A_PORTS[@]}" || die "start on A failed"
start_services "$B_USER" "$B_PASS" "$B_HOST" "$B_PORT" "${B_PORTS[@]}" || die "start on B failed"

# Verify each instance is responding
verify_ping() {
    local user="$1" pass="$2" host="$3" port="$4" p
    for p in "${@:5}"; do
        ssh_run "$user" "$pass" "$host" "$port" \
            "/usr/local/bin/redis-cli -a '$CLUSTER_PASS' -p $p PING" \
            | grep -q PONG \
            || { echo "ping failed on $host:$p" >&2; return 1; }
    done
}
verify_ping "$A_USER" "$A_PASS" "$A_HOST" "$A_PORT" "${A_PORTS[@]}" || die "PING on A failed"
verify_ping "$B_USER" "$B_PASS" "$B_HOST" "$B_PORT" "${B_PORTS[@]}" || die "PING on B failed"
log_ok "All 6 instances responding to PING"

# === Step 12: Check if cluster already created ===
log_info "[12] Checking cluster state..."
existing_info=$(ssh_run "$A_USER" "$A_PASS" "$A_HOST" "$A_PORT" \
    "/usr/local/bin/redis-cli -a '$CLUSTER_PASS' -p 6379 cluster info" || true)
# Use a tmpfile for safe parsing
if echo "$existing_info" > /tmp/cluster_info_$$ && is_cluster_healthy < /tmp/cluster_info_$$; then
    log_ok "Cluster already healthy, skipping create"
    rm -f /tmp/cluster_info_$$
else
    rm -f /tmp/cluster_info_$$
    log_info "Creating cluster..."
    # Build the create command
    create_args=()
    for p in "${A_PORTS[@]}"; do create_args+=("$A_HOST:$p"); done
    for p in "${B_PORTS[@]}"; do create_args+=("$B_HOST:$p"); done

    # We need redis-cli on the local control machine. If not, ssh to A and run from there.
    if command -v redis-cli >/dev/null 2>&1; then
        redis-cli --cluster create "${create_args[@]}" \
            --cluster-replicas 1 --cluster-yes \
            -a "$CLUSTER_PASS" \
            || die "redis-cli --cluster create failed"
    else
        log_warn "redis-cli not on control machine; running create from node A"
        ssh_run "$A_USER" "$A_PASS" "$A_HOST" "$A_PORT" \
            "/usr/local/bin/redis-cli --cluster create $(printf '%s ' "${create_args[@]}") --cluster-replicas 1 --cluster-yes -a '$CLUSTER_PASS'" \
            || die "redis-cli --cluster create from A failed"
    fi
fi

# === Step 13: Final health check ===
log_info "[13] Verifying cluster health..."
final=$(ssh_run "$A_USER" "$A_PASS" "$A_HOST" "$A_PORT" \
    "/usr/local/bin/redis-cli -a '$CLUSTER_PASS' -p 6379 cluster info" || true)
if echo "$final" > /tmp/cluster_final_$$ && is_cluster_healthy < /tmp/cluster_final_$$; then
    rm -f /tmp/cluster_final_$$
    log_ok "Cluster is healthy"
else
    rm -f /tmp/cluster_final_$$
    die "cluster health check failed:\n$final"
fi

# === Step 14: Print summary card ===
cat <<CARD

==========================================
 Redis Cluster READY
==========================================
 Nodes:
   A  $A_HOST : ${A_PORTS[*]}
   B  $B_HOST : ${B_PORTS[*]}
 Auth password file: $PASSWORD_FILE
 To connect:  redis-cli -c -a "\$(cat $PASSWORD_FILE)" -h $A_HOST -p 6379
 Other scripts: status.sh  uninstall.sh  add-node.sh
==========================================
CARD
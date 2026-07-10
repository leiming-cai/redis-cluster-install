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
REDIS_PREFIX="${REDIS_PREFIX:-/opt/software/redis}"   # install root; bin/ ends up under here
REDIS_BIN="$REDIS_PREFIX/bin"

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
    A_USER=$(read_default "  A SSH user" "$(whoami)")
    A_PORT=$(read_default "  A SSH port" "22")
    A_PASS=$(read_secret "  A SSH password")

    log_info "Configure SSH access to node B (3 instances: 6382, 6383, 6384)"
    B_HOST=$(read_default "  B host or IP" "")
    [ -n "$B_HOST" ] || die "B host is required"
    B_USER=$(read_default "  B SSH user" "$(whoami)")
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
command -v make   >/dev/null || { echo "missing make"; exit 12; }
command -v tar    >/dev/null || { echo "missing tar"; exit 13; }
ulimit -n | awk '{ if ($1 < 10001) { print "ulimit -n too low: " $1; exit 15; } }'

# --- GCC 11+ detection ---
# Search a list of common locations/variants in order of preference.
# Redis 8 requires GCC 7+ (uses __builtin_cpu_supports and C11 features).
gcc_ok=0
for gcc_candidate in \
    gcc-14 \
    gcc-13 \
    gcc-12 \
    gcc-11 \
    gcc-10 \
    gcc-9 \
    gcc-8 \
    gcc-7 \
    /opt/rh/gcc-toolset-11/root/bin/gcc \
    /opt/rh/devtoolset-11/root/bin/gcc \
    /opt/rh/gcc-toolset-12/root/bin/gcc \
    /opt/rh/devtoolset-12/root/bin/gcc \
    gcc; do
    if command -v "$gcc_candidate" >/dev/null 2>&1 || [ -x "$gcc_candidate" ]; then
        gcc_version=$("$gcc_candidate" -dumpversion 2>/dev/null | cut -d. -f1) || continue
        if [ "${gcc_version:-0}" -ge 7 ] 2>/dev/null; then
            # Pick matching g++ if possible
            case "$gcc_candidate" in
                gcc-*)  cxx_candidate="${gcc_candidate}g++" ;;  # gcc-11 -> g++-11
                /opt/rh/*gcc-toolset-11/*) cxx_candidate="/opt/rh/gcc-toolset-11/root/bin/g++" ;;
                /opt/rh/*devtoolset-11/*)  cxx_candidate="/opt/rh/devtoolset-11/root/bin/g++" ;;
                /opt/rh/*gcc-toolset-12/*) cxx_candidate="/opt/rh/gcc-toolset-12/root/bin/g++" ;;
                /opt/rh/*devtoolset-12/*)  cxx_candidate="/opt/rh/devtoolset-12/root/bin/g++" ;;
                *)       cxx_candidate="g++" ;;
            esac
            if command -v "$cxx_candidate" >/dev/null 2>&1 || [ -x "$cxx_candidate" ]; then
                echo "  using CC=$gcc_candidate (version $gcc_version), CXX=$cxx_candidate"
            else
                echo "  using CC=$gcc_candidate (version $gcc_version) — g++ not found, may break C++ builds"
                cxx_candidate="g++"
            fi
            # Persist for later build steps in this session
            echo "export CC=$gcc_candidate"     > /tmp/.redis-cluster-build-env
            echo "export CXX=$cxx_candidate"    >> /tmp/.redis-cluster-build-env
            gcc_ok=1
            break
        fi
    fi
done

if [ "$gcc_ok" != "1" ]; then
    found_gcc=$(command -v gcc 2>/dev/null || echo "not found")
    found_ver=""
    if [ -x "$found_gcc" ]; then
        found_ver=$("$found_gcc" -dumpversion 2>/dev/null)
    fi
    echo "ERROR: GCC 7+ required (Redis 8 build dependency)"
    echo "       Found: ${found_gcc}${found_ver:+ (version $found_ver)}"
    echo ""
    echo "Install GCC 7+ on this node:"
    if command -v dnf >/dev/null 2>&1; then
        echo "  # Fedora / RHEL 8+ (dnf)"
        echo "  sudo dnf install -y gcc-toolset-11"
        echo "  # or for older Fedora: sudo dnf install -y gcc11 gcc11-c++"
    elif command -v yum >/dev/null 2>&1; then
        echo "  # RHEL 7 / CentOS 7 (yum)"
        echo "  sudo yum install -y centos-release-scl"
        echo "  sudo yum install -y devtoolset-11"
        echo "  # devtoolset installs to /opt/rh/devtoolset-11/ — install.sh will auto-detect it."
    elif command -v apt >/dev/null 2>&1; then
        echo "  # Debian / Ubuntu (apt)"
        echo "  sudo apt install -y gcc-7 g++-7"
        echo "  # gcc-7 installs to /usr/bin/gcc-7 — install.sh will auto-detect it."
        echo "  # (gcc-8/9/10/11 all work too — pick whichever your distro provides)"
    elif command -v apk >/dev/null 2>&1; then
        echo "  # Alpine (apk) — main repo gcc is typically 12+"
        echo "  sudo apk add gcc g++ musl-dev"
    else
        echo "  # Unknown package manager — install GCC 7+ via your OS package manager."
    fi
    echo ""
    echo "After installing, re-run install.sh — it will auto-detect the new compiler."
    exit 14
fi

command -v "$CXX" >/dev/null 2>&1 || command -v "g++" >/dev/null 2>&1 || {
    echo "missing g++ (required for C++ build)"; exit 16;
}
echo "toolchain OK"
REMOTE
}
verify_remote "$A_USER" "$A_PASS" "$A_HOST" "$A_PORT" || die "node A toolchain check failed"
verify_remote "$B_USER" "$B_PASS" "$B_HOST" "$B_PORT" || die "node B toolchain check failed"
log_ok "Toolchain verified on both nodes"

# === Step 4.5: Verify sudo access (if SSH user is not root) ===
log_info "[4.5] Verifying sudo access on remotes..."
verify_sudo() {
    local user="$1" pass="$2" host="$3" port="$4"
    # root user always has sudo
    if ssh_run "$user" "$pass" "$host" "$port" "id -u" 2>/dev/null | grep -qx 0; then
        log_info "  $user@$host: root user, sudo is implicit"
        return 0
    fi
    # Try passwordless sudo
    if ssh_run "$user" "$pass" "$host" "$port" "sudo -n true" 2>/dev/null; then
        log_info "  $user@$host: passwordless sudo available"
        return 0
    fi
    # Try with SSH password piped
    if printf '%s\n' "$pass" | SSHPASS="$pass" sshpass -e \
            ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
            -p "$port" "${user}@${host}" "sudo -S -p '' true" 2>/dev/null; then
        log_info "  $user@$host: sudo with password (will use SSH password)"
        return 0
    fi
    die "  $user@$host: sudo unavailable. Either configure NOPASSWD in /etc/sudoers (recommended), or ensure the sudo password matches the SSH password."
}
verify_sudo "$A_USER" "$A_PASS" "$A_HOST" "$A_PORT"
verify_sudo "$B_USER" "$B_PASS" "$B_HOST" "$B_PORT"
log_ok "sudo access verified on both nodes"

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
    # IMPORTANT: pass REDIS_PREFIX so the install PREFIX on the remote
    # matches the expected location. Without this, `make install` would
    # install to /usr/local (default PREFIX), but verify_ping looks for
    # the binary at $REDIS_BIN.
    ssh_run "$user" "$pass" "$host" "$port" bash -s "$pass" "$REDIS_PREFIX" <<'REMOTE'
set -e
SUDO_PASS="$1"
REDIS_PREFIX="$2"
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
if [ -x "$REDIS_BIN/redis-server" ] && [ -x "$REDIS_BIN/redis-cli" ]; then
    echo "already installed, skipping build"
    exit 0
fi
# Source the build env if step 4 wrote it (gives us CC/CXX when gcc-11 etc. was found)
if [ -f /tmp/.redis-cluster-build-env ]; then
    . /tmp/.redis-cluster-build-env
    echo "  using CC=${CC:-cc} CXX=${CXX:-c++}"
fi
cd /tmp
tar xzf redis-8.8.0.tar.gz
cd redis-8.8.0
make -C src BUILD_TLS=no USE_SYSTEMD=no CC="${CC:-gcc}" CXX="${CXX:-g++}" -j"$(nproc)"
_sudo make -C src install PREFIX="$REDIS_PREFIX"
echo "build OK"
echo "  installed to $REDIS_BIN"
ls "$REDIS_BIN" | head -3
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
    shift 4
    local ports=("$@")
    ssh_run "$user" "$pass" "$host" "$port" bash -s "$pass" "${ports[*]}" <<'REMOTE'
set -e
SUDO_PASS="$1"
PORTS="$2"
_sudo() {
    if sudo -n true 2>/dev/null; then
        sudo -n "$@"
    elif [ -n "$SUDO_PASS" ]; then
        echo "$SUDO_PASS" | sudo -S -p '' "$@" 2>/dev/null
    else
        sudo "$@"
    fi
}
id redis >/dev/null 2>&1 || _sudo useradd --system --no-create-home --shell /usr/sbin/nologin redis
_sudo mkdir -p /etc/redis/cluster /var/lib/redis/cluster /var/log/redis/cluster /var/run/redis/cluster
# Per-port subdirs (loop explicitly with one mkdir call per port, not bundled,
# so we can verify each one was created)
for p in $PORTS; do
    _sudo mkdir -p "/var/lib/redis/cluster/$p"
    _sudo mkdir -p "/var/run/redis/cluster/$p"
done
_sudo chown -R redis:redis /var/lib/redis /var/log/redis /var/run/redis /etc/redis
# Verify: every per-port data dir must exist
missing=""
for p in $PORTS; do
    if [ ! -d "/var/lib/redis/cluster/$p" ]; then
        missing="$missing $p"
    fi
done
if [ -n "$missing" ]; then
    echo "ERROR: missing data dirs for ports:$missing" >&2
    echo "Current /var/lib/redis/cluster/ contents:" >&2
    ls -la /var/lib/redis/cluster/ >&2
    exit 1
fi
echo "dirs OK"
REMOTE
}
provision_dirs "$A_USER" "$A_PASS" "$A_HOST" "$A_PORT" "${A_PORTS[@]}" &
pid_a=$!
provision_dirs "$B_USER" "$B_PASS" "$B_HOST" "$B_PORT" "${B_PORTS[@]}" &
pid_b=$!
wait "$pid_a" || die "dirs on A failed"
wait "$pid_b" || die "dirs on B failed"
log_ok "Directories provisioned"

# === Step 8: Push cluster auth file ===
log_info "[8] Pushing cluster auth file..."
push_auth() {
    local user="$1" pass="$2" host="$3" port="$4"
    # SCP the content to a remote temp file (avoids multi-line shell args).
    local local_tmpf
    local_tmpf=$(mktemp)
    printf '%s' "$CLUSTER_PASS" > "$local_tmpf"
    ssh_copy "$user" "$pass" "$host" "$port" "$local_tmpf" "/tmp/redis-cluster-auth.conf" || { rm -f "$local_tmpf"; die "scp auth to $host failed"; }
    rm -f "$local_tmpf"

    ssh_run "$user" "$pass" "$host" "$port" bash -s "$pass" <<'REMOTE'
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
echo "auth file deployed"
REMOTE
}
push_auth "$A_USER" "$A_PASS" "$A_HOST" "$A_PORT" || die "auth file to A failed"
push_auth "$B_USER" "$B_PASS" "$B_HOST" "$B_PORT" || die "auth file to B failed"
log_ok "Auth file deployed"

# === Step 9: Render per-instance redis.conf ===
# IMPORTANT: multi-line content MUST travel as a file (via scp), NOT as a
# positional argument to bash. Some sshd/shell combinations split multi-line
# args on newlines, causing bash to interpret the file content as commands.
log_info "[9] Rendering 6 instance configs..."
render_and_push() {
    local user="$1" pass="$2" host="$3" port="$4" p
    for p in "${@:5}"; do
        # Render locally, then SCP the file to the remote /tmp
        local local_tmpf
        local_tmpf=$(mktemp)
        render_redis_conf "$CONF_TEMPLATE" "$p" "$CLUSTER_PASS" "node-${p}" "0.0.0.0" > "$local_tmpf"
        ssh_copy "$user" "$pass" "$host" "$port" "$local_tmpf" "/tmp/redis-${p}.conf" \
            || { rm -f "$local_tmpf"; die "scp redis-${p}.conf to $host failed"; }
        rm -f "$local_tmpf"

        ssh_run "$user" "$pass" "$host" "$port" bash -s "$pass" "$p" <<'REMOTE'
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
echo "  rendered redis-${PORT}.conf"
REMOTE
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
        local local_tmpf
        local_tmpf=$(mktemp)
        render_systemd_unit "$SERVICE_TEMPLATE" "$p" "node-${p}" "$CLUSTER_PASS" > "$local_tmpf"
        ssh_copy "$user" "$pass" "$host" "$port" "$local_tmpf" "/tmp/redis-${p}.service" \
            || { rm -f "$local_tmpf"; die "scp redis-${p}.service to $host failed"; }
        rm -f "$local_tmpf"

        ssh_run "$user" "$pass" "$host" "$port" bash -s "$pass" "$p" <<'REMOTE'
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
echo "  rendered redis-${PORT}.service"
REMOTE
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
        ssh_run "$user" "$pass" "$host" "$port" bash -s "$pass" "$p" <<'REMOTE'
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
_sudo systemctl daemon-reload
_sudo systemctl enable "redis-${PORT}"
_sudo systemctl restart "redis-${PORT}"
REMOTE
    done
}
start_services "$A_USER" "$A_PASS" "$A_HOST" "$A_PORT" "${A_PORTS[@]}" || die "start on A failed"
start_services "$B_USER" "$B_PASS" "$B_HOST" "$B_PORT" "${B_PORTS[@]}" || die "start on B failed"

# Verify each instance is responding
verify_ping() {
    local user="$1" pass="$2" host="$3" port="$4" p
    for p in "${@:5}"; do
        if ssh_run "$user" "$pass" "$host" "$port" \
                "$REDIS_BIN/redis-cli -a '$CLUSTER_PASS' -p $p PING" \
                | grep -qx PONG; then
            continue
        fi
        # Service didn't respond — surface the real reason
        log_error "redis-cli PING failed on $host:$p — fetching diagnostics..."
        ssh_run "$user" "$pass" "$host" "$port" bash -s "$pass" "$p" <<'REMOTE' >&2
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
echo "==== systemctl status redis-$PORT.service ===="
_sudo systemctl status "redis-$PORT.service" --no-pager 2>&1 || true
echo ""
echo "==== last 30 journalctl lines for redis-$PORT.service ===="
_sudo journalctl -u "redis-$PORT.service" -n 30 --no-pager 2>&1 || true
echo ""
echo "==== /etc/redis/cluster/redis-$PORT.conf ===="
_sudo cat "/etc/redis/cluster/redis-$PORT.conf" 2>&1 || true
echo ""
echo "==== /opt/software/redis/bin/ contents ===="
ls -la /opt/software/redis/bin/ 2>&1 || true
REMOTE
        die "redis on $host:$p failed to start — see diagnostics above"
    done
}
verify_ping "$A_USER" "$A_PASS" "$A_HOST" "$A_PORT" "${A_PORTS[@]}" || die "PING on A failed"
verify_ping "$B_USER" "$B_PASS" "$B_HOST" "$B_PORT" "${B_PORTS[@]}" || die "PING on B failed"
log_ok "All 6 instances responding to PING"

# === Step 12: Check if cluster already created ===
log_info "[12] Checking cluster state..."
if ! existing_info=$(ssh_run "$A_USER" "$A_PASS" "$A_HOST" "$A_PORT" \
        "$REDIS_BIN/redis-cli -a '$CLUSTER_PASS' -p 6379 cluster info" 2>/dev/null); then
    log_warn "Cannot reach A:6379 for cluster info; assuming cluster uninitialized"
    existing_info=""
fi
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
            "$REDIS_BIN/redis-cli --cluster create $(printf '%s ' "${create_args[@]}") --cluster-replicas 1 --cluster-yes -a '$CLUSTER_PASS'" \
            || die "redis-cli --cluster create from A failed"
    fi
fi

# === Step 13: Final health check ===
log_info "[13] Verifying cluster health..."
if ! final=$(ssh_run "$A_USER" "$A_PASS" "$A_HOST" "$A_PORT" \
        "$REDIS_BIN/redis-cli -a '$CLUSTER_PASS' -p 6379 cluster info" 2>/dev/null); then
    die "Cannot reach A:6379 for final cluster health check"
fi
if echo "$final" > /tmp/cluster_final_$$ && is_cluster_healthy < /tmp/cluster_final_$$; then
    rm -f /tmp/cluster_final_$$
    log_ok "Cluster is healthy"
else
    rm -f /tmp/cluster_final_$$
    die "cluster health check failed:\n$final"
fi

# === Optional: SELinux hint for RHEL-family ===
selinux_hint=$(ssh_run "$A_USER" "$A_PASS" "$A_HOST" "$A_PORT" "getenforce 2>/dev/null || true" 2>/dev/null || true)
if echo "$selinux_hint" | grep -q Enforcing; then
    log_warn "SELinux is enforcing on node A. If writes fail, run on each node:"
    log_warn "  semanage fcontext -a -t redis_var_lib_t '/var/lib/redis/cluster(/.*)?'"
    log_warn "  restorecon -R /var/lib/redis/cluster"
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
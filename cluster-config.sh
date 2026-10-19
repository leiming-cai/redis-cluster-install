#!/usr/bin/env bash
# HELP-START
# cluster-config.sh — Configure and form a Redis Cluster on machines that
# already have the Redis binaries and the `redis` user in place.
#
# This script creates the runtime directories itself (and corrects their
# ownership): Redis refuses to start when its data directory is missing, and
# putting that on an operator's checklist is an easy way to lose an hour.
# Installing Redis and creating the `redis` user remain out of scope — those
# are checked before anything is touched, and a missing one is reported by
# name.
#
# Usage:
#   bash cluster-config.sh                       # read ./cluster.conf
#   bash cluster-config.sh --config FILE         # read FILE
#   bash cluster-config.sh --dry-run             # print the plan, change nothing
#   bash cluster-config.sh --print-credentials   # resolve logins, print them, stop
#   bash cluster-config.sh --help
#
# SSH credentials: environment variables take precedence, anything missing is
# asked for interactively. Variables are per node group, derived from the
# [node.X] label in the config:
#
#   NODE_A_SSH_USER  NODE_A_HOST  NODE_A_SSH_PORT  NODE_A_SSH_PASS
#   NODE_B_SSH_USER  NODE_B_HOST  NODE_B_SSH_PORT  NODE_B_SSH_PASS
#
# For [node.a] the prefix is NODE_A_; for [node.worker-1] it is NODE_WORKER_1_.
# NODE_<X>_HOST overrides the config's host. NODE_<X>_SSH_PORT defaults to 22,
# NODE_<X>_SSH_USER defaults to root, NODE_<X>_SSH_PASS is asked silently.
#
# There is no sensible default for a password, so a run with no terminal and
# no NODE_<X>_SSH_PASS stops and names the variable to set, rather than
# failing somewhere further on.
#
# Requires: bash 4+, sshpass, redis-cli, openssh-client.
#
# NOTE: re-running this script re-renders and re-deploys every redis.conf and
# systemd unit, then restarts the affected instances. Data is preserved and an
# already-healthy cluster is not recreated, but instances restart.
# HELP-END

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$REPO_ROOT/lib/common.sh"
# shellcheck source=lib/conf.sh
. "$REPO_ROOT/lib/conf.sh"
# shellcheck source=lib/ssh.sh
. "$REPO_ROOT/lib/ssh.sh"
# shellcheck source=lib/config_gen.sh
. "$REPO_ROOT/lib/config_gen.sh"
# shellcheck source=lib/systemd.sh
. "$REPO_ROOT/lib/systemd.sh"
# shellcheck source=lib/prompt.sh
. "$REPO_ROOT/lib/prompt.sh"
# shellcheck source=lib/cluster.sh
. "$REPO_ROOT/lib/cluster.sh"

CONF_TEMPLATE="$REPO_ROOT/config/redis.conf.template"
UNIT_TEMPLATE="$REPO_ROOT/config/redis-cluster.service.template"

CONF_FILE="./cluster.conf"
DRY_RUN=0
PRINT_CREDENTIALS=0

usage() {
    # Print the header comment block, which is the help text. It is delimited
    # by sentinel lines rather than by line numbers: editing the header above
    # must never be able to make --help start printing `set -euo pipefail`.
    # `s/^#//` then `s/^ //` strips the comment marker and at most one space
    # after it, so `#` alone becomes an empty line and the indentation of
    # `#   bash cluster-config.sh ...` survives.
    sed -n '/^# HELP-START$/,/^# HELP-END$/p' "${BASH_SOURCE[0]}" \
        | sed -e '/^# HELP-START$/d' -e '/^# HELP-END$/d' \
              -e 's/^#//' -e 's/^ //'
}

# === CLI ===
while [ $# -gt 0 ]; do
    case "$1" in
        --config) shift; [ $# -gt 0 ] || die "--config requires a file argument"
                 CONF_FILE="$1" ;;
        --config=*) CONF_FILE="${1#*=}" ;;
        --dry-run) DRY_RUN=1 ;;
        --print-credentials) PRINT_CREDENTIALS=1 ;;
        --help|-h) usage; exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
    shift
done

# === Step 1 of 9: parse config ===
log_info "[1/9] Reading config $CONF_FILE"
parse_conf "$CONF_FILE"

# Unknown keys are ignored rather than fatal, but a typo like `ssh_prot`
# would otherwise be silently swallowed, so surface them once here.
if [ -n "$CONF_UNKNOWN_KEYS" ]; then
    log_warn "unrecognised key(s) in $CONF_FILE — check for typos:"
    while IFS= read -r k; do
        if [ -n "$k" ]; then
            log_warn "  - $k"
        fi
    done <<< "$CONF_UNKNOWN_KEYS"
fi

REDIS_PREFIX="$CONF_REDIS_PREFIX"
REDIS_BIN="$REDIS_PREFIX/bin"
log_ok "Config OK: $CONF_NODE_COUNT node(s), $CONF_TOTAL_INSTANCES instance(s), $CONF_REPLICAS replica(s) per master"

# === Step 2 of 9: plan / dry-run ===
log_info "[2/9] Resolved plan"
for (( i = 1; i <= CONF_NODE_COUNT; i++ )); do
    log_info "  ${CONF_NODE_GROUP[i]} (${CONF_NODE_ENVKEY[i]}) ${CONF_NODE_HOST[i]}:${CONF_NODE_SSH_PORT[i]} ports=[${CONF_NODE_PORTS[i]}]"
done

if [ "$DRY_RUN" = "1" ]; then
    echo
    log_ok "DRY-RUN complete — no changes were made"
    exit 0
fi

# === Credentials ===
# For each node: env var first, interactive prompt only for what is missing.
# Results land in CRED_USER[i] / CRED_HOST[i] / CRED_SSH_PORT[i] / CRED_PASS[i].
CRED_USER=() CRED_HOST=() CRED_SSH_PORT=() CRED_PASS=()

# conf_env_get VARNAME -> value, or empty if unset/empty.
# Indirect expansion without `set -u` blowing up on unset names.
conf_env_get() {
    local v="${!1:-}"
    printf '%s' "$v"
}

collect_credentials() {
    local i key env_user env_host env_port env_pass pass_var
    for (( i = 1; i <= CONF_NODE_COUNT; i++ )); do
        key="${CONF_NODE_ENVKEY[i]}"

        env_user="$(conf_env_get "${key}_SSH_USER")"
        env_host="$(conf_env_get "${key}_HOST")"
        env_port="$(conf_env_get "${key}_SSH_PORT")"
        env_pass="$(conf_env_get "${key}_SSH_PASS")"

        # host: config supplies the default; env overrides; prompt allows override
        if [ -n "$env_host" ]; then
            CRED_HOST[$i]="$env_host"
        else
            CRED_HOST[$i]="$(read_default "  ${CONF_NODE_GROUP[i]} host (override config: ${CONF_NODE_HOST[i]})" "${CONF_NODE_HOST[i]}")"
        fi

        if [ -n "$env_user" ]; then
            CRED_USER[$i]="$env_user"
        else
            CRED_USER[$i]="$(read_default "  ${CONF_NODE_GROUP[i]} SSH user" "root")"
        fi

        if [ -n "$env_port" ]; then
            CRED_SSH_PORT[$i]="$env_port"
        else
            CRED_SSH_PORT[$i]="$(read_default "  ${CONF_NODE_GROUP[i]} SSH port" "${CONF_NODE_SSH_PORT[i]}")"
        fi

        # The password is the one field with no usable default, so unlike the
        # three above it cannot fall back on EOF. `read_secret` returning
        # non-zero means there was no terminal to ask on, and under `set -e` a
        # bare `CRED_PASS[$i]="$(read_secret ...)"` would take the whole script
        # down with no message at all — which is exactly the case where the
        # operator most needs to be told which variable is missing. Testing the
        # assignment inside `elif` keeps that status from escaping. (A leading
        # `local` would swallow it instead: `local v="$(cmd)"` always succeeds,
        # whereas a bare assignment propagates the command's status.)
        if [ -n "$env_pass" ]; then
            CRED_PASS[$i]="$env_pass"
        elif pass_var="$(read_secret "  ${CONF_NODE_GROUP[i]} SSH password")"; then
            CRED_PASS[$i]="$pass_var"
        else
            die "no terminal available to prompt for the SSH password of node group ${CONF_NODE_GROUP[i]}; set ${key}_SSH_PASS to a non-empty value"
        fi

        [ -n "${CRED_HOST[$i]}"   ] || die "no host for node group ${CONF_NODE_GROUP[i]}"
        [ -n "${CRED_USER[$i]}"   ] || die "no SSH user for node group ${CONF_NODE_GROUP[i]}"
        [ -n "${CRED_SSH_PORT[$i]}" ] || die "no SSH port for node group ${CONF_NODE_GROUP[i]}"
        [ -n "${CRED_PASS[$i]}"   ] || die "SSH password for node group ${CONF_NODE_GROUP[i]} is empty; sshpass cannot use an empty password"
    done
}

log_info "[3/9] Resolving SSH credentials (environment first, prompt for gaps)..."
collect_credentials

if [ "$PRINT_CREDENTIALS" = "1" ]; then
    for (( i = 1; i <= CONF_NODE_COUNT; i++ )); do
        log_info "  ${CONF_NODE_GROUP[i]}: ${CRED_USER[$i]}@${CRED_HOST[$i]}:${CRED_SSH_PORT[$i]} (password: ${#CRED_PASS[$i]} chars)"
    done
    exit 0
fi

# === Preflight ===
# Verifies the two things a human must have done: install the Redis binaries
# and create the `redis` system user. Directories are NOT checked here —
# spec §"职责边界" assigns their creation to this script (step 5), so
# checking them here would reject a correctly-prepared machine.
preflight_node() {
    local i="$1"
    local user="${CRED_USER[$i]}" pass="${CRED_PASS[$i]}"
    local host="${CRED_HOST[$i]}" port="${CRED_SSH_PORT[$i]}"

    log_info "  preflight ${CONF_NODE_GROUP[$i]} ($user@$host:$port)"

    ssh_check "$user" "$pass" "$host" "$port" \
        || die "cannot reach $user@$host:$port (check host, port and password)"

    # The remote script only echoes MISSING_* markers and always exits 0, so a
    # non-zero status from ssh_run means a transport failure, not a missing
    # prerequisite. Capture output with `if ! report=$(...)` so that `set -e`
    # does not abort before the report is inspected.
    local report
    if ! report="$(ssh_run "$user" "$pass" "$host" "$port" bash -s "$REDIS_PREFIX" <<'PREFLIGHT'
set -u
REDIS_PREFIX="$1"
for b in "$REDIS_PREFIX/bin/redis-server" "$REDIS_PREFIX/bin/redis-cli"; do
    [ -x "$b" ] || echo "MISSING_BIN: $b"
done
id redis >/dev/null 2>&1 || echo "MISSING_USER: redis"
PREFLIGHT
)"; then
        log_error "could not run the preflight command on ${CONF_NODE_GROUP[$i]} ($host)"
        [ -n "$report" ] && printf '%s\n' "$report" >&2
        die "SSH to $user@$host:$port worked for 'true' but failed for the preflight script.
       Check that the login shell on $host accepts a script on stdin."
    fi

    # A non-empty report IS the failure signal. The remote script deliberately
    # exits 0 and communicates purely through these markers, so testing
    # ssh_run's exit status alone would make preflight a no-op: a node with no
    # Redis binaries and no redis user would be reported as passing.
    if [ -n "$(conf_trim "$report")" ]; then
        log_error "preflight failed on ${CONF_NODE_GROUP[$i]} ($host):"
        printf '%s\n' "$report" >&2
        die "fix the items above on $host, then re-run.
       Install Redis binaries into $REDIS_PREFIX/bin/ and create the 'redis'
       system user; this script creates directories but does not install
       software or create users."
    fi
}

log_info "[4/9] Verifying pre-provisioned state on all nodes..."
for (( i = 1; i <= CONF_NODE_COUNT; i++ )); do
    preflight_node "$i"
done
log_ok "Preflight passed on all nodes"

# === Create runtime directories ===
# mkdir -p is idempotent, so re-running only fills in what is missing.
# Redis refuses to start when its data directory is absent, which is why
# these live here rather than in the operator's checklist.
create_dirs() {
    local i="$1"
    local user="${CRED_USER[$i]}" pass="${CRED_PASS[$i]}"
    local host="${CRED_HOST[$i]}" port="${CRED_SSH_PORT[$i]}"

    # Split on commas and NOTHING else. `IFS=',' local -a x=($raw)` would
    # leave the value unquoted and send it through pathname expansion, so
    # the result would depend on $PWD — see the note in lib/conf.sh.
    local -a port_list=()
    IFS=',' read -r -a port_list <<< "${CONF_NODE_PORTS[$i]}"

    local p rc
    for p in "${port_list[@]}"; do
        # Each ssh_run's status must be checked: the remote script runs under
        # `set -e`, so a failed mkdir returns non-zero. Without this the loop
        # would sail past a node whose directories were never created.
        rc=0
        ssh_run "$user" "$pass" "$host" "$port" bash -s "$pass" "$p" "$REDIS_PREFIX" <<'DIRS' || rc=$?
set -e
SUDO_PASS="$1"
PORT="$2"
REDIS_PREFIX="$3"
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
_sudo mkdir -p "/var/lib/redis/cluster/$PORT"
_sudo mkdir -p "/var/run/redis/cluster/$PORT"
_sudo mkdir -p "$REDIS_PREFIX/cluster/$PORT"
_sudo mkdir -p "$REDIS_PREFIX/log"
# Chown the PARENT trees, not just the cluster subdirectories. On hosts where
# /etc/redis is 0770 redis:redis with the setgid bit, a redis user that is ever
# recreated (container rebuild, restore from backup) gets a new uid and that
# parent stays behind owned by a dangling one. Chowning only
# /etc/redis/cluster looks correct — the files really do end up owned by the
# new redis at 0640 — yet the service still dies with
#   "Fatal error, can't open config file ...: Permission denied"
# because it cannot traverse the 0770 parent to reach them. Owning the
# parent is a no-op when the uid has not changed.
#
# NOTE: the 0770+setgid shape is NOT something apt's redis-server produces —
# 6.0.16-1ubuntu1.2 and 7.0.15-1~deb12u10 both ship it 0755 root:root. It is
# seen in the wild on other packagings and on hand-provisioned hosts, which is
# why this chown covers the parents unconditionally rather than only the
# subdirectories this script creates.
_sudo chown -R redis:redis /etc/redis /var/lib/redis /var/run/redis \
    "$REDIS_PREFIX/cluster" "$REDIS_PREFIX/log"

# Confirm what we just created, in the same round trip. `set -e` already
# catches a mkdir that failed outright; this catches the quieter cases —
# a path that exists but is not a directory, or a directory the chown could
# not reach. Verifying here rather than in a second pass keeps this to one
# SSH connection per port instead of two.
for d in /etc/redis/cluster "/var/lib/redis/cluster/$PORT" \
         "/var/run/redis/cluster/$PORT" "$REDIS_PREFIX/cluster/$PORT" \
         "$REDIS_PREFIX/log"; do
    [ -d "$d" ] || { echo "MISSING_DIR: $d" >&2; exit 1; }
done
DIRS
        if [ "$rc" -ne 0 ]; then
            die "creating the runtime directories for port $p on $host failed"
        fi
    done
}

log_info "[5/9] Creating runtime directories..."
for (( i = 1; i <= CONF_NODE_COUNT; i++ )); do
    create_dirs "$i"
done
log_ok "Runtime directories created on all nodes"

# === Deploy auth.conf ===
# Content matches EnvironmentFile=/etc/redis/cluster/auth.conf in the unit
# template; ExecStop references it as $REDIS_PASSWORD.
deploy_auth() {
    local i="$1"
    local user="${CRED_USER[$i]}" pass="${CRED_PASS[$i]}"
    local host="${CRED_HOST[$i]}" port="${CRED_SSH_PORT[$i]}"

    # File content travels via scp, never as an SSH positional argument:
    # some sshd versions re-inject multi-line args as stdin and the remote
    # shell would try to execute the file content as commands.
    local tmpf
    tmpf="$(mktemp)"
    printf 'REDIS_PASSWORD=%s\n' "$CONF_PASSWORD" > "$tmpf"
    ssh_copy "$user" "$pass" "$host" "$port" "$tmpf" "/tmp/redis-cluster-auth.conf" \
        || { rm -f "$tmpf"; die "scp auth.conf to $host failed"; }
    rm -f "$tmpf"

    # The remote script runs under `set -e`, so a failed cp/chown/chmod comes
    # back as a non-zero exit. It has to be checked: otherwise the node would
    # be reported as deployed while /etc/redis/cluster/auth.conf is absent or
    # world-readable, and redis would fail to authenticate much later.
    local rc=0
    ssh_run "$user" "$pass" "$host" "$port" bash -s "$pass" <<'AUTHREMOTE' || rc=$?
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
# /etc/redis/cluster already exists: create_dirs (step 5) ran before this.
_sudo cp /tmp/redis-cluster-auth.conf /etc/redis/cluster/auth.conf
_sudo chown redis:redis /etc/redis/cluster/auth.conf
_sudo chmod 600 /etc/redis/cluster/auth.conf
rm -f /tmp/redis-cluster-auth.conf
AUTHREMOTE
    [ "$rc" -eq 0 ] || die "installing auth.conf on $host failed"
    log_info "  ${CONF_NODE_GROUP[$i]}: auth.conf deployed"
}

# === Render and deploy redis.conf + systemd unit ===
# REDIS_PREFIX is threaded into BOTH templates so that
# cluster-config-file / logfile (redis.conf) and ExecStart / ReadWritePaths
# (unit) resolve to the same directories. If they disagree,
# ProtectSystem=strict makes the paths read-only and redis-server refuses
# to start — see docs/VERIFICATION.md D8.
deploy_configs() {
    local i="$1"
    local user="${CRED_USER[$i]}" pass="${CRED_PASS[$i]}"
    local host="${CRED_HOST[$i]}" port="${CRED_SSH_PORT[$i]}"
    local ports="${CONF_NODE_PORTS[$i]}"
    local p tmpf rc

    # Split on commas and NOTHING else — see the note in lib/conf.sh about the
    # unquoted `IFS=',' local -a x=($raw)` form going through pathname
    # expansion and making the result depend on $PWD.
    local -a port_list=()
    IFS=',' read -r -a port_list <<< "$ports"

    for p in "${port_list[@]}"; do
        # redis.conf
        tmpf="$(mktemp)"
        render_redis_conf "$CONF_TEMPLATE" "$p" "$CONF_PASSWORD" "node-$p" "$CONF_BIND_ADDR" "$REDIS_PREFIX" > "$tmpf" \
            || { rm -f "$tmpf"; die "rendering redis-$p.conf failed"; }
        ssh_copy "$user" "$pass" "$host" "$port" "$tmpf" "/tmp/redis-$p.conf" \
            || { rm -f "$tmpf"; die "scp redis-$p.conf to $host failed"; }
        rm -f "$tmpf"

        # systemd unit
        tmpf="$(mktemp)"
        render_systemd_unit "$UNIT_TEMPLATE" "$p" "node-$p" "$CONF_PASSWORD" "$REDIS_PREFIX" > "$tmpf" \
            || { rm -f "$tmpf"; die "rendering redis-$p.service failed"; }
        ssh_copy "$user" "$pass" "$host" "$port" "$tmpf" "/tmp/redis-$p.service" \
            || { rm -f "$tmpf"; die "scp redis-$p.service to $host failed"; }
        rm -f "$tmpf"

        rc=0
        ssh_run "$user" "$pass" "$host" "$port" bash -s "$pass" "$p" <<'DEPLOYREMOTE' || rc=$?
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
# Directories already exist: create_dirs (step 5) ran before this.
_sudo cp "/tmp/redis-${PORT}.conf" "/etc/redis/cluster/redis-${PORT}.conf"
_sudo chown redis:redis "/etc/redis/cluster/redis-${PORT}.conf"
_sudo chmod 640 "/etc/redis/cluster/redis-${PORT}.conf"
_sudo cp "/tmp/redis-${PORT}.service" "/etc/systemd/system/redis-${PORT}.service"
_sudo chmod 644 "/etc/systemd/system/redis-${PORT}.service"
rm -f "/tmp/redis-${PORT}.conf" "/tmp/redis-${PORT}.service"

# Confirm both landed. The unit is the one that decides whether redis ever
# starts, and a unit that was never copied looks exactly like a unit that was
# installed and simply has not been started yet.
for f in "/etc/redis/cluster/redis-${PORT}.conf" \
         "/etc/systemd/system/redis-${PORT}.service"; do
    [ -f "$f" ] || { echo "MISSING_FILE: $f" >&2; exit 1; }
done
DEPLOYREMOTE
        [ "$rc" -eq 0 ] || die "deploying redis-$p.conf and redis-$p.service to $host failed"
        log_info "  ${CONF_NODE_GROUP[$i]}: redis-$p.conf + redis-$p.service deployed"
    done
}

log_info "[6/9] Deploying auth.conf..."
for (( i = 1; i <= CONF_NODE_COUNT; i++ )); do
    deploy_auth "$i"
done
log_ok "auth.conf deployed on all nodes"

log_info "[7/9] Rendering and deploying redis.conf and systemd units..."
for (( i = 1; i <= CONF_NODE_COUNT; i++ )); do
    deploy_configs "$i"
done
log_ok "redis.conf and systemd units deployed on all nodes"

# === Start and verify ===

# ping_instance USER PASS HOST SSH_PORT REDIS_PORT
# Returns 0 only when the instance answers PING with exactly PONG.
ping_instance() {
    local user="$1" pass="$2" host="$3" ssh_port="$4" redis_port="$5"
    local out
    # The cluster password travels as a positional argument, never inside the
    # remote command string. lib/conf.sh only requires cluster_password to be
    # non-empty — it does not restrict the characters — so interpolating it
    # into `redis-cli -a '...'` would hand a password containing ' ; $(...) or
    # a backtick straight to the remote shell, on a host where this same
    # script runs sudo. 2>/dev/null drops redis-cli's "-a is insecure" notice
    # so it cannot pollute the PONG comparison.
    out="$(ssh_run "$user" "$pass" "$host" "$ssh_port" \
        bash -s "$CONF_PASSWORD" "$redis_port" "$REDIS_BIN" 2>/dev/null <<'PING'
set -u
CLUSTER_PASS="$1"
PORT="$2"
REDIS_BIN="$3"
"$REDIS_BIN/redis-cli" -a "$CLUSTER_PASS" -p "$PORT" PING
PING
    )" || return 1
    [ "$(conf_trim "$out")" = "PONG" ]
}

start_and_verify() {
    local i="$1"
    local user="${CRED_USER[$i]}" pass="${CRED_PASS[$i]}"
    local host="${CRED_HOST[$i]}" port="${CRED_SSH_PORT[$i]}"

    # Split on commas and NOTHING else — see the note in lib/conf.sh about the
    # unquoted `IFS=',' local -a x=($raw)` form going through pathname
    # expansion and making the result depend on $PWD.
    local -a port_list=()
    IFS=',' read -r -a port_list <<< "${CONF_NODE_PORTS[$i]}"

    local p rc
    for p in "${port_list[@]}"; do
        # The remote script runs under `set -e`, so a failed systemctl comes
        # back non-zero. Check it rather than letting the PING probe below be
        # the only thing that notices — it cannot tell "unit failed to start"
        # apart from "unit started but redis is not accepting connections".
        rc=0
        ssh_run "$user" "$pass" "$host" "$port" bash -s "$pass" "$p" "$REDIS_PREFIX" <<'STARTREMOTE' || rc=$?
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
# Directories and ownership already handled by create_dirs (step 5).
_sudo systemctl daemon-reload
_sudo systemctl enable "redis-$PORT"
_sudo systemctl restart "redis-$PORT"
STARTREMOTE
        [ "$rc" -eq 0 ] || die "starting redis-$p.service on $host failed"
    done

    # PING every instance; on failure dump the same diagnostics install.sh uses
    # (this is what pinpointed the D8 read-only-filesystem bug).
    for p in "${port_list[@]}"; do
        if ping_instance "$user" "$pass" "$host" "$port" "$p"; then
            continue
        fi
        log_error "PING failed on $host:$p — collecting diagnostics..."
        ssh_run "$user" "$pass" "$host" "$port" bash -s "$pass" "$p" "$REDIS_PREFIX" <<'DIAG' >&2
SUDO_PASS="$1"
PORT="$2"
REDIS_PREFIX="$3"
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
echo "==== journalctl -u redis-$PORT.service -n 30 ===="
_sudo journalctl -u "redis-$PORT.service" -n 30 --no-pager 2>&1 || true
echo ""
echo "==== /etc/redis/cluster/redis-$PORT.conf ===="
_sudo cat "/etc/redis/cluster/redis-$PORT.conf" 2>&1 || true
echo ""
echo "==== $REDIS_PREFIX/bin/ ===="
ls -la "$REDIS_PREFIX/bin/" 2>&1 || true
DIAG
        die "redis on $host:$p failed to start — see diagnostics above"
    done
    log_info "  ${CONF_NODE_GROUP[$i]}: all instances responding to PING"
}

log_info "[8/9] Starting instances..."
for (( i = 1; i <= CONF_NODE_COUNT; i++ )); do
    start_and_verify "$i"
done
log_ok "All instances responding to PING"

# === Create cluster ===
# Node list is built from the resolved credentials + config ports.
# NOTE: no `local` here — this code runs at script top level, not in a
# function, and bash rejects `local` outside functions (fatal under set -e).
BUILD_CREATE_ARGS=()
_port_list=()
for (( i = 1; i <= CONF_NODE_COUNT; i++ )); do
    # Split on commas and NOTHING else — see the note in lib/conf.sh about the
    # unquoted `IFS=',' local -a x=($raw)` form going through pathname
    # expansion and making the result depend on $PWD.
    _port_list=()
    IFS=',' read -r -a _port_list <<< "${CONF_NODE_PORTS[$i]}"
    for p in "${_port_list[@]}"; do
        BUILD_CREATE_ARGS+=("${CRED_HOST[$i]}:$p")
    done
done

# Query the first node's first port to decide whether to create.
FIRST_HOST="${CRED_HOST[1]}"
FIRST_SSH_PORT="${CRED_SSH_PORT[1]}"
FIRST_USER="${CRED_USER[1]}"
FIRST_PASS="${CRED_PASS[1]}"
_first_ports=()
IFS=',' read -r -a _first_ports <<< "${CONF_NODE_PORTS[1]}"
FIRST_REDIS_PORT="${_first_ports[0]}"

# cluster_info_from USER PASS HOST SSH_PORT REDIS_PORT
# Echoes `redis-cli cluster info` for one instance.
#
# As in ping_instance, the cluster password travels as a positional argument
# instead of being interpolated into the remote command string: lib/conf.sh
# accepts any non-empty cluster_password, so `-a '...'` with a password
# holding a quote, `;` or `$(...)` would be executed by the remote shell.
cluster_info_from() {
    local user="$1" pass="$2" host="$3" ssh_port="$4" redis_port="$5"
    ssh_run "$user" "$pass" "$host" "$ssh_port" \
        bash -s "$CONF_PASSWORD" "$redis_port" "$REDIS_BIN" 2>/dev/null <<'CLINFO'
set -u
CLUSTER_PASS="$1"
PORT="$2"
REDIS_BIN="$3"
"$REDIS_BIN/redis-cli" -a "$CLUSTER_PASS" -p "$PORT" cluster info
CLINFO
}

cluster_info="$(cluster_info_from "$FIRST_USER" "$FIRST_PASS" "$FIRST_HOST" "$FIRST_SSH_PORT" "$FIRST_REDIS_PORT" || true)"

# Compare against the instance count this config actually declares, not a
# hardcoded 6: conf.sh accepts a 5-instance layout (ceil(5/2) = 3 masters),
# and such a cluster reports cluster_known_nodes:5.
if printf '%s\n' "$cluster_info" | is_cluster_healthy "$CONF_TOTAL_INSTANCES"; then
    log_ok "Cluster already healthy — skipping create"
else
    log_info "[9/9] Creating cluster with ${#BUILD_CREATE_ARGS[@]} instances..."
    if command -v redis-cli >/dev/null 2>&1; then
        redis-cli --cluster create "${BUILD_CREATE_ARGS[@]}" \
            --cluster-replicas "$CONF_REPLICAS" --cluster-yes \
            -a "$CONF_PASSWORD" \
            || die "redis-cli --cluster create failed"
    else
        log_warn "redis-cli not on control machine; running create from $FIRST_HOST"
        # Node addresses arrive as positional args too, so the remote script
        # never re-parses a string this process built by concatenation.
        rc=0
        ssh_run "$FIRST_USER" "$FIRST_PASS" "$FIRST_HOST" "$FIRST_SSH_PORT" \
            bash -s "$CONF_PASSWORD" "$CONF_REPLICAS" "$REDIS_BIN" "${BUILD_CREATE_ARGS[@]}" <<'CREATE' || rc=$?
set -u
CLUSTER_PASS="$1"
REPLICAS="$2"
REDIS_BIN="$3"
shift 3
exec "$REDIS_BIN/redis-cli" --cluster create "$@" \
    --cluster-replicas "$REPLICAS" --cluster-yes -a "$CLUSTER_PASS"
CREATE
        [ "$rc" -eq 0 ] || die "redis-cli --cluster create from $FIRST_HOST failed"
    fi
fi

# === Health check ===
# Right after create, masters may still be doing bus handshakes, so
# cluster_state can briefly read "fail". Retry with backoff.
log_info "[health] Verifying cluster health..."
health_ok=0
attempt=1
while [ "$attempt" -le 5 ]; do
    cluster_info="$(cluster_info_from "$FIRST_USER" "$FIRST_PASS" "$FIRST_HOST" "$FIRST_SSH_PORT" "$FIRST_REDIS_PORT" || true)"
    if printf '%s\n' "$cluster_info" | is_cluster_healthy "$CONF_TOTAL_INSTANCES"; then
        health_ok=1
        break
    fi
    [ "$attempt" -eq 5 ] && break
    log_warn "health check attempt $attempt/5 not ready; sleeping 3s"
    sleep 3
    attempt=$((attempt + 1))
done

[ "$health_ok" -eq 1 ] || die "cluster health check failed after 5 attempts:
$cluster_info

Clustered instances can take longer than 15s to finish their master-to-master
handshakes. Re-run this script once the nodes have settled: step 9 skips
'--cluster create' entirely when the cluster already reports healthy."

log_ok "Cluster is healthy (attempt $attempt)"

# === Summary card ===
cat <<CARD

==========================================
 Redis Cluster READY
==========================================
CARD
for (( i = 1; i <= CONF_NODE_COUNT; i++ )); do
    echo "  ${CONF_NODE_GROUP[$i]}  ${CRED_HOST[$i]}  ports=[${CONF_NODE_PORTS[$i]}]"
done
cat <<CARD
  Connect:  redis-cli -c -a "<password>" -h ${FIRST_HOST} -p ${FIRST_REDIS_PORT}
  Password: cluster_password in $CONF_FILE
  Other:    status.sh  uninstall.sh  add-node.sh
==========================================
CARD

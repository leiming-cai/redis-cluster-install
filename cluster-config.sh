#!/usr/bin/env bash
# HELP-START
# cluster-config.sh — Configure and form a Redis Cluster on machines that
# already have the Redis binaries, the `redis` user and the required
# directories in place.
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

collect_credentials

if [ "$PRINT_CREDENTIALS" = "1" ]; then
    for (( i = 1; i <= CONF_NODE_COUNT; i++ )); do
        log_info "  ${CONF_NODE_GROUP[i]}: ${CRED_USER[$i]}@${CRED_HOST[$i]}:${CRED_SSH_PORT[$i]} (password: ${#CRED_PASS[$i]} chars)"
    done
    exit 0
fi

die "not implemented yet: preflight and deployment (see spec section 4)"

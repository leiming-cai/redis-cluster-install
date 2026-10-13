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

die "not implemented yet: credential collection and deployment (see spec section 4)"

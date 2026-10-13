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

# NOTE: the redirect and the health check must stay a single `&&` chain.
# `! cmd1 && cmd2` parses as `(! cmd1) && cmd2`, so with a failing check the
# condition becomes true and the script took the "not healthy" branch even
# for a perfectly healthy cluster (and vice versa).
if printf '%s\n' "$info" | is_cluster_healthy; then
    :
else
    log_error "cluster not healthy"
    printf '%s\n' "$info"
    exit 1
fi

echo
echo "== Cluster Info =="
echo "$info"
echo
echo "== Cluster Nodes =="
redis-cli -a "$PASS" -h "$A_HOST" -p "$A_PORT" cluster nodes 2>/dev/null
echo
echo "== Slot Distribution =="
# `redis-cli cluster slots` emits one field PER LINE, not one range per line:
#
#     <start-slot>
#     <end-slot>
#     <master-ip>
#     <master-port>
#     <master-node-id>
#     <replica-ip>        \
#     <replica-port>      |  zero or more replica triples
#     <replica-node-id>   /
#     ... then the next range header, and so on.
#
# The previous awk paired lines 1-2, 3-4, ... assuming two lines per range,
# which produced completely garbled output. Rebuild the ranges from the flat
# field stream: a range header is 5 fields, each replica adds 3 more, and the
# next range header starts with two integers.
redis-cli -a "$PASS" -h "$A_HOST" -p "$A_PORT" cluster slots 2>/dev/null \
    | awk '
        NF { f[++c] = $1 }
        END {
            i = 1
            while (i + 4 <= c) {
                s  = f[i]; e = f[i+1]; mh = f[i+2]; mp = f[i+3]
                printf "%-6s - %-6s  master  %s:%s\n", s, e, mh, mp
                i += 5
                while (i + 2 <= c && !(f[i] ~ /^[0-9]+$/ && f[i+1] ~ /^[0-9]+$/)) {
                    printf "%-6s - %-6s  replica %s:%s\n", s, e, f[i], f[i+1]
                    i += 3
                }
            }
        }
    '
echo
log_ok "Status check complete"
#!/usr/bin/env bash
# lib/cluster.sh — parse and inspect Redis cluster state.
# These helpers read the output of `redis-cli -a PASS cluster info` from stdin.

# cluster_known_nodes
# Echoes the integer value of `cluster_known_nodes:N` from stdin, or empty string.
cluster_known_nodes() {
    grep -E '^cluster_known_nodes:' | awk -F: '{print $2}' | tr -d '[:space:]'
}

# is_cluster_healthy [MIN_KNOWN_NODES]
# Returns 0 if the cluster is functionally healthy, even if it briefly
# reports cluster_state:fail during initial handshakes.
#   - all 16384 slots assigned
#   - cluster_slots_fail = 0
#   - cluster_known_nodes >= MIN_KNOWN_NODES (default 6)
# cluster_state:ok is the goal but transient "fail" is allowed immediately
# after cluster create (master-to-master handshakes still in flight).
#
# MIN_KNOWN_NODES defaults to 6 because that is the 3-master/1-replica layout
# this project ships, and callers like status.sh have no config to read an
# instance count from. A caller that DOES know its own instance count should
# pass it: lib/conf.sh accepts as few as 5 instances (ceil(5/2) = 3 masters),
# and such a cluster reports cluster_known_nodes:5, which a hardcoded 6 would
# reject forever — the health check could then never pass.
is_cluster_healthy() {
    local min_known="${1:-6}"
    # Guard the numeric comparison: a non-numeric argument would make `[` fail
    # with "integer expression expected" instead of reporting cluster health.
    case "$min_known" in
        ''|*[!0-9]*) min_known=6 ;;
    esac
    local info state slots known fail
    info=$(cat)
    state=$(printf '%s\n' "$info" | grep -E '^cluster_state:'            | awk -F: '{print $2}' | tr -d '[:space:]')
    slots=$(printf '%s\n' "$info" | grep -E '^cluster_slots_assigned:'   | awk -F: '{print $2}' | tr -d '[:space:]')
    known=$(printf '%s\n' "$info" | grep -E '^cluster_known_nodes:'      | awk -F: '{print $2}' | tr -d '[:space:]')
    fail=$(printf '%s\n' "$info"  | grep -E '^cluster_slots_fail:'        | awk -F: '{print $2}' | tr -d '[:space:]')
    [ "$slots"  = "16384" ] && \
    [ "$fail"   = "0" ]    && \
    [ "${known:-0}" -ge "$min_known" ] && \
    [ "$state"  = "ok"  -o "$state" = "fail" ]
}

# build_create_command PASSWORD USER HOST PORT ... USER HOST PORT
# Echoes a fully-formed `redis-cli --cluster create ...` argv list (one arg per line).
# Caller is responsible for eval or backgrounded exec.
build_create_command() {
    local pass="$1"
    shift
    printf 'redis-cli\n--cluster\ncreate\n'
    for arg in "$@"; do
        printf '%s\n' "$arg"
    done
    printf -- '--cluster-replicas\n1\n--cluster-yes\n-a\n%s\n' "$pass"
}

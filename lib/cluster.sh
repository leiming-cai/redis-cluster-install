#!/usr/bin/env bash
# lib/cluster.sh — parse and inspect Redis cluster state.
# These helpers read the output of `redis-cli -a PASS cluster info` from stdin.

# cluster_known_nodes
# Echoes the integer value of `cluster_known_nodes:N` from stdin, or empty string.
cluster_known_nodes() {
    grep -E '^cluster_known_nodes:' | awk -F: '{print $2}' | tr -d '[:space:]'
}

# is_cluster_healthy
# Returns 0 if cluster_state:ok AND cluster_slots_assigned:16384, else non-zero.
is_cluster_healthy() {
    # Read stdin once into a variable, then parse from it (avoid double-read of pipe).
    local info state slots
    info=$(cat)
    state=$(printf '%s\n' "$info" | grep -E '^cluster_state:' | awk -F: '{print $2}' | tr -d '[:space:]')
    slots=$(printf '%s\n' "$info" | grep -E '^cluster_slots_assigned:' | awk -F: '{print $2}' | tr -d '[:space:]')
    [ "$state" = "ok" ] && [ "$slots" = "16384" ]
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

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

# build_create_command PASSWORD [REPLICAS] NODE...
# Echoes a fully-formed `redis-cli --cluster create ...` argv list (one arg per
# line). Caller is responsible for eval or backgrounded exec.
#
# REPLICAS is optional and defaults to 1. A node address always contains a
# ':', so a bare integer as the second argument can only be the replica
# count. Pass 0 to create the masters only: the replicas are then attached
# one by one with --cluster add-node --cluster-slave, which is the only way
# to control WHICH master each replica follows.
build_create_command() {
    local pass="$1"
    shift
    local replicas=1
    if [ "$#" -gt 0 ]; then
        case "$1" in
            ''|*[!0-9]*) ;;
            *) replicas="$1"; shift ;;
        esac
    fi
    printf 'redis-cli\n--cluster\ncreate\n'
    for arg in "$@"; do
        printf '%s\n' "$arg"
    done
    printf -- '--cluster-replicas\n%s\n--cluster-yes\n-a\n%s\n' "$replicas" "$pass"
}

# build_add_replica_command PASSWORD NEW_NODE MASTER_NODE
# Echoes a `redis-cli --cluster add-node NEW MASTER --cluster-slave` argv
# list (one arg per line). Naming the master explicitly is what makes the
# replica map deterministic; left to itself redis-cli picks one.
build_add_replica_command() {
    local pass="$1" new_node="$2" master_node="$3"
    printf 'redis-cli\n--cluster\nadd-node\n%s\n%s\n--cluster-slave\n-a\n%s\n' \
        "$new_node" "$master_node" "$pass"
}

# build_eval_argv
# Reads one argument per line on stdin and echoes a single shell-quoted
# string, safe to `eval`. Every argument is wrapped in single quotes and any
# single quote inside it is closed, escaped and reopened, so a password
# holding ' ; $(...) or a backtick stays one argument instead of becoming a
# command.
build_eval_argv() {
    local line first=1 quoted
    while IFS= read -r line; do
        quoted="$(printf '%s' "$line" | sed "s/'/'\\\\''/g")"
        if [ "$first" = "1" ]; then
            printf "'%s'" "$quoted"
            first=0
        else
            printf " '%s'" "$quoted"
        fi
    done
}

# cluster_nodes_index
# Reads `redis-cli cluster nodes` on stdin and emits, for every node:
#   <node-id> <host:port> <master|replica> <master-node-id>
# The bus port and the optional hostname are stripped from the address, and
# the master's own id is kept so a replica can be matched to it.
cluster_nodes_index() {
    awk '
        NF >= 4 {
            addr = $2
            sub(/@.*$/, "", addr)
            role = ($3 ~ /master/) ? "master" : "replica"
            printf "%s %s %s %s\n", $1, addr, role, $4
        }
    '
}

# cluster_role_of NODES_TEXT HOST PORT
# Echoes "master", "replica" or "none" (not a member of the cluster).
cluster_role_of() {
    local nodes="$1" host="$2" port="$3"
    printf '%s\n' "$nodes" | cluster_nodes_index | awk -v want="$host:$port" '
        $2 == want { print $3; found = 1; exit }
        END { if (!found) print "none" }
    '
}

# cluster_replica_master_of NODES_TEXT HOST PORT
# Echoes the "host:port" of the master a replica follows, or nothing when the
# node is not a replica.
cluster_replica_master_of() {
    local nodes="$1" host="$2" port="$3"
    printf '%s\n' "$nodes" | cluster_nodes_index | awk -v want="$host:$port" '
        { addr[$1] = $2; role[$1] = $3; mid[$1] = $4 }
        END {
            for (id in addr) {
                if (role[id] == "replica" && addr[id] == want && (mid[id] in addr)) {
                    print addr[mid[id]]
                    exit
                }
            }
        }
    '
}

# cluster_exists
# Reads `redis-cli cluster info` on stdin. Returns 0 when the instance has
# already joined a cluster (more than one known node, or any slot assigned)
# and 1 when it is still a lone instance.
cluster_exists() {
    local info known slots
    info=$(cat)
    known=$(printf '%s\n' "$info" | cluster_known_nodes)
    slots=$(printf '%s\n' "$info" | grep -E '^cluster_slots_assigned:' | awk -F: '{print $2}' | tr -d '[:space:]')
    [ "${known:-1}" -gt 1 ] || [ "${slots:-0}" -gt 0 ]
}

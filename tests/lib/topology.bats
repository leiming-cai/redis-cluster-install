load '../setup'
load_lib common
load_lib topology

# The layout algorithm is a pure function, so every rule in the spec can be
# pinned here without a cluster, a network or a container.
#
# The reference layout is the one this project ships: 6 instances, 3 on each
# of 2 hosts.
#
# Every TOPO_* array is 1-BASED, the same convention CONF_NODE_* uses.
REF="10.0.0.1:6379,6380,6381 10.0.0.2:6382,6383,6384"

@test "topology_plan selects the masters round-robin over the node groups" {
    topology_plan "$REF"
    [ "$TOPO_MASTER_COUNT" -eq 3 ]
    [ "${TOPO_MASTER[1]}" = "10.0.0.1:6379" ]
    [ "${TOPO_MASTER[2]}" = "10.0.0.2:6382" ]
    [ "${TOPO_MASTER[3]}" = "10.0.0.1:6380" ]
}

@test "topology_plan attaches every replica to a master on ANOTHER host" {
    topology_plan "$REF"
    [ "$TOPO_REPLICA_COUNT" -eq 3 ]
    for (( i = 1; i <= TOPO_REPLICA_COUNT; i++ )); do
        [ "${TOPO_REPLICA[$i]%%:*}" != "${TOPO_REPLICA_MASTER[$i]%%:*}" ]
    done
}

@test "topology_plan gives every master exactly one replica" {
    topology_plan "$REF"
    for (( m = 1; m <= TOPO_MASTER_COUNT; m++ )); do
        n=0
        for (( r = 1; r <= TOPO_REPLICA_COUNT; r++ )); do
            [ "${TOPO_REPLICA_MASTER[$r]}" = "${TOPO_MASTER[$m]}" ] && n=$((n + 1))
        done
        [ "$n" -eq 1 ]
    done
}

@test "topology_plan accounts for every instance exactly once" {
    topology_plan "$REF"
    [ "$TOPO_TOTAL_INSTANCES" -eq 6 ]
    [ $(( TOPO_MASTER_COUNT + TOPO_REPLICA_COUNT )) -eq "$TOPO_TOTAL_INSTANCES" ]
}

@test "topology_plan marks the host holding fewer masters as the survivable one" {
    # 3 masters over 2 hosts: one host holds 2 and the other holds 1.
    # A replica can only be promoted when a majority of the masters is alive,
    # so the host with 1 master is the one whose failure the cluster survives.
    topology_plan "$REF"
    [ "${TOPO_SURVIVES[1]}" = "no" ]
    [ "${TOPO_SURVIVES[2]}" = "yes" ]
    # The premise the name states, pinned as well: the masters are SPREAD over
    # both hosts, 2 on the first and 1 on the second. The two SURVIVES
    # assertions above cannot see this on their own: a layout that puts all
    # three masters on the FIRST host also yields no/yes (killing it leaves 0
    # masters, killing the other leaves all 3), so the outcome is identical
    # while the layout is exactly the one this library exists to prevent.
    local on_first=0 on_second=0
    for (( m = 1; m <= TOPO_MASTER_COUNT; m++ )); do
        case "${TOPO_MASTER[$m]}" in
            "${TOPO_GROUP_HOST[1]}:"*) on_first=$((on_first + 1)) ;;
            "${TOPO_GROUP_HOST[2]}:"*) on_second=$((on_second + 1)) ;;
        esac
    done
    [ "$on_first" -eq 2 ]
    [ "$on_second" -eq 1 ]
}

@test "topology_plan reports no warnings for the reference layout" {
    topology_plan "$REF"
    [ "${#TOPO_WARNINGS[@]}" -eq 0 ]
    [ "$TOPO_UNPROTECTED_COUNT" -eq 0 ]
}

@test "topology_plan warns about a master that cannot get a replica" {
    # 5 instances -> 3 masters but only 2 replicas: one master is
    # geometrically unable to get one. That is a limitation to report, not
    # an algorithm error.
    topology_plan "10.0.0.1:6379,6380,6381 10.0.0.2:6382,6383"
    [ "$TOPO_MASTER_COUNT" -eq 3 ]
    [ "$TOPO_REPLICA_COUNT" -eq 2 ]
    [ "$TOPO_UNPROTECTED_COUNT" -ge 1 ]
    [ "${#TOPO_WARNINGS[@]}" -ge 1 ]
}

# The refusal is reported through the TOPO_ERROR global, NOT through stdout
# or stderr, so `run` cannot be used to check it: bats implements `run` as
# `output="$("$@" 2>&1)"`, a command substitution, and every global the
# command sets dies with that subshell. TOPO_ERROR stays unset in this
# shell and `set -u` turns the check into "unbound variable" instead of an
# assertion. The call therefore happens here and the return code is
# captured by hand.
@test "topology_plan refuses a node group that is not HOST:PORT" {
    local rc=0
    topology_plan "10.0.0.1" || rc=$?
    [ "$rc" -ne 0 ]
    [ -n "$TOPO_ERROR" ]
}

@test "topology_plan refuses a node group with an invalid port" {
    local rc=0
    topology_plan "10.0.0.1:6379,abc" || rc=$?
    [ "$rc" -ne 0 ]
    [ -n "$TOPO_ERROR" ]
}

@test "topology_plan refuses an empty group list" {
    local rc=0
    topology_plan "" || rc=$?
    [ "$rc" -ne 0 ]
    [ -n "$TOPO_ERROR" ]
}

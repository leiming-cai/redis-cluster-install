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

# Temporary directories made by the tests that need one. `teardown` removes
# them. `setup` is deliberately NOT redefined here, so tests/setup.bash's
# `set -u` stays in force for every test in this file.
TOPO_TMP_DIRS=()

teardown() {
    local d
    for d in "${TOPO_TMP_DIRS[@]+"${TOPO_TMP_DIRS[@]}"}"; do
        rm -rf "$d"
    done
    TOPO_TMP_DIRS=()
}

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

@test "topology_plan serves the master with the fewest cross-host candidates first" {
    # The master with the FEWEST free instances on another host is served
    # first, because it is the one that would otherwise be left without a
    # replica. Here 10.0.0.3:6385 has exactly ONE cross-host candidate
    # (10.0.0.2:6383) while 10.0.0.1:6379 has three (10.0.0.2:6383,
    # 10.0.0.3:6386 and 10.0.0.3:6387), so the scarce master is served
    # first and takes 10.0.0.2:6383. Serving the rich master first would
    # take 10.0.0.2:6383 away and leave 10.0.0.3:6385 with no replica at
    # all -- one master without a replica is a slot range nobody covers.
    topology_plan "10.0.0.1:6379 10.0.0.2:6382,6383 10.0.0.3:6385,6386,6387"
    [ "${TOPO_REPLICA[1]}" = "10.0.0.2:6383" ]
    [ "${TOPO_REPLICA_MASTER[1]}" = "10.0.0.3:6385" ]
    [ "${TOPO_REPLICA[2]}" = "10.0.0.3:6386" ]
    [ "${TOPO_REPLICA_MASTER[2]}" = "10.0.0.1:6379" ]
    [ "${TOPO_REPLICA[3]}" = "10.0.0.3:6387" ]
    [ "${TOPO_REPLICA_MASTER[3]}" = "10.0.0.2:6382" ]
    # Every master ends up with a replica -- which is the whole point of
    # serving the scarce one first.
    [ "$TOPO_UNPROTECTED_COUNT" -eq 0 ]
}

@test "topology_plan breaks a tie in candidate count by the selection order" {
    # When two masters have the same number of cross-host candidates, the
    # one SELECTED FIRST is served first. In the reference layout
    # 10.0.0.1:6379 and 10.0.0.1:6380 both have two candidates left, and
    # 10.0.0.1:6379 was selected first, so it takes 10.0.0.2:6383 and
    # 10.0.0.1:6380 takes 10.0.0.2:6384. The reverse order would be the
    # wrong tie-break.
    topology_plan "$REF"
    [ "${TOPO_REPLICA[1]}" = "10.0.0.1:6381" ]
    [ "${TOPO_REPLICA_MASTER[1]}" = "10.0.0.2:6382" ]
    [ "${TOPO_REPLICA[2]}" = "10.0.0.2:6383" ]
    [ "${TOPO_REPLICA_MASTER[2]}" = "10.0.0.1:6379" ]
    [ "${TOPO_REPLICA[3]}" = "10.0.0.2:6384" ]
    [ "${TOPO_REPLICA_MASTER[3]}" = "10.0.0.1:6380" ]
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

@test "topology_plan marks a group whose master has no replica as not survivable" {
    # The survival rule has TWO halves: enough masters must survive the loss
    # of the group, AND every master ON the group must have a replica
    # somewhere else that can be promoted. This layout is the only case that
    # exercises the second half: the three masters sit on three different
    # hosts, so killing 10.0.0.3 leaves 2 of the 3 masters alive -- that is
    # a majority, so the first half of the rule is satisfied. But the master
    # on 10.0.0.3 has no replica at all (2 replicas for 3 masters), so
    # nothing can take over its slots and the cluster does NOT keep
    # serving: "no".
    topology_plan "10.0.0.1:6379 10.0.0.2:6382,6383 10.0.0.3:6384,6385"
    [ "${TOPO_MASTER[3]}" = "10.0.0.3:6384" ]
    [ "${TOPO_SURVIVES[3]}" = "no" ]
    # The master that has no replica is the one the warning names.
    [ "$TOPO_UNPROTECTED_COUNT" -ge 1 ]
    # The two groups whose masters are all covered still survive.
    [ "${TOPO_SURVIVES[1]}" = "yes" ]
    [ "${TOPO_SURVIVES[2]}" = "yes" ]
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

@test "topology_plan refuses a layout that spans only one host" {
    # A replica must live on ANOTHER host than its master, so a layout that
    # spans a single host cannot be satisfied at all: every instance would
    # have to be the replica of a master on its own host, and a host
    # failure would then take both down at once. There is no arrangement
    # that works, so this is a hard error and not a warning.
    local rc=0
    topology_plan "10.0.0.1:6379,6380,6381,6382" || rc=$?
    [ "$rc" -ne 0 ]
    [ -n "$TOPO_ERROR" ]
    # The message has to say WHY: the instances have no master on another
    # host to attach to.
    [[ "$TOPO_ERROR" == *"no master on another host"* ]]
}

@test "topology_plan does not let the shell expand a wildcard host" {
    # The input is split on spaces, and an unquoted expansion ALSO performs
    # pathname expansion: a group whose host is `*` would expand to the
    # files in the current directory, so the parsed layout would depend on
    # $PWD -- the same trap lib/conf.sh documents for
    # `IFS=',' local -a x=($raw)`. Two directories with DIFFERENT file
    # listings must therefore yield the SAME layout, and the host must
    # stay the literal `*`.
    local d1 d2
    d1="$(mktemp -d)"
    d2="$(mktemp -d)"
    TOPO_TMP_DIRS+=("$d1" "$d2")
    # A file whose name matches the wildcard: without `set -f` the group
    # `*:6379` expands to it and the host silently becomes "alpha".
    touch "$d1/alpha:6379"
    touch "$d2/beta:6379"

    local layout="*:6379 10.0.0.2:6382,6383 10.0.0.3:6384,6385"
    local out1 out2
    out1="$( cd "$d1" && topology_plan "$layout" && echo "${TOPO_MASTER[*]}" )"
    out2="$( cd "$d2" && topology_plan "$layout" && echo "${TOPO_MASTER[*]}" )"
    [ "$out1" = "$out2" ]
    # The host is still the literal `*`, not a file name.
    [[ "$out1" == *"*:6379"* ]]

    # `set -f` is a shell option and not a local variable, so the call must
    # not leave it switched on for the caller. The call has to happen in
    # THIS shell: inside a command substitution it runs in a subshell, and a
    # subshell cannot leak a shell option back to its parent, so the check
    # below would pass no matter what the function did.
    local pwd="$PWD"
    cd "$d1"
    topology_plan "$layout" >/dev/null
    cd "$pwd"
    case "$-" in
        *f*) false ;;
    esac
}

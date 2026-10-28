load '../setup'
load_lib cluster

@test "cluster_known_nodes parses 'cluster_known_nodes:6'" {
    result=$(cluster_known_nodes <<<$'cluster_state:ok\ncluster_slots_assigned:16384\ncluster_known_nodes:6')
    [ "$result" = "6" ]
}

@test "cluster_known_nodes returns empty on missing key" {
    result=$(cluster_known_nodes <<<$'cluster_state:ok')
    [ -z "$result" ]
}

# NOTE: the fixture below mirrors the real `redis-cli cluster info` output.
# lib/cluster.sh also requires cluster_slots_fail and cluster_known_nodes,
# so a two-line sample would (correctly) be reported unhealthy.
# See lib/cluster.sh:11-30 and tests/validate_libs.sh for the same matrix.
HEALTHY_INFO=$'cluster_state:ok\ncluster_slots_assigned:16384\ncluster_slots_ok:16384\ncluster_slots_pfail:0\ncluster_slots_fail:0\ncluster_known_nodes:6\ncluster_size:3'

@test "is_cluster_healthy returns 0 for a real 6-node/16384-slot cluster" {
    run is_cluster_healthy <<<"$HEALTHY_INFO"
    [ "$status" -eq 0 ]
}

@test "is_cluster_healthy tolerates transient fail right after cluster create" {
    run is_cluster_healthy <<<"${HEALTHY_INFO/cluster_state:ok/cluster_state:fail}"
    [ "$status" -eq 0 ]
}

@test "is_cluster_healthy returns 1 when slots are incomplete" {
    run is_cluster_healthy <<<"${HEALTHY_INFO/cluster_slots_assigned:16384/cluster_slots_assigned:16000}"
    [ "$status" -ne 0 ]
}

@test "is_cluster_healthy returns 1 when slots are failing" {
    run is_cluster_healthy <<<"${HEALTHY_INFO/cluster_slots_fail:0/cluster_slots_fail:100}"
    [ "$status" -ne 0 ]
}

@test "is_cluster_healthy returns 1 when too few nodes are known" {
    run is_cluster_healthy <<<"${HEALTHY_INFO/cluster_known_nodes:6/cluster_known_nodes:3}"
    [ "$status" -ne 0 ]
}

@test "is_cluster_healthy returns 1 on empty input (redis-cli unreachable)" {
    run is_cluster_healthy <<<""
    [ "$status" -ne 0 ]
}

# --- MIN_KNOWN_NODES threshold ---
#
# The default of 6 suits the 3-master/1-replica layout this project ships and
# keeps status.sh (which has no config to count instances from) unchanged. A
# caller that knows its instance count passes it, because lib/conf.sh accepts
# a 5-instance layout that would otherwise never satisfy a hardcoded 6.
SMALL_INFO=$'cluster_state:ok\ncluster_slots_assigned:16384\ncluster_slots_ok:16384\ncluster_slots_pfail:0\ncluster_slots_fail:0\ncluster_known_nodes:5\ncluster_size:3'

@test "is_cluster_healthy defaults to requiring 6 known nodes" {
    # No argument -> the default threshold still rejects a 5-node cluster.
    run is_cluster_healthy <<<"$SMALL_INFO"
    [ "$status" -ne 0 ]
}

@test "is_cluster_healthy accepts a 5-node cluster when told the threshold is 5" {
    run is_cluster_healthy 5 <<<"$SMALL_INFO"
    [ "$status" -eq 0 ]
}

@test "is_cluster_healthy still rejects a 5-node cluster when the threshold is 6" {
    run is_cluster_healthy 6 <<<"$SMALL_INFO"
    [ "$status" -ne 0 ]
}

@test "is_cluster_healthy honours a threshold above the known node count" {
    run is_cluster_healthy 9 <<<"$HEALTHY_INFO"
    [ "$status" -ne 0 ]
}

@test "is_cluster_healthy falls back to the default on a non-numeric threshold" {
    # An empty or junk argument must not make `[` fail with
    # "integer expression expected" and be mistaken for cluster health.
    run is_cluster_healthy abc <<<"$HEALTHY_INFO"
    [ "$status" -eq 0 ]
    run is_cluster_healthy "" <<<"$HEALTHY_INFO"
    [ "$status" -eq 0 ]
}

@test "build_create_command emits redis-cli then create then nodes then replicas 1" {
    out=$(build_create_command "secret" "10.0.0.1:6379" "10.0.0.2:6379")
    [[ "$out" == *"redis-cli"* ]]
    [[ "$out" == *"--cluster"* ]]
    [[ "$out" == *"create"* ]]
    [[ "$out" == *"10.0.0.1:6379"* ]]
    [[ "$out" == *"10.0.0.2:6379"* ]]
    [[ "$out" == *"--cluster-replicas"* ]]
    [[ "$out" == *"1"* ]]
    # -a and secret are separate argv tokens (one per line, for eval)
    [[ "$out" == *$'-a\nsecret'* ]]
}

# --- the two-phase assembly ---------------------------------------------
#
# `redis-cli --cluster create --cluster-replicas 1` picks the roles itself,
# and its pick is not spread across hosts (measured: 6 instances on 2 hosts
# ended up with all 3 masters on one host, and killing that host left the
# cluster with no quorum). So the cluster is built in two phases: create the
# masters with 0 replicas, then attach each replica with
# `--cluster add-node ... --cluster-slave`.

@test "build_create_command accepts an explicit replica count" {
    out=$(build_create_command "secret" 0 "10.0.0.1:6379" "10.0.0.2:6382")
    [[ "$out" == *"--cluster-replicas"* ]]
    [[ "$out" == *$'--cluster-replicas\n0'* ]]
}

@test "build_create_command still defaults to one replica" {
    out=$(build_create_command "secret" "10.0.0.1:6379")
    [[ "$out" == *$'--cluster-replicas\n1'* ]]
}

@test "build_add_replica_command names the new node, its master and --cluster-slave" {
    out=$(build_add_replica_command "secret" "10.0.0.2:6383" "10.0.0.1:6379")
    [[ "$out" == *"redis-cli"* ]]
    [[ "$out" == *"--cluster"* ]]
    [[ "$out" == *"add-node"* ]]
    [[ "$out" == *"10.0.0.2:6383"* ]]
    [[ "$out" == *"10.0.0.1:6379"* ]]
    [[ "$out" == *"--cluster-slave"* ]]
    [[ "$out" == *$'-a\nsecret'* ]]
}

@test "build_eval_argv quotes every argument so eval cannot be tricked by it" {
    # The password is arbitrary user input: lib/conf.sh only requires it to be
    # non-empty. An unquoted eval would let a password containing a quote or
    # a semicolon run as a command.
    out=$(printf '%s\n' "redis-cli" "-a" "pw'; rm -rf /;'" | build_eval_argv)
    [ "$out" = "'redis-cli' '-a' 'pw'\''; rm -rf /;'\'''" ]
}

@test "build_eval_argv round-trips an argument that contains a single quote" {
    out=$(printf '%s\n' "a'b" | build_eval_argv)
    eval "set -- $out"
    [ "$1" = "a'b" ]
}

# --- reading the cluster's current roles -------------------------------
#
# `redis-cli cluster nodes` prints:
#   <id> <ip:port@bus-port[,hostname]> <flags> <master-id> ...
# A master carries the master id all zeroes; a replica carries its master's id.

NODES=$'421018a0575212623c289749ed20e83ddecf65c1 10.0.0.1:6379@16379 myself,master - 0 0 1 connected 0-5460\n32b1facc82951483e09626c50c68e8a9ed72e5f7 10.0.0.2:6383@16379 slave 421018a0575212623c289749ed20e83ddecf65c1 0 0 2 connected'

@test "cluster_nodes_index reports the role and the master of every node" {
    out=$(cluster_nodes_index <<<"$NODES")
    [[ "$out" == *"10.0.0.1:6379 master"* ]]
    [[ "$out" == *"10.0.0.2:6383 replica 421018a0575212623c289749ed20e83ddecf65c1"* ]]
}

@test "cluster_role_of finds the role of an instance" {
    [ "$(cluster_role_of "$NODES" 10.0.0.1 6379)" = "master" ]
    [ "$(cluster_role_of "$NODES" 10.0.0.2 6383)" = "replica" ]
}

@test "cluster_role_of reports none for an instance that is not a member" {
    [ "$(cluster_role_of "$NODES" 10.0.0.3 6385)" = "none" ]
}

@test "cluster_replica_master_of resolves the master address of a replica" {
    [ "$(cluster_replica_master_of "$NODES" 10.0.0.2 6383)" = "10.0.0.1:6379" ]
}

@test "cluster_exists is false for an instance that has not joined a cluster" {
    run cluster_exists <<<"cluster_state:fail
cluster_slots_assigned:0
cluster_known_nodes:1"
    [ "$status" -ne 0 ]
}

@test "cluster_exists is true once the cluster has slots assigned" {
    run cluster_exists <<<"cluster_state:ok
cluster_slots_assigned:16384
cluster_known_nodes:6"
    [ "$status" -eq 0 ]
}

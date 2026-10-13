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

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

@test "is_cluster_healthy returns 0 when state=ok and slots=16384" {
    is_cluster_healthy <<<$'cluster_state:ok\ncluster_slots_assigned:16384\ncluster_known_nodes:6'
    [ "$? " -eq 0 ]
}

@test "is_cluster_healthy returns 1 when state is not ok" {
    run is_cluster_healthy <<<$'cluster_state:fail\ncluster_slots_assigned:16384\ncluster_known_nodes:6'
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

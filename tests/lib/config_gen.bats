load '../setup'
load_lib config_gen

@test "render_redis_conf replaces %PORT% placeholder" {
    result=$(render_redis_conf "tests/fixtures/redis.conf.template" "6379" "secret123" "node-a" "0.0.0.0")
    [[ "$result" == *"port 6379"* ]]
}

@test "render_redis_conf replaces %PASSWORD% in both places" {
    result=$(render_redis_conf "tests/fixtures/redis.conf.template" "6379" "secret123" "node-a" "0.0.0.0")
    [[ "$result" == *"requirepass secret123"* ]]
    [[ "$result" == *"masterauth secret123"* ]]
}

@test "render_redis_conf replaces %NODE_NAME%" {
    result=$(render_redis_conf "tests/fixtures/redis.conf.template" "6379" "x" "alpha" "0.0.0.0")
    [[ "$result" == *"node_name alpha"* ]]
}

@test "render_redis_conf replaces %BIND_ADDR%" {
    result=$(render_redis_conf "tests/fixtures/redis.conf.template" "6379" "x" "alpha" "10.0.0.1")
    [[ "$result" == *"bind 10.0.0.1"* ]]
}

@test "render_redis_conf aborts on missing template" {
    run render_redis_conf "tests/fixtures/missing.conf.template" "6379" "x" "alpha" "0.0.0.0"
    [ "$status" -ne 0 ]
}
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

# A password containing sed's replacement-side metacharacters was silently
# mangled before every field was escaped:
#   a&b -> requirepass a%PASSWORD%b
#   a\b -> requirepass ab
#   a|b -> sed aborted with "unknown option to `s'|"
# cluster_password is arbitrary user input, so this must round-trip exactly
# and must agree with lib/systemd.sh's renderer.
@test "render_redis_conf keeps a password containing & intact" {
    result=$(render_redis_conf "tests/fixtures/redis.conf.template" "6379" 'a&b' "node-a" "0.0.0.0")
    [[ "$result" == *"requirepass a&b"* ]]
    [[ "$result" == *"masterauth a&b"* ]]
}

@test "render_redis_conf keeps a password containing a backslash intact" {
    result=$(render_redis_conf "tests/fixtures/redis.conf.template" "6379" 'a\b' "node-a" "0.0.0.0")
    [[ "$result" == *"requirepass a\b"* ]]
}

@test "render_redis_conf does not abort when the password contains |" {
    run render_redis_conf "tests/fixtures/redis.conf.template" "6379" 'a|b' "node-a" "0.0.0.0"
    [ "$status" -eq 0 ]
    [[ "$output" == *"requirepass a|b"* ]]
}

@test "render_redis_conf and render_systemd_unit agree on a hostile password" {
    # The shipped unit template deliberately keeps the password OUT of the
    # unit (it reads EnvironmentFile=/etc/redis/cluster/auth.conf), so to
    # compare the two renderers we need a template that really interpolates
    # %PASSWORD%.
    load_lib systemd
    pw='p&ss|w\rd'
    conf=$(render_redis_conf "tests/fixtures/redis.conf.template" "6379" "$pw" "node-a" "0.0.0.0")
    unit=$(render_systemd_unit "tests/fixtures/with-password.service.template" "6379" "node-a" "$pw")
    [[ "$conf" == *"requirepass $pw"* ]]
    [[ "$unit" == *"$pw"* ]]
}

@test "render_redis_conf escapes a REDIS_PREFIX containing & and |" {
    result=$(render_redis_conf "tests/fixtures/cluster-config.redis.conf.template" \
        "6379" "pw" "node-a" "0.0.0.0" '/opt/r&d/is|')
    [[ "$result" == *"cluster-config-file /opt/r&d/is|/cluster/6379/nodes.conf"* ]]
}
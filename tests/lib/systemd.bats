load '../setup'
load_lib systemd

@test "render_systemd_unit includes port in Description" {
    result=$(render_systemd_unit "tests/fixtures/systemd.service.template" "6379" "node-a")
    [[ "$result" == *"Description=Redis 6379 (node-a)"* ]]
}

@test "render_systemd_unit substitutes ExecStart path" {
    result=$(render_systemd_unit "tests/fixtures/systemd.service.template" "6380" "node-b")
    [[ "$result" == *"/etc/redis/cluster/redis-6380.conf"* ]]
}

@test "render_systemd_unit aborts on missing template" {
    run render_systemd_unit "tests/fixtures/missing.service.template" "6379" "x"
    [ "$status" -ne 0 ]
}

@test "systemd_unit_name returns redis-PORT.service" {
    result=$(systemd_unit_name "6379")
    [ "$result" = "redis-6379.service" ]
}

@test "systemd_unit_path returns /etc/systemd/system/redis-PORT.service" {
    result=$(systemd_unit_path "6380")
    [ "$result" = "/etc/systemd/system/redis-6380.service" ]
}
load '../setup'
load_lib common
load_lib conf

setup() {
    CONF_TMP="$(mktemp -d)"
    export CONF_TMP
}

teardown() {
    rm -rf "$CONF_TMP"
}

write_conf() {
    cat > "$CONF_TMP/cluster.conf"
}

@test "parse_conf reads global keys and defaults" {
    write_conf <<'EOF'
redis_prefix     = /custom/redis
cluster_password = s3cret
bind_addr        = 127.0.0.1
[node.a]
host  = 10.0.0.1
ports = 6379,6380,6381
[node.b]
host  = 10.0.0.2
ports = 6382,6383
[node.c]
host  = 10.0.0.3
ports = 6383
EOF
    parse_conf "$CONF_TMP/cluster.conf"
    [ "$CONF_REDIS_PREFIX" = "/custom/redis" ]
    [ "$CONF_PASSWORD" = "s3cret" ]
    [ "$CONF_BIND_ADDR" = "127.0.0.1" ]
}

@test "parse_conf applies default prefix and bind_addr when absent" {
    write_conf <<'EOF'
cluster_password = pw
[node.a]
host  = h1
ports = 6379,6380,6381
[node.b]
host  = h2
ports = 6382,6383
EOF
    parse_conf "$CONF_TMP/cluster.conf"
    [ "$CONF_REDIS_PREFIX" = "/opt/software/redis" ]
    [ "$CONF_BIND_ADDR" = "0.0.0.0" ]
}

@test "parse_conf stores nodes in file order with group and envkey" {
    write_conf <<'EOF'
cluster_password = pw
[node.a]
host  = 10.0.0.1
ports = 6379,6380,6381
[node.worker-1]
host  = 10.0.0.2
ports = 6382,6383,6384
EOF
    parse_conf "$CONF_TMP/cluster.conf"
    [ "$CONF_NODE_COUNT" -eq 2 ]
    [ "${CONF_NODE_GROUP[1]}" = "a" ]
    [ "${CONF_NODE_ENVKEY[1]}" = "NODE_A" ]
    [ "${CONF_NODE_HOST[1]}" = "10.0.0.1" ]
    [ "${CONF_NODE_GROUP[2]}" = "worker-1" ]
    [ "${CONF_NODE_ENVKEY[2]}" = "NODE_WORKER_1" ]
    [ "${CONF_NODE_HOST[2]}" = "10.0.0.2" ]
}

@test "parse_conf defaults ssh_port to 22 when absent" {
    write_conf <<'EOF'
cluster_password = pw
[node.a]
host  = h1
ports = 6379,6380,6381
[node.b]
host  = h2
ports = 6382,6383
EOF
    parse_conf "$CONF_TMP/cluster.conf"
    [ "${CONF_NODE_SSH_PORT[1]}" = "22" ]
}

@test "parse_conf honours an explicit ssh_port" {
    # 5 instances in total: the master-count rule (spec 3.4) rejects anything
    # under 5 instances with replicas=1, so a 1-port-per-group fixture would
    # never reach the ssh_port assertion.
    write_conf <<'EOF'
cluster_password = pw
[node.a]
host     = h1
ssh_port = 2222
ports    = 6379,6380
[node.b]
host  = h2
ports = 6381,6382
[node.c]
host  = h3
ports = 6383
EOF
    parse_conf "$CONF_TMP/cluster.conf"
    [ "${CONF_NODE_SSH_PORT[1]}" = "2222" ]
}

@test "parse_conf normalises whitespace around keys, values and ports" {
    write_conf <<'EOF'
   cluster_password    =    pw
[node.a]
   host     =   10.0.0.1
   ports    =   6379 , 6380 ,6381
[node.b]
host  = h2
ports = 6382,6383
[node.c]
host  = h3
ports = 6383
EOF
    parse_conf "$CONF_TMP/cluster.conf"
    [ "$CONF_PASSWORD" = "pw" ]
    [ "${CONF_NODE_HOST[1]}" = "10.0.0.1" ]
    [ "${CONF_NODE_PORTS[1]}" = "6379,6380,6381" ]
}

@test "parse_conf dies when cluster_password is missing" {
    write_conf <<'EOF'
[node.a]
host  = h1
ports = 6379,6380,6381
[node.b]
host  = h2
ports = 6382,6383
EOF
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cluster_password"* ]]
}

@test "parse_conf dies when a node group has no host" {
    write_conf <<'EOF'
cluster_password = pw
[node.a]
ports = 6379
[node.b]
host  = h2
ports = 6380
[node.c]
host  = h3
ports = 6381
EOF
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"host"* ]]
}

@test "parse_conf dies when a node group has no ports" {
    write_conf <<'EOF'
cluster_password = pw
[node.a]
host = h1
[node.b]
host  = h2
ports = 6380
[node.c]
host  = h3
ports = 6381
EOF
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ports"* ]]
}

@test "parse_conf dies on a malformed line without an equals sign" {
    write_conf <<'EOF'
cluster_password = pw
this line has no equals
[node.a]
host  = h1
ports = 6379,6380,6381
[node.b]
host  = h2
ports = 6382,6383
EOF
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no equals"* ]]
}

@test "parse_conf dies when too few instances are configured for 3 masters" {
    write_conf <<'EOF'
cluster_password = pw
[node.a]
host  = h1
ports = 6379
[node.b]
host  = h2
ports = 6380
EOF
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"at least 3 masters"* ]]
    [[ "$output" == *"2 instance(s)"* ]]
}

@test "parse_conf counts INSTANCES not node groups for the master threshold" {
    # Two groups but six ports: the canonical "A:6379-6381 + B:6382-6384"
    # layout must be accepted. Counting groups would compute ceil(2/2)=1
    # master and wrongly reject it.
    write_conf <<'EOF'
cluster_password = pw
[node.a]
host  = h1
ports = 6379,6380,6381
[node.b]
host  = h2
ports = 6382,6383,6384
EOF
    parse_conf "$CONF_TMP/cluster.conf"
    [ "$CONF_NODE_COUNT" -eq 2 ]
    [ "$CONF_TOTAL_INSTANCES" -eq 6 ]
}

@test "parse_conf dies when the config file does not exist" {
    run parse_conf "$CONF_TMP/nope.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found"* ]]
}

@test "parse_conf splits on the FIRST equals so values may contain equals" {
    write_conf <<'EOF'
cluster_password = pa=ss=word
[node.a]
host  = h1
ports = 6379,6380,6381
[node.b]
host  = h2
ports = 6382,6383
EOF
    parse_conf "$CONF_TMP/cluster.conf"
    [ "$CONF_PASSWORD" = "pa=ss=word" ]
}

@test "parse_conf collects unknown keys instead of failing" {
    write_conf <<'EOF'
cluster_password = pw
ssh_prot = 22
[node.a]
host   = h1
prot   = 6379
ports  = 6379,6380
[node.b]
host  = h2
ports = 6381,6382
[node.c]
host  = h3
ports = 6383
EOF
    # Called directly (not via `run`) so the CONF_* globals stay in scope;
    # reaching the assertions below proves parsing succeeded, since die() exits.
    parse_conf "$CONF_TMP/cluster.conf"
    [ "$CONF_UNKNOWN_KEYS" = "ssh_prot
prot" ]
}

@test "parse_conf does not execute shell code in the config" {
    write_conf <<'EOF'
cluster_password = pw
INJECTED = $(touch /tmp/conf-pwned-$$)
[node.a]
host  = h1
ports = 6379,6380,6381
[node.b]
host  = h2
ports = 6382,6383
EOF
    # No `run`: `run` captures output in a command substitution, which would
    # discard the CONF_* globals this test inspects.
    parse_conf "$CONF_TMP/cluster.conf"
    [ ! -e "/tmp/conf-pwned-$$" ]
    [[ "$CONF_UNKNOWN_KEYS" == *"INJECTED"* ]]
}
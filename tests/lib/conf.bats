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
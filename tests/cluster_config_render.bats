load 'setup'
load_lib config_gen
load_lib systemd

# Contract tests for the rendering step of cluster-config.sh.
#
# The bug these guard (docs/VERIFICATION.md D8) was only ever visible on a
# real node: config/redis.conf.template sends cluster-config-file and logfile
# under $REDIS_PREFIX, the systemd unit has ProtectSystem=strict, and unless
# ReadWritePaths names the same directories redis-server aborts with
# "Can't open the log file: Read-only file system". A unit test is cheap
# enough that the next edit to either template should not be able to
# reintroduce it silently.
#
# Two template pairs are exercised:
#   * tests/fixtures/cluster-config.*  — small hand-written fixtures, so the
#     assertions stay readable and independent of the real templates.
#   * config/*                         — the templates the script actually
#     deploys. A fixture-only test would keep passing even if someone broke
#     the real ones, which is the regression worth preventing.

setup() {
    FIXTURE_CONF="$REPO_ROOT/tests/fixtures/cluster-config.redis.conf.template"
    FIXTURE_UNIT="$REPO_ROOT/tests/fixtures/cluster-config.service.template"
    REAL_CONF="$REPO_ROOT/config/redis.conf.template"
    REAL_UNIT="$REPO_ROOT/config/redis-cluster.service.template"
    PREFIX="/opt/software/redis"
    PASS="s3cret"
}

# Every absolute path a rendered redis.conf makes redis-server open for
# writing. Under ProtectSystem=strict these must all be writable, or the
# instance dies on start.
writable_paths() {
    printf '%s\n' "$1" | awk '
        /^cluster-config-file[ \t]/ { print $2 }
        /^logfile[ \t]/             { print $2 }
        /^dir[ \t]/                { print $2 }
    '
}

read_write_paths() {
    printf '%s\n' "$1" | sed -n 's/^ReadWritePaths=//p' | tr ' ' '\n' | sed '/^$/d'
}

# covered PATH — reads the ReadWritePaths list on stdin, succeeds when PATH
# is one of the entries or lives underneath one of them.
covered() {
    local p="$1" r
    while IFS= read -r r; do
        case "$p" in
            "$r"|"$r"/*) return 0 ;;
        esac
    done
    return 1
}

@test "rendered redis.conf carries the right port and password" {
    out="$(render_redis_conf "$FIXTURE_CONF" 6379 "$PASS" "node-6379" "0.0.0.0" "$PREFIX")"
    [[ "$out" == *"port 6379"* ]]
    [[ "$out" == *"requirepass s3cret"* ]]
    [[ "$out" == *"masterauth s3cret"* ]]
}

@test "rendered redis.conf points cluster-config-file at REDIS_PREFIX" {
    out="$(render_redis_conf "$FIXTURE_CONF" 6380 "$PASS" "node-6380" "0.0.0.0" "$PREFIX")"
    [[ "$out" == *"cluster-config-file /opt/software/redis/cluster/6380/nodes.conf"* ]]
}

@test "rendered redis.conf logfile lives under REDIS_PREFIX/log" {
    out="$(render_redis_conf "$FIXTURE_CONF" 6381 "$PASS" "node-6381" "0.0.0.0" "$PREFIX")"
    [[ "$out" == *"logfile /opt/software/redis/log/redis-6381.log"* ]]
}

@test "a custom REDIS_PREFIX propagates into redis.conf" {
    out="$(render_redis_conf "$FIXTURE_CONF" 6379 "$PASS" "node-6379" "0.0.0.0" "/custom/redis")"
    [[ "$out" == *"cluster-config-file /custom/redis/cluster/6379/nodes.conf"* ]]
    [[ "$out" == *"logfile /custom/redis/log/redis-6379.log"* ]]
    [[ "$out" != *"/opt/software/redis"* ]]
}

@test "rendered unit ExecStart uses REDIS_PREFIX/bin/redis-server" {
    out="$(render_systemd_unit "$FIXTURE_UNIT" 6379 "node-6379" "$PASS" "$PREFIX")"
    [[ "$out" == *"ExecStart=/opt/software/redis/bin/redis-server /etc/redis/cluster/redis-6379.conf"* ]]
}

@test "unit ReadWritePaths covers cluster and log dirs (D8 regression)" {
    out="$(render_systemd_unit "$FIXTURE_UNIT" 6379 "node-6379" "$PASS" "$PREFIX")"
    [[ "$out" == *"/opt/software/redis/cluster"* ]]
    [[ "$out" == *"/opt/software/redis/log"* ]]
    [[ "$out" == *"/var/lib/redis"* ]]
}

@test "config and unit agree on the port for every instance" {
    for p in 6379 6380 6381 6382 6383 6384; do
        conf="$(render_redis_conf "$FIXTURE_CONF" "$p" "$PASS" "node-$p" "0.0.0.0" "$PREFIX")"
        unit="$(render_systemd_unit "$FIXTURE_UNIT" "$p" "node-$p" "$PASS" "$PREFIX")"
        [[ "$conf" == *"port $p"* ]]
        [[ "$unit" == *"redis-$p.conf"* ]]
    done
}

# --- the same contract, asserted against the templates that ship ----------

@test "the real redis.conf keeps cluster-config-file and logfile under REDIS_PREFIX" {
    out="$(render_redis_conf "$REAL_CONF" 6380 "$PASS" "node-6380" "0.0.0.0" "$PREFIX")"
    [[ "$out" == *"cluster-config-file /opt/software/redis/cluster/6380/nodes.conf"* ]]
    [[ "$out" == *"logfile /opt/software/redis/log/redis-6380.log"* ]]
    [[ "$out" != *"%REDIS_PREFIX%"* ]]
    [[ "$out" != *"%PORT%"* ]]
}

@test "the real unit ExecStart binary lives under the same prefix (D8 regression)" {
    out="$(render_systemd_unit "$REAL_UNIT" 6380 "node-6380" "$PASS" "$PREFIX")"
    [[ "$out" == *"ExecStart=/opt/software/redis/bin/redis-server /etc/redis/cluster/redis-6380.conf"* ]]
    [[ "$out" != *"%REDIS_PREFIX%"* ]]
}

@test "every path the real redis.conf writes is granted by the real unit's ReadWritePaths" {
    conf="$(render_redis_conf "$REAL_CONF" 6380 "$PASS" "node-6380" "0.0.0.0" "$PREFIX")"
    unit="$(render_systemd_unit "$REAL_UNIT" 6380 "node-6380" "$PASS" "$PREFIX")"
    rwp="$(read_write_paths "$unit")"
    [ -n "$rwp" ] || { echo "unit has no ReadWritePaths at all" >&2; false; }

    checked=0
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        if ! printf '%s\n' "$rwp" | covered "$p"; then
            echo "redis.conf writes '$p' but ReadWritePaths ($rwp) does not cover it" >&2
            false
        fi
        checked=$((checked + 1))
    done <<< "$(writable_paths "$conf")"
    [ "$checked" -ge 3 ]
}

@test "a custom prefix keeps the real redis.conf and unit in agreement" {
    p="/srv/redis-data"
    conf="$(render_redis_conf "$REAL_CONF" 6379 "$PASS" "node-6379" "0.0.0.0" "$p")"
    unit="$(render_systemd_unit "$REAL_UNIT" 6379 "node-6379" "$PASS" "$p")"
    [[ "$conf" == *"cluster-config-file $p/cluster/6379/nodes.conf"* ]]
    [[ "$conf" == *"logfile $p/log/redis-6379.log"* ]]
    [[ "$unit" == *"ExecStart=$p/bin/redis-server "* ]]
    rwp="$(read_write_paths "$unit")"
    while IFS= read -r w; do
        [ -n "$w" ] || continue
        printf '%s\n' "$rwp" | covered "$w" \
            || { echo "'$w' is not covered by ReadWritePaths ($rwp)" >&2; false; }
    done <<< "$(writable_paths "$conf")"
}

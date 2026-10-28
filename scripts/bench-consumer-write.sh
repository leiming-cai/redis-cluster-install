#!/usr/bin/env bash
# Backlog-drain benchmark for the Kafka -> RTListener -> Redis Cluster write path.
#
# Why backlog drain: producing while consuming measures the producer (measured
# at ~8.5k/s in the ninth round), not the writer. Stop the consumer, fill the
# topic, then measure the pure drain rate. See docs/HANDOFF.md, ninth round.
#
# Usage (host has no usable bash; run this inside the E2E runner image):
#   docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
#     -v "D:/work/rediscluterproject:/repo" \
#     -e NEW_JAR=D:/path/to/rtdata-consumer-1.0.14.jar \
#     rc-e2e-runner:local bash /repo/scripts/bench-consumer-write.sh
#
# Env:
#   NEW_JAR    optional; recreate the consumer against this jar (daemon-visible path)
#   N          records to produce (default 200000)
#   CONC       listener concurrency per instance (default 1)
#   CONSUMERS  number of consumer containers, same group (default 1). With 2,
#              Kafka splits INCDATA's two partitions between the two instances --
#              this measures more *JVMs* on the same Redis/Kafka, which is a
#              different question from CONC (more threads in one JVM).
#   GROUP      consumer group; defaults to the running consumer's group id
#   MIN_MEAN  lowest mean_active_per_s to accept (default 0); a slow run still
#             drains to completion, then fails, so the gate cannot hide a stall
#
# NOTE: this harness DESTROYS and RECREATES the consumer container(s) ($APP, or
# $APP-1..$APP-CONSUMERS) from the flag list below. Heap (Xms/Xmx), the port and
# every --flag come from this script, not from whatever the container ran
# before -- point it at a throwaway consumer, never at production.
#
# Requires: the consumer group must be caught up (lag 0) before measuring,
# otherwise the drain would include someone else's backlog and the numbers
# would not be comparable.
set -uo pipefail

APP=${APP:-rc-cpsweb-app}
NODE=${NODE:-rc-cpsweb-node-a}
NET=${NET:-rc-cpsweb-net}
BASE_IMAGE=${BASE_IMAGE:-cpsweb-env:1.0}
BROKERS=${BROKERS:-172.21.0.2:9092,172.21.0.3:9092}
CLUSTER_PW=${CLUSTER_PW:-CpsE2eClusterPw}
REDIS_CLI=/opt/software/redis/bin/redis-cli
K=/opt/software/kafka_2.13-2.8.0
N=${N:-200000}
CONC=${CONC:-1}
CONSUMERS=${CONSUMERS:-1}
CONFIG_FROM_YAML=${CONFIG_FROM_YAML:-0}
# The Redis cluster the consumer must end up using. Asserted at startup: a yaml
# that failed to load would silently leave the app on its defaults.
REDIS_NODES=${REDIS_NODES:-172.21.0.2:6379,172.21.0.2:6380,172.21.0.3:6382}
# Consumer group the application.yaml declares (used when the command line
# carries no group-id, i.e. CONFIG_FROM_YAML=1).
YAML_GROUP=${YAML_GROUP:-rc-kafka-cluster-1793069287}
MIN_MEAN=${MIN_MEAN:-0}

fail() { echo "FAIL: $*" >&2; exit 1; }
info() { echo "[bench] $*"; }

# Bad inputs must fail here, not after a 200k-record publish.
[[ "$N" =~ ^[0-9]+$ ]] || fail "N must match ^[0-9]+$, got [$N]"
[[ "$CONC" =~ ^[0-9]+$ ]] || fail "CONC must match ^[0-9]+$, got [$CONC]"
[[ "$CONSUMERS" =~ ^[1-9][0-9]*$ ]] || fail "CONSUMERS must match ^[1-9][0-9]*$, got [$CONSUMERS]"
[[ "$CONFIG_FROM_YAML" =~ ^[01]$ ]] || fail "CONFIG_FROM_YAML must be 0 or 1, got [$CONFIG_FROM_YAML]"
[[ "$MIN_MEAN" =~ ^[0-9]+$ ]] || fail "MIN_MEAN must match ^[0-9]+$, got [$MIN_MEAN]"
# N >= 4 keeps both partitions non-empty and the eight sample indices distinct.
[ "$N" -ge 4 ] || fail "N must be >= 4, got $N"

# Names of the consumer containers of this run. One instance keeps the historic
# name ($APP) so every existing invocation behaves exactly as before.
apps() {
    if [ "$CONSUMERS" -eq 1 ]; then
        printf '%s\n' "$APP"
    else
        local i
        for i in $(seq 1 "$CONSUMERS"); do printf '%s-%s\n' "$APP" "$i"; done
    fi
}

# --- interrupt safety -------------------------------------------------------
# Set while this script holds the consumer stopped. Dying between `docker stop`
# and `docker start` would leave the pipeline down and two producers running;
# the EXIT trap puts the consumer back and kills the producers.
STOPPED_CONSUMER=0
cleanup() {
    local rc=$?
    if [ -n "${P1:-}" ]; then kill "$P1" 2>/dev/null || true; fi
    if [ -n "${P2:-}" ]; then kill "$P2" 2>/dev/null || true; fi
    if [ "$STOPPED_CONSUMER" = "1" ]; then
        echo "[bench] restarting the consumers this script left stopped" >&2
        while read -r _a; do
            docker start "$_a" >/dev/null 2>&1 \
                || echo "[bench] WARNING: could not restart $_a; start it by hand" >&2
        done < <(apps)
        STOPPED_CONSUMER=0
    fi
    if [ "$rc" -ne 0 ]; then
        while read -r _a; do
            [ -s "${LOG:-}.$_a" ] || continue
            echo "----- last 20 lines of $LOG.$_a -----" >&2
            tail -20 "$LOG.$_a" >&2
            echo "----- per-second series ($_a) -----" >&2
            sed -n 's/.*每秒已处理实时数据变化数量：\([0-9]*\).*/\1/p' "$LOG.$_a" | tr '\n' ' ' >&2
            echo >&2
        done < <(apps)
    fi
}
trap cleanup EXIT
# A non-interactive bash does not run the EXIT trap on SIGTERM (that is what
# `docker stop` sends), so turn TERM/INT into a normal exit and let EXIT run.
trap 'exit 130' INT
trap 'exit 143' TERM

# --- preflight --------------------------------------------------------------
# GROUP and JAR are read off a running consumer. With CONSUMERS>1 the previous
# run leaves $APP-1..$APP-N and no $APP, so fall back to the first of those.
SRC=$APP
if ! docker inspect "$SRC" >/dev/null 2>&1; then
    SRC=""
    for i in $(seq 1 5); do
        if docker inspect -f '{{.Id}}' "$APP-$i" >/dev/null 2>&1; then SRC="$APP-$i"; break; fi
    done
fi
[ -n "$SRC" ] || fail "no consumer container to read the group/jar from ($APP or $APP-1..5)"
GROUP=${GROUP:-$(docker inspect -f '{{range .Config.Cmd}}{{.}} {{end}}' "$SRC" \
    | tr ' ' '\n' | sed -n 's/^--spring\.kafka\.consumer\.group-id=//p' | head -1)}
if [ -z "$GROUP" ]; then
    # No group-id on the command line of the running container: it comes from
    # the application's own configuration. The group is verified against the
    # app's log and against the group description, so a wrong guess fails loudly.
    GROUP=$YAML_GROUP
fi
JAR=${NEW_JAR:-$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/app/app.jar"}}{{.Source}}{{end}}{{end}}' "$SRC")}
[ -n "$JAR" ] || fail "cannot determine the app.jar mount; pass NEW_JAR=..."
# NOTE: JAR is resolved by the Docker daemon, not by this container, so we must
# not test it with [ -f ]. An invalid path fails on `docker run` instead.

lag_sum() {
    # Failure must not look like "caught up": an unreachable broker, a missing
    # group or a partition without a committed offset all have to abort the run.
    local out
    out=$(docker exec "$NODE" $K/bin/kafka-consumer-groups.sh --bootstrap-server "$BROKERS" \
        --describe --group "$GROUP" 2>&1) || return 1
    printf '%s\n' "$out" | awk '
        $2 == "INCDATA" { rows++; if ($6 ~ /^[0-9]+$/) { s += $6; numeric++ } }
        END {
            # A partially non-numeric LAG column (a partition with no committed
            # offset) must also abort: summing only the numeric rows would
            # understate the backlog and pass the "caught up" gate.
            if (rows == 0 || numeric != rows) exit 3
            print s + 0
        }'
}

total_written() {
    # Sum of every instance's own counter: TotalSetCounter lives in the JVM, so
    # one consumer's "共计写入" knows nothing about the other's writes.
    # Same window as the rest of the measurement: the current JVM run only.
    # --tail would return the previous run's counter after `docker start` and
    # fabricate an instant "stable" drain.
    local w a sum=0
    while read -r a; do
        w=$(docker logs --since "$tstart" "$a" 2>&1 \
            | sed -n 's/.*共计写入：\([0-9]*\)条数据.*/\1/p' | tail -1)
        sum=$(( sum + ${w:-0} ))
    done < <(apps)
    printf '%s\n' "$sum"
}

group_hosts() {
    # One consumer JVM == one container IP. Counting HOSTs is therefore the only
    # way to tell "two instances joined" from "one instance with more threads"
    # (four threads per JVM also hold four different client ids).
    local out
    out=$(docker exec "$NODE" $K/bin/kafka-consumer-groups.sh --bootstrap-server "$BROKERS" \
        --describe --group "$GROUP" --members 2>&1) || return 1
    printf '%s\n' "$out" | awk '$3 ~ /^\/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print $3 }' | sort -u | wc -l
}

log_has() { # $1 container, $2 pattern
    # Match against a file, never against a pipe: `docker logs | grep -q` can
    # kill the writer with SIGPIPE, and under `set -o pipefail` that turns a
    # successful match into a non-zero pipeline status -- the assertion then
    # fails on a run that actually succeeded (measured: it broke once the log
    # grew past a few hundred KB).
    local f rc
    f=$(mktemp)
    docker logs "$1" > "$f" 2>&1 || true
    grep -q -F -- "$2" "$f"
    rc=$?
    rm -f "$f"
    return $rc
}

start_consumers() {
    local a app_args
    # CONFIG_FROM_YAML=1: the business configuration (oms.*, spring.kafka.*,
    # commitdata.*, server.port) comes from the application's own
    # application.yaml inside the jar -- no configuration on the command line.
    #
    # The two Nacos switches stay on the command line on purpose: the Nacos
    # client is created during the BOOTSTRAP phase, where only bootstrap.yml
    # and command line arguments are visible. Setting
    # spring.cloud.nacos.config.enabled=false in application.yml is too late --
    # the client is already trying to reach node1:18848 (measured: 12s of
    # grpc timeouts before the app continued).
    if [ "$CONFIG_FROM_YAML" = "1" ]; then
        app_args="--spring.cloud.nacos.config.enabled=false \
              --spring.cloud.nacos.discovery.enabled=false"
    else
        app_args="--spring.cloud.nacos.config.enabled=false \
              --spring.cloud.nacos.discovery.enabled=false \
              --spring.kafka.bootstrap-servers=$BROKERS \
              --spring.kafka.consumer.group-id=$GROUP \
              --spring.kafka.consumer.auto-offset-reset=earliest \
              --spring.kafka.listener.type=batch --spring.kafka.listener.concurrency=$CONC \
              --oms.redisMode=cluster \
              --oms.clusters[0]=172.21.0.2:6379 --oms.clusters[1]=172.21.0.2:6380 --oms.clusters[2]=172.21.0.3:6382 \
              --oms.password=$CLUSTER_PW --oms.database=0 --oms.timeout=5000 \
              --commitdata.inclusions.object-type.31=DPSPoint \
              --commitdata.inclusions.object-type.33=MVPoint \
              --server.port=8092"
    fi
    # Remove every name this script could have created, plus the historic one,
    # so a leftover 2-consumer run cannot silently keep consuming.
    for a in "$APP" "$APP-1" "$APP-2" "$APP-3" "$APP-4" "$APP-5"; do
        docker rm -f "$a" >/dev/null 2>&1 || true
    done
    while read -r a; do
        docker run -d --name "$a" --network "$NET" --entrypoint bash \
            -v "$JAR:/app/app.jar:ro" "$BASE_IMAGE" \
            -c "exec /opt/software/jdk8u292-b10/bin/java -Dfile.encoding=UTF-8 -Xms256m -Xmx512m \
                  -jar /app/app.jar $app_args" >/dev/null || fail "docker run failed for $a"
    done < <(apps)
    while read -r a; do
        for _ in $(seq 1 180); do
            log_has "$a" 'Redis mode detected: CLUSTER' && break
            [ "$(docker inspect -f '{{.State.Status}}' "$a")" = "running" ] \
                || fail "consumer $a exited during startup; see: docker logs $a"
            sleep 2
        done
        log_has "$a" 'Redis mode detected: CLUSTER' \
            || fail "consumer $a did not report CLUSTER mode within 360s"
        # The settings must be the ones the run asked for, no matter where they
        # came from: a yaml that silently failed to load would leave the app on
        # its defaults (standalone Redis, no Kafka group) and the measurement
        # would still "pass" while measuring nothing.
        log_has "$a" "Using Redis Cluster with nodes: $REDIS_NODES" \
            || fail "$a did not start with the expected Redis cluster nodes: $REDIS_NODES"
        # Same for the consumer group: the Kafka client logs it once it starts.
        for _ in $(seq 1 60); do
            log_has "$a" "groupId=$GROUP" && break
            sleep 2
        done
        log_has "$a" "groupId=$GROUP" \
            || fail "$a did not join the expected consumer group: $GROUP"
    done < <(apps)
}

stop_consumers() {
    local a rc=0
    while read -r a; do docker stop "$a" >/dev/null || rc=1; done < <(apps)
    return $rc
}

start_stopped_consumers() {
    local a rc=0
    while read -r a; do docker start "$a" >/dev/null || rc=1; done < <(apps)
    return $rc
}

produce_key() { # $1 partition-key, $2 count, $3 first obid
    awk -v n="$2" -v b="$3" -v k="$1" 'BEGIN{
        ts=1793095000000+b;
        for(i=0;i<n;i++) printf "%s:%d;Value,1,%d.20,%d\n", k, b+i, 100+(i%900), ts+i
    }' | docker exec -i "$NODE" $K/bin/kafka-console-producer.sh --bootstrap-server "$BROKERS" \
          --topic INCDATA --property parse.key=true --property key.separator=: \
          --producer-property acks=all --producer-property linger.ms=50 \
          --producer-property batch.size=262144 \
          --producer-property enable.idempotence=true \
          --producer-property max.in.flight.requests.per.connection=5 >/dev/null 2>&1
}

topic_messages() { # total messages in INCDATA, from the log-end offsets
    docker exec "$NODE" $K/bin/kafka-run-class.sh kafka.tools.GetOffsetShell \
        --broker-list "$BROKERS" --topic INCDATA --time -1 2>/dev/null \
        | awk -F: '/^INCDATA:/ { s += $3 } END { print s + 0 }'
}

masters() { # host:port, one per line
    docker exec "$NODE" $REDIS_CLI -p 6379 -a "$CLUSTER_PW" --no-auth-warning cluster nodes 2>/dev/null \
        | awk '$3 ~ /master/ {split($2,a,"@"); print a[1]}'
}

hset_calls() { # $1 host:port -- the app writes hash data via HMSET (putAll)
    # A read failure must not degrade to 0: a 0 baseline would let delta_sum
    # accumulate a master's whole lifetime and pass the >= N check by accident.
    local out
    out=$(docker exec "$NODE" $REDIS_CLI -h "${1%%:*}" -p "${1##*:}" -a "$CLUSTER_PW" --no-auth-warning \
        info commandstats) || return 1
    printf '%s\n' "$out" \
        | sed -n 's/^cmdstat_\(hset\|hmset\):calls=\([0-9]*\).*/\2/p' \
        | awk '{s+=$1} END{print s+0}'
}

verify_sample() { # $1 partition base, $2 index
    local base=$1 idx=$2
    local obid=$(( base + idx ))
    local value=$(( 100 + (idx % 900) ))
    local ts=$(( 1793095000000 + base + idx ))
    local expected="\"$value.20,$ts,1\""
    local got
    got=$(docker exec "$NODE" $REDIS_CLI -c -p 6379 -a "$CLUSTER_PW" --no-auth-warning \
              hget "real_data:11:$obid" Value 2>/dev/null)
    [ "$got" = "$expected" ] || fail "value mismatch obid=$obid got=[$got] expected=[$expected]"
}

# --- wait until the group is caught up --------------------------------------
info "group=$GROUP consumers=$CONSUMERS conc=$CONC n=$N jar=$JAR"
start_consumers
info "waiting for the group to reach lag 0 (refusing to measure a backlog)"
for _ in $(seq 1 120); do
    lag=$(lag_sum) || fail "cannot read consumer-group lag for $GROUP"
    [ "$lag" = "0" ] && break
    sleep 2
done
lag=$(lag_sum) || fail "cannot read consumer-group lag for $GROUP"
[ "$lag" = "0" ] || fail "group not caught up (lag=$lag); refusing to measure"

# --- stop, fill, start, drain ----------------------------------------------
stop_consumers || fail "could not stop the consumers"
STOPPED_CONSUMER=1

# B0 is 47244640256 == 11 << 32: the app keys RT data as real_data:11:<obid>,
# and the jitter (epoch % 3000) * 1e6 stays below 2^32 (2999e6 < 4295e6), so
# every obid of a run is still inside the 11<<32 block while consecutive runs
# get disjoint ranges -- a stale key from the previous run can never be read
# back and mistaken for a fresh write.
B0=$(( 47244640256 + ($(date +%s) % 3000) * 1000000 ))
# +500000 keeps p0 and p1 disjoint with a hole far larger than one run's N
# (default 200000); the two ranges are what the sample checks assert on.
B1=$(( B0 + 500000 ))
HALF=$(( N / 2 ))
REST=$(( N - HALF ))

declare -A BEFORE=()
while read -r hp; do
    [ -n "$hp" ] || continue
    v=$(hset_calls "$hp") || fail "cannot read commandstats from master $hp"
    BEFORE[$hp]=$v
done < <(masters)
[ "${#BEFORE[@]}" -ge 3 ] || fail "expected 3 masters, got ${#BEFORE[@]}"

info "publishing $HALF + $REST records (p0 base=$B0, p1 base=$B1)"
msgs_before=$(topic_messages) || fail "cannot read the INCDATA log-end offsets before publishing"
t0=$(date +%s)
produce_key a "$HALF" "$B0" & P1=$!
produce_key d "$REST" "$B1" & P2=$!
wait "$P1" || fail "publish to partition 0 failed"
wait "$P2" || fail "publish to partition 1 failed"
t1=$(date +%s)
# Count what actually landed in the topic, not what the producer was asked to
# send: a producer that times out and retries (acks=all without idempotence)
# delivers duplicates, and the consumer would then write more records than the
# run published -- measured once (212,763 instead of 200,000).
msgs_after=$(topic_messages) || fail "cannot read the INCDATA log-end offsets after publishing"
published=$(( msgs_after - msgs_before ))
[ "$published" -eq "$N" ] \
    || fail "the topic received $published messages, expected $N (duplicates or missing records)"

tstart=$(date +%s)
start_stopped_consumers || fail "could not start the consumers"
STOPPED_CONSUMER=0
prev=-1; stable=0; waited=0
while [ "$waited" -lt 900 ]; do
    sleep 1; waited=$((waited+1))
    w=$(total_written); w=${w:-0}
    if [ "$w" = "$prev" ] && [ "$w" -gt 0 ] && [ "$waited" -gt 5 ]; then
        stable=$((stable+1)); [ "$stable" -ge 5 ] && break
    else
        stable=0
    fi
    prev=$w
    [ $(( waited % 10 )) -eq 0 ] && info "draining: waited=${waited}s written=${w} (idle ${stable}s)"
done
tend=$(date +%s)

LOG=/tmp/bench-consumer-write.log
per_written=""
written=0
while read -r _a; do
    docker logs --timestamps --since "$tstart" "$_a" > "$LOG.$_a" 2>&1
    [ -s "$LOG.$_a" ] || fail "consumer log for $_a is empty; nothing to measure"
    _w=$(sed -n 's/.*共计写入：\([0-9]*\)条数据.*/\1/p' "$LOG.$_a" | tail -1); _w=${_w:-0}
    written=$(( written + _w ))
    per_written="$per_written $_a=$_w"
done < <(apps)

lag=""
for _ in $(seq 1 10); do
    # A batch listener commits after the listener returns, so lag can trail the
    # final log line by a second or two.
    lag=$(lag_sum) || fail "cannot read consumer-group lag for $GROUP"
    [ "$lag" = "0" ] && break
    sleep 1
done
# Without a numeric label there is no evidence of zero failures -- the sum would
# be 0 because nothing matched, not because nothing failed. Every instance has to
# emit it: a silent instance would otherwise contribute an invisible 0.
failcnt=0
while read -r _a; do
    grep -q '每秒写入失败点数：[0-9]' "$LOG.$_a" \
        || fail "failure-counter label/value is missing from $_a's log; cannot claim 0 failures"
    _f=$(sed -n 's/.*每秒写入失败点数：\([0-9]*\).*/\1/p' "$LOG.$_a" | awk '{s+=$1} END{print s+0}')
    failcnt=$(( failcnt + _f ))
done < <(apps)
# Per-second rate: bucket every instance's samples by their (docker) timestamp
# second and sum the buckets, so "active seconds" and "peak" describe the whole
# pipeline rather than one JVM's share.
series() {
    local a
    for a in $(apps); do cat "$LOG.$a"; done \
        | sed -n 's/^\([0-9-]*T[0-9:]*\)\.[0-9]*Z .*每秒已处理实时数据变化数量：\([0-9]*\).*/\1 \2/p' \
        | awk '{ s[$1] += $2 } END { for (k in s) print s[k] }'
}
psum=$(series | awk '{s+=$1} END{print s+0}')
active=$(series | awk '$1>0{c++} END{print c+0}')
peak=$(series | sort -n | tail -1)
mean=$(( psum / (active > 0 ? active : 1) ))
[ "$active" -gt 0 ] || fail "no per-second throughput samples matched in the logs; log format changed?"

delta_sum=0; delta_report=""
while read -r hp; do
    [ -n "$hp" ] || continue
    [ -n "${BEFORE[$hp]:-}" ] || fail "no baseline commandstats for $hp"
    after=$(hset_calls "$hp") || fail "cannot read commandstats from master $hp"
    d=$(( after - BEFORE[$hp] ))
    delta_sum=$(( delta_sum + d ))
    delta_report="$delta_report $hp=$d"
    [ "$d" -gt 0 ] || fail "no HSET/HMSET reached master $hp (delta=$d)"
done < <(masters)
# One hash command per record is the expected cost; >>2 means retries or extra
# writes, and would make the rate look better than the work actually done.
delta_per_record=$(awk -v d="$delta_sum" -v n="$N" 'BEGIN{printf "%.2f", d / n}')

# --- assertions -------------------------------------------------------------
[ "$written" -eq "$N" ] || fail "conservation: written=$written expected=$N ($per_written )"
[ "$failcnt" = "0" ] || fail "write failures: $failcnt"
[ "$lag" = "0" ] || fail "consumer lag after drain: $lag"
[ "$delta_sum" -ge "$N" ] || fail "server-side HSET/HMSET delta $delta_sum < $N"
[ "$delta_sum" -le "$(( N * 2 ))" ] || fail "server-side HSET/HMSET delta $delta_sum > 2 per record (N=$N); retrying or writing extra?"
[ "$mean" -ge "$MIN_MEAN" ] || fail "mean $mean/s is below MIN_MEAN=$MIN_MEAN"
# Two instances must genuinely share the work: an instance that never got an
# INCDATA partition (or died) would leave its counter at 0 and make a
# "2 consumers" run an expensive way to measure one consumer.
if [ "$CONSUMERS" -gt 1 ]; then
    while read -r _a; do
        _w=$(printf '%s\n' $per_written | sed -n "s/^$_a=\([0-9]*\)$/\1/p")
        [ "${_w:-0}" -gt 0 ] || fail "$_a wrote nothing ($per_written ); the two instances did not share INCDATA"
    done < <(apps)
    # A consumer that was killed or restarted lingers in the group until its
    # session times out, so a single sample can see 3 hosts for a few seconds.
    # Poll until it settles; failing at the first sample would reject a good run.
    hosts=""
    for _ in $(seq 1 15); do
        hosts=$(group_hosts) || fail "cannot read consumer-group members for $GROUP"
        [ "$hosts" = "$CONSUMERS" ] && break
        sleep 2
    done
    [ "$hosts" = "$CONSUMERS" ] \
        || fail "expected $CONSUMERS consumer containers in group $GROUP, saw $hosts distinct hosts"
fi

# The eight indices below (both ends plus two mid-points per partition) were
# checked against the live cluster: for every jitter value sampled they hashed
# (CRC16 over real_data:11:<obid>) into all three masters, so a single dead
# node cannot hide behind these checks.
verify_sample "$B0" 0
verify_sample "$B0" 1
verify_sample "$B0" $((HALF / 2))
verify_sample "$B0" $((HALF - 1))
verify_sample "$B1" 0
verify_sample "$B1" 1
verify_sample "$B1" $((REST / 2))
verify_sample "$B1" $((REST - 1))

app_status=""
while read -r _a; do
    _s=$(docker inspect -f '{{.State.Status}}' "$_a" 2>/dev/null)
    app_status="${app_status:+$app_status,}$_a=$_s"
    [ "$_s" = "running" ] \
        || echo "WARNING: consumer $_a is '$_s' at the end of the run (expected running)" >&2
done < <(apps)

echo
echo "===== RESULT: Kafka -> RTListener -> Redis Cluster ====="
echo "group             : $GROUP"
echo "consumers         : $CONSUMERS"
echo "concurrency       : $CONC"
echo "jar               : $JAR"
echo "consumer_state    : $app_status"
echo "sent              : $N"
echo "publish_sec       : $(( t1 - t0 ))"
echo "wall_sec_incl_startup : $(( tend - tstart ))"
echo "written           : $written ($per_written )"
echo "lag               : $lag"
echo "write_failures    : $failcnt"
echo "active_seconds    : $active"
echo "mean_active_per_s : $mean"
echo "peak_per_s        : ${peak:-0}"
echo "hset_delta        : $delta_sum ($delta_report )"
echo "delta_per_record  : $delta_per_record"
echo "samples           : 8/8 matched"
echo "BENCH PASSED"

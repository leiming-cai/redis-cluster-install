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
#   NEW_JAR   optional; recreate the consumer against this jar (daemon-visible path)
#   N         records to produce (default 200000)
#   CONC      listener concurrency (default 1)
#   GROUP     consumer group; defaults to the running consumer's group id
#   MIN_MEAN  lowest mean_active_per_s to accept (default 0); a slow run still
#             drains to completion, then fails, so the gate cannot hide a stall
#
# NOTE: this harness DESTROYS and RECREATES the consumer container ($APP) from
# the flag list below. Heap (Xms/Xmx), the port and every --flag come from this
# script, not from whatever the container ran before -- point it at a throwaway
# consumer, never at production.
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
MIN_MEAN=${MIN_MEAN:-0}

fail() { echo "FAIL: $*" >&2; exit 1; }
info() { echo "[bench] $*"; }

# Bad inputs must fail here, not after a 200k-record publish.
[[ "$N" =~ ^[0-9]+$ ]] || fail "N must match ^[0-9]+$, got [$N]"
[[ "$CONC" =~ ^[0-9]+$ ]] || fail "CONC must match ^[0-9]+$, got [$CONC]"
[[ "$MIN_MEAN" =~ ^[0-9]+$ ]] || fail "MIN_MEAN must match ^[0-9]+$, got [$MIN_MEAN]"
# N >= 4 keeps both partitions non-empty and the eight sample indices distinct.
[ "$N" -ge 4 ] || fail "N must be >= 4, got $N"

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
        echo "[bench] restarting $APP (this script left it stopped)" >&2
        docker start "$APP" >/dev/null 2>&1 \
            || echo "[bench] WARNING: could not restart $APP; start it by hand" >&2
        STOPPED_CONSUMER=0
    fi
    if [ "$rc" -ne 0 ] && [ -s "${LOG:-}" ]; then
        echo "----- last 20 lines of $LOG -----" >&2
        tail -20 "$LOG" >&2
        echo "----- per-second series -----" >&2
        sed -n 's/.*每秒已处理实时数据变化数量：\([0-9]*\).*/\1/p' "$LOG" | tr '\n' ' ' >&2
        echo >&2
    fi
}
trap cleanup EXIT
# A non-interactive bash does not run the EXIT trap on SIGTERM (that is what
# `docker stop` sends), so turn TERM/INT into a normal exit and let EXIT run.
trap 'exit 130' INT
trap 'exit 143' TERM

# --- preflight --------------------------------------------------------------
docker inspect "$APP" >/dev/null 2>&1 || fail "consumer container $APP does not exist"
GROUP=${GROUP:-$(docker inspect -f '{{range .Config.Cmd}}{{.}} {{end}}' "$APP" \
    | tr ' ' '\n' | sed -n 's/^--spring\.kafka\.consumer\.group-id=//p' | head -1)}
[ -n "$GROUP" ] || fail "cannot determine the consumer group; pass GROUP=..."
JAR=${NEW_JAR:-$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/app/app.jar"}}{{.Source}}{{end}}{{end}}' "$APP")}
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
    # Same window as the rest of the measurement: the current JVM run only.
    # --tail would return the previous run's counter after `docker start` and
    # fabricate an instant "stable" drain.
    docker logs --since "$tstart" "$APP" 2>&1 \
        | sed -n 's/.*共计写入：\([0-9]*\)条数据.*/\1/p' | tail -1
}

start_consumer() {
    docker rm -f "$APP" >/dev/null 2>&1 || true
    docker run -d --name "$APP" --network "$NET" --entrypoint bash \
        -v "$JAR:/app/app.jar:ro" "$BASE_IMAGE" \
        -c "exec /opt/software/jdk8u292-b10/bin/java -Dfile.encoding=UTF-8 -Xms256m -Xmx512m \
              -jar /app/app.jar \
              --spring.cloud.nacos.config.enabled=false \
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
              --server.port=8092" >/dev/null || fail "docker run failed"
    for _ in $(seq 1 120); do
        docker logs "$APP" 2>&1 | grep -q 'Redis mode detected: CLUSTER' && return 0
        [ "$(docker inspect -f '{{.State.Status}}' "$APP")" = "running" ] \
            || fail "consumer exited during startup; see: docker logs $APP"
        sleep 2
    done
    fail "consumer did not report CLUSTER mode within 240s"
}

produce_key() { # $1 partition-key, $2 count, $3 first obid
    awk -v n="$2" -v b="$3" -v k="$1" 'BEGIN{
        ts=1793095000000+b;
        for(i=0;i<n;i++) printf "%s:%d;Value,1,%d.20,%d\n", k, b+i, 100+(i%900), ts+i
    }' | docker exec -i "$NODE" $K/bin/kafka-console-producer.sh --bootstrap-server "$BROKERS" \
          --topic INCDATA --property parse.key=true --property key.separator=: \
          --producer-property acks=all --producer-property linger.ms=50 \
          --producer-property batch.size=262144 >/dev/null 2>&1
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
info "group=$GROUP conc=$CONC n=$N jar=$JAR"
start_consumer
info "waiting for the group to reach lag 0 (refusing to measure a backlog)"
for _ in $(seq 1 120); do
    lag=$(lag_sum) || fail "cannot read consumer-group lag for $GROUP"
    [ "$lag" = "0" ] && break
    sleep 2
done
lag=$(lag_sum) || fail "cannot read consumer-group lag for $GROUP"
[ "$lag" = "0" ] || fail "group not caught up (lag=$lag); refusing to measure"

# --- stop, fill, start, drain ----------------------------------------------
docker stop "$APP" >/dev/null || fail "could not stop the consumer"
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
t0=$(date +%s)
produce_key a "$HALF" "$B0" & P1=$!
produce_key d "$REST" "$B1" & P2=$!
wait "$P1" || fail "publish to partition 0 failed"
wait "$P2" || fail "publish to partition 1 failed"
t1=$(date +%s)

tstart=$(date +%s)
docker start "$APP" >/dev/null || fail "could not start the consumer"
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
docker logs --since "$tstart" "$APP" > "$LOG" 2>&1
[ -s "$LOG" ] || fail "consumer log is empty; nothing to measure"

written=$(sed -n 's/.*共计写入：\([0-9]*\)条数据.*/\1/p' "$LOG" | tail -1); written=${written:-0}
lag=""
for _ in $(seq 1 10); do
    # A batch listener commits after the listener returns, so lag can trail the
    # final log line by a second or two.
    lag=$(lag_sum) || fail "cannot read consumer-group lag for $GROUP"
    [ "$lag" = "0" ] && break
    sleep 1
done
# Without a numeric label there is no evidence of zero failures -- the sum would
# be 0 because nothing matched, not because nothing failed.
grep -q '每秒写入失败点数：[0-9]' "$LOG" || fail "failure-counter label/value is missing from the log; cannot claim 0 failures"
failcnt=$(sed -n 's/.*每秒写入失败点数：\([0-9]*\).*/\1/p' "$LOG" | awk '{s+=$1} END{print s+0}')
psum=$(sed -n 's/.*每秒已处理实时数据变化数量：\([0-9]*\).*/\1/p' "$LOG" | awk '{s+=$1} END{print s+0}')
active=$(sed -n 's/.*每秒已处理实时数据变化数量：\([0-9]*\).*/\1/p' "$LOG" | awk '$1>0{c++} END{print c+0}')
peak=$(sed -n 's/.*每秒已处理实时数据变化数量：\([0-9]*\).*/\1/p' "$LOG" | sort -n | tail -1)
mean=$(( psum / (active > 0 ? active : 1) ))
[ "$active" -gt 0 ] || fail "no per-second throughput samples matched in $LOG; log format changed?"

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
[ "$written" -eq "$N" ] || fail "conservation: written=$written expected=$N"
[ "$failcnt" = "0" ] || fail "write failures: $failcnt"
[ "$lag" = "0" ] || fail "consumer lag after drain: $lag"
[ "$delta_sum" -ge "$N" ] || fail "server-side HSET/HMSET delta $delta_sum < $N"
[ "$delta_sum" -le "$(( N * 2 ))" ] || fail "server-side HSET/HMSET delta $delta_sum > 2 per record (N=$N); retrying or writing extra?"
[ "$mean" -ge "$MIN_MEAN" ] || fail "mean $mean/s is below MIN_MEAN=$MIN_MEAN"

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

app_status=$(docker inspect -f '{{.State.Status}}' "$APP" 2>/dev/null)
[ "$app_status" = "running" ] \
    || echo "WARNING: consumer $APP is '$app_status' at the end of the run (expected running)" >&2

echo
echo "===== RESULT: Kafka -> RTListener -> Redis Cluster ====="
echo "group             : $GROUP"
echo "concurrency       : $CONC"
echo "jar               : $JAR"
echo "consumer_state    : $app_status"
echo "sent              : $N"
echo "publish_sec       : $(( t1 - t0 ))"
echo "wall_sec_incl_startup : $(( tend - tstart ))"
echo "written           : $written"
echo "lag               : $lag"
echo "write_failures    : $failcnt"
echo "active_seconds    : $active"
echo "mean_active_per_s : $mean"
echo "peak_per_s        : ${peak:-0}"
echo "hset_delta        : $delta_sum ($delta_report )"
echo "delta_per_record  : $delta_per_record"
echo "samples           : 8/8 matched"
echo "BENCH PASSED"

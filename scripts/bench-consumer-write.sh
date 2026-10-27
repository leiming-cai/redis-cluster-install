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

fail() { echo "FAIL: $*" >&2; exit 1; }
info() { echo "[bench] $*"; }

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
    docker exec "$NODE" $K/bin/kafka-consumer-groups.sh --bootstrap-server "$BROKERS" \
        --describe --group "$GROUP" 2>/dev/null | awk '$2=="INCDATA"{s+=$6} END{print s+0}'
}

total_written() {
    docker logs --tail 60 "$APP" 2>&1 | sed -n 's/.*共计写入：\([0-9]*\)条数据.*/\1/p' | tail -1
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
    docker exec "$NODE" $REDIS_CLI -h "${1%%:*}" -p "${1##*:}" -a "$CLUSTER_PW" --no-auth-warning \
        info commandstats 2>/dev/null \
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
    [ "$(lag_sum)" = "0" ] && break
    sleep 2
done
[ "$(lag_sum)" = "0" ] || fail "group not caught up (lag=$(lag_sum)); refusing to measure"

# --- stop, fill, start, drain ----------------------------------------------
docker stop "$APP" >/dev/null || fail "could not stop the consumer"

B0=$(( 47244640256 + ($(date +%s) % 3000) * 1000000 ))
B1=$(( B0 + 500000 ))
HALF=$(( N / 2 ))
REST=$(( N - HALF ))

declare -A BEFORE=()
while read -r hp; do
    [ -n "$hp" ] || continue
    BEFORE[$hp]=$(hset_calls "$hp"); BEFORE[$hp]=${BEFORE[$hp]:-0}
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
done
tend=$(date +%s)

LOG=/tmp/bench-consumer-write.log
docker logs --since "$tstart" "$APP" > "$LOG" 2>&1

written=$(total_written); written=${written:-0}
lag=$(lag_sum)
failcnt=$(sed -n 's/.*每秒写入失败点数：\([0-9]*\).*/\1/p' "$LOG" | awk '{s+=$1} END{print s+0}')
psum=$(sed -n 's/.*每秒已处理实时数据变化数量：\([0-9]*\).*/\1/p' "$LOG" | awk '{s+=$1} END{print s+0}')
active=$(sed -n 's/.*每秒已处理实时数据变化数量：\([0-9]*\).*/\1/p' "$LOG" | awk '$1>0{c++} END{print c+0}')
peak=$(sed -n 's/.*每秒已处理实时数据变化数量：\([0-9]*\).*/\1/p' "$LOG" | sort -n | tail -1)
mean=$(( psum / (active > 0 ? active : 1) ))

delta_sum=0; delta_report=""
while read -r hp; do
    [ -n "$hp" ] || continue
    after=$(hset_calls "$hp"); after=${after:-0}
    d=$(( after - ${BEFORE[$hp]:-0} ))
    delta_sum=$(( delta_sum + d ))
    delta_report="$delta_report $hp=$d"
    [ "$d" -gt 0 ] || fail "no HSET/HMSET reached master $hp (delta=$d)"
done < <(masters)

# --- assertions -------------------------------------------------------------
[ "$written" = "$N" ] || fail "conservation: written=$written expected=$N"
[ "$failcnt" = "0" ] || fail "write failures: $failcnt"
[ "$lag" = "0" ] || fail "consumer lag after drain: $lag"
[ "$delta_sum" -ge "$N" ] || fail "server-side HSET/HMSET delta $delta_sum < $N"

verify_sample "$B0" 0
verify_sample "$B0" 1
verify_sample "$B0" $((HALF / 2))
verify_sample "$B0" $((HALF - 1))
verify_sample "$B1" 0
verify_sample "$B1" 1
verify_sample "$B1" $((REST / 2))
verify_sample "$B1" $((REST - 1))

echo
echo "===== RESULT: Kafka -> RTListener -> Redis Cluster ====="
echo "group             : $GROUP"
echo "concurrency       : $CONC"
echo "jar               : $JAR"
echo "sent              : $N"
echo "publish_sec       : $(( t1 - t0 ))"
echo "wall_sec          : $(( tend - tstart ))"
echo "written           : $written"
echo "lag               : $lag"
echo "write_failures    : $failcnt"
echo "active_seconds    : $active"
echo "mean_active_per_s : $mean"
echo "peak_per_s        : ${peak:-0}"
echo "hset_delta        : $delta_sum ($delta_report )"
echo "samples           : 8/8 matched"
echo "BENCH PASSED"

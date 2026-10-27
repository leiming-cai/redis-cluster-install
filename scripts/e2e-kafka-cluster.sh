#!/usr/bin/env bash
# e2e-kafka-cluster.sh — 2-voter ZooKeeper + 2-broker Kafka on the CPS node
# containers (rc-cpsweb-node-a / rc-cpsweb-node-b), for the E2E environment.
#
# WHY THIS IS NOT "HIGH AVAILABILITY"
#   The ensemble has TWO voters, so quorum is 2: losing either node stops all
#   writes to Kafka. That is a deliberate choice for the E2E environment (it is
#   the smallest thing that is genuinely a cluster). A broker-failure drill is
#   impossible under this topology — not skipped, impossible.
#
# WHAT IT DOES
#   1. stops the single-node ZooKeeper/Kafka that the cpsweb image starts on
#      boot (STOP_LEGACY=0 to keep it)
#   2. writes zoo.cfg + myid and /etc/kafka/server.properties on both nodes,
#      using the IPs read from docker at run time (never hard-coded)
#   3. installs systemd units and starts ZooKeeper, then Kafka
#   4. creates the four topics with replication factor 2
#   5. asserts the things that actually matter (see ASSERTS below)
#
# ASSERTS — every one of these has been observed to be wrong at least once:
#   A1 both ZooKeeper nodes report a mode (leader + follower)
#   A2 both brokers are registered in ZooKeeper
#   A3 the Kafka JVM really has a 256 MB heap (not the 980 MB JVM default:
#      systemd silently drops the second word of an unquoted Environment= value)
#   A4 the ZooKeeper JVM really has a 256 MB heap (zkEnv.sh defaults to 1000 MB)
#   A5 every topic has replication factor 2 and 2 replicas in ISR
#   A6 no under-replicated and no unavailable partitions
#   A7 a smoke record is produced and read back
#
# ENVIRONMENT
#   NODE_A / NODE_B        container names (default rc-cpsweb-node-a/-b)
#   KAFKA_CONTAINER        legacy single-node cluster to stop (default cpsweb)
#   STOP_LEGACY            default 1
#   WITH_CONSUMER          default 0; 1 = repoint rc-cpsweb-app at the cluster
#   CONSUMER_GROUP         group id to use when WITH_CONSUMER=1
#   APP_JAR                consumer jar (needed only when WITH_CONSUMER=1)
#
# REQUIREMENTS: docker; the two node containers must already exist (create them
# with scripts/e2e-cpsweb-nodes.sh KEEP=1).
#
# EXIT CODE: 0 when every assertion passed, 1 on the first failure.

set -uo pipefail

NODE_A="${NODE_A:-rc-cpsweb-node-a}"
NODE_B="${NODE_B:-rc-cpsweb-node-b}"
KAFKA_CONTAINER="${KAFKA_CONTAINER:-cpsweb}"
STOP_LEGACY="${STOP_LEGACY:-1}"
WITH_CONSUMER="${WITH_CONSUMER:-0}"

ZK_HOME=/opt/software/apache-zookeeper-3.9.0-bin
KAFKA_HOME=/opt/software/kafka_2.13-2.8.0
JDK=/opt/software/jdk8u292-b10
KAFKA_HEAP=268435456   # 256 MB, in bytes, as reported by jinfo
ZK_HEAP=268435456

BASE_IMAGE="${CPSWEB_BASE_IMAGE:-cpsweb-env:1.0}"
NET="${NET:-rc-cpsweb-net}"
APP_C="${APP_C:-rc-cpsweb-app}"
CLUSTER_PW="${CLUSTER_PW:-CpsE2eClusterPw}"

TOPICS="INCDATA COMMITDATA COMMITDATAINCRE QUERYRESPONSE"
PARTITIONS=2
REPLICATION=2

log()  { printf '\n=== %s ===\n' "$*"; }
info() { printf '  [INFO] %s\n' "$*"; }
ok()   { printf '  [ OK ] %s\n' "$*"; }
fail() { printf '\nFAIL: %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null || fail "docker not found"

for c in "$NODE_A" "$NODE_B"; do
    docker inspect "$c" >/dev/null 2>&1 || fail "container '$c' does not exist.
       Create the node containers first: KEEP=1 bash scripts/e2e-cpsweb-nodes.sh"
done

node_ip() {
    docker inspect -f "{{with index .NetworkSettings.Networks \"$NET\"}}{{.IPAddress}}{{end}}" "$1"
}

A_IP="$(node_ip "$NODE_A")"
B_IP="$(node_ip "$NODE_B")"
[ -n "$A_IP" ] || fail "$NODE_A is not attached to network $NET"
[ -n "$B_IP" ] || fail "$NODE_B is not attached to network $NET"
[ "$A_IP" != "$B_IP" ] || fail "both nodes report the same IP ($A_IP)"
ok "node-a=$A_IP  node-b=$B_IP   (read from docker, not hard-coded)"

BROKERS="$A_IP:9092,$B_IP:9092"
ZK_CONNECT="$A_IP:2181,$B_IP:2181"

# ---------------------------------------------------------------------------
log "1/6 stop the legacy single-node ZooKeeper/Kafka on $KAFKA_CONTAINER"
# ---------------------------------------------------------------------------
if [ "$STOP_LEGACY" = "1" ] && docker inspect "$KAFKA_CONTAINER" >/dev/null 2>&1; then
    docker exec "$KAFKA_CONTAINER" "$KAFKA_HOME/bin/kafka-server-stop.sh" >/dev/null 2>&1 || true
    sleep 5
    docker exec "$KAFKA_CONTAINER" "$ZK_HOME/bin/zkServer.sh" stop >/dev/null 2>&1 || true
    sleep 3
    left="$(docker exec "$KAFKA_CONTAINER" sh -c 'ss -ltn 2>/dev/null | grep -cE ":2181|:9092"' 2>/dev/null)"
    [ "${left:-0}" = "0" ] || fail "$KAFKA_CONTAINER still listens on 2181/9092"
    ok "legacy cluster stopped"
    info "NOTE: $KAFKA_CONTAINER's entrypoint starts them again on container restart"
else
    info "STOP_LEGACY=$STOP_LEGACY — leaving $KAFKA_CONTAINER alone"
fi

# ---------------------------------------------------------------------------
log "2/6 write ZooKeeper + Kafka configuration"
# ---------------------------------------------------------------------------
zoo_cfg() {
    cat <<EOF
tickTime=2000
initLimit=10
syncLimit=5
dataDir=/var/lib/zookeeper
clientPort=2181
maxClientCnxns=200
admin.enableServer=false
4lw.commands.whitelist=srvr,ruok,stat,mntr
server.1=$A_IP:2888:3888
server.2=$B_IP:2888:3888
EOF
}

zoo_unit() {
    cat <<EOF
[Unit]
Description=ZooKeeper (CPS node, 2-voter ensemble)
After=network.target

[Service]
Type=simple
Environment=JAVA_HOME=$JDK
Environment=ZOO_LOG_DIR=/var/log/zookeeper
Environment=ZOO_LOG4J_PROP=INFO,ROLLINGFILE
Environment="SERVER_JVMFLAGS=-Xms256m -Xmx256m"
ExecStart=$ZK_HOME/bin/zkServer.sh start-foreground
Restart=always
RestartSec=5
LimitNOFILE=65536
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
}

kafka_props() { # kafka_props BROKER_ID MY_IP
    cat <<EOF
broker.id=$1
listeners=PLAINTEXT://0.0.0.0:9092
advertised.listeners=PLAINTEXT://$2:9092
num.network.threads=3
num.io.threads=8
socket.send.buffer.bytes=102400
socket.receive.buffer.bytes=102400
socket.request.max.bytes=104857600
log.dirs=/var/lib/kafka
num.partitions=$PARTITIONS
default.replication.factor=$REPLICATION
offsets.topic.replication.factor=$REPLICATION
transaction.state.log.replication.factor=$REPLICATION
transaction.state.log.min.isr=1
min.insync.replicas=1
num.recovery.threads.per.data.dir=1
log.retention.hours=168
log.segment.bytes=1073741824
log.retention.check.interval.ms=300000
zookeeper.connect=$ZK_CONNECT
zookeeper.connection.timeout.ms=18000
group.initial.rebalance.delay.ms=0
auto.create.topics.enable=true
delete.topic.enable=true
EOF
}

kafka_unit() {
    # KAFKA_HEAP_OPTS MUST be quoted: systemd treats an unquoted value with a
    # space as one assignment plus garbage, and silently keeps only "-Xms256m".
    # The JVM then falls back to its ergonomic default (1/4 of RAM ~= 980 MB).
    cat <<EOF
[Unit]
Description=Kafka broker (CPS node)
After=network.target zookeeper.service
Wants=zookeeper.service

[Service]
Type=simple
Environment=JAVA_HOME=$JDK
Environment="KAFKA_HEAP_OPTS=-Xms256m -Xmx256m"
Environment=LOG_DIR=/var/log/kafka
ExecStart=$KAFKA_HOME/bin/kafka-server-start.sh /etc/kafka/server.properties
Restart=always
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
}

put_file() { # put_file CONTAINER PATH CONTENT-STDIN
    docker exec -i "$1" sh -c "cat > '$2'" || fail "could not write $2 on $1"
}

for spec in "$NODE_A:1:1:$A_IP" "$NODE_B:2:2:$B_IP"; do
    IFS=: read -r c myid bid ip <<< "$spec"
    docker exec "$c" sh -c "install -d -m 0755 /var/lib/zookeeper /var/lib/kafka /var/log/kafka /var/log/zookeeper /etc/kafka" \
        || fail "could not create directories on $c"
    zoo_cfg   | put_file "$c" "$ZK_HOME/conf/zoo.cfg"
    printf '%s\n' "$myid" | put_file "$c" /var/lib/zookeeper/myid
    zoo_unit  | put_file "$c" /etc/systemd/system/zookeeper.service
    kafka_props "$bid" "$ip" | put_file "$c" /etc/kafka/server.properties
    kafka_unit | put_file "$c" /etc/systemd/system/kafka.service
    docker exec "$c" systemctl daemon-reload || fail "daemon-reload failed on $c"
    ok "$c configured (myid=$myid broker.id=$bid advertised=$ip:9092)"
done

# ---------------------------------------------------------------------------
log "3/6 start ZooKeeper and assert the ensemble"
# ---------------------------------------------------------------------------
# Restart rather than start: the config may have changed (IPs, myid).
for c in "$NODE_A" "$NODE_B"; do
    docker exec "$c" systemctl enable zookeeper >/dev/null 2>&1 || true
    docker exec "$c" systemctl restart zookeeper || fail "could not restart zookeeper on $c"
done

za=''; zb=''
for _ in $(seq 1 30); do
    za="$(docker exec "$NODE_A" "$ZK_HOME/bin/zkServer.sh" status 2>&1 | grep -o 'Mode: [a-z]*' || true)"
    zb="$(docker exec "$NODE_B" "$ZK_HOME/bin/zkServer.sh" status 2>&1 | grep -o 'Mode: [a-z]*' || true)"
    { [ -n "$za" ] && [ -n "$zb" ]; } && break
    sleep 2
done
# A1
[ -n "$za" ] || fail "A1: $NODE_A reports no ZooKeeper mode\n$(docker exec "$NODE_A" systemctl status zookeeper --no-pager -l 2>&1 | tail -15)"
[ -n "$zb" ] || fail "A1: $NODE_B reports no ZooKeeper mode"
case "$za$zb" in
    *leader*follower*|*follower*leader*) : ;;
    *) fail "A1: expected one leader and one follower, got node-a='$za' node-b='$zb'" ;;
esac
ok "A1 zookeeper: node-a=$za node-b=$zb"

# A4 — read the heap from the running JVM, not from the unit file
for c in "$NODE_A" "$NODE_B"; do
    pid="$(docker exec "$c" sh -c 'ps -ef | grep "[Q]uorumPeerMain" | awk "{print \$2}"' | head -1)"
    [ -n "$pid" ] || fail "A4: no ZooKeeper JVM on $c"
    heap="$(docker exec "$c" "$JDK/bin/jinfo" -flag MaxHeapSize "$pid" 2>/dev/null | sed 's/.*=//')"
    [ "$heap" = "$ZK_HEAP" ] || fail "A4: ZooKeeper on $c has MaxHeapSize=$heap, expected $ZK_HEAP"
done
ok "A4 zookeeper heap is 256 MB on both nodes"

# ---------------------------------------------------------------------------
log "4/6 start Kafka and assert both brokers register"
# ---------------------------------------------------------------------------
for c in "$NODE_A" "$NODE_B"; do
    docker exec "$c" systemctl enable kafka >/dev/null 2>&1 || true
    docker exec "$c" systemctl restart kafka || fail "could not restart kafka on $c"
done

ids=''
for _ in $(seq 1 40); do
    ids="$(docker exec "$NODE_A" "$KAFKA_HOME/bin/zookeeper-shell.sh" "$A_IP:2181" ls /brokers/ids 2>/dev/null | tail -1)"
    case "$ids" in
        *1*2*|*2*1*) break ;;
    esac
    sleep 3
done
# A2
case "$ids" in
    *1*2*|*2*1*) ok "A2 brokers registered: $ids" ;;
    *) fail "A2: brokers did not both register (got '$ids')\n$(docker exec "$NODE_A" systemctl status kafka --no-pager -l 2>&1 | tail -20)" ;;
esac

# A3 — the systemd quoting trap
for c in "$NODE_A" "$NODE_B"; do
    pid="$(docker exec "$c" sh -c 'ps -ef | grep "[k]afka.Kafka" | awk "{print \$2}"' | head -1)"
    [ -n "$pid" ] || fail "A3: no Kafka JVM on $c"
    heap="$(docker exec "$c" "$JDK/bin/jinfo" -flag MaxHeapSize "$pid" 2>/dev/null | sed 's/.*=//')"
    [ "$heap" = "$KAFKA_HEAP" ] || fail "A3: Kafka on $c has MaxHeapSize=$heap, expected $KAFKA_HEAP
       (an unquoted Environment=KAFKA_HEAP_OPTS drops the -Xmx word)"
done
ok "A3 kafka heap is 256 MB on both brokers"

# ---------------------------------------------------------------------------
log "5/6 create topics and assert replication"
# ---------------------------------------------------------------------------
kt() { docker exec "$NODE_A" "$KAFKA_HOME/bin/kafka-topics.sh" --bootstrap-server "$BROKERS" "$@" 2>/dev/null; }

for t in $TOPICS; do
    kt --create --topic "$t" --partitions "$PARTITIONS" --replication-factor "$REPLICATION" \
        --if-not-exists >/dev/null || fail "could not create topic $t"
done

report="$(kt --describe)" || fail "kafka-topics --describe failed"
for t in $TOPICS; do
    # A5: replication factor and ISR size for every partition
    printf '%s\n' "$report" | awk -v t="$t" -v r="$REPLICATION" '
        $1=="Topic:" && $2==t { found=1 }
        $1=="Topic:" && $2==t && /ReplicationFactor:/ {
            for (i=1;i<=NF;i++) if ($i=="ReplicationFactor:") rf=$(i+1)
            if (rf+0 != r+0) { printf "A5: %s has ReplicationFactor=%s, expected %s\n", t, rf, r; bad=1 }
        }
        found && $1=="Topic:" && $3=="Partition:" {
            isr=""; for (i=1;i<=NF;i++) if ($i=="Isr:") isr=$(i+1)
            n=split(isr, a, ",")
            if (n+0 != r+0) { printf "A5: %s partition %s has %d replicas in ISR, expected %d\n", t, $4, n, r; bad=1 }
        }
        END { exit bad?1:0 }
    ' || fail "A5: replication check failed for topic $t"
done
ok "A5 all topics: replication factor $REPLICATION, $REPLICATION replicas in ISR"

# A6
under="$(kt --describe --under-replicated-partitions)"
[ -z "$under" ] || fail "A6: under-replicated partitions:\n$under"
unavail="$(kt --describe --unavailable-partitions)"
[ -z "$unavail" ] || fail "A6: unavailable partitions:\n$unavail"
ok "A6 no under-replicated or unavailable partitions"

# A7 — smoke produce/consume on a throwaway topic, so INCDATA is not polluted
# with records the consumer would have to skip.
smoke="rc-smoke-$$"
probe="probe-$$-$(date +%s)"
kt --create --topic "$smoke" --partitions 1 --replication-factor "$REPLICATION" --if-not-exists >/dev/null \
    || fail "A7: could not create $smoke"
printf '%s\n' "$probe" | docker exec -i "$NODE_A" "$KAFKA_HOME/bin/kafka-console-producer.sh" \
    --bootstrap-server "$BROKERS" --topic "$smoke" --producer-property acks=all >/dev/null 2>&1 \
    || fail "A7: smoke produce failed"
got="$(docker exec "$NODE_A" "$KAFKA_HOME/bin/kafka-console-consumer.sh" \
        --bootstrap-server "$BROKERS" --topic "$smoke" --from-beginning \
        --max-messages 1 --timeout-ms 30000 2>/dev/null)"
kt --delete --topic "$smoke" >/dev/null 2>&1 || true
[ "$got" = "$probe" ] || fail "A7: smoke consume returned '$got', expected '$probe'"
ok "A7 smoke record round-tripped (on $smoke, deleted afterwards)"

# ---------------------------------------------------------------------------
log "6/6 optional: repoint the consumer"
# ---------------------------------------------------------------------------
if [ "$WITH_CONSUMER" = "1" ]; then
    APP_JAR="${APP_JAR:-}"
    jar="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/app/app.jar"}}{{.Source}}{{end}}{{end}}' "$APP_C" 2>/dev/null)"
    [ -n "$jar" ] || jar="$APP_JAR"
    [ -n "$jar" ] || fail "WITH_CONSUMER=1 needs APP_JAR (or an existing $APP_C with the jar mounted)"
    group="${CONSUMER_GROUP:-rc-e2e-kafka-$(date +%s)}"

    docker rm -f "$APP_C" >/dev/null 2>&1 || true
    docker run -d --name "$APP_C" --network "$NET" --entrypoint bash \
        -v "$jar:/app/app.jar:ro" "$BASE_IMAGE" \
        -c "exec $JDK/bin/java -Dfile.encoding=UTF-8 -Xms256m -Xmx512m \
              -jar /app/app.jar \
              --spring.cloud.nacos.config.enabled=false \
              --spring.cloud.nacos.discovery.enabled=false \
              --spring.kafka.bootstrap-servers=$BROKERS \
              --spring.kafka.consumer.group-id=$group \
              --spring.kafka.consumer.auto-offset-reset=earliest \
              --spring.kafka.listener.type=batch --spring.kafka.listener.concurrency=2 \
              --oms.redisMode=cluster \
              --oms.clusters[0]=$A_IP:6379 --oms.clusters[1]=$A_IP:6380 --oms.clusters[2]=$B_IP:6382 \
              --oms.password=$CLUSTER_PW --oms.database=0 --oms.timeout=5000 \
              --commitdata.inclusions.object-type.31=DPSPoint \
              --commitdata.inclusions.object-type.33=MVPoint \
              --server.port=8092" >/dev/null || fail "could not start $APP_C"

    for _ in $(seq 1 120); do
        docker logs "$APP_C" 2>&1 | grep -q 'Redis mode detected: CLUSTER' && break
        [ "$(docker inspect -f '{{.State.Status}}' "$APP_C")" = "running" ] \
            || { docker logs --tail 40 "$APP_C" >&2; fail "$APP_C exited during startup"; }
        sleep 2
    done
    docker logs "$APP_C" 2>&1 | grep -q 'Redis mode detected: CLUSTER' \
        || fail "$APP_C never detected cluster mode"
    ok "$APP_C repointed at $BROKERS (group=$group)"

    for _ in $(seq 1 60); do
        rows="$(docker exec "$NODE_A" "$KAFKA_HOME/bin/kafka-consumer-groups.sh" \
                 --bootstrap-server "$BROKERS" --describe --group "$group" 2>/dev/null \
               | awk '$2=="INCDATA" && $5!="-"' | wc -l)"
        [ "$rows" -ge 2 ] && break
        sleep 2
    done
    [ "${rows:-0}" -ge 2 ] || fail "consumer group $group did not get 2 partition assignments"
    ok "consumer group $group has 2 consumers assigned"
else
    info "WITH_CONSUMER=0 — the consumer was not touched"
fi

cat <<CARD

==========================================
 E2E KAFKA CLUSTER READY
==========================================
  ZooKeeper   $A_IP:2181 (myid=1)   $B_IP:2181 (myid=2)   quorum=2
  Kafka       broker 1 = $A_IP:9092
              broker 2 = $B_IP:9092
  Topics      $TOPICS  (partitions=$PARTITIONS, RF=$REPLICATION)
  Heaps       kafka 256m / zookeeper 256m
  CAVEAT      two voters: losing either node stops all writes
==========================================
CARD

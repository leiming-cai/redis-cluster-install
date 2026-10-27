#!/usr/bin/env bash
# e2e-cpsweb-nodes.sh — deploy a two-node Redis Cluster onto nodes derived from
# the CPS Web environment image, using cluster-config.sh, then (optionally)
# drive the real Kafka consumer RTListener.onMessage against it.
#
# WHAT THIS COVERS THAT scripts/e2e-cluster-config.sh DOES NOT
#   That E2E builds its nodes from the official redis:8 image, which already
#   has a redis user and no systemd. The cluster this project actually ships
#   into runs on the CPS Web node image (cpsweb-env:1.0, built from the
#   cpsweb-install package), which has Redis 8.10.0 but NO systemd, NO sshd and
#   NO `redis` user. Those are exactly the three preconditions cluster-config.sh
#   refuses to proceed without, so the deployment was never exercised on the
#   real target until this script existed.
#
#   See tests/fixtures/Dockerfile.node.cpsweb for how the node image is derived
#   and why ENTRYPOINT is cleared.
#
# USAGE
#   bash scripts/e2e-cpsweb-nodes.sh
#
#   With the consumer write test (needs a running CPS Web environment, i.e. a
#   container with Kafka on it — see KAFKA_CONTAINER):
#     APP_JAR=/abs/path/rtdata-consumer-1.0.14.jar \
#       bash scripts/e2e-cpsweb-nodes.sh
#
# ENVIRONMENT
#   CPSWEB_BASE_IMAGE   base image for the node fixture   (default cpsweb-env:1.0)
#   KAFKA_CONTAINER     container that runs Kafka         (default cpsweb)
#   APP_JAR             rtdata-consumer jar; enables the write test.
#                       MUST be a path the Docker DAEMON can bind-mount
#                       (on Docker Desktop/Windows that means D:/..., not /d/...).
#   E2E_HOST_REPO       daemon-visible path of this repo when the script itself
#                       runs inside a container (same purpose as in
#                       e2e-cluster-config.sh — `docker run -v` is resolved by
#                       the daemon, `docker build` context by the CLI).
#   KEEP=1              leave the containers and network up for inspection.
#
# REQUIREMENTS: docker. Nothing else on the host — every command that needs
# sshpass runs in the control container.
#
# WHAT IT ASSERTS (all guarded with `|| fail`; the script runs `set -uo pipefail`
# WITHOUT `set -e`, so an unguarded test would silently not fail the run)
#   D1  6 instances answer PING, and the nodes really are Redis 8 with a
#       `redis` user — the two preconditions cluster-config.sh checks
#   D2  `--cluster check` reports all 16384 slots covered
#   D3  cluster_state / slots_assigned / known_nodes / cluster_size are correct
#   D4  cross-node read/write routes through the cluster
#   D5  cluster-config.sh itself completed all 9 steps (exit 0 + READY banner)
#   D6  (optional) RTListener.onMessage writes into the cluster
#   D7  (optional) a master is killed, its replica promoted, and writes continue
#
# EXIT CODE: 0 on success, 1 on the first failed assertion.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_REPO="${E2E_HOST_REPO:-$REPO_ROOT}"

BASE_IMAGE="${CPSWEB_BASE_IMAGE:-cpsweb-env:1.0}"
NODE_IMAGE=rc-cpsweb-node:local
CTL_IMAGE=rc-cpsweb-control:local
NET=rc-cpsweb-net
NODE_A=rc-cpsweb-node-a
NODE_B=rc-cpsweb-node-b
APP_C=rc-cpsweb-app

NODE_PW='ClusterPw123!'
CLUSTER_PW='CpsE2eClusterPw'
PREFIX=/opt/software/redis

KAFKA_CONTAINER="${KAFKA_CONTAINER:-cpsweb}"
APP_JAR="${APP_JAR:-}"

# Set to 1 only when THIS script attached KAFKA_CONTAINER to $NET. It has to be
# undone before the network can be removed: `docker network rm` fails with
# "has active endpoints" while any container is still attached, so without
# this the network outlives the run and every later run inherits it.
ATTACHED_KAFKA=0

log()  { printf '\n=== %s ===\n' "$*"; }
info() { printf '  [INFO] %s\n' "$*"; }
ok()   { printf '  [ OK ] %s\n' "$*"; }
fail() { printf '\nFAIL: %s\n' "$*" >&2; exit 1; }

cleanup() {
    [ "${KEEP:-0}" = "1" ] && { info "KEEP=1 — 保留容器与网络"; return; }
    docker rm -f "$APP_C" "$NODE_A" "$NODE_B" >/dev/null 2>&1 || true
    if [ "$ATTACHED_KAFKA" = "1" ]; then
        docker network disconnect -f "$NET" "$KAFKA_CONTAINER" >/dev/null 2>&1 || true
    fi
    docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Run a command inside the control container, joined to the cluster network.
# -i is REQUIRED: without it docker discards stdin, so a `bash -s <<EOF`
# heredoc never reaches ssh and the remote script sees an empty stdin, exits 0
# and does nothing — a completely silent failure.
ctl() {
    docker run --rm -i --network "$NET" -v "$HOST_REPO:/repo" "$CTL_IMAGE" "$@"
}

command -v docker >/dev/null || fail "docker not found"

# ---------------------------------------------------------------------------
log "0/6 前置检查"
# ---------------------------------------------------------------------------
docker image inspect "$BASE_IMAGE" >/dev/null 2>&1 \
    || fail "base image '$BASE_IMAGE' not found.
       Build it from the cpsweb-install package first:
         cd <cpsweb-install> && docker build -f docker/Dockerfile -t $BASE_IMAGE .
       Override the name with CPSWEB_BASE_IMAGE=... if yours differs."
ok "base image $BASE_IMAGE present"

if [ "${KEEP:-0}" != "1" ]; then
    docker rm -f "$APP_C" "$NODE_A" "$NODE_B" >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
log "1/6 构建节点镜像（从 $BASE_IMAGE 派生）"
# ---------------------------------------------------------------------------
# `docker build -f` and its context are read by the CLI, not the daemon, so
# this must be REPO_ROOT and not HOST_REPO (same distinction as
# e2e-cluster-config.sh's header note).
docker build -q -f "$REPO_ROOT/tests/fixtures/Dockerfile.node.cpsweb" \
    -t "$NODE_IMAGE" "$REPO_ROOT" >/dev/null \
    || fail "node image build failed (base: $BASE_IMAGE)"
ok "built $NODE_IMAGE"

# ---------------------------------------------------------------------------
log "2/6 构建控制端镜像"
# ---------------------------------------------------------------------------
docker build -q -f "$REPO_ROOT/tests/fixtures/Dockerfile.control.cpsweb" \
    -t "$CTL_IMAGE" "$REPO_ROOT" >/dev/null \
    || fail "control image build failed"
ok "built $CTL_IMAGE"

# ---------------------------------------------------------------------------
log "3/6 启动两个节点"
# ---------------------------------------------------------------------------
docker network create "$NET" >/dev/null 2>&1 || true
for n in "$NODE_A" "$NODE_B"; do
    docker run -d --name "$n" --network "$NET" \
        --hostname "${n#rc-cpsweb-node-}" \
        --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
        "$NODE_IMAGE" >/dev/null || fail "could not start $n"
done
ok "started $NODE_A, $NODE_B"

# Wait for systemd to bring sshd up on both. Polling for the real thing (a
# successful ssh) rather than sleeping a fixed amount: the nodes run the CPS
# base image, whose first boot is slower than a bare redis:8 container.
info "等待 systemd + sshd 就绪 ..."
ready=0
for _ in $(seq 1 60); do
    if ctl bash -c '
        for h in '"$NODE_A $NODE_B"'; do
          ip="$(getent hosts "$h" | awk "{print \$1}")"
          [ -n "$ip" ] || exit 1
          SSHPASS='"$NODE_PW"' sshpass -e ssh -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 \
            root@"$ip" true 2>/dev/null || exit 1
        done
      ' >/dev/null 2>&1; then
        ready=1; break
    fi
    sleep 2
done
[ "$ready" = 1 ] || fail "nodes did not become reachable over SSH within 120s"
ok "both nodes reachable over SSH"

A_IP="$(ctl bash -c "getent hosts $NODE_A | awk '{print \$1}'")"
B_IP="$(ctl bash -c "getent hosts $NODE_B | awk '{print \$1}'")"
[ -n "$A_IP" ] && [ -n "$B_IP" ] || fail "could not resolve node IPs"
ok "node-a=$A_IP  node-b=$B_IP"
# NOTE: nodes are addressed by IP, never by hostname — CLUSTER MEET cannot
# resolve container hostnames, and the generated cluster.conf would carry
# names the cluster then refuses ("Invalid node address specified").

# ---------------------------------------------------------------------------
log "4/6 用 cluster-config.sh 组网（9 步）"
# ---------------------------------------------------------------------------
# cluster.conf travels as an ENVIRONMENT VARIABLE rather than a bind mount:
# the file lives in this script's filesystem, and `docker run -v` sources are
# resolved by the daemon, which cannot see a container-local path when this
# script itself runs inside a container. Writing it inside the control
# container side-steps the whole class of "path not found" errors.
CLUSTER_CONF="redis_prefix     = $PREFIX
cluster_password = $CLUSTER_PW
bind_addr        = 0.0.0.0

[node.a]
host     = $A_IP
ssh_port = 22
ports    = 6379,6380,6381

[node.b]
host     = $B_IP
ssh_port = 22
ports    = 6382,6383,6384"
export CLUSTER_CONF

CONFIG_LOG="$(mktemp)"
docker run --rm -i --network "$NET" \
    -e PROMPT_NO_TTY=1 \
    -e NODE_A_SSH_USER=root -e NODE_A_HOST="$A_IP" -e NODE_A_SSH_PORT=22 -e NODE_A_SSH_PASS="$NODE_PW" \
    -e NODE_B_SSH_USER=root -e NODE_B_HOST="$B_IP" -e NODE_B_SSH_PORT=22 -e NODE_B_SSH_PASS="$NODE_PW" \
    -e CLUSTER_CONF \
    -v "$HOST_REPO:/repo" \
    "$CTL_IMAGE" bash -c '
        set -e
        mkdir -p /work
        printf "%s\n" "$CLUSTER_CONF" > /work/cluster.conf
        exec bash /repo/cluster-config.sh --config /work/cluster.conf
    ' 2>&1 | tee "$CONFIG_LOG"
rc=${PIPESTATUS[0]}
[ "$rc" -eq 0 ] || fail "cluster-config.sh exited $rc (see log above)"
grep -q "Redis Cluster READY" "$CONFIG_LOG" \
    || fail "cluster-config.sh exited 0 but never printed 'Redis Cluster READY'"
ok "cluster-config.sh completed all 9 steps (exit 0)"

# ---------------------------------------------------------------------------
log "5/6 校验集群（DoD1-4）"
# ---------------------------------------------------------------------------
# A3_IP is the first node's first port; every probe goes through the nodes'
# own redis-cli so the client version matches the server version.
rc_on() { # rc_on NODE_IP PORT ARGS...
    local ip="$1" port="$2"; shift 2
    docker run --rm -i --network "$NET" "$CTL_IMAGE" bash -c \
        "SSHPASS='$NODE_PW' sshpass -e ssh -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@$ip \
            '$PREFIX/bin/redis-cli -a $CLUSTER_PW --no-auth-warning -p $port $*'" 2>/dev/null | tr -d '\r'
}

info "D1: 6 个实例 PING"
for spec in "$A_IP:6379" "$A_IP:6380" "$A_IP:6381" "$B_IP:6382" "$B_IP:6383" "$B_IP:6384"; do
    out="$(rc_on "${spec%:*}" "${spec#*:}" PING)"
    [ "$out" = "PONG" ] || fail "PING $spec -> '$out'"
    ok "PING $spec = PONG"
done

# live_spec — echo "ip:port" of the FIRST instance that answers PING.
#
# WHY THIS EXISTS: the failover drill kills a master, and several polls after
# that point still need to read `cluster nodes`. Hardcoding the read entry
# point to node-a:6379 looks fine until the drill happens to kill 6379 — then
# every poll connects to a dead port, gets "Connection refused" (stderr is
# discarded), sees empty output, and reports "replica was not promoted" even
# though the promotion already happened. Measured: the first run of this
# script killed 6380 and passed; the second killed 6379 and failed wrongly.
live_spec() {
    local spec
    for spec in "$A_IP:6379" "$A_IP:6380" "$A_IP:6381" "$B_IP:6382" "$B_IP:6383" "$B_IP:6384"; do
        if [ "$(rc_on "${spec%:*}" "${spec#*:}" PING)" = "PONG" ]; then
            printf '%s' "$spec"
            return 0
        fi
    done
    return 1
}

info "D1b: 节点上确实是 Redis 8，且有 redis 用户"
for ip in "$A_IP" "$B_IP"; do
    ver="$(docker run --rm -i --network "$NET" "$CTL_IMAGE" bash -c \
        "SSHPASS='$NODE_PW' sshpass -e ssh -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@$ip \
            '$PREFIX/bin/redis-server --version'" 2>/dev/null | tr -d '\r')"
    case "$ver" in
        *"v=8."*) : ;;
        *) fail "expected Redis 8 on $ip, got: $ver" ;;
    esac
    docker run --rm -i --network "$NET" "$CTL_IMAGE" bash -c \
        "SSHPASS='$NODE_PW' sshpass -e ssh -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@$ip 'id redis'" >/dev/null 2>&1 \
        || fail "the redis user is missing on $ip"
    ok "$ip: $ver；redis 用户存在"
done

info "D2: --cluster check"
check_report="$(rc_on "$A_IP" 6379 "--cluster check $A_IP:6379")"
grep -q "All 16384 slots covered" <<< "$check_report" \
    || fail "cluster check did not report all 16384 slots covered"
ok "All 16384 slots covered"

info "D3: cluster info 四个条件各自独立断言"
cluster_info="$(rc_on "$A_IP" 6379 "cluster info")"
grep -qE '^cluster_state:ok'              <<< "$cluster_info" || fail "cluster_state is not ok"
grep -qE '^cluster_slots_assigned:16384'  <<< "$cluster_info" || fail "not all 16384 slots are assigned"
grep -qE '^cluster_known_nodes:6'         <<< "$cluster_info" || fail "cluster_known_nodes is not 6"
grep -qE '^cluster_size:3'                <<< "$cluster_info" || fail "cluster_size is not 3"
ok "cluster_state:ok / slots 16384 / known 6 / size 3"

info "D4: 跨节点读写"
rc_on "$A_IP" 6379 "-c SET e2e:cpsweb:key from-a" >/dev/null || fail "SET on node A failed"
sleep 1
v="$(rc_on "$B_IP" 6382 "-c GET e2e:cpsweb:key")"
[ "$v" = "from-a" ] || fail "node B GET -> '$v'"
ok "A 写 B 读 = from-a"
rc_on "$B_IP" 6382 "-c SET e2e:cpsweb:key2 from-b" >/dev/null || fail "SET on node B failed"
sleep 1
v="$(rc_on "$A_IP" 6380 "-c GET e2e:cpsweb:key2")"
[ "$v" = "from-b" ] || fail "node A GET -> '$v'"
ok "B 写 A 读 = from-b"

# ---------------------------------------------------------------------------
log "6/6 RTListener.onMessage 集群写入测试"
# ---------------------------------------------------------------------------
if [ -z "$APP_JAR" ]; then
    info "APP_JAR 未设置 —— 跳过写入测试。"
    info "要跑的话：APP_JAR=<daemon 可见路径>/rtdata-consumer-1.0.14.jar bash $0"
    printf '\n==========================================\n E2E PASSED (infra only)\n==========================================\n'
    exit 0
fi

docker inspect "$KAFKA_CONTAINER" >/dev/null 2>&1 \
    || fail "KAFKA_CONTAINER='$KAFKA_CONTAINER' does not exist; set it to a container running Kafka"

# Kafka must be on the cluster network so the app container can reach both.
if ! docker inspect "$KAFKA_CONTAINER" \
        --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' | grep -qw "$NET"; then
    docker network connect "$NET" "$KAFKA_CONTAINER" || fail "could not attach $KAFKA_CONTAINER to $NET"
    ATTACHED_KAFKA=1
    ok "$KAFKA_CONTAINER 已接入 $NET"
fi
KAFKA_IP="$(docker inspect -f "{{with index .NetworkSettings.Networks \"$NET\"}}{{.IPAddress}}{{end}}" "$KAFKA_CONTAINER")"
[ -n "$KAFKA_IP" ] || fail "could not read $KAFKA_CONTAINER's address on $NET"
ok "Kafka 在 $NET 上 = $KAFKA_IP:9092"

kafka() { # kafka BIN ARGS...  (runs a Kafka CLI inside the Kafka container)
    local bin="$1"; shift
    docker exec -i "$KAFKA_CONTAINER" \
        "/opt/software/kafka_2.13-2.8.0/bin/$bin" --bootstrap-server 127.0.0.1:9092 "$@" 2>/dev/null
}

kafka kafka-topics.sh --list | grep -qx INCDATA \
    || fail "topic INCDATA not found in $KAFKA_CONTAINER"

# otype = (obid >>> 32) & 0xFFFFFFFF, so obid must live in [11<<32, 12<<32) for
# RTListener/RedisRealDataServiceImpl to build the key real_data:11:<obid>.
# 11<<32 = 47244640256. Offset by the epoch so repeated runs do not collide and
# so the test cannot pass by reading a value left over from a previous run.
BASE_OBID=47244640256
STAMP=$(( $(date +%s) % 100000 ))
OBID1=$(( BASE_OBID + STAMP * 10 + 1 ))
OBID2=$(( BASE_OBID + STAMP * 10 + 2 ))
KEY1="real_data:11:$OBID1"
KEY2="real_data:11:$OBID2"
MSG1="${OBID1};Value,1,123.45,1712345678000"
MSG2="${OBID2};Value,1,888.88,1712345678999"
GROUP_ID="rc-cpsweb-$(date +%s)"

# The app image is the BASE image, not the node image: the node image replaced
# the entrypoint and installed systemd, neither of which the consumer needs,
# and using the base keeps the JDK that ships with the CPS package.
docker rm -f "$APP_C" >/dev/null 2>&1
docker run -d --name "$APP_C" --network "$NET" \
    --entrypoint bash \
    --add-host "node1:$KAFKA_IP" \
    -v "$APP_JAR:/app/app.jar:ro" \
    "$BASE_IMAGE" \
    -c "exec /opt/software/jdk8u292-b10/bin/java -Dfile.encoding=UTF-8 -Xms256m -Xmx512m \
          -jar /app/app.jar \
          --spring.cloud.nacos.config.enabled=false \
          --spring.cloud.nacos.discovery.enabled=false \
          --spring.kafka.bootstrap-servers=$KAFKA_IP:9092 \
          --spring.kafka.consumer.group-id=$GROUP_ID \
          --spring.kafka.consumer.auto-offset-reset=earliest \
          --spring.kafka.listener.type=batch --spring.kafka.listener.concurrency=1 \
          --oms.redisMode=cluster \
          --oms.clusters[0]=$A_IP:6379 --oms.clusters[1]=$A_IP:6380 --oms.clusters[2]=$B_IP:6382 \
          --oms.password=$CLUSTER_PW --oms.database=0 --oms.timeout=5000 \
          --commitdata.inclusions.object-type.31=DPSPoint \
          --commitdata.inclusions.object-type.33=MVPoint \
          --server.port=8092" >/dev/null \
    || fail "could not start the consumer container"

APP_LOG="$(mktemp)"
docker logs -f "$APP_C" > "$APP_LOG" 2>&1 &
LOGGER_PID=$!

info "等待应用识别集群模式 ..."
detected=0
for _ in $(seq 1 120); do
    if grep -q 'Redis mode detected: CLUSTER' "$APP_LOG" 2>/dev/null; then detected=1; break; fi
    st="$(docker inspect -f '{{.State.Status}}' "$APP_C" 2>/dev/null)"
    [ "$st" = "running" ] || { tail -40 "$APP_LOG" >&2; fail "consumer container exited ($st)"; }
    sleep 2
done
[ "$detected" = 1 ] || { tail -40 "$APP_LOG" >&2; fail "app never logged 'Redis mode detected: CLUSTER'"; }
ok "$(grep -m1 'Redis mode detected' "$APP_LOG")"
grep -m1 'Using Redis Cluster' "$APP_LOG" | sed 's/^/         /'

# The group being registered is NOT enough: a consumer can join and then never
# fetch if it cannot reach the broker the group coordinator advertises
# (broker advertised.listeners is node1:9092, so the container needs the
# --add-host above). Require that no connection error appears.
info "等待消费组订阅 INCDATA ..."
subscribed=0
for _ in $(seq 1 90); do
    if kafka kafka-consumer-groups.sh --group "$GROUP_ID" --describe | grep -q INCDATA; then
        subscribed=1; break
    fi
    sleep 2
done
[ "$subscribed" = 1 ] || fail "consumer group $GROUP_ID never subscribed to INCDATA"
grep -q 'could not be established' "$APP_LOG" 2>/dev/null \
    && { grep -m3 'could not be established' "$APP_LOG" >&2; fail "app cannot reach the Kafka broker"; }
ok "消费组 $GROUP_ID 已订阅 INCDATA"

# Read a hash field through the cluster. HGET, not GET: the cluster write path
# is opsForHash().putAll(), so the value is a hash FIELD named after the atype.
# -c handles redirection; it does not change the command, so GET would return
# WRONGTYPE no matter which node answered.
read_hash() { # read_hash KEY
    local key="$1" spec ip port out
    for spec in "$A_IP:6379" "$A_IP:6380" "$A_IP:6381" "$B_IP:6382" "$B_IP:6383" "$B_IP:6384"; do
        ip="${spec%:*}"; port="${spec#*:}"
        out="$(rc_on "$ip" "$port" "-c HGET $key Value")"
        case "$out" in
            ''|*Connection*refused*) continue ;;
            *) printf '%s' "$out"; return 0 ;;
        esac
    done
    printf ''
    return 1
}

info "注入 $MSG1"
printf '%s\n' "$MSG1" | docker exec -i "$KAFKA_CONTAINER" \
    /opt/software/kafka_2.13-2.8.0/bin/kafka-console-producer.sh \
    --bootstrap-server 127.0.0.1:9092 --topic INCDATA >/dev/null 2>&1

found=''
for _ in $(seq 1 40); do
    v="$(read_hash "$KEY1")"
    case "$v" in *123.45*) found="$v"; break ;; esac
    sleep 1
done
[ -n "$found" ] || { tail -40 "$APP_LOG" >&2; fail "D6: $KEY1 never appeared (waited 40s)"; }
ok "D6: RTListener.onMessage 写入成功 $KEY1 Value=$found"

# Slot ownership + cross-node read, so this cannot pass by writing locally.
slot="$(rc_on "$A_IP" 6379 "cluster keyslot $KEY1")"
info "D6b: $KEY1 的槽位 = $slot"
masters="$(rc_on "$A_IP" 6379 "cluster nodes")"
owner_ip=''; owner_port=''
while IFS= read -r line; do
    [ -n "$line" ] || continue
    flags="$(awk '{print $3}' <<< "$line")"
    case "$flags" in *master*) : ;; *) continue ;; esac
    case "$flags" in *slave*) continue ;; esac
    addr="$(awk '{print $2}' <<< "$line")"; addr="${addr%%@*}"; addr="${addr%%,*}"
    for rng in $(cut -d' ' -f8- <<< "$line"); do
        case "$rng" in
            *-*) lo="${rng%-*}"; hi="${rng#*-}"
                 if [ "$slot" -ge "$lo" ] 2>/dev/null && [ "$slot" -le "$hi" ] 2>/dev/null; then
                     owner_ip="${addr%:*}"; owner_port="${addr#*:}"
                 fi ;;
        esac
        [ -n "$owner_ip" ] && break
    done
    [ -n "$owner_ip" ] && break
done <<< "$masters"
[ -n "$owner_ip" ] || fail "could not find the master owning slot $slot"
ok "槽位 $slot 的持有主节点 = $owner_ip:$owner_port"

# ---------------------------------------------------------------------------
info "D7: 杀掉持有一个主实例，等副本提升，再写一条"
# ---------------------------------------------------------------------------
# Kill whichever master owns KEY1's slot: that is the one whose loss the
# consumer must survive, and it makes the follow-up assertion meaningful.
# If the slot owner is the node hosting two masters we still only stop one unit.
if [ "$owner_ip" = "$A_IP" ]; then VICTIM_C="$NODE_A"; else VICTIM_C="$NODE_B"; fi
VICTIM_P="$owner_port"
info "受害实例 = $VICTIM_C:$VICTIM_P"

victim_id="$(awk -v a="$owner_ip:$VICTIM_P@" 'index($2,a){print $1; exit}' <<< "$masters")"
replica_id="$(awk -v v="$victim_id" '$4==v {print $1; exit}' <<< "$masters")"
[ -n "$victim_id" ]  || fail "could not identify the victim node id"
[ -n "$replica_id" ] || fail "no replica reports master id $victim_id"

docker exec "$VICTIM_C" systemctl stop "redis-$VICTIM_P" || fail "could not stop redis-$VICTIM_P"
ok "已停止 $VICTIM_C:redis-$VICTIM_P.service"

promoted=0
# 20 x 5s = 100s. The promotion itself is bounded by cluster-node-timeout
# (15000ms) and normally lands in 15-30s; the margin is for the memory-starved
# Docker engines this project is developed on, not for a latency SLA. The
# assertion is "it does promote", not "it promotes fast".
for _ in $(seq 1 20); do
    sleep 5
    # Read through a LIVE instance, never through a fixed port: the victim may
    # be exactly the port a hardcoded entry point would use (see live_spec).
    live="$(live_spec)" || fail "no instance answered PING 60s into the drill"
    nodes_now="$(rc_on "${live%:*}" "${live#*:}" "cluster nodes")"
    # Poll the REPLICA's own flags. Polling `$1==victim && $3 ~ /master/`
    # would be true before the kill too — a check that can never fail.
    if awk -v r="$replica_id" '$1==r && $3 !~ /(slave|replica)/ {f=1} END{exit !f}' <<< "$nodes_now"; then
        promoted=1; break
    fi
done
[ "$promoted" = 1 ] || fail "replica $replica_id was not promoted within 100s"
ok "副本 $replica_id 已提升为主"

printf '%s\n' "$MSG2" | docker exec -i "$KAFKA_CONTAINER" \
    /opt/software/kafka_2.13-2.8.0/bin/kafka-console-producer.sh \
    --bootstrap-server 127.0.0.1:9092 --topic INCDATA >/dev/null 2>&1

found2=''
for _ in $(seq 1 40); do
    v="$(read_hash "$KEY2")"
    case "$v" in *888.88*) found2="$v"; break ;; esac
    sleep 1
done
[ -n "$found2" ] || { tail -40 "$APP_LOG" >&2; fail "D7: $KEY2 never appeared after failover"; }
ok "D7: 故障转移后仍能写入 $KEY2 Value=$found2"

# Restore the instance and require it to come back as a replica — a node that
# returns as a second master would be split brain. Poll rather than sleep a
# fixed amount: after a restart the node needs to rejoin and be reconfigured,
# and the exact time depends on how long the promotion handshake takes.
docker exec "$VICTIM_C" systemctl start "redis-$VICTIM_P" >/dev/null 2>&1 || true
role=''
for _ in $(seq 1 12); do
    sleep 3
    role="$(rc_on "$owner_ip" "$VICTIM_P" "INFO replication" | awk -F: '/^role:/{print $2}')"
    [ "$role" = "slave" ] && break
done
[ "$role" = "slave" ] || fail "restarted $VICTIM_P came back as '$role', expected slave"
ok "旧主回来是副本（无双主）"

live="$(live_spec)" || fail "no instance answered PING after the drill"
cluster_info="$(rc_on "${live%:*}" "${live#*:}" "cluster info")"
grep -qE '^cluster_state:ok' <<< "$cluster_info" || fail "cluster_state is not ok after the failover drill"
ok "cluster_state:ok（恢复后）"

kill "$LOGGER_PID" 2>/dev/null || true

cat <<CARD

==========================================
 E2E PASSED
==========================================
  D1  6 实例 PING + Redis 8 + redis 用户   OK
  D2  All 16384 slots covered             OK
  D3  cluster_state/slots/known/size      OK
  D4  跨节点读写                           OK
  D5  cluster-config.sh 9 步              OK
  D6  RTListener.onMessage 写入            OK ($KEY1)
  D7  主节点故障转移后仍能写入              OK ($KEY2)
==========================================
CARD

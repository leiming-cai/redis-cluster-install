#!/bin/bash
# 华盾 napstar2.0 环境入口 (hd-node1)
#   PG -> Redis x2 -> ZK#1 -> Kafka#1 -> Nacos
#   应用**不自动启动** —— 由 scripts/start-hd-apps.sh 分批拉起
#   （本机只有 3.9GB 内存，11 个应用同时跑会 OOM）。
#
# ⚠️ 命名契约：本脚本只管华盾 napstar2.0 的东西。绝不碰门户的 cpsweb。
set -uo pipefail

# ---- hd-node2 用另一个入口 ----
if [ "${HD_ROLE:-node1}" = "node2" ]; then
  exec /usr/local/bin/hd-entrypoint-node2.sh
fi

log() { echo "[hd-entrypoint] $*"; }

# ---- 主机别名 ----
# 构建期 /etc/hosts 只读，这里在运行时写。
#
# ⚠️ **node2 不能指向 127.0.0.1** —— ZooKeeper 是 2 节点 ensemble，
#    server.2=node2:2888:3888 如果解析回本机，quorum 选举会撞成
#    "We got a connection request from a server with our own ID"。
#    所以 node2 要指向 hd-node2 容器的真实 IP。
#    做法: 用 Docker 网络别名解析（node2 由 hd-net 的 alias 提供），
#    拿不到就退化成 127.0.0.1（单节点模式，ZK 会起不来但其余组件正常）。
resolve_alias() {
  local name="$1"
  getent hosts "$name" 2>/dev/null | awk '{print $1; exit}'
}

NODE1_IP="$(resolve_alias hd-node1)"
[ -z "$NODE1_IP" ] && NODE1_IP="127.0.0.1"
NODE2_IP="$(resolve_alias hd-node2)"
[ -z "$NODE2_IP" ] && NODE2_IP="127.0.0.1"

# 删掉之前写入的别名行（幂等）
sed -i '/[[:space:]]node1[[:space:]]/d; /[[:space:]]hd-node1[[:space:]]/d; /[[:space:]]node2[[:space:]]/d; /[[:space:]]hd-node2[[:space:]]/d; /[[:space:]]node01[[:space:]]/d; /[[:space:]]node02[[:space:]]/d; /[[:space:]]webdb[[:space:]]/d; /[[:space:]]napstardb[[:space:]]/d' /etc/hosts 2>/dev/null || true
{
  echo "${NODE1_IP} node1 hd-node1 node01 webdb"
  echo "${NODE2_IP} node2 hd-node2 node02 napstardb"
} >> /etc/hosts 2>/dev/null || true
log "hosts: node1=${NODE1_IP} node2=${NODE2_IP}"

# ---- PostgreSQL ----
PG_VERSION=14
PG_CLUSTER=main
export PGPORT="${PGPORT:-5432}"
export PGHOST="${PGHOST:-127.0.0.1}"
if ! pg_isready -h "$PGHOST" -p "$PGPORT" -U postgres >/dev/null 2>&1; then
  log "starting PostgreSQL ${PG_VERSION}/${PG_CLUSTER}"
  mkdir -p /var/log/postgresql && chown postgres:postgres /var/log/postgresql 2>/dev/null || true
  pg_ctlcluster "${PG_VERSION}" "${PG_CLUSTER}" start || \
    su postgres -c "/usr/lib/postgresql/${PG_VERSION}/bin/pg_ctl -D /var/lib/postgresql/${PG_VERSION}/main -w -t 60 -l /var/log/postgresql/startup.log start"
fi
for i in $(seq 1 60); do
  pg_isready -h "$PGHOST" -p "$PGPORT" -U postgres >/dev/null 2>&1 && break
  sleep 1
done
pg_isready -h "$PGHOST" -p "$PGPORT" -U postgres >/dev/null 2>&1 \
  && log "PostgreSQL ready" || { log "PostgreSQL FAILED"; exit 1; }

# ---- Redis x2 (6379 master / 6389 slave) ----
start_redis() {
  local conf="$1"
  local logfile
  logfile=$(grep -E '^logfile' "$conf" | sed 's/^logfile *"//; s/"$//')
  [ -n "$logfile" ] && mkdir -p "$(dirname "$logfile")" 2>/dev/null
  "$REDIS_HOME/bin/redis-server" "$conf" &
  log "redis started from $conf"
}
start_redis "$REDIS_HOME/config/redismaster.conf"   # 6379
start_redis "$REDIS_HOME/config/redis.conf"         # 6389
sleep 2

# ---- ZooKeeper #1 ----
ZK_DATA="$ZOOKEEPER_HOME/data"
mkdir -p "$ZK_DATA" "$ZOOKEEPER_HOME/logs"
echo 1 > "$ZK_DATA/myid"
rm -f "$ZK_DATA/zookeeper_server.pid"
export SERVER_JVMFLAGS="-Xmx${ZK_HEAP_SIZE:-256M}"
"$ZOOKEEPER_HOME/bin/zkServer.sh" start
log "zookeeper #1 started"

# 2 节点 ensemble 要凑齐 quorum（2 节点里活 1 个不够 —— 实际需要 2 个都活）
# 最多等 90 秒让 hd-node2 的 ZK 起来并完成选举
log "waiting for the 2-node ZooKeeper ensemble to form ..."
for i in $(seq 1 45); do
  if "$ZOOKEEPER_HOME/bin/zkServer.sh" status 2>/dev/null | grep -qE "Mode: (leader|follower)"; then
    log "zookeeper #1 is in the ensemble"
    break
  fi
  sleep 2
done

# ---- Kafka broker #1 ----
cd "$KAFKA_HOME"
export KAFKA_HEAP_OPTS="${KAFKA_HEAP_OPTS:--Xms128M -Xmx256M}"
export LOG_DIR="$KAFKA_HOME/logs"
JMX_PORT=9998 ./bin/kafka-server-start.sh -daemon config/server.properties
log "kafka broker #1 starting"

# ---- Nacos ----
if [ -n "${NACOS_JVM_OPTS:-}" ] && [ -f "$NACOS_HOME/bin/startup.sh" ]; then
  sed -i "s/-Xms[0-9]*[gm] -Xmx[0-9]*[gm] -Xmn[0-9]*[gm]/$(echo "${NACOS_JVM_OPTS}" | sed 's/[&|]/\\&/g')/" \
      "$NACOS_HOME/bin/startup.sh"
  log "Nacos heap -> ${NACOS_JVM_OPTS}"
fi
cd "$NACOS_HOME/bin" && sh startup.sh -m standalone
log "nacos starting"

# ---- 等待就绪 ----
log "waiting for redis / zookeeper / kafka / nacos ..."
for i in $(seq 1 60); do ss -lnt 2>/dev/null | grep -q ':6379' && break; sleep 2; done
for i in $(seq 1 60); do ss -lnt 2>/dev/null | grep -q ':2181' && break; sleep 2; done
for i in $(seq 1 60); do ss -lnt 2>/dev/null | grep -q ':9092' && break; sleep 2; done
for i in $(seq 1 90); do
  curl -fsS -m 5 http://127.0.0.1:18848/nacos/v1/console/health/readiness >/dev/null 2>&1 && break
  sleep 2
done

log "==================== hd-node1 status ===================="
pg_isready -h "$PGHOST" -p "$PGPORT" -U postgres >/dev/null 2>&1 && log "  PostgreSQL :5432   OK" || log "  PostgreSQL : DOWN"
"$REDIS_HOME/bin/redis-cli" -h 127.0.0.1 -p 6379 -a sac888 --no-auth-warning PING 2>/dev/null | grep -q PONG && log "  Redis 6379 : OK" || log "  Redis 6379 : DOWN"
"$REDIS_HOME/bin/redis-cli" -h 127.0.0.1 -p 6389 -a sac888 --no-auth-warning PING 2>/dev/null | grep -q PONG && log "  Redis 6389 : OK" || log "  Redis 6389 : DOWN"
"$ZOOKEEPER_HOME/bin/zkServer.sh" status 2>/dev/null | grep -q Mode && log "  ZooKeeper  : OK" || log "  ZooKeeper  : DOWN"
ss -lnt 2>/dev/null | grep -q ':9092' && log "  Kafka      : OK" || log "  Kafka      : DOWN"
curl -fsS -m 5 http://127.0.0.1:18848/nacos/v1/console/health/readiness >/dev/null 2>&1 && log "  Nacos      : OK" || log "  Nacos      : DOWN"
log "=========================================================="
log "container stays up; apps are started by start-hd-apps.sh in batches"

while true; do sleep 3600 & wait $! 2>/dev/null; done

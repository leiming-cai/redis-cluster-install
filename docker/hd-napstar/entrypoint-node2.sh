#!/bin/bash
# 华盾 napstar2.0 环境入口 (hd-node2) —— 只起 ZK#2 + Kafka#2
#
# ⚠️ 命名契约：本脚本只管华盾 napstar2.0 的东西。绝不碰门户的 cpsweb。
set -uo pipefail
log() { echo "[hd-entrypoint2] $*"; }

# ---- 主机别名 ----
# ⚠️ node1 必须指向 hd-node1 容器的真实 IP（跨容器），不能是 127.0.0.1 ——
#    否则 hd-node2 的 ZK 会连回自己，ensemble 选举撞 ID。
resolve_alias() {
  local name="$1"
  getent hosts "$name" 2>/dev/null | awk '{print $1; exit}'
}

NODE1_IP="$(resolve_alias hd-node1)"
[ -z "$NODE1_IP" ] && NODE1_IP="${HD_NODE1_IP:-127.0.0.1}"
NODE2_IP="$(resolve_alias hd-node2)"
[ -z "$NODE2_IP" ] && NODE2_IP="127.0.0.1"

sed -i '/[[:space:]]node1[[:space:]]/d; /[[:space:]]hd-node1[[:space:]]/d; /[[:space:]]node2[[:space:]]/d; /[[:space:]]hd-node2[[:space:]]/d; /[[:space:]]node01[[:space:]]/d; /[[:space:]]node02[[:space:]]/d; /[[:space:]]webdb[[:space:]]/d; /[[:space:]]napstardb[[:space:]]/d' /etc/hosts 2>/dev/null || true
{
  echo "${NODE1_IP} node1 hd-node1 node01 webdb"
  echo "${NODE2_IP} node2 hd-node2 node02 napstardb"
} >> /etc/hosts 2>/dev/null || true
log "hosts: node1=${NODE1_IP} node2=${NODE2_IP}"

# ---- ZooKeeper #2 ----
ZK_DATA="$ZOOKEEPER_HOME/data"
mkdir -p "$ZK_DATA" "$ZOOKEEPER_HOME/logs"
echo 2 > "$ZK_DATA/myid"
rm -f "$ZK_DATA/zookeeper_server.pid"
export SERVER_JVMFLAGS="-Xmx${ZK_HEAP_SIZE:-256M}"
"$ZOOKEEPER_HOME/bin/zkServer.sh" start
log "zookeeper #2 started"

# ---- Kafka broker #2 ----
cd "$KAFKA_HOME"
export KAFKA_HEAP_OPTS="${KAFKA_HEAP_OPTS:--Xms128M -Xmx256M}"
export LOG_DIR="$KAFKA_HOME/logs"
# broker #2 的 server.properties：镜像里只有 node1 那份，这里派生 node2 版本
sed -e 's/^broker\.id=.*/broker.id=756/' \
    -e 's#^advertised\.listeners=.*#advertised.listeners=PLAINTEXT://node2:9092#' \
    config/server.properties > config/server.properties.node2
JMX_PORT=9999 ./bin/kafka-server-start.sh -daemon config/server.properties.node2
log "kafka broker #2 starting"

log "==================== hd-node2 status ===================="
"$ZOOKEEPER_HOME/bin/zkServer.sh" status 2>/dev/null | grep -q Mode && log "  ZooKeeper #2 : OK" || log "  ZooKeeper #2 : DOWN"
log "=========================================================="

while true; do sleep 3600 & wait $! 2>/dev/null; done

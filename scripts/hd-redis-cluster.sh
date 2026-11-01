#!/bin/bash
# 华盾容器内的 Redis 集群（3 master，只给 HD 用）。
#
# ⚠️ 为什么不在宿主那套（16379-16384）上测：
#    宿主那套的 cluster-announce-ip = 127.0.0.1 -> 从 HD 容器里连 127.0.0.1
#    连的是 HD 容器自己，会被拒。已实测（docs/OPERATIONS.md:980-986 那个没测过的优先级问题）。
#    所以这里自建一套，announce-ip 填容器内可达的地址。
#
# 用法：
#   bash hd-redis-cluster.sh start     起 3 个节点并组集群
#   bash hd-redis-cluster.sh stop      停掉并清干净
#   bash hd-redis-cluster.sh status    看状态
set -uo pipefail

REDIS_HOME=/opt/software/redis-8.10.0
RS="$REDIS_HOME/bin/redis-server"
RC="$REDIS_HOME/bin/redis-cli"
DATA=/opt/hd/redis-cluster
PASS="${HD_CLUSTER_PASS:-HdClusterPw2026}"

# 容器内可达的地址 —— 必须不是 127.0.0.1
# ⚠️ 不能用 `hostname -i`：它返回**空格分隔的多个值**（"172.22.0.2 172.22.0.2"），
#    传给 redis-cli -h 会变成 "Could not connect to Redis at 172.22.0.2 172.22.0.2:16379"。
#    `getent hosts node1 | awk '{print $1}'` 稳定返回单个 IP（实测一致）。
ANNOUNCE_IP="${HD_CLUSTER_IP:-$(getent hosts node1 | awk '{print $1}')}"
PORTS="16379 16380 16381"

# 每个节点 64MB 上限 —— 宿主只剩 ~1.7GB，不能让 Redis 吃光
MAXMEM=64mb

# cluster bus 端口 = 客户端端口 + 10000（Redis 默认约定）。
# ⚠️ 别把 bus 端口设成跟客户端端口一样（`--cluster-announce-bus-port "$p"`）：
#    那样 bus 和 client 抢同一个监听端口，节点之间没法正常走 cluster bus。
#    实测：bus==client 时三个节点各自成孤岛，cluster_size 一直是 1，组不成集群。

rc() { "$RC" -h "$ANNOUNCE_IP" -p "$1" -a "$PASS" --no-auth-warning "${@:2}"; }

start_nodes() {
  echo "=== 起 3 个 cluster-enabled 节点（announce-ip=$ANNOUNCE_IP）==="
  mkdir -p "$DATA"
  for p in $PORTS; do
    if rc "$p" PING 2>/dev/null | grep -q PONG; then
      echo "  端口 $p 已在跑，跳过"
      continue
    fi
    mkdir -p "$DATA/$p"
    "$RS" --port "$p" \
      --cluster-enabled yes \
      --cluster-config-file "$DATA/$p/nodes.conf" \
      --cluster-announce-ip "$ANNOUNCE_IP" \
      --cluster-announce-port "$p" \
      --cluster-announce-bus-port "$((p + 10000))" \
      --cluster-require-full-coverage no \
      --requirepass "$PASS" \
      --masterauth "$PASS" \
      --maxmemory $MAXMEM \
      --maxmemory-policy noeviction \
      --save '' \
      --appendonly no \
      --protected-mode no \
      --dir "$DATA/$p" \
      --daemonize yes \
      --logfile "$DATA/$p/redis.log"
    echo "  端口 $p 启动返回码 = $?"
  done
  sleep 3
  for p in $PORTS; do
    printf "  %s -> %s\n" "$p" "$(rc "$p" PING 2>&1 | head -1)"
  done
}

create_cluster() {
  echo "=== 组集群（3 master，0 副本）==="
  local args=""
  for p in $PORTS; do args="$args $ANNOUNCE_IP:$p"; done
  # ⚠️ `redis-cli --cluster create` 不接受 -a 给节点认证用；必须走 REDISCLI_AUTH 环境变量，
  #    否则第一次连接就 NOAUTH Authentication required.，集群根本组不起来（实测）。
  REDISCLI_AUTH="$PASS" "$RC" --cluster create $args --cluster-replicas 0 --cluster-yes 2>&1 | tail -20
  echo
  echo "=== 等 cluster_state:ok（刚组完的一瞬间还是 fail，要给它收敛的时间）==="
  local i st
  for i in 1 2 3 4 5 6 7 8 9 10; do
    st="$(rc 16379 CLUSTER INFO 2>/dev/null | grep -m1 '^cluster_state' | tr -d '\r' | cut -d: -f2)"
    echo "  尝试 $i: cluster_state=$st"
    [ "$st" = "ok" ] && break
    sleep 3
  done
  echo
  echo "=== 组完后检查 ==="
  for p in $PORTS; do
    echo "  --- $p ---"
    rc "$p" CLUSTER INFO 2>/dev/null | grep -E 'cluster_state|cluster_slots_assigned|cluster_size|cluster_known_nodes' | sed 's/^/    /'
  done
}

stop_cluster() {
  echo "=== 停掉并清干净 ==="
  for p in $PORTS; do
    rc "$p" SHUTDOWN NOSAVE 2>/dev/null
  done
  sleep 2
  # 兜底：按端口精确匹配（绝不用 pkill -f java）
  for p in $PORTS; do
    pkill -f "[-]redis-server \*:$p" 2>/dev/null || true
  done
  sleep 1
  rm -rf "$DATA"
  echo "  剩余 redis-server 进程："
  ps -eo pid,args 2>/dev/null | grep '[r]edis-server' | cut -c1-100 | sed 's/^/    /'
}

status() {
  echo "=== 集群状态 ==="
  for p in $PORTS; do
    echo "  --- $ANNOUNCE_IP:$p ---"
    rc "$p" CLUSTER INFO 2>/dev/null | grep -E 'cluster_state|cluster_slots_assigned|cluster_size' | sed 's/^/    /'
  done
  echo
  echo "=== CLUSTER NODES ==="
  rc 16379 CLUSTER NODES 2>/dev/null | sed 's/^/  /'
  echo
  echo "=== CLUSTER SLOTS ==="
  rc 16379 CLUSTER SLOTS 2>/dev/null | sed 's/^/  /'
}

case "${1:-start}" in
  start)  start_nodes; create_cluster ;;
  stop)   stop_cluster ;;
  status) status ;;
  *) echo "usage: $0 {start|stop|status}" >&2; exit 2 ;;
esac

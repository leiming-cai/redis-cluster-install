#!/bin/bash
# 从华盾 napstar2.0 安装包的 env/ 目录生成容器用的中间件配置。
# 只改「路径 / 守护方式 / 地址」三类，**不改语义**。
#
# 用法: prepare-configs.sh <安装包路径> <输出目录>
# 例:   prepare-configs.sh /pkg /repo/docker/hd-napstar/generated
set -euo pipefail
PKG="${1:?安装包路径}"
OUT="${2:?输出目录}"
mkdir -p "$OUT/redis" "$OUT/zookeeper" "$OUT/kafka" "$OUT/nacos"

REDIS_HOME=/opt/software/redis-8.10.0
ZK_HOME=/opt/software/apache-zookeeper-3.9.0-bin
KAFKA_HOME=/opt/software/kafka_2.13-2.8.0

# ---------------- Redis ----------------
# 安装包 redis.conf = 6389 (slave), redismaster.conf = 6379 (master)
# 改动: daemonize no / pidfile 各自端口 / 日志与 dir 路径改成实际安装路径
for pair in "redis.conf:6389" "redismaster.conf:6379"; do
  f="${pair%%:*}"; port="${pair##*:}"
  sed -e 's/^daemonize yes/daemonize no/' \
      -e "s#^pidfile /var/run/redis_[0-9]*\.pid#pidfile /var/run/redis_${port}.pid#" \
      -e "s#^logfile \"/opt/software/redis-8\.0\.2/logs/[0-9]*/redis\.log\"#logfile \"${REDIS_HOME}/logs/${port}/redis.log\"#" \
      -e "s#^dir /opt/software/redis-8\.0\.2/logs/[0-9]*/#dir ${REDIS_HOME}/logs/${port}/#" \
      "$PKG/env/redis/$f" > "$OUT/redis/$f"
done

# ---------------- ZooKeeper ----------------
# 安装包 zoo.cfg 里 server.1 写的是生产 IP 10.137.220.202 —— 换成容器别名。
# server.2 在安装包里是**注释掉的**（单机部署）；本套要 2 节点 ensemble → 追加一行。
sed -e "s#^dataDir=.*#dataDir=${ZK_HOME}/data#" \
    -e "s#^dataLogDir=.*#dataLogDir=${ZK_HOME}/logs#" \
    -e 's#^server\.1=.*#server.1=node1:2888:3888#' \
    "$PKG/env/zookeeper/zoo.cfg" > "$OUT/zookeeper/zoo.cfg"
# 追加 server.2（安装包里那行是注释掉的）
if ! grep -qE '^server\.2=' "$OUT/zookeeper/zoo.cfg"; then
  echo "server.2=node2:2888:3888" >> "$OUT/zookeeper/zoo.cfg"
fi

# ---------------- Kafka ----------------
# 安装包 server.properties: broker.id=755 / advertised 写生产 IP / zk.connect=127.0.0.1
# node1 用 755，node2 用 756 —— prepare 时按 node 编号生成两份
for node in 1 2; do
  if [ "$node" = "1" ]; then bid=755; else bid=756; fi
  sed -e "s/^broker\.id=.*/broker.id=${bid}/" \
      -e "s#^advertised\.listeners=.*#advertised.listeners=PLAINTEXT://node${node}:9092#" \
      -e 's#^zookeeper\.connect=.*#zookeeper.connect=node1:2181,node2:2181#' \
      -e "s#^log\.dirs=.*#log.dirs=${KAFKA_HOME}/data#" \
      -e 's#^offsets\.topic\.replication\.factor=.*#offsets.topic.replication.factor=2#' \
      -e 's#^transaction\.state\.log\.replication\.factor=.*#transaction.state.log.replication.factor=2#' \
      -e 's#^transaction\.state\.log\.min\.isr=.*#transaction.state.log.min.isr=2#' \
      "$PKG/env/kafka/server.properties" > "$OUT/kafka/server.properties.node$node"
done

# ---------------- Nacos ----------------
# 安装包用 install_nacos.sh 把 server.port 改成 18848；这里只记录来源
grep -n 'server.port' "$PKG/env/nacos/install_nacos.sh" > "$OUT/nacos/port-from-installpkg.txt" || true

echo "### generated configs in $OUT"
find "$OUT" -type f | sort

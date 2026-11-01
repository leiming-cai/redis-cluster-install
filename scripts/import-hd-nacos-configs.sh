#!/bin/bash
# 把安装包 env/nacos/nacos_config_export_postgresql-napstar2.0/ 导入 hd-node1 的 Nacos。
set -uo pipefail
TREE="${1:?导出包路径}"
NACOS="${NACOS:-http://127.0.0.1:18848/nacos}"
export CURL_HOME=${CURL_HOME:-}

post() {
  local group="$1" dataId="$2" file="$3"
  local resp
  resp=$(curl -s -m 20 -X POST "$NACOS/v1/cs/configs" \
      --data-urlencode "dataId=$dataId" \
      --data-urlencode "group=$group" \
      --data-urlencode "type=yaml" \
      --data-urlencode "content@$file")
  printf "  %-46s -> %s\n" "$group/$dataId" "$resp"
}

cd "$TREE" || exit 1
for f in $(find . -type f -name '*.yaml' | sort); do
  group=$(dirname "$f" | sed 's|^\./||')
  dataId=$(basename "$f")
  post "$group" "$dataId" "$f"
done
# 没有扩展名的那一个
post "MODELSERVER_GROUP" "icms-hisDataSend" "./MODELSERVER_GROUP/icms-hisDataSend"

echo "=== published configs (dataId list) ==="
curl -s -m 20 "$NACOS/v1/cs/configs?search=accurate&dataId=&group=&pageNo=1&pageSize=100" \
  | tr ',' '\n' | grep '"dataId"' | sed 's/.*"dataId":"\([^"]*\)".*/  \1/' | sort
echo "=== count ==="
curl -s -m 20 "$NACOS/v1/cs/configs?search=accurate&dataId=&group=&pageNo=1&pageSize=100" \
  | tr ',' '\n' | grep -c '"dataId"'

# ==============================================================
# 补齐安装包导包里缺的 3 个 dataId
#   ext_base.yaml / share_base.yaml / hisdataSend-ext.yaml
# 详见 docker/hd-napstar/NACOS-GAPS.md
#
# 模板来自镜像预置的门户版 ext_base / share_base（无扩展名），
# 但 datasource 改成华盾的 napstar 库 + 4 schema，PG 全走 node1
# （PG 只跑在 hd-node1；node2 是 ZK/Kafka 那个节点）。
# ==============================================================
echo "=== filling the 3 missing dataIds ==="

PG_URL_BASE="jdbc:postgresql://node1:5432/napstar?currentSchema="
read_cfg() {  # $1=dataId $2=group
  curl -s -m 20 -G "$NACOS/v1/cs/configs" --data-urlencode "dataId=$1" --data-urlencode "group=$2"
}

# ---- share_base.yaml ----
{
  echo "spring:"
  echo "  cloud:"
  echo "    config:"
  echo "      override-none: true"
  echo "      allow-override: true"
  echo "      override-system-properties: false"
  echo "  servlet:"
  echo "    multipart:"
  echo "      max-file-size: 200MB"
  echo "      max-request-size: 1000MB"
  echo "  datasource:"
  echo "    info:"
  echo "      url: ${PG_URL_BASE}info&stringtype=unspecified&characterEncoding=UTF-8"
  echo "      driver-class-name: org.postgresql.Driver"
  echo "      type: com.alibaba.druid.pool.DruidDataSource"
  echo "      username: info"
  echo "      password: info"
  echo "    sac:"
  echo "      url: ${PG_URL_BASE}sac&stringtype=unspecified&characterEncoding=UTF-8"
  echo "      driver-class-name: org.postgresql.Driver"
  echo "      type: com.alibaba.druid.pool.DruidDataSource"
  echo "      username: sac"
  echo "      password: sac"
  echo "    his:"
  echo "      url: ${PG_URL_BASE}hds&stringtype=unspecified&characterEncoding=UTF-8"
  echo "      driver-class-name: org.postgresql.Driver"
  echo "      type: com.alibaba.druid.pool.DruidDataSource"
  echo "      username: hds"
  echo "      password: hds"
  echo "    cmt:"
  echo "      url: ${PG_URL_BASE}cmt&stringtype=unspecified&characterEncoding=UTF-8"
  echo "      driver-class-name: org.postgresql.Driver"
  echo "      type: com.alibaba.druid.pool.DruidDataSource"
  echo "      username: cmt"
  echo "      password: cmt"
  echo "  kafka:"
  echo "    bootstrap-servers: node1:9092,node2:9092"
  echo "    producer:"
  echo "      retries: 6"
  echo "      batch-size: 20"
  echo "      buffer-memory: 33554432"
  echo "      acks: all"
  echo "      properties:"
  echo "        linger.ms: 1"
  echo "        enable.idempotence: true"
  echo "    listener:"
  echo "      type: batch"
  echo "      concurrency: 1"
  echo "    consumer:"
  echo "      bootstrap-servers: node1:9092,node2:9092"
  echo "      group-id: sac"
  echo "      enable-auto-commit: false"
  echo "      auto-offset-reset: latest"
  echo "      max-poll-records: 100000"
  echo "mybatis:"
  echo "  configuration:"
  echo "    map-underscore-to-camel-case: true"
  echo "pagehelper:"
  echo "  helper-dialect: postgresql"
  echo "  reasonable: true"
  echo "  support-methods-arguments: true"
  echo "  params: count=countSql"
} > /tmp/hd-share_base.yaml
post "DEFAULT_GROUP" "share_base.yaml" /tmp/hd-share_base.yaml

# ---- ext_base.yaml ----
# 模板取镜像预置的 ext_base（门户版），但：
#   - datasource 换成华盾的（share_base 里已有，这里不重复定义）
#   - 删掉门户的 shiroconfig（那是门户的权限表）
#   - oms 指向 node1:6379，redisMode standalone
read_cfg "ext_base" "DEFAULT_GROUP" > /tmp/hd-ext-base-src.yaml 2>/dev/null || true
{
  echo "hisdataproducer:"
  echo "  path: /home/cps/CPS_Project/linx/data/db_rep/server1/hts/bak/"
  echo "  bak: /home/cps/CPS_Project/linx/data/db_rep/server1/hts/consumer/"
  echo "  thread-pool-size: 16"
  echo "  delTime: 1"
  echo "hisDataSendArea:"
  echo "  impl: ningxia"
  echo "oms:"
  echo "  redisMode: standalone"
  echo "  database: 0"
  echo "  hostname: node1"
  echo "  port: 6379"
  echo "  password: sac888"
  echo "  timeout: 5000"
  echo "orm:"
  echo "  database: pg"
  echo "  datasource: sac"
  echo "task:"
  echo "  url: http://node1:27000"
} > /tmp/hd-ext_base.yaml
post "DEFAULT_GROUP" "ext_base.yaml" /tmp/hd-ext_base.yaml

# ---- hisdataSend-ext.yaml ----
# hisDataSend 与 hisDataProducer 共用一套 hisdata 配置，但**键名不同**：
# bootstrap.yml 读的是 `hisDataSend.thread-pool-size`，
# 所以两个键都要有（实测：只给 hisdataproducer 会报
#   Could not resolve placeholder 'hisDataSend.thread-pool-size'）。
cat > /tmp/hd-hisdataSend-ext.yaml <<'EOF'
hisDataSend:
  partition-path: /home
  diskcheck-interval-minutes: 5
  threshold-percentage: 95
  low-threshold-percentage: 90
  delete-nums: 300
  disk-check-path: /home/cps/CPS_Project/linx/data/db_rep/web/hts/out/
  csv-path: /home/cps/CPS_Project/linx/data/db_rep/web/hts/
  history-path: /home/cps/CPS_Project/linx/data/db_rep/web/hts/history/
  history-time-minutes: 259200
  core-pool-size: 16
  queue-capacity: 200
  parase-data-queue-size: 100
  process-count: 4
  page-size: 500000
  # ⚠️ hisDataSend 独有（源码 JsonDataSendServiceImpl 读 ${hisDataSend.thread-pool-size}）
  #    hisdataproducer 那份没有这个键 -> 少了它就
  #    "Could not resolve placeholder 'hisDataSend.thread-pool-size'"
  thread-pool-size: 16
hisdataproducer:
  partition-path: /home
  diskcheck-interval-minutes: 5
  threshold-percentage: 95
  low-threshold-percentage: 90
  delete-nums: 300
  disk-check-path: /home/cps/CPS_Project/linx/data/db_rep/web/hts/out/
  csv-path: /home/cps/CPS_Project/linx/data/db_rep/web/hts/
  history-path: /home/cps/CPS_Project/linx/data/db_rep/web/hts/history/
  history-time-minutes: 259200
  core-pool-size: 16
  queue-capacity: 300
  parase-data-queue-size: 100
  process-count: 4
  page-size: 500000
  thread-pool-size: 16
EOF
post "DEFAULT_GROUP" "hisdataSend-ext.yaml" /tmp/hd-hisdataSend-ext.yaml

echo "=== final count ==="
curl -s -m 20 "$NACOS/v1/cs/configs?search=accurate&dataId=&group=&pageNo=1&pageSize=100" \
  | tr ',' '\n' | grep -c '"dataId"'

# ==============================================================
# 把所有指向 node2:5432 的 PG URL 改成 node1:5432
#
# 原因: PG 只跑在 hd-node1；hd-node2 是 ZK/Kafka 那个节点。
# 安装包的 icms-controller.yaml / napstarweb-controller.yaml 里
# sac / cmt / hds 三个 datasource 写的是 node2:5432 ->
#   PSQLException: Connection to node2:5432 refused（实测）
# ==============================================================
echo "=== fixing node2:5432 -> node1:5432 ==="
fix_node2() {
  local dataId="$1" group="$2"
  local body new resp back
  body=$(curl -s -m 20 -G "$NACOS/v1/cs/configs" --data-urlencode "dataId=$dataId" --data-urlencode "group=$group")
  if [ -z "$body" ] || [ "$body" = "config data not exist" ]; then
    echo "  $group/$dataId : 不存在，跳过"; return
  fi
  if ! echo "$body" | grep -q 'node2:5432'; then
    echo "  $group/$dataId : 无 node2:5432，跳过"; return
  fi
  new=$(printf '%s' "$body" | sed 's#node2:5432#node1:5432#g')
  printf '%s' "$new" > /tmp/hd-fix.yaml
  resp=$(curl -s -m 20 -X POST "$NACOS/v1/cs/configs" \
    --data-urlencode "dataId=$dataId" --data-urlencode "group=$group" \
    --data-urlencode "type=yaml" --data-urlencode "content@/tmp/hd-fix.yaml")
  back=$(curl -s -m 20 -G "$NACOS/v1/cs/configs" --data-urlencode "dataId=$dataId" --data-urlencode "group=$group")
  if echo "$back" | grep -q 'node2:5432'; then
    echo "  $group/$dataId : ⚠️ 仍然有 node2:5432"
  else
    echo "  $group/$dataId : ✅ 已改为 node1:5432"
  fi
}
fix_node2 "napstarweb-controller.yaml" "NAPSTARWEB_GROUP"
fix_node2 "scheviewer.yaml" "NAPSTARWEB_GROUP"
fix_node2 "icms-controller.yaml" "MODELSERVER_GROUP"
fix_node2 "icms-real-controller.yaml" "MODELSERVER_GROUP"
fix_node2 "icms-rtdataconsumer.yaml" "MODELSERVER_GROUP"
fix_node2 "icms-commitDataIncreProducer.yaml" "MODELSERVER_GROUP"
fix_node2 "icms-hisDataProducer.yaml" "MODELSERVER_GROUP"
fix_node2 "icms-hisDataSend" "MODELSERVER_GROUP"
fix_node2 "share_base.yaml" "DEFAULT_GROUP"
fix_node2 "ext_base.yaml" "DEFAULT_GROUP"

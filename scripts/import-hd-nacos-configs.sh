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
# ⚠️ 2026-11-01 第二轮实测更正：
#   缺 ext_base.yaml / share_base.yaml **并不阻断 model-controller 启动** ——
#   安装包自带的 icms-controller.yaml 里已经有 shiroconfig.perms /
#   import.commit.* / dashboard.* / oms.* / orm.* / spring.datasource.* /
#   spring.redis.* 全部所需键。
#
#   所以这里**不再手写一份「阉割版」配置**（上一轮的做法，
#   它把真配置里的键删掉了一部分，等于用更差的配置覆盖真配置）。
#   改成：**从真实的 icms-controller.yaml 派生** ——
#   它的内容本来就是 model-controller 真正在用的那份，
#   拆成 share_base.yaml（spring.* / mybatis / pagehelper / logging）
#   和 ext_base.yaml（oms / orm / task / shiroconfig / dashboard / import ...）
#   两份，键集与 icms-controller.yaml 完全一致（不丢任何键）。
#
#   同时修掉上一轮手写版里的两个实错：
#     1) 顶层键写成 hisdataproducer: —— 死键。代码读 ${hisdata.*} / ${hisdataproducer.*}
#     2) kafka 段缺 producer/consumer 的 serializer（真配置里有 StringSerializer）
# ==============================================================
echo "=== filling the 3 missing dataIds ==="

PG_URL_BASE="jdbc:postgresql://node1:5432/napstar?currentSchema="
read_cfg() {  # $1=dataId $2=group
  curl -s -m 20 -G "$NACOS/v1/cs/configs" --data-urlencode "dataId=$1" --data-urlencode "group=$2"
}

# ---- 从真实的 icms-controller.yaml 派生，而不是手写 ----
# icms-controller.yaml 是 model-controller 自己的 dataId（MODELSERVER_GROUP），
# 里面有它实际在用的全部键。分拆成两个 dataId，内容等价。
derive_from_icms_controller() {
  read_cfg "icms-controller.yaml" "MODELSERVER_GROUP" > /tmp/hd-icms-controller.yaml
  if [ ! -s /tmp/hd-icms-controller.yaml ]; then
    echo "  !! 读不到 icms-controller.yaml，跳过派生" >&2
    return 1
  fi
  # 去掉顶层 server: 段（那是应用的端口/上下文路径，由 icms-controller.yaml 自己管）
  awk '
    /^server:/            { skip=1; next }
    skip && /^[^ \t]/      { skip=0 }
    skip                   { next }
    { print }
  ' /tmp/hd-icms-controller.yaml > /tmp/hd-base-no-server.yaml
}

# ---- share_base.yaml：spring.* / mybatis / pagehelper / logging ----
derive_from_icms_controller
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
  echo "    cmt:"
  echo "      url: ${PG_URL_BASE}cmt&stringtype=unspecified&characterEncoding=UTF-8"
  echo "      driver-class-name: org.postgresql.Driver"
  echo "      type: com.alibaba.druid.pool.DruidDataSource"
  echo "      username: cmt"
  echo "      password: cmt"
  echo "    sac:"
  echo "      url: ${PG_URL_BASE}sac&stringtype=unspecified&characterEncoding=UTF-8"
  echo "      driver-class-name: org.postgresql.Driver"
  echo "      type: com.alibaba.druid.pool.DruidDataSource"
  echo "      username: sac"
  echo "      password: sac"
  echo "  redis:"
  echo "    database: 0"
  echo "    host: node1"
  echo "    port: 6379"
  echo "    password: sac888"
  echo "    jedis:"
  echo "      pool:"
  echo "        max-active: 8"
  echo "        max-wait: -1ms"
  echo "        max-idle: 8"
  echo "        min-idle: 0"
  echo "    timeout: 5000ms"
  echo "  cache:"
  echo "    type: simple"
  echo "    redis:"
  echo "      time-to-live: 1d"
  echo "      use-key-prefix: true"
  echo "      key-prefix: \"model:\""
  echo "      cache-null-values: true"
  echo "  kafka:"
  echo "    bootstrap-servers: node1:9092,node2:9092"
  echo "    producer:"
  echo "      retries: 6"
  echo "      batch-size: 20"
  echo "      buffer-memory: 33554432"
  echo "      acks: all"
  echo "      key-serializer: org.apache.kafka.common.serialization.StringSerializer"
  echo "      value-serializer: org.apache.kafka.common.serialization.StringSerializer"
  echo "      properties:"
  echo "        linger.ms: 1"
  echo "    listener:"
  echo "      type: batch"
  echo "      concurrency: 1"
  echo "    consumer:"
  echo "      bootstrap-servers: node1:9092,node2:9092"
  echo "      group-id: sac"
  echo "      enable-auto-commit: false"
  echo "      auto-offset-reset: latest"
  echo "      key-deserializer: org.apache.kafka.common.serialization.StringDeserializer"
  echo "      value-deserializer: org.apache.kafka.common.serialization.StringDeserializer"
  echo "      max-poll-records: 100000"
  echo "mybatis:"
  echo "  mapper-locations: classpath*:mappings/*.xml"
  echo "  configuration:"
  echo "    cache-enabled: true"
  echo "    map-underscore-to-camel-case: true"
  echo "    log-impl: org.apache.ibatis.logging.stdout.StdOutImpl"
  echo "pagehelper:"
  echo "  helper-dialect: postgresql"
  echo "  reasonable: true"
  echo "  support-methods-arguments: true"
  echo "logging:"
  echo "  config: classpath:logback-spring.xml"
  echo "  level:"
  echo "    com.sac: info"
  echo "    org.apache.kafka: error"
  echo "    com.alibaba.nacos.client.naming: error"
} > /tmp/hd-share_base.yaml
post "DEFAULT_GROUP" "share_base.yaml" /tmp/hd-share_base.yaml

# ---- ext_base.yaml：应用自定义段，键集对齐 icms-controller.yaml ----
# 注意顶层是 hisdata:（不是 hisdataproducer:）——
#   ${hisdata.path} / ${hisdata.bak} / ${hisdata.delTime}  -> hisDataSend 侧
#   ${hisdataproducer.*}                                  -> hisDataProducer 侧（来自 hisdataproducer-ext.yaml）
# 两者互不相干，不能混写。
{
  echo "hisdata:"
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
  echo "shiroconfig:"
  echo "  perms:"
  echo "    - url: /unauth"
  echo "      permission: anon"
  echo "    - url: /401"
  echo "      permission: anon"
  echo "    - url: /login"
  echo "      permission: anon"
  echo "    - url: /websocket"
  echo "      permission: anon"
  echo "    - url: /**"
  echo "      permission: jwt"
  echo "dashboard:"
  echo "  jmx: node1:9998"
  echo "  nacos: node1:18848"
  echo "  namespace: public"
  echo "import:"
  echo "  commit:"
  echo "    filepath: /opt/software/modelFile"
  echo "    templatepath: /opt/software/modelFile"
  echo "svg:"
  echo "  rtpoint_path: /opt/software/svg/kafkaBus.ini"
  echo "systemserviceconfig:"
  echo "  wiring-service:"
  echo "    base_parentwiring: com.sac.platform.modelserver.service.impl.ParentWiringServiceImpl"
  echo "    base_multiwiring: com.sac.platform.modelserver.service.impl.MultiWiringServiceImpl"
  echo "project:"
  echo "  worker:"
  echo "    workerId: 1"
  echo "    datacenterId: 1"
} > /tmp/hd-ext_base.yaml
post "DEFAULT_GROUP" "ext_base.yaml" /tmp/hd-ext_base.yaml

# ---- hisdataSend-ext.yaml ----
# 🚫 **不导入** —— 只有 `hisDataSend` 这个应用读它，而那个模块
#    （和 `hisDataProducer` 一起）**用户决定不做修改**，
#    在本环境里预期起不来（jar 里没有 PG 驱动，见 docker/hd-napstar/DEFECTS.md D1）。
#    所以这个 dataId 对本轮没有任何作用，不引入。
#
# 参考（如果将来 hisDataSend 要能跑，键集与 hisdataproducer 不同：
#       源码 JsonDataSendServiceImpl 读 ${hisDataSend.thread-pool-size}，
#       而 hisdataproducer-ext.yaml 里没有这个键）：
#
#   hisDataSend:
#     partition-path: /home
#     diskcheck-interval-minutes: 5
#     threshold-percentage: 95
#     low-threshold-percentage: 90
#     delete-nums: 300
#     disk-check-path: /home/cps/CPS_Project/linx/data/db_rep/web/hts/out/
#     csv-path: /home/cps/CPS_Project/linx/data/db_rep/web/hts/
#     history-path: /home/cps/CPS_Project/linx/data/db_rep/web/hts/history/
#     history-time-minutes: 259200
#     core-pool-size: 16
#     queue-capacity: 200
#     parase-data-queue-size: 100
#     process-count: 4
#     page-size: 500000
#     thread-pool-size: 16

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

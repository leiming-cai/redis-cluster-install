#!/bin/bash
# 在 hd-node1 容器内启动一批应用。
# 用法: start-hd-apps.sh <batch>   batch = 1 | 2 | all
#
# ⚠️ 本机只有 3.9GB 内存（门户容器已占 ~380MB）→ 必须分批。
#    批次之间只停 java 应用进程，**不动中间件**。
set -uo pipefail
BATCH="${1:-1}"
APP_DIR=/opt/napstar_app
JAVA=/opt/software/jdk-21.0.2/bin/java
LOG_DIR=/opt/hd/logs
mkdir -p "$LOG_DIR"

# ⚠️ 堆参数比生产小很多（本机 3.9GB，且要给中间件留位置）。
#    -Xmx192m 是能跑起来的下限；生产是 4G/2G。
JAVA_OPTS="-Xms64m -Xmx192m -server -XX:+UseG1GC -XX:MaxGCPauseMillis=20 -XX:InitiatingHeapOccupancyPercent=35 -XX:MaxMetaspaceSize=160m -Dfile.encoding=UTF-8"

# ---------------------------------------------------------------
# Redis 集群端点 —— **一次性**算出来，不是每个应用算一次。
# 这是**环境的属性**，不是应用的属性。
# ---------------------------------------------------------------
# ⚠️ 不能用 `hostname -i`：它返回**空格分隔的多个值**
#    （"172.22.0.2 172.22.0.2"），传给 redis-cli -h 会变成
#    "Could not connect to Redis at 172.22.0.2 172.22.0.2:16379"。
# ⚠️ `awk '{print $1}'` 也不行：它打印**每一行**的第一个字段，
#    多行输出（getent ahosts node1 在这台机器上就是 3 行 STREAM/DGRAM/RAW）
#    会得到多个 IP -> 命令行被拆开 -> 集群配置静默写错。
#    `awk 'NF{print $1; exit}'` 只取第一个非空行。
#    三个脚本（start-hd-apps.sh / hd-redis-cluster.sh / hd-cluster-verify.sh）
#    必须用**同一种**写法，否则 IP 推导会分叉。
#
# ⚠️ 用 `${VAR-...}`（只认**没设**）而不是 `${VAR:-...}`（没设**或**空串都算）：
#    显式设了空值是一种"我以为配了"的错误状态，应该报错，
#    而不是悄悄回退到 getent 的结果 —— 那会让操作的人以为设成功了。
if [ -n "${HD_CLUSTER_IP+set}" ]; then
  CLUSTER_IP="$HD_CLUSTER_IP"
else
  CLUSTER_IP="$(getent hosts node1 | awk 'NF{print $1; exit}')"
fi
# ⚠️ 密码必须跟 hd-redis-cluster.sh 的 HD_CLUSTER_PASS **完全一致** ——
#    这是两个文件里各自独立的默认值，改一个不改另一个就会分叉，
#    分叉的后果是 NOAUTH —— 正是这个开关本来要解决的那类坑。
if [ -n "${HD_CLUSTER_PASS+set}" ]; then
  CLUSTER_PASS="$HD_CLUSTER_PASS"
else
  CLUSTER_PASS="HdClusterPw2026"
fi

# 集群地址必须是**单个** IP：多个值会在命令行里被拆成散落的参数，
# 既污染集群配置，又给 JVM 塞了莫名其妙的额外参数。
case "$CLUSTER_IP" in
  ''|*' '*|*$'\n'*|*[!0-9.]*)
    echo "!! 容器 IP 解析失败或含多个值: '$CLUSTER_IP'" >&2
    echo "   （getent hosts node1 的输出或 HD_CLUSTER_IP 有问题）" >&2
    exit 1
    ;;
esac

# ⚠️ 密码不能含空白：命令行参数是按空白切分的，
#    "my pass" 会被切成 "--oms.password=my" 和 "pass" 两个 argv ——
#    前者让应用拿到**错的**密码（NOAUTH），后者被静默吞掉。
#    操作的人会看到一个他"设过了"的密码却报认证失败，极难排查。
# ⚠️ **空密码也要拒**：`*[[:space:]]*` 要求**至少一个**空白字符，
#    空串一个都没有 → 守卫漏掉 → 密码变成空的 → 应用带着空密码去连 ->
#    启动等 60 秒，然后报一个莫名其妙的 NOAUTH。
#    显式设成空值跟 IP 一样是"我以为配了"的错误状态，应该当场报错。
case "$CLUSTER_PASS" in
  '')
    echo "!! HD_CLUSTER_PASS 是空的 —— 这是配置错误，不是'用默认值'" >&2
    exit 1
    ;;
  *[[:space:]]*)
    echo "!! HD_CLUSTER_PASS 里有空白字符，不能放进命令行" >&2
    exit 1
    ;;
esac

# 停止上一批：按 jar 名匹配，**绝不用 pkill -f java**（会杀掉中间件的 Kafka/ZK/Nacos）
# ⚠️ hisDataProducer / hisDataSend 仍列在停止名单里 —— 万一之前跑起来了要能停掉。
#    但**不启动**它们（见 BATCH2 的注释）。
APP_JARS="web-controller|realalarmconsumer|realalarmproducer|rtdata-consumer|realserver-conntroller|model-controller|commitDataIncreProducer|hisDataProducer|hisDataSend|transformNapstarModel|sche-viewer-server"
stop_apps() {
  pkill -f "[-]jar .*(${APP_JARS}).*\.jar" 2>/dev/null || true
  sleep 3
}

start_one() {
  local name="$1" jar="$2"
  if [ ! -f "$APP_DIR/$jar" ]; then echo "  SKIP $name (no $jar)"; return; fi
  # ⚠️ 打印这个 jar 的指纹 —— D8 的教训：「jar 文件换回」≠「运行中的 JVM 换回」。
  #    每一轮回归都必须能回答「这个 app 是用哪份 jar、什么时候的、怎么起来的」。
  #    md5 用来认出是哪个构建产物；mtime 用来认出是不是刚换的。
  if [ -f "$APP_DIR/$jar" ]; then
    echo "    jar  : $APP_DIR/$jar"
    echo "    md5  : $(md5sum "$APP_DIR/$jar" 2>/dev/null | cut -d' ' -f1)"
    echo "    mtime: $(stat -c '%y' "$APP_DIR/$jar" 2>/dev/null)"
  fi
  echo "  starting $name ($jar)"
  cd "$APP_DIR" || return
  # ⚠️ transformNapstarModel 的 application.yml（**打进了 jar 里**）把 sac/cmt
  #    两个 datasource 写成 node2:5432，但 PG 只跑在 hd-node1 ->
  #    "Connection to node2:5432 refused"。用命令行覆盖（Spring Boot 优先于 jar 内配置）。
  #
  # ⚠️ 这里用**数组**，不是字符串：数组里每个元素原样变成一个 argv，
  #    不会被空白切开、不会被通配符展开。
  #    （字符串 + 不加引号的 $extra 会把 "my pass" 这种密码切成两个参数。）
  local extra=()
  case "$name" in
    transformNapstarModel)
      extra=("--spring.datasource.sac.url=jdbc:postgresql://node1:5432/napstar?currentSchema=sac&stringtype=unspecified&characterEncoding=UTF-8"
             "--spring.datasource.cmt.url=jdbc:postgresql://node1:5432/napstar?currentSchema=cmt&stringtype=unspecified&characterEncoding=UTF-8")
      ;;
  esac

  # ⚠️ Redis 集群模式（HD_REDIS_CLUSTER=1 时生效）
  #
  # 📌 为什么用命令行覆盖，**不写 Nacos**：
  #    实测（docs/superpowers/specs/2026-11-01-hd-redis-cluster-test-design.md §2.2）：
  #      命令行 --oms.*      赢
  #      jar 内 application.yml  赢过 Nacos
  #      Nacos 的 oms:          输
  #    model-controller 的 jar 内 application.yml 硬编码了
  #    oms.redisMode=cluster + clusters:[127.0.0.1:6379] + password:""
  #    → Nacos 里的 oms 根本压不过它 → 只能走命令行。
  #    判据：启动日志里那行
  #      *** Using Redis Cluster with nodes: <列表> (connectTimeout=..., ...)
  #    列表就是生效值（**没有**结尾的 ***）。
  if [ "${HD_REDIS_CLUSTER:-0}" = "1" ]; then
    extra+=(--oms.redisMode=cluster
            "--oms.clusters[0]=$CLUSTER_IP:16379"
            "--oms.clusters[1]=$CLUSTER_IP:16380"
            "--oms.clusters[2]=$CLUSTER_IP:16381"
            "--oms.password=$CLUSTER_PASS")
  fi

  # ⚠️ "${extra[@]}" 必须**加引号**：`${extra[@]+"${extra[@]}"}` 是 set -u 下
  #    展开空数组的安全写法（bash < 4.4 直接 "${extra[@]}" 会报 unbound variable；
  #    这台机器是 bash 5.1，但安全写法在任何版本都对）。
  nohup "$JAVA" $JAVA_OPTS -jar "$jar" ${extra[@]+"${extra[@]}"} > "$LOG_DIR/$name.log" 2>&1 &
  echo "$!" > "$LOG_DIR/$name.pid"
  sleep 3
}

declare -A APPS=(
  [web-controller]="web-controller-3.0.0.jar"
  # 🚫 realserver **不启动** —— 用户说明它没用，不需要跑。
  #    只保留映射，供手动排查时用。
  [realserver]="realserver-conntroller-3.0.0.jar"
  [model-controller]="model-controller-3.0.0.jar"
  [rtdata-consumer]="rtdata-consumer-3.0.0.jar"
  [commitDataIncreProducer]="commitDataIncreProducer-3.0.0.jar"
  [realalarmproducer]="realalarmproducer-3.0.0.jar"
  [realalarmconsumer]="realalarmconsumer-3.0.0.jar"
  # 🚫 hisDataProducer / hisDataSend **不启动** —— 用户决定这两个模块不做修改，
  #    它们的 jar 里没有 PG 驱动（docker/hd-napstar/DEFECTS.md D1）→ 预期起不来。
  #    这里只保留映射，供手动排查时用。
  [hisDataProducer]="hisDataProducer-3.2.3.jar"
  [hisDataSend]="hisDataSend-3.2.3.jar"
  [transformNapstarModel]="transformNapstarModel-3.0.0.jar"
  [sche-viewer-server]="sche-viewer-server-3.0.0.jar"
)

BATCH1="web-controller realalarmconsumer rtdata-consumer"
# 🚫 realserver 不在这里 —— 用户说明它没用，不需要启动
BATCH1B="model-controller"
BATCH2="commitDataIncreProducer realalarmproducer transformNapstarModel sche-viewer-server"

case "$BATCH" in
  1) LIST="$BATCH1";;
  1b) LIST="$BATCH1B";;
  2) LIST="$BATCH2";;
  all) LIST="$BATCH1 $BATCH1B $BATCH2";;
  *) echo "batch must be 1|1b|2|all"; exit 2;;
esac

# ⚠️ 每次运行都把 Redis 模式**喊出来** —— 别让操作的人猜。
#    不同 jar 的 oms: 块不一样（model-controller 是 cluster+127.0.0.1:6379，
#    realalarmconsumer 是 standalone+node1:6379，web-controller / rtdata-consumer
#    干脆没有 oms: 块），所以"这次到底走的哪条路"不是脚本能替他们决定的。
if [ "${HD_REDIS_CLUSTER:-0}" = "1" ]; then
  echo "=== Redis 模式: CLUSTER (命令行覆盖 oms.*) ==="
  echo "    集群端点: $CLUSTER_IP:16379,$CLUSTER_IP:16380,$CLUSTER_IP:16381"
else
  echo "=== Redis 模式: 默认（走 jar/Nacos 自己的 oms.*）==="
  # 📌 交付树的三个 app 的 application.yml 里 oms: 块是**注释着的**
  #    （web-controller:108 / modelserver/controller:92 / rtdata-consumer:43）
  #    → jar 不覆盖 Nacos → Nacos 的 oms: 生效 → node1:6379 + sac888（standalone）。
  # 📌 只有**门户树**编出来的 jar 才把 oms: 固化成 cluster+127.0.0.1:6379+空密码
  #    → 那种 jar 在这个环境里起不来（NOAUTH）。本仓库部署的 jar 来自交付树。
  echo "    ℹ️ 交付树的 jar 里 oms: 是注释的 → 生效值来自 Nacos（standalone node1:6379）。"
fi

echo "=== stopping any running app from a previous batch ==="
stop_apps

# ⚠️ 必须等 Nacos 完全就绪（HTTP + gRPC 19848）再起应用。
#    否则应用在 Nacos 启动期间注册服务 -> 'Failed to start bean webServerStartStop'
#    -> 'Client not connected, current status:STARTING'（实测踩过）。
echo "=== waiting for Nacos (http 18848 + grpc 19848) ==="
for i in $(seq 1 60); do
  http=$(curl -s -m 5 -o /dev/null -w "%{http_code}" http://127.0.0.1:18848/nacos/v1/console/health/readiness 2>/dev/null)
  grpc_open=$(timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/19848' 2>/dev/null && echo yes || echo no)
  if [ "$http" = "200" ] && [ "$grpc_open" = "yes" ]; then
    echo "  Nacos ready (http=$http grpc=$grpc_open)"
    break
  fi
  sleep 2
done

echo "=== starting batch $BATCH ==="
for name in $LIST; do
  start_one "$name" "${APPS[$name]}"
done

echo "=== waiting 60s for the apps to come up ==="
sleep 60

echo "=== listening app ports ==="
ss -lnt 2>/dev/null | grep -E ':(8090|8091|8092|8096|8097|8099|8199|8991|8992|27000|8080)\b' | awk '{print "  "$4}' | sort -u

echo "=== running app jvms ==="
ps -eo pid,args 2>/dev/null | grep -E '[-]jar .*(web-controller|realalarm|rtdata|realserver|model-controller|commitData|hisData|transformNapstar|sche-viewer)' \
  | sed 's/\(-jar [^ ]*\).*/\1/' | sed 's/^/  /'

echo "=== per-app startup result ==="
# ⚠️ 失败计数 -> 退出码。
#    脚本以前**永远**返回 0，哪怕整批应用全挂了 —— 那等于骗人。
failed=0
for name in $LIST; do
  if grep -qE 'Started .* in .* seconds' "$LOG_DIR/$name.log" 2>/dev/null; then
    echo "  OK       $name  $(grep -oE 'Started .* in .* seconds' "$LOG_DIR/$name.log" | tail -1)"
  elif grep -qE 'APPLICATION FAILED TO START|Application run failed' "$LOG_DIR/$name.log" 2>/dev/null; then
    # ⚠️ 两种失败串都要认：
    #    'APPLICATION FAILED TO START' 是 Spring 的标准文案，
    #    'Application run failed' 是这批 jar 实际用的文案。
    #    实测（容器里所有 app 日志）：**零**个日志用了前者，
    #    所有真实失败（commitDataIncreProducer / hisDataProducer / hisDataSend / cd-a）
    #    用的都是后者 —— 只认前者的分支等于死代码，
    #    失败的应用会被报成 UNKNOWN("还在启动")，最误导。
    #    这里把根因（Caused by: ...）带出来。
    failed=$((failed+1))
    echo "  FAILED   $name  $(grep -oE 'Caused by: .*' "$LOG_DIR/$name.log" | tail -1)"
  else
    echo "  UNKNOWN  $name  (no 'Started ... in ... seconds' yet)"
  fi
done

if [ "$failed" -gt 0 ]; then
  echo "!! $failed 个应用启动失败（详见 /opt/hd/logs/<应用名>.log）" >&2
  exit 1
fi
exit 0

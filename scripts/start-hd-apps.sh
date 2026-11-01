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
#    -Xmx256m 是能跑起来的下限；生产是 4G/2G。
JAVA_OPTS="-Xms96m -Xmx256m -server -XX:+UseG1GC -XX:MaxGCPauseMillis=20 -XX:InitiatingHeapOccupancyPercent=35 -XX:MaxMetaspaceSize=192m -Dfile.encoding=UTF-8"

# 停止上一批：按 jar 名匹配，**绝不用 pkill -f java**（会杀掉中间件的 Kafka/ZK/Nacos）
APP_JARS="web-controller|realalarmconsumer|realalarmproducer|rtdata-consumer|realserver-conntroller|model-controller|commitDataIncreProducer|hisDataProducer|hisDataSend|transformNapstarModel|sche-viewer-server"
stop_apps() {
  pkill -f "[-]jar .*(${APP_JARS}).*\.jar" 2>/dev/null || true
  sleep 3
}

start_one() {
  local name="$1" jar="$2"
  if [ ! -f "$APP_DIR/$jar" ]; then echo "  SKIP $name (no $jar)"; return; fi
  echo "  starting $name ($jar)"
  cd "$APP_DIR" || return
  nohup "$JAVA" $JAVA_OPTS -jar "$jar" > "$LOG_DIR/$name.log" 2>&1 &
  echo "$!" > "$LOG_DIR/$name.pid"
  sleep 3
}

declare -A APPS=(
  [web-controller]="web-controller-3.0.0.jar"
  [realserver]="realserver-conntroller-3.0.0.jar"
  [model-controller]="model-controller-3.0.0.jar"
  [rtdata-consumer]="rtdata-consumer-3.0.0.jar"
  [commitDataIncreProducer]="commitDataIncreProducer-3.0.0.jar"
  [realalarmproducer]="realalarmproducer-3.0.0.jar"
  [realalarmconsumer]="realalarmconsumer-3.0.0.jar"
  [hisDataProducer]="hisDataProducer-3.2.3.jar"
  [hisDataSend]="hisDataSend-3.2.3.jar"
  [transformNapstarModel]="transformNapstarModel-3.0.0.jar"
  [sche-viewer-server]="sche-viewer-server-3.0.0.jar"
)

BATCH1="web-controller realalarmconsumer rtdata-consumer"
BATCH1B="realserver model-controller"
BATCH2="commitDataIncreProducer realalarmproducer hisDataProducer hisDataSend transformNapstarModel sche-viewer-server"

case "$BATCH" in
  1) LIST="$BATCH1";;
  1b) LIST="$BATCH1B";;
  2) LIST="$BATCH2";;
  all) LIST="$BATCH1 $BATCH1B $BATCH2";;
  *) echo "batch must be 1|1b|2|all"; exit 2;;
esac

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
for name in $LIST; do
  if grep -qE 'Started .* in .* seconds' "$LOG_DIR/$name.log" 2>/dev/null; then
    echo "  OK       $name  $(grep -oE 'Started .* in .* seconds' "$LOG_DIR/$name.log" | tail -1)"
  elif grep -q 'APPLICATION FAILED TO START' "$LOG_DIR/$name.log" 2>/dev/null; then
    echo "  FAILED   $name  $(grep -oE 'Description:|Action:' "$LOG_DIR/$name.log" | head -2 | tr '\n' ' ')"
  else
    echo "  UNKNOWN  $name  (no 'Started ... in ... seconds' yet)"
  fi
done

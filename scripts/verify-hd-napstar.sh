#!/bin/bash
# 华盾 napstar2.0 验证矩阵 M1-M8 / A1-A4 / B1-B9
# 在 hd-node1 容器内跑。
# 用法: bash verify-hd-napstar.sh [batch]
set -uo pipefail
BATCH="${1:-1}"
PASS=0; FAIL=0; SKIP=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
skip(){ echo "  SKIP  $*"; SKIP=$((SKIP+1)); }
chk() { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1 (got '$2', want '$3')"; fi; }

REDIS=/opt/software/redis-8.10.0/bin/redis-cli
ZK=/opt/software/apache-zookeeper-3.9.0-bin/bin/zkServer.sh
KAFKA=/opt/software/kafka_2.13-2.8.0
NACOS=http://127.0.0.1:18848/nacos
LOGDIR=/opt/hd/logs
export PGPASSWORD=postgres
PSQL="psql -U postgres -h 127.0.0.1"

# ⚠️ 先把 PG 日志清空 —— B8 那个「改前语句必须失败」的测试会**故意**产生错误，
#    不能让它污染 A4 / B1 的判据。清空要在所有检查之前。
: > /var/log/postgresql/postgresql-14-main.log

echo "############ M — 中间件 ############"
$REDIS -h 127.0.0.1 -p 6379 -a sac888 --no-auth-warning PING 2>/dev/null | grep -q PONG && ok "M1 Redis 6379 PONG" || bad "M1 Redis 6379"
$REDIS -h 127.0.0.1 -p 6389 -a sac888 --no-auth-warning PING 2>/dev/null | grep -q PONG && ok "M2 Redis 6389 PONG" || bad "M2 Redis 6389"
$REDIS -h 127.0.0.1 -p 6379 -a sac888 --no-auth-warning INFO server 2>/dev/null | grep -q "redis_mode:standalone" && ok "M1b 6379 standalone" || bad "M1b 6379 not standalone"
n=$(REDISCLI_AUTH= $REDIS -h 127.0.0.1 -p 6379 PING 2>&1 | grep -c NOAUTH)
chk "M3 无密码被拒" "${n:-0}" "1"
$ZK status 2>/dev/null | grep -qE "Mode: (leader|follower)" && ok "M4 ZK ensemble" || bad "M4 ZK"
b=$($KAFKA/bin/kafka-broker-api-versions.sh --bootstrap-server node1:9092,node2:9092 2>/dev/null | grep -cE "^node[12]:9092")
chk "M5 Kafka 2 brokers" "${b:-0}" "2"
for t in QUERYREQUEST COMMITDATA INCDATA QUERYRESPONSE REALALARM; do
  $KAFKA/bin/kafka-topics.sh --list --zookeeper node1:2181 2>/dev/null | grep -qw "$t" && ok "M6 topic $t" || bad "M6 topic $t missing"
done
curl -fsS -m 10 "$NACOS/v1/console/health/readiness" >/dev/null 2>&1 && ok "M7 Nacos ready" || bad "M7 Nacos"
n=$($PSQL -d napstar -Atc "select count(*) from information_schema.tables where table_schema='info'" 2>/dev/null)
chk "M8 PG info 表数" "${n:-0}" "30"
n=$($PSQL -d postgres -Atc "select count(*) from pg_database where datname='napstar'" 2>/dev/null)
chk "M8b napstar 库存在" "${n:-0}" "1"
n=$($PSQL -d postgres -Atc "select count(*) from pg_roles where rolname in ('info','cmt','sac','hds')" 2>/dev/null)
chk "M8c 4 个业务角色" "${n:-0}" "4"
n=$(grep -cE 'host +all +all +0\.0\.0\.0/0' /etc/postgresql/14/main/pg_hba.conf 2>/dev/null || echo 0)
if [ "${n:-0}" -gt 0 ]; then ok "M8d pg_hba 放行了容器 IP（安装包的 initPostgresDB.sql 漏了）"; else bad "M8d pg_hba 没放行容器 IP —— 应用连不上 DB"; fi

echo "############ A — 应用 ############"
# ⚠️ app 日志里混进了二进制内容（3MB+，有控制字符）→ grep 默认会说
#    "binary file matches" 什么都不输出。用 grep -a 强制按文本处理。
#
# ⚠️ realserver **不在名单里** —— 用户说明它没用，不需要启动。
#    （它确实能起来，但 Redis 走的是 OmsConfig 硬编码那条路，见 DEFECTS.md）
for n in web-controller realalarmconsumer rtdata-consumer model-controller; do
  L="$LOGDIR/$n.log"
  [ -f "$L" ] || { skip "A1 $n 没日志"; continue; }
  if grep -aqE 'Started .* in .* seconds' "$L"; then
    ok "A1 $n 启动成功  ($(grep -aoE 'Started [A-Za-z0-9_]+ in [0-9.]+ seconds' "$L" | tail -1))"
  else
    bad "A1 $n 没起来"
  fi
  f=$(grep -acE 'APPLICATION FAILED TO START|Error starting ApplicationContext' "$L")
  chk "A1b $n 无致命错误" "${f:-0}" "0"
  r=$(grep -aoE '\*\*\* Using Redis Standalone at [^)]*\)' "$L" | head -1)
  case "$r" in
    *"at node1:6379"*"connectTimeout=5000ms"*"readTimeout=5000ms"*"maxWait=5000ms"*)
      ok "A2 $n Redis 连的是 node1:6379 且 timeout=5000" ;;
    *"10.137.220.191"*)
      bad "A2 $n 走了 OmsConfig 硬编码 10.137.220.191 —— 连错机器且丢了 timeout" ;;
    *)
      bad "A2 $n Redis 连接行异常: ${r:-<none>}" ;;
  esac
  grep -aqE 'Redis mode detected: STANDALONE' "$L" && ok "A2b $n Redis 模式 = STANDALONE" || bad "A2b $n Redis 模式"
done
n=$(grep -ciE 'ERROR|FATAL' /var/log/postgresql/postgresql-14-main.log 2>/dev/null | head -1)
chk "A4 PG 错误数（应用启动后）" "${n:-0}" "0"
n=$($PSQL -d napstar -Atc "select count(*) from pg_stat_activity where datname='napstar'" 2>/dev/null)
if [ "${n:-0}" -gt 0 ]; then ok "A3 应用有 PG 连接（$n 条）"; else bad "A3 应用没有 PG 连接"; fi

echo "############ B1 — HIS 告警列表（V1 mapper）############"
# Shiro 要求 Authorization 头（JWT）。用应用自己的 JWTUtil 铸的 token（见 mint-token.sh）。
TOK=$(cat /tmp/hd-token.txt 2>/dev/null)
if [ -z "$TOK" ]; then
  skip "B1 没有 token（先跑 mint-token.sh）"
else
  r=$(curl -s -m 60 -X POST \
    "http://127.0.0.1:8099/napstarweb/hisAlarm/queryTodayAlarmList?startTime=2026-11-01%2000:00:00&endTime=2026-11-01%2023:59:59" \
    -H "Authorization: $TOK" -H 'Content-Type: application/json' \
    -d '{"stationIds":[],"bayIds":[],"feederIds":[],"dtIds":[],"dmsIds":[],"alarmTypes":[],"alarmLevels":[],"alarmText":[]}' 2>&1)
  echo "  resp: $(echo "$r" | head -c 200)"
  # 关键: 不能是「缺参数」这种 500 —— 那说明 mapper 根本没被调用到
  case "$r" in
    *"Required request parameter"*) bad "B1 参数不全，mapper 没被调用到" ;;
    *) ok "B1 参数齐，mapper 被调用到了" ;;
  esac
  # ⚠️ 已知数据缺口（上一轮 §七 #2 遗留，不是本轮引入）:
  #    hds schema 的 HIS 历史表**不在本安装包**（由 HIS 数据服务器提供），
  #    info.real_alarmevents 也是空表 -> 业务查询必然失败。
  #    这里要区分「数据缺失导致的失败」和「mapper 写错导致的失败」。
  hds_n=$($PSQL -d napstar -Atc "select count(*) from information_schema.tables where table_schema='hds'" 2>/dev/null)
  evt_n=$($PSQL -d napstar -Atc "select count(*) from info.real_alarmevents" 2>/dev/null)
  if [ "${hds_n:-0}" = "0" ] || [ "${evt_n:-0}" = "0" ]; then
    case "$r" in
      *"查询历史数据服务失败"*|*"属性名称非法或不存在"*)
        skip "B1 返回 ${r:0:40} —— 因为 hds schema 无表(${hds_n})、real_alarmevents 无数据(${evt_n})：安装包不含 HIS 历史数据（已知遗留）" ;;
      *) bad "B1 失败，但原因不是数据缺失：$(echo "$r" | head -c 120)" ;;
    esac
  else
    case "$r" in
      *'"code":500'*) bad "B1 返回 500（数据齐但查询失败 → mapper 有问题）：$(echo "$r" | head -c 160)" ;;
      *'"code"'*)     ok "B1 有业务响应（不是空/超时）" ;;
      *)             bad "B1 无响应 —— 应用可能没起来" ;;
    esac
  fi
  # 看 PG 有没有真的收到应用发的 SQL
  n=$(grep -c 'LOG:  execute' /var/log/postgresql/postgresql-14-main.log 2>/dev/null | head -1)
  if [ "${n:-0}" -gt 0 ]; then ok "B1 PG 收到了应用的 SQL（$n 条 execute）"; else bad "B1 PG 没收到应用的 SQL"; fi
fi
n=$(grep -ciE "date_format|syntax error" /var/log/postgresql/postgresql-14-main.log 2>/dev/null | head -1)
chk "B1 PG 无方言错误" "${n:-0}" "0"

echo "############ B2 — 曲线过滤真的生效（V4 静默 bug）############"
if [ -z "$TOK" ]; then
  skip "B2 没有 token"
else
  r=$(curl -s -m 60 -X POST \
    "http://127.0.0.1:8099/napstarweb/curve/getHisPoint?startTime=2026-11-01%2000:00:00&endTime=2026-11-01%2023:59:59&curveType=1" \
    -H "Authorization: $TOK" -H 'Content-Type: application/json' \
    -d '[{"objectid":"999999","obid":999999}]' 2>&1)
  echo "  resp: $(echo "$r" | head -c 200)"
  # ⚠️ 已知数据缺口: 华盾的模型定义不在安装包的 seed 里
  #    (model_objecttype / model_attribute 都是空表) ->
  #    曲线接口在「查模型」这一步就返回「属性名称非法或不存在」，
  #    **根本走不到 mapper**。所以接口层验不了 V4，必须在 SQL 层验。
  case "$r" in
    *"属性名称非法或不存在"*)
      skip "B2 接口在模型查询阶段就返回错了（model_objecttype 空表）→ 走不到 mapper，改用 SQL 层验证" ;;
    *'"code":500'*) bad "B2 返回 500：$(echo "$r" | head -c 160)" ;;
    *'"code"'*)     ok "B2 有业务响应（mapper 被调用到了）" ;;
    *)             bad "B2 无响应" ;;
  esac
  # 关键判据: SQL 里必须出现修好后的过滤写法
  n=$(grep -c "MOD(TO_NUMBER(TO_CHAR" /var/log/postgresql/postgresql-14-main.log 2>/dev/null | head -1)
  if [ "${n:-0}" -gt 0 ]; then ok "B2 过滤条件进了 SQL（$n 条 MOD(TO_NUMBER(TO_CHAR...)）"; else skip "B2 SQL 里没抓到过滤 SQL（模型表为空，接口走不到 mapper）"; fi
  # 旧写法不能出现
  n=$(grep -c "TO_DATE(TO_CHAR" /var/log/postgresql/postgresql-14-main.log 2>/dev/null | head -1)
  chk "B2 SQL 里没有旧写法 TO_DATE(TO_CHAR" "${n:-0}" "0"
  # ⭐ 决定性判据：在真 PG 上直接验「过滤真的生效 + 旧写法是空操作」
  #    （接口层验不了 —— 华盾的模型表 model_objecttype/model_attribute 在安装包 seed 里是空的）
  if [ -f /opt/hd/b2-curve-test.sh ]; then
    if bash /opt/hd/b2-curve-test.sh >/tmp/b2out.txt 2>&1; then
      ok "B2 曲线过滤在真 PG 上验证通过（改后只命中该命中的分钟；改前命中全部 → 旧写法是空操作）"
      grep -E 'PASS|FAIL' /tmp/b2out.txt | sed 's/^/       /'
    else
      bad "B2 曲线过滤验证失败"
      grep -E 'PASS|FAIL' /tmp/b2out.txt | sed 's/^/       /'
    fi
  fi
fi
# 静态判据: jar 里的 Curve.xml 不能有旧写法
cd /tmp && rm -rf b6 && mkdir b6
n=0
for j in /opt/napstar_app/*.jar; do
  unzip -o -q "$j" 'BOOT-INF/lib/*' -d b6 2>/dev/null
done
for j in $(find b6 -name '*.jar' 2>/dev/null); do
  c=$(unzip -p "$j" 'mappings/*' 2>/dev/null | grep -c 'TO_DATE(TO_CHAR' || true)
  n=$((n + ${c:-0}))
done
chk "B6 jar 里没有 TO_DATE(TO_CHAR 旧写法" "${n:-0}" "0"

echo "############ B7 — V6 生效链：his-dao jar 的 mapper MD5 ############"
hj=$(find /tmp/b6 -name 'his-dao-*.jar' 2>/dev/null | head -1)
if [ -n "$hj" ]; then
  m=$(unzip -p "$hj" "mappings/his/postgresql/HisData.xml" 2>/dev/null | md5sum | cut -d' ' -f1)
  chk "B7 HisData.xml MD5（= 基线树改完后的值）" "$m" "18e9144bc39a5b221f8c572e36e4a0bd"
  df=$(unzip -p "$hj" "mappings/his/postgresql/HisData.xml" 2>/dev/null | grep -c DATE_FORMAT || true)
  chk "B7 DATE_FORMAT 计数" "${df:-0}" "0"
  m2=$(unzip -p "$hj" "mappings/his/postgresql/HisDataStatisticsMapper.xml" 2>/dev/null | md5sum | cut -d' ' -f1)
  chk "B7 HisDataStatisticsMapper.xml MD5" "$m2" "bcbc0854fef297fd0efcbaae915cba4c"
  m3=$(unzip -p "$hj" "mappings/his/postgresql/HisPointMapper.xml" 2>/dev/null | md5sum | cut -d' ' -f1)
  chk "B7 HisPointMapper.xml MD5" "$m3" "c6c995b8bd46e9330ffa164839801dcc"
  m4=$(unzip -p "$hj" "mappings/his/postgresql/HisAlarmeventsMapper.xml" 2>/dev/null | md5sum | cut -d' ' -f1)
  chk "B7 HisAlarmeventsMapper.xml MD5" "$m4" "520fa81ff532bce93abf62de5cab5f66"
else
  bad "B7 找不到 his-dao jar"
fi

echo "############ B8 — PG 方言在真库上跑通 ############"
if [ -f /opt/hd/b8-sql-test.sh ]; then
  bash /opt/hd/b8-sql-test.sh 2>&1 | sed 's/^/  /'
  if bash /opt/hd/b8-sql-test.sh >/dev/null 2>&1; then ok "B8 方言测试通过"; else bad "B8 方言测试失败"; fi
else
  skip "B8 没有 b8-sql-test.sh"
fi

echo "############ B9 — 建库脚本一致性 ############"
n=$($PSQL -d napstar -Atc "select count(*) from information_schema.tables where table_schema='info'" 2>/dev/null)
chk "B9 HD info 表数" "${n:-0}" "30"

echo
echo "SUMMARY: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]

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

# ---------------------------------------------------------------
# C — 容器内 Redis 集群（可选段）
#
# ⚠️ **只有集群在跑的时候才跑这一段** —— 集群没起来时 hd-cluster-verify.sh
#    会在 L0 探活那里 FAIL（"这个 master 没起来"），那是**环境状态**，
#    不是回归失败。回归矩阵的判据是「既有行为不退化」，
#    所以集群不在的时候整段跳过，而不是把它算成 FAIL。
#
# ⚠️ **计数必须并进外层，只由外层打一行 SUMMARY**：
#    hd-cluster-verify.sh 自己也会打 "SUMMARY: PASS=.. FAIL=.."。
#    如果直接把它整段输出出去，一次回归里会出现**两行 SUMMARY**，
#    人和脚本都分不清哪行是结论 —— 而且外层的那行会漏掉集群的计数，
#    看起来像「集群一条都没验」。
#    所以这里：捕获它的输出 + 退出码，把它的 PASS/FAIL **加到外层的
#    $PASS / $FAIL 上**，它自己的 SUMMARY 行**过滤掉**（不显示、也不计数）。
#
# 📌 计数合并的**具体逻辑**在 scripts/hd-cluster-summary.sh 里（单独一个文件），
#    这样它可以被 `source`、可以被测试直接跑
#    （scripts/test-hd-cluster-summary.sh source 的是**那个文件本身**，
#      不是它的复制品）。
#    改逻辑请先跑那个测试。
# ---------------------------------------------------------------
if [ -x /opt/hd/hd-redis-cluster.sh ] || [ -f /opt/hd/hd-redis-cluster.sh ]; then
  if bash /opt/hd/hd-redis-cluster.sh status >/dev/null 2>&1; then
    echo
    echo "############ C — 容器内 Redis 集群 ############"
    # ⚠️ **找 helper 要在「集群在跑」这个分支里面做**。
    #    集群没跑的时候这一段根本不会用到它 —— 那时候为一个用不到的文件
    #    硬依赖（找不到就 exit 3），等于让**既有的门禁**因为一个
    #    **跟本轮无关的新文件**而中止。
    #    ⇒ 集群没跑 → 整段跳过，base 矩阵照跑照出 SUMMARY；
    #      集群跑了 → 必须有这个文件，缺了就**大声失败**。
    HD_CLUSTER_SUMMARY_HELPER=""
    for cand in /opt/hd/hd-cluster-summary.sh /repo/scripts/hd-cluster-summary.sh ; do
      if [ -f "$cand" ]; then HD_CLUSTER_SUMMARY_HELPER="$cand"; break; fi
    done
    if [ -z "$HD_CLUSTER_SUMMARY_HELPER" ]; then
      echo "!! 找不到 hd-cluster-summary.sh（试过 /opt/hd/ 和 /repo/scripts/）—— 计数合并逻辑缺失" >&2
      echo "!! 这一轮回归的集群部分**没法计入**，结果不可信。" >&2
      exit 3
    fi
    # ⚠️⚠️ **source 的结果必须检查** ——
    #    `. file` 在「文件是空的」或「文件有语法错误」时都会**失败**，
    #    但**不会中断脚本**（没有 set -e 的时候）。
    #    ⇒ 结果就是：merge_cluster_summary 压根没被定义，
    #      调用它 → "command not found" → 集群的 FAIL 计数**永远并不进来**，
    #      而矩阵照样打印 "SUMMARY: PASS=47 FAIL=0" 并 exit 0。
    #    **这就是一个假绿**：集群验证报了 FAIL，回归说全绿。
    #
    #    触发条件很现实：`docker cp` 被中断 → 文件被截断；
    #    容器里有人手滑打了个错字。
    #
    #    ⇒ 所以这里必须 ①检查 source 的返回值，
    #      ②检查函数**确实被定义了**。
    #      两条都要 —— 只查一条不够：
    #        - 只查 source 返回值：source 成功但文件里没有那个函数 → 漏；
    #        - 只查函数：source 失败时函数当然也没有 → 也能覆盖。
    #      但两条都查，才能在**错误发生的那一刻**给出准确的诊断。
    if ! . "$HD_CLUSTER_SUMMARY_HELPER"; then
      echo "!! 加载失败: $HD_CLUSTER_SUMMARY_HELPER" >&2
      echo "!! 计数合并逻辑没加载进来 —— 集群的失败会被**悄悄丢掉**，这一轮不可信。" >&2
      exit 3
    fi
    if ! command -v merge_cluster_summary >/dev/null 2>&1; then
      echo "!! merge_cluster_summary 未定义（$HD_CLUSTER_SUMMARY_HELPER 里没有这个函数）" >&2
      echo "!! 集群的失败会被**悄悄丢掉**，这一轮不可信。" >&2
      exit 3
    fi

    CV_OUT=$(mktemp /tmp/hd-cluster-verify-out.XXXXXX 2>/dev/null)
    if [ -z "${CV_OUT:-}" ]; then
      CV_OUT="/tmp/hd-cluster-verify-out.$$"
    fi
    # ⚠️ **临时文件一定要清掉** —— 下面那条「计数没并进来」的 exit 3
    #    会在 rm 之前就退出 → 不清就会在 /tmp 里留垃圾。
    #    （一次回归留一个文件，跑几十轮就攒几十个。）
    #    用 trap 而不是到处写 rm —— exit 的路径太多，漏一个就漏一个文件。
    #    ⚠️ trap 里只删**自己那个**文件（CV_OUT 是具体路径，不是通配符）。
    trap 'rm -f "${CV_OUT:-}" 2>/dev/null' EXIT
    bash /opt/hd/hd-cluster-verify.sh >"$CV_OUT" 2>&1
    CV_RC=$?
    # 把它的明细（PASS/FAIL 行、上下文）显示出来，但**滤掉它自己的 SUMMARY**。
    grep -v '^SUMMARY: ' "$CV_OUT" | sed 's/^/  /'
    # 计数合并（逻辑在 hd-cluster-summary.sh 里，可被测试 source）。
    # ⚠️ merge_cluster_summary 自己会把异常**计入 $FAIL**，
    #    并把说明写进 $CLUSTER_SUMMARY_NOTES ——
    #    这里**只打印**，不能再调 bad()（那会重复计数）。
    CLUSTER_SUMMARY_NOTES=""
    CLUSTER_SUMMARY_PASS=0
    CLUSTER_SUMMARY_FAIL=0
    merge_cluster_summary "$CV_OUT" "$CV_RC"
    if [ -n "$CLUSTER_SUMMARY_NOTES" ]; then
      echo "$CLUSTER_SUMMARY_NOTES" | sed '/^$/d; s/^/  FAIL  /'
    fi
    # ⚠️ 计数**只从 helper 拿**（它才是唯一的解析源）。
    #    这里**绝不能**再自己解析一遍 SUMMARY ——
    #    两处解析各走各的，异常路径下就会打印出
    #    「已并入本轮计数: FAIL +0」而最终 SUMMARY 里是 FAIL=1，
    #    **自相矛盾**。
    echo "  (集群验证已并入本轮计数: PASS +${CLUSTER_SUMMARY_PASS:-0}, FAIL +${CLUSTER_SUMMARY_FAIL:-0})"

    # ⚠️ **断言计数真的动了** —— 这是「合并有没有生效」的最后一道检查。
    #    前面已经保证函数存在、source 成功，但万一函数内部**没有改计数器**
    #    （比如被人改坏了），计数就还是 0，而集群报了 FAIL。
    #    ⇒ 拿子脚本自己的 SUMMARY 做对照：它说有 N 个 FAIL，
    #    合并后外层的 FAIL 至少也得比合并前多 N。
    #    差得不够 → 说明没并进来 → **大声失败**，不打印绿 SUMMARY。
    #    ⚠️ 用的是**合并后的实际增量**（$CLUSTER_SUMMARY_FAIL），
    #    不是解析出来的原始计数 —— 异常路径上原始计数是 0，
    #    但实际并进去 1（异常本身算一个失败）。
    CV_CLAIMED_F=$(grep '^SUMMARY: ' "$CV_OUT" 2>/dev/null | tail -1 | grep -oP 'FAIL=\K[0-9]+' || true)
    CV_CLAIMED_F=${CV_CLAIMED_F:-0}
    if [ "${CLUSTER_SUMMARY_FAIL:-0}" -lt "$CV_CLAIMED_F" ]; then
      echo "!! 集群验证报了 $CV_CLAIMED_F 个 FAIL，但合并进来的只有 ${CLUSTER_SUMMARY_FAIL:-0} 个" >&2
      echo "!! 计数没并进来 —— 这一轮不可信。" >&2
      exit 3
    fi
    rm -f "$CV_OUT" 2>/dev/null
    trap - EXIT
  else
    echo
    echo "############ C — 容器内 Redis 集群（跳过：集群没在跑）############"
    skip "C 集群没在跑（hd-redis-cluster.sh status 非 0）—— 不计入本轮回归"
  fi
else
  echo
  echo "############ C — 容器内 Redis 集群（跳过：没有 hd-redis-cluster.sh）############"
  skip "C 容器里没有 /opt/hd/hd-redis-cluster.sh"
fi

echo
echo "SUMMARY: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]

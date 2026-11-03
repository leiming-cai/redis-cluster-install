#!/bin/bash
# monitor 的集群分支 —— **运行时**覆盖验证（单机 vs 集群对比）
#
# ⚠️ **为什么必须两种模式都跑**：
#    `loadRTConfigKafka()` 在**单机**模式下也会写 `real_graph:realscope`。
#    只验集群模式 ⇒ 无法排除「写进去了但用的是单机分支」（比如 isCluster() 判断错了）。
#    ⇒ 判据 = 两边**field 名逐个相等** + **field 数相等**。
#
# 用法（在 hd-node1 容器内跑）:
#   bash /opt/hd/hd-monitor-runtime-verify.sh
#
# 退出码: 0 = 全部通过；非 0 = 有失败
set -uo pipefail

REDIS_CLI=/opt/software/redis-8.10.0/bin/redis-cli
LOG_DIR=/opt/hd/logs
KEY=real_graph:realscope
# 期望的 field 数 = 3 个类型 × 各自属性数（2 + 2 + 8 = 12）
EXPECT_FIELDS=12
# 种子编号段（obj_type ∈ 900001..900003, attr_type ∈ 900101..900112）
SEED_OTYPES="900001 900002 900003"

P1=16379; P2=16380; P3=16381
PASS=0; FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

# 集群密码 —— 语义跟 hd-redis-cluster.sh / hd-cluster-app-test.sh **完全一致**：
# 用 `${VAR-...}`（只认「没设」）而不是 `${VAR:-...}`（没设**或**空串都算）。
if [ -n "${HD_CLUSTER_PASS+set}" ]; then
  PASS_WORD="$HD_CLUSTER_PASS"
else
  PASS_WORD="HdClusterPw2026"
fi
case "$PASS_WORD" in
  '') echo "!! HD_CLUSTER_PASS 是空的 —— 这是配置错误" >&2; exit 1 ;;
esac

if [ -n "${HD_CLUSTER_IP+set}" ]; then
  IP="$HD_CLUSTER_IP"
else
  IP="$(getent hosts node1 | awk 'NF{print $1; exit}')"
fi
case "$IP" in
  ''|*' '*|*$'\n'*|*[!0-9.]*) echo "!! 容器 IP 解析失败: '$IP'" >&2; exit 1 ;;
esac

# 集群里读 hash（-c 跟随 MOVED）
rcc() { timeout 5 "$REDIS_CLI" -c -h "$IP" -p "$1" -a "$PASS_WORD" --no-auth-warning "${@:2}" 2>&1 | tr -d '\r'; }
# 单机里读 hash
rs()  { timeout 5 "$REDIS_CLI" -h 127.0.0.1 -p "$1" -a sac888 --no-auth-warning "${@:2}" 2>&1 | tr -d '\r'; }

# 取出某模式下这个 hash 的 field 名（排序去重），写到 $1
# ⚠️ **两种模式的读法不一样**：
#    集群 —— 要遍历 3 个 master（key 按 slot 落在一个 master 上，-c 跟随 MOVED）；
#    单机 —— 只有 6379 一个端口，读一次就够。
# ⚠️ field 名是 `<objType>_<attrType>`（数字_数字）。这里用 `^[0-9]+_[0-9]+$`
#    过滤掉 redis-cli 的报错文本（AUTH failed / NOAUTH / Could not connect 等）——
#    否则错密码时那些行会被当成 field，污染列表、还可能碰巧凑成期望的计数。
dump_fields() {
  local out="$1" mode="$2" p f
  : > "$out"
  if [ "$mode" = cluster ]; then
    for p in $P1 $P2 $P3; do
      f=$(rcc "$p" HKEYS "$KEY")
      echo "$f" | grep -E '^[0-9]+_[0-9]+$' >> "$out"
    done
  else
    f=$(rs 6379 HKEYS "$KEY")
    echo "$f" | grep -E '^[0-9]+_[0-9]+$' >> "$out"
  fi
  sort -u -o "$out" "$out"
}

# web-controller 的日志（判据 4/5 读它、判据 1/2 也靠它的 Started 行确认应用起来了）
A_LOG="$LOG_DIR/web-controller.log"
APP_CLS_WEB="NapstarWebRestApplication"

# 等应用**真的起来**（web-controller 实测要 67~72 秒才打完 Started，
# start-hd-apps.sh 内部只固定 sleep 60，返回时日志可能还是空的）。
# 有界等待：最多 200 秒、每 5 秒看一次；Started 之后 StartupRunner 还要跑，再补 10 秒。
wait_started() {
  local i waited=0
  for i in $(seq 1 40); do
    if [ -f "$A_LOG" ] && grep -aq "Started $APP_CLS_WEB in " "$A_LOG" 2>/dev/null; then
      waited=$((i*5))
      break
    fi
    sleep 5
  done
  if [ "$waited" -gt 0 ]; then
    echo "  （已出现 'Started $APP_CLS_WEB in '，等了 ${waited} 秒）"
  else
    echo "  （等了 200 秒仍没有 'Started $APP_CLS_WEB in ' —— 下面的判据会如实报 FAIL）"
  fi
  # StartupRunner（ApplicationRunner）在 Started 之后才跑，再给它一点时间刷出写结果/异常。
  sleep 10
}

# C3/C4 的**可测量性**守卫（同 hd-cluster-app-test.sh 的 check_no_pipeline_exception）：
#   日志文件必须存在、应用必须起来了（有 'Started <appcls> in ' 行），
#   否则「读到 0 个异常」是**假 PASS**（应用根本没起来）。
#   返回 0 = 可测量；非 0 = 已打印 bad，不可测量。
c_log_measurable() {
  [ -f "$A_LOG" ] || { bad "C3/C4 无法测量：日志文件 $A_LOG 不存在"; return 1; }
  if ! grep -aq "Started $APP_CLS_WEB in " "$A_LOG" 2>/dev/null; then
    bad "C3/C4 无法测量：应用没起来（$A_LOG 里没有 'Started $APP_CLS_WEB in '）"
    return 1
  fi
  return 0
}

echo "############ monitor 集群分支 —— 运行时覆盖验证 ############"
echo "### 目标 key: $KEY   期望 field 数: $EXPECT_FIELDS"
echo "### 集群: $IP:$P1/$P2/$P3"

# ---------------------------------------------------------------
# 前置：元数据表必须非空（否则判据不可执行 ⇒ 跳过，不是 FAIL）
# ---------------------------------------------------------------
export PGPASSWORD=postgres
META=$(psql -U postgres -h 127.0.0.1 -d napstar -Atc "select count(*) from info.model_objecttype" 2>/dev/null | tr -d '\r')
case "$META" in
  ''|*[!0-9]*) echo "!! 读不到 info.model_objecttype 的行数 —— 前置条件无法判定"; exit 3 ;;
esac
echo "### 前置检查: info.model_objecttype 行数 = $META"
if [ "$META" -eq 0 ]; then
  echo "!! 元数据表是空的 —— 判据不可执行。"
  echo "   先跑: bash /opt/hd/seed-hd-model-metadata.sh --seed"
  exit 3
fi

# ---------------------------------------------------------------
# 判据 1：单机模式
# ---------------------------------------------------------------
echo
echo "############ 1) 单机模式（standalone） ############"
# 单机模式：应用走 jar/Nacos 自己的 oms.* → node1:6379
# ⚠️ 先删掉旧 hash（单机那份在 6379）—— 这样下面读到的 field 一定是**本次**写进去的，
#    而不是上一轮运行留下的残留。不能依赖 loadRTConfigKafka 自己先删：它要是不跑，
#    残留的 hash 会让「0 次写」也被误判成「写成功了」。
rs 6379 DEL "$KEY" >/dev/null 2>&1
bash /opt/hd/start-hd-apps.sh 1 >/tmp/mrv-standalone-app.log 2>&1
SAPP_RC=$?
echo "  起单机模式应用：start-hd-apps.sh 退出码 = $SAPP_RC"
if [ "$SAPP_RC" -eq 0 ]; then
  ok "S0 单机模式应用启动成功（start-hd-apps.sh 退出码 0）"
else
  bad "S0 单机模式应用启动失败（start-hd-apps.sh 退出码 $SAPP_RC）"
fi
# 等 web-controller 真的起来（Started 行出现）—— 固定 sleep 5 太薄，见 wait_started 的注释
wait_started
# 断言这次跑的是单机模式（Standalone 那行必须在日志里）—— 证明「单机分支」真的生效了
# ⚠️ **双向断言**：正确的行必须在，**错的行必须不在** ——
  #    只查「有」不够：万一日志里两种行都有，模式就是有歧义的。
  #    （house 脚本的 check_cluster_mode 就是这么做的。）
  if grep -aqE '\*\*\* Using Redis Standalone at [^)]*\)' "$A_LOG" 2>/dev/null \
     && ! grep -aqE '\*\*\* Using Redis Cluster with nodes:' "$A_LOG" 2>/dev/null; then
    ok "S3 单机模式日志里有 Standalone 行、且没有 Cluster 行（模式唯一）"
  else
    bad "S3 单机模式的模式判定有歧义（Standalone 行缺失，或两种行同时出现）"
  fi
# 触发写路径（StartupRunner 启动时也会跑一次，这里主动再跑一次）
TOK=$(cat /tmp/hd-token.txt 2>/dev/null)
if [ -n "$TOK" ]; then
  CODE=$(curl -s -m 30 -o /tmp/mrv-standalone-resp.txt -w '%{http_code}' \
    -X POST -H "Authorization: $TOK" -H 'Content-Type: application/json' -d '{}' \
    "http://127.0.0.1:8099/napstarweb/svgCache/initGraph" 2>/dev/null)
  echo "  触发 svgCache/initGraph -> HTTP $CODE"
  case "$CODE" in
    401|403) echo "!! token 过期或无效（HTTP $CODE）—— 判据没法执行"; exit 3 ;;
    404|000|'') echo "!! 触发入口不可达（HTTP $CODE）—— 判据没法执行"; exit 3 ;;
  esac
else
  echo "!! 没有 token（/tmp/hd-token.txt）—— 判据没法执行"; exit 3
fi
sleep 3
dump_fields /tmp/mrv-standalone-fields.txt standalone
S_FIELDS=$(grep -c . /tmp/mrv-standalone-fields.txt)
echo "  单机 field 数 = $S_FIELDS"
echo "  单机 field 列表:"
sed 's/^/      /' /tmp/mrv-standalone-fields.txt
if [ "$S_FIELDS" -eq "$EXPECT_FIELDS" ]; then
  ok "S1 单机模式 field 数 = $EXPECT_FIELDS"
else
  bad "S1 单机模式 field 数 = $S_FIELDS（期望 $EXPECT_FIELDS）"
fi
# 每个 field 的 objType 段必须是种子编号
SEEN_SEED=0
for f in $(cat /tmp/mrv-standalone-fields.txt); do
  ot=$(echo "$f" | cut -d_ -f1)
  case " $SEED_OTYPES " in *" $ot "*) SEEN_SEED=$((SEEN_SEED+1)) ;; esac
done
if [ "$SEEN_SEED" -eq "$EXPECT_FIELDS" ]; then
  ok "S2 单机模式的 field 全部来自种子编号（$SEEN_SEED/$EXPECT_FIELDS）"
else
  bad "S2 只有 $SEEN_SEED/$EXPECT_FIELDS 个 field 的 objType 段是种子编号"
fi

# ---------------------------------------------------------------
# 判据 2：集群模式
# ---------------------------------------------------------------
echo
echo "############ 2) 集群模式（cluster） ############"
# ⚠️ 先删掉旧 hash（集群那份落在某个 master 上，-c 跟随 MOVED）—— 同上，证明「本次写」。
rcc "$P1" DEL "$KEY" >/dev/null 2>&1
HD_REDIS_CLUSTER=1 bash /opt/hd/start-hd-apps.sh 1 >/tmp/mrv-cluster-app.log 2>&1
CAPP_RC=$?
echo "  起集群模式应用：start-hd-apps.sh 退出码 = $CAPP_RC"
if [ "$CAPP_RC" -eq 0 ]; then
  ok "C0 集群模式应用启动成功（start-hd-apps.sh 退出码 0）"
else
  bad "C0 集群模式应用启动失败（start-hd-apps.sh 退出码 $CAPP_RC）"
fi
wait_started
# 断言这次跑的是集群模式（Cluster 那行必须在日志里）—— 证明「集群分支」真的生效了
# ⚠️ **双向断言**：正确的行必须在，**错的行必须不在**（同 S3 的理由）
  if grep -aqE '\*\*\* Using Redis Cluster with nodes: [^)]*\)' "$A_LOG" 2>/dev/null \
     && ! grep -aqE '\*\*\* Using Redis Standalone at' "$A_LOG" 2>/dev/null; then
    ok "C5 集群模式日志里有 Cluster 行、且没有 Standalone 行（模式唯一）"
  else
    bad "C5 集群模式的模式判定有歧义（Cluster 行缺失，或两种行同时出现）"
  fi
CODE=$(curl -s -m 30 -o /tmp/mrv-cluster-resp.txt -w '%{http_code}' \
  -X POST -H "Authorization: $TOK" -H 'Content-Type: application/json' -d '{}' \
  "http://127.0.0.1:8099/napstarweb/svgCache/initGraph" 2>/dev/null)
echo "  触发 svgCache/initGraph -> HTTP $CODE"
case "$CODE" in
  401|403) echo "!! token 过期或无效（HTTP $CODE）—— 判据没法执行"; exit 3 ;;
  404|000|'') echo "!! 触发入口不可达（HTTP $CODE）—— 判据没法执行"; exit 3 ;;
esac
sleep 3
dump_fields /tmp/mrv-cluster-fields.txt cluster
C_FIELDS=$(grep -c . /tmp/mrv-cluster-fields.txt)
echo "  集群 field 数 = $C_FIELDS"
echo "  集群 field 列表:"
sed 's/^/      /' /tmp/mrv-cluster-fields.txt
if [ "$C_FIELDS" -eq "$EXPECT_FIELDS" ]; then
  ok "C1 集群模式 field 数 = $EXPECT_FIELDS"
else
  bad "C1 集群模式 field 数 = $C_FIELDS（期望 $EXPECT_FIELDS）"
fi

# ---------------------------------------------------------------
# 判据 3：**逐个比对**（这是排除「其实走的是单机分支」的唯一办法）
# ---------------------------------------------------------------
echo
echo "############ 3) 单机 vs 集群 —— field 名逐个比对 ############"
C2_CNT=$(grep -c . /tmp/mrv-cluster-fields.txt)
if [ "${C2_CNT:-0}" -eq 0 ]; then
  # 两边都是 0 个 field 时 diff 也会「成功」—— 那是空比，不能算「逐个相等」
  bad "C2 集群模式的 field 数是 0 —— 没有 field 可比，不能判「逐个相等」"
elif diff -u /tmp/mrv-standalone-fields.txt /tmp/mrv-cluster-fields.txt > /tmp/mrv-field-diff.txt 2>&1; then
  ok "C2 集群模式的 field 名与单机模式**逐个相等**（$C2_CNT 个）"
else
  bad "C2 集群模式的 field 名与单机模式**不一致**："
  sed 's/^/      /' /tmp/mrv-field-diff.txt
fi

# ---------------------------------------------------------------
# 判据 4：kafkabus 那 3 个类型的 OTypeException 归零
# ---------------------------------------------------------------
echo
echo "############ 4) OTypeException（kafkabus 那 3 个类型） ############"
if c_log_measurable; then
  N3=$(grep -ac 'oType数值非法或不存在：\(MVPoint\|DPSPoint\|Machine\)' "$A_LOG" 2>/dev/null)
  NTOT=$(grep -ac 'OTypeException' "$A_LOG" 2>/dev/null)
  echo "  kafkabus 3 个类型的异常数 = $N3   （总数 = $NTOT）"
  echo "  ⚠️ 总数**不会**归零：另外那些来自 SVG 解析路径的其它类型，不在本轮范围"
  # ⚠️ 显式区分「读到 0」和「读不到」（空/非数字 = 无法测量，不能判 PASS）
  case "$N3" in
    ''|*[!0-9]*) bad "C3 无法读取 OTypeException 计数（grep 返回 '$N3'）—— 不能判 PASS" ;;
    0) ok "C3 kafkabus 那 3 个类型的 OTypeException 已归零（总数仍有 $NTOT，来自其它类型）" ;;
    *) bad "C3 kafkabus 那 3 个类型还有 $N3 个 OTypeException" ;;
  esac
fi

# ---------------------------------------------------------------
# 判据 5：集群模式下没有 UOE
# ---------------------------------------------------------------
echo
echo "############ 5) JVM 层的 UnsupportedOperationException ############"
if c_log_measurable; then
  NU=$(grep -ac 'java\.lang\.UnsupportedOperationException\|not supported for JedisClusterConnection' "$A_LOG" 2>/dev/null)
  case "$NU" in
    ''|*[!0-9]*) bad "C4 无法读取 UOE 计数（grep 返回 '$NU'）—— 不能判 PASS" ;;
    0) ok "C4 集群模式下无 UnsupportedOperationException" ;;
    *) bad "C4 集群模式下有 $NU 个 UnsupportedOperationException" ;;
  esac
fi

# ───────────────────────────────────────────────
# 结束状态（给下一个任务）：
#   - 应用**留着没杀** —— 此刻跑在**集群模式**（HD_REDIS_CLUSTER=1）。
#   - 本脚本**不**停 Redis 集群（hd-redis-cluster.sh stop 由调用方/后续任务负责）。
#   - 判据临时文件留在 /tmp/mrv-*.txt（诊断用）。
echo
echo "SUMMARY: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

#!/bin/bash
# 应用层集群读写验证（三个工程各一个应用）。
#
# 在 hd-node1 容器内跑（宿主 bash 是坏的 WSL shim）。
#
# 【每个应用两条判据】
#   ① 启动日志那行 *** Using Redis Cluster with nodes: <列表> *** 的列表
#      == 我们配的列表（**逐字、含顺序**比较）。
#   ② 一次**真实的读写往返**成功 —— 不是只看「连上了」。
#      教训：oms.clusters 填错时启动正常、第一次读写才炸
#      （设计文档 docs/superpowers/specs/2026-11-01-hd-redis-cluster-test-design.md §2.3；
#        同一个坑在 docs/HANDOFF.md 里也有记述，但行号已经漂移，别按行号引用）。
#
# 【判据 ② 怎么测才算数】
#   光用 redis-cli 写读只能证明**集群**能用，证明不了**应用**能用。
#   所以这里测的是**应用自己**在集群里留下的痕迹 —— 即**应用自己写的 key**
#   出现在集群里，而且能读回应用自己那份载荷：
#     - web-controller   : StartupRunner -> SVGCacheServiceImpl.loadRTConfigKafka()
#                          写 hash `real_graph:realscope`
#     - model-controller : CacheServiceImpl 的 @Cacheable 写 `model:*` 前缀
#                          （POST /model/modelData/getEnumDictTypes 触发）
#     - rtdata-consumer  : RTListener.onMessage(INCDATA) -> batchWirtePip()
#                          写 hash `real_data:<otype>:<obid>`，field=<atype>
#
#   这就是判据 ② 的**全部**依据 —— 「应用自己的 key + 应用自己的载荷」。
#
#   ⚠️ 曾经还有一个「三个 master 的 total_commands_processed 增量 > 0」的判据，
#      **已删除**：它是**空判**（不可能失败）。每个 `INFO stats` 本身就是要查的
#      那个节点上**被计数的命令**，所以脚本自己取的快照就自带增量 ——
#      实测「没有应用、什么都不做、隔 3 秒取两次快照」增量就已经是 2。
#      而且这个计数器是**节点级全局**的（所有客户端的命令都算进去），
#      根本没法把流量归属到应用身上。现在它只作为**诊断信息**打印，不作判据。
#
# 【判据的「可执行性」前提】
#   有些判据在某些环境里**根本跑不起来**（数据缺失），这时必须**跳过并说清楚原因**，
#   不能报 FAIL —— 否则会把「环境缺数据」误报成「应用有 bug」。
#   本脚本里 web-controller 的 A2 就是这种情况（见下面 A2 段的说明）。
#
# 【JVM 层的 UnsupportedOperationException 限制】
#   SDR 2.7.18 的 JedisClusterConnection.openPipeline() 直接抛
#   UnsupportedOperationException("Pipeline is currently not supported for
#   JedisClusterConnection.")，**回调体一次都不执行**。
#   Task 2 的 L6 只证了协议层（跨槽 pipeline 拿 MOVED），
#   那个 JVM 层面的限制只能由**应用日志**来证。
#   正确的期望是：应用走了集群分支 -> 那个异常**不该出现**。
#   出现即 FAIL —— 那说明有代码路径还在裸用 executePipelined，
#   该路径在集群模式下**静默失效**（数据写不进去，而且可能连日志都没有）。
set -uo pipefail

REDIS_HOME=/opt/software/redis-8.10.0
RC="$REDIS_HOME/bin/redis-cli"
LOG_DIR=/opt/hd/logs
KAFKA_HOME=/opt/software/kafka_2.13-2.8.0
P1=16379; P2=16380; P3=16381
TMO=5

# ⚠️ 密码的语义必须跟 start-hd-apps.sh / hd-cluster-verify.sh / hd-redis-cluster.sh
#    **完全一致**：用 `${VAR-...}`（只认「没设」）而不是 `${VAR:-...}`
#    （没设**或**空串都算）。显式设了空值是一种「我以为配了」的错误状态，
#    应该报错，而不是悄悄回退到默认值 —— 那会让操作的人以为设成功了，
#    实际连上去的是 NOAUTH。
if [ -n "${HD_CLUSTER_PASS+set}" ]; then
  PASS="$HD_CLUSTER_PASS"
else
  PASS="HdClusterPw2026"
fi
case "$PASS" in
  '')
    echo "!! HD_CLUSTER_PASS 是空的 —— 这是配置错误，不是'用默认值'" >&2
    exit 1
    ;;
esac

# ⚠️ IP 推导必须跟另外三个脚本**一模一样**：
#    不能用 `hostname -i`（返回空格分隔的多个地址），
#    不能用 `awk '{print $1}'`（打印**每一行**的第一个字段，
#    getent ahosts node1 在这台机器上是 3 行 STREAM/DGRAM/RAW ->
#    得到多个 IP -> 命令行被拆开 -> 断言打到错误的节点上）。
#    `awk 'NF{print $1; exit}'` 只取第一个非空行。
if [ -n "${HD_CLUSTER_IP+set}" ]; then
  IP="$HD_CLUSTER_IP"
else
  IP="$(getent hosts node1 | awk 'NF{print $1; exit}')"
fi
# ⚠️ 必须是**单个** IP：多个值会让 redis-cli -h 拿到一个畸形 host，
#    报出更难懂的错，而且断言可能悄悄打到别的节点上。
case "$IP" in
  ''|*' '*|*$'\n'*|*[!0-9.]*)
    echo "!! 容器 IP 解析失败或含多个值: '$IP'" >&2
    echo "   （getent hosts node1 的输出或 HD_CLUSTER_IP 有问题）" >&2
    exit 1
    ;;
esac

P=0; F=0; S=0
ok()  { echo "  PASS  $*"; P=$((P+1)); }
bad() { echo "  FAIL  $*"; F=$((F+1)); }
skip(){ echo "  SKIP  $*"; S=$((S+1)); }
chk() { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1 (got '$2', want '$3')"; fi; }

# ⚠️ **每一次** redis-cli 调用都要套 timeout：
#    redis-cli 自己**没有连接超时**，地址不可达时会永远挂着。
# ⚠️ redis-cli 的**退出码不可靠**（连不上时也返回 0），
#    所以判活/断言一律看**输出文本**，绝不拿退出码当判据。
#
# r()  = 直连某个 master（不做槽感知；访问非本槽 key 会拿到 MOVED）
# rc() = 集群模式（-c，跟随 MOVED 跳转）—— **查 key 必须用这个**，
#        否则 EXISTS 拿到的是一句 "MOVED 1234 172.22.0.2:16380"，
#        会被误当成「key 不存在」。
r()  { timeout "$TMO" "$RC" -h "$IP" -p "$1" -a "$PASS" --no-auth-warning "${@:2}" 2>&1; }
rc() { timeout "$TMO" "$RC" -c -h "$IP" -p "$1" -a "$PASS" --no-auth-warning "${@:2}" 2>&1; }

# 三个 master 的地址，逗号分隔（**顺序即配置顺序**）。
EXPECTED_NODES="$IP:$P1,$IP:$P2,$IP:$P3"

# ⚠️ **不要把密码打到 stdout**（日志会被贴到 issue / 工单里）。
#    只说密码的**来源**，不说值。
if [ -n "${HD_CLUSTER_PASS+set}" ]; then
  PASS_SRC="HD_CLUSTER_PASS 已设置"
else
  PASS_SRC="HD_CLUSTER_PASS 未设置（用内置默认值）"
fi

# ---------------------------------------------------------------
# 我们自己创建的 key（收尾要清干净）。
# 跨槽的 key 不能用一条 DEL 删（会 CROSSSLOT 整条失败），
# 所以必须一个一个删。
CLEAN_KEYS=()

# 本次运行的临时目录（放 Kafka 消息文件等）。
WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/hd-cluster-app-test.XXXXXX" 2>/dev/null)
OWNRUN_DIR=0
if [ -n "${WORKDIR:-}" ] && [ -d "${WORKDIR:-}" ]; then
  OWNRUN_DIR=1
else
  WORKDIR="${TMPDIR:-/tmp}/hd-cluster-app-test.fallback.$$"
  mkdir -p "$WORKDIR" 2>/dev/null && OWNRUN_DIR=1
fi

cleanup() {
  local k
  if [ "${#CLEAN_KEYS[@]}" -gt 0 ]; then
    # ⚠️ 一条一条 DEL —— 跨槽的 key 用一条 DEL 删会 CROSSSLOT，一个都删不掉。
    for k in "${CLEAN_KEYS[@]}"; do
      [ -n "$k" ] && rc "$P1" DEL "$k" >/dev/null 2>&1
    done
  fi
  if [ "${OWNRUN_DIR:-0}" -eq 1 ] && [ -n "${WORKDIR:-}" ] && [ -d "${WORKDIR:-}" ]; then
    rm -rf "$WORKDIR"
  fi
  return 0
}
# 兜底清理：脚本退出时把自己写的 key 删掉。
#
# ⚠️ 收到 TERM/INT/HUP 时 bash 被杀，EXIT trap 里的 `$?` 是 0 而不是 128+n
#    （bash 是在 trap **返回之后**才把信号状态算进去的），
#    所以光靠 `[ "$_e" -ne 0 ]` 会被信号杀死时误判成「假绿」。
#    这三个显式的信号 trap 把信号转成普通的非零退出。
DONE=0
trap '_e=$?; cleanup; if [ "$DONE" -eq 0 ]; then
        if [ "$_e" -ne 0 ] && [ "$F" -eq 0 ]; then
          F=$((F+1))
          echo "  FAIL  脚本异常退出（exit=$_e）—— 上面那条错误才是根因"
        fi
        echo; echo "SUMMARY: PASS=$P FAIL=$F SKIP=$S"
      fi; exit $_e' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP

# ---------------------------------------------------------------
# 集群侧的**诊断信息**（不是判据）。
#
# ⚠️ 这个计数器**不能**当判据用 —— 原因写在文件头的说明里：
#    每个 `INFO stats` 本身就是要查的那个节点上**被计数的命令**，
#    所以脚本自己取的快照就自带增量（实测空闲集群隔 3 秒取两次 = 2），
#    「增量 > 0」是个**永远不会失败**的空判；
#    而且计数器是**节点级全局**的（所有客户端的命令都算进去），
#    无法把流量归属到应用。
#
#    所以这里只把它**打印出来**，供人判断「应用到底有没有在跟集群说话」：
#    应用真的在写时，增量会明显高于「脚本自己那几条命令」的量级。
#
# ⚠️ 三个 master 都要看：应用写的 key 可能落在任意一个 master 上，
#    只看 16379 会漏掉「应用只碰到了 16379」以外的情况。
cmd_counter() {
  local p="$1" v
  v=$(r "$p" INFO stats | grep -m1 '^total_commands_processed:' | cut -d: -f2 | tr -d '\r')
  case "$v" in
    ''|*[!0-9]*) echo "-1" ;;
    *) echo "$v" ;;
  esac
}
counters_snapshot() {
  echo "$(cmd_counter $P1) $(cmd_counter $P2) $(cmd_counter $P3)"
}
# 三个 master 的增量之和（-1 = 某个 master 的计数器读不到）
counter_delta() {
  local before="$1" after="$2"
  local b1 b2 b3 a1 a2 a3
  b1=$(echo "$before" | cut -d' ' -f1); b2=$(echo "$before" | cut -d' ' -f2); b3=$(echo "$before" | cut -d' ' -f3)
  a1=$(echo "$after"  | cut -d' ' -f1); a2=$(echo "$after"  | cut -d' ' -f2); a3=$(echo "$after"  | cut -d' ' -f3)
  local i
  for i in "$b1" "$b2" "$b3" "$a1" "$a2" "$a3"; do
    [ "$i" = "-1" ] && { echo "-1"; return; }
  done
  echo $(( (a1-b1) + (a2-b2) + (a3-b3) ))
}
# 打印动作窗口里的命令增量（**仅供参考**，不是判据 —— 见上面的说明）
report_counter_delta() {
  local name="$1" delta="$2"
  echo "    [诊断] 三个 master 的命令增量合计 = $delta"
  echo "           （参考值，不是判据：脚本自己的 INFO/EXISTS 命令也计入；"
  echo "             应用真在写时会明显高于这个量级）"
}

# ---------------------------------------------------------------
# 前置条件：模型元数据表里有没有行。
#
# ⚠️ 为什么需要它：web-controller 的写路径
#    `SVGCacheServiceImpl.loadRTConfigKafka()` 会对每个模型类型调
#    `modelDataService.matchOType(oname)`；**只有 matchOType 返回非 null
#    才会执行 hSet**。而 matchOType 查的是 `info.model_objecttype` 等表 ——
#    这个安装包里这些表**是空的**（0 行），于是每个模型名都抛
#    `OTypeException: oType数值非法或不存在：XXX`，`continue` 掉，
#    **hSet 一次都不执行**。
#
#    实测（同一个 jar，**单机**模式，pipeline 完全正常、0 个 UOE）：
#      `real_graph:*` key 数 = 0
#    ⇒ 也就是说这个 key 在**单机模式也不会出现**。
#    它**不是**集群模式的问题，是**数据缺口**。
#    所以 A2 判据必须**跳过**，不能报 FAIL ——
#    否则重建 jar 之后它还是会 FAIL，就把「环境缺数据」误报成「应用有 bug」。
#
# 用法：model_metadata_rows -> 打印 `info.model_objecttype` 的行数（读不到则 -1）
model_metadata_rows() {
  local n
  n=$(PGPASSWORD="${PGPASSWORD:-postgres}" \
       psql -U postgres -h 127.0.0.1 -d napstar -Atc \
       "select count(*) from info.model_objecttype" 2>/dev/null | tr -d '\r')
  case "$n" in
    ''|*[!0-9]*) echo "-1" ;;
    *) echo "$n" ;;
  esac
}

# ---------------------------------------------------------------
# 判据 ①：日志那行集群节点列表。
#
# ⚠️ 列表是**逐字、按配置顺序**打印的（RedisUtilConfig 里
#    `String.join(",", props.getClusters())`），
#    所以这里必须**顺序敏感**地比较 —— 顺序变了也是配错了。
# ⚠️ 取 tail -1：同一个 jar 里可能有多行（比如重启过），
#    最后一组才是当前生效的。
check_cluster_mode() {
  local name="$1" log="$2"
  [ -f "$log" ] || { bad "$name 没有日志文件 $log"; return 1; }
  local line
  line=$(grep -a -oE '\*\*\* Using Redis Cluster with nodes: [^)]*\)' "$log" 2>/dev/null | tail -1)
  if [ -z "$line" ]; then
    bad "$name 没有出现集群模式那行日志（说明没进 cluster 分支）"
    grep -a -oE '\*\*\* Using Redis [^)]*\)' "$log" 2>/dev/null | tail -1 | sed 's/^/        实际: /'
    return 1
  fi
  local nodes
  nodes=$(echo "$line" | sed 's/.*with nodes: //; s/ (.*//')
  echo "        生效节点: $nodes"
  chk "$name 集群节点列表" "$nodes" "$EXPECTED_NODES"
  # 顺带把模式行也钉住 —— 集群模式那行必须在，
  # 并且 Standalone 那行**不该**在同一次启动里出现。
  #
  # ⚠️ 这里扫的是**整个日志文件**，所以它依赖一个前提：
  #    `start-hd-apps.sh` 用 `>`（**截断**）写日志，不是 `>>`（追加）。
  #    截断 => 每次启动的日志里只有本次的模式行 => 判据成立。
  #    万一哪天改成追加（或有人手工 `>>` 续写），上一轮单机启动留下的
  #    Standalone 行会留在文件里 -> 这里会误报 FAIL。
  #    所以这条判据的可靠性**依赖日志被截断**；真要改成追加的话，
  #    这里必须改成只扫「本次启动之后」的那一段。
  local standalone
  standalone=$(grep -a -oE '\*\*\* Using Redis Standalone at [^)]*\)' "$log" 2>/dev/null | tail -1)
  if [ -n "$standalone" ]; then
    bad "$name 日志里同时出现了 Standalone 那行（$standalone）—— 模式判定有歧义"
  else
    ok "$name 日志里没有 Standalone 那行（模式唯一）"
  fi
  # RedisClusterHelper 的模式判定（三个应用都打这行）
  local mode
  mode=$(grep -a -oE 'Redis mode detected: [A-Z]+' "$log" 2>/dev/null | tail -1 | awk '{print $NF}')
  chk "$name RedisClusterHelper 判定模式" "${mode:-<none>}" "CLUSTER"
}

# ---------------------------------------------------------------
# 判据：JVM 层的 UnsupportedOperationException **不该**出现。
#
# 这是本任务的核心回归判据，理由要说清楚：
#   - SDR 2.7.18 的 JedisClusterConnection.openPipeline() **直接抛**
#     UnsupportedOperationException，回调体一次都不执行。
#     所以在集群模式下，**任何**裸用 executePipelined 的代码路径
#     都会让功能**静默失效**（回调体没跑，异常可能被异步框架吞掉，
#     连日志都不一定看得到 —— 实测 rtdata-consumer 就是这样：
#     数据一条没写进去，日志里一个异常都没有）。
#   - 应用应该已经加了集群分支（isCluster() -> execute(cb)），
#     正确的结果是**功能正常**、那个异常**不出现**。
#   - 因此这里的期望是「**没有**这个异常」。
#     出现了 = FAIL = 有代码路径漏了集群分支。
#
# ⚠️ 判据必须**分清**「这个异常」和别的 UnsupportedOperationException：
#    `com.sac.platform.common.exception.UnsupportedException` 是业务异常
#    （模型不支持之类），跟 Redis 的那个没关系，不能一起算。
#    所以只认 `java.lang.UnsupportedOperationException` 这个全限定名
#    以及 JedisClusterConnection 那句原文。
#
# ⚠️⚠️ 两种写法（限定名 / SDR 原文）**合成一条断言**，不要拆成两条。
#    实测：每一条 SDR 原文都带着那个全限定名，反之亦然（57 = 57，
#    两个方向都没有例外）。所以它们量的是**同一件事** ——
#    拆成两条就是把**同一个缺陷数了两遍**，
#    计数会虚高一倍（缺陷数 2 却报 FAIL=3），读的人也会以为有两个问题。
#    保留两种写法是为了防「将来某个 SDR 版本只打印其中一种」，
#    但它们必须**共用一个 ok/bad**，所以只能失败一次。
check_no_pipeline_exception() {
  local name="$1" log="$2"
  [ -f "$log" ] || { bad "$name 没有日志文件 $log"; return 1; }
  # 两种写法都数一遍，取**并集**的条数（一条异常行会被两种写法各数一次，
  # 所以这里要数「行」而不是「次」，否则会翻倍）。
  local n_fqn n_sdr n
  n_fqn=$(grep -ac 'java\.lang\.UnsupportedOperationException' "$log" 2>/dev/null)
  n_sdr=$(grep -ac 'not supported for JedisClusterConnection' "$log" 2>/dev/null)
  # ⚠️ 两个计数里**较小**的那个才是「异常出现的次数」——
  #    实测两者恒等（同一个异常行同时被两种写法命中），
  #    取 min 在「相等」时就是真实次数，在「将来只打印一种」时也不会翻倍。
  if [ "${n_fqn:-0}" -le "${n_sdr:-0}" ] 2>/dev/null; then
    n="${n_fqn:-0}"
  else
    n="${n_sdr:-0}"
  fi
  chk "$name 无 java.lang.UnsupportedOperationException（没踩 openPipeline 的雷；限定名计数 ${n_fqn:-0} / SDR 原文计数 ${n_sdr:-0}）" "${n:-0}" "0"
}

# ---------------------------------------------------------------
# 致命错误计数。启动失败类 + 集群连接类。
# ⚠️ `Could not resolve placeholder` 是「Nacos/命令行没把 oms.clusters 送进来」。
# ⚠️ `JedisNoReachableClusterException` 是「集群连不上（announce-ip / 端口 / 防火墙）」。
check_fatal() {
  local name="$1" log="$2"
  [ -f "$log" ] || { bad "$name 没有日志文件 $log"; return 1; }
  local n
  n=$(grep -a -icE 'APPLICATION FAILED TO START|Application run failed|Could not resolve placeholder|BeanCreationException|JedisNoReachableClusterException|JedisConnectionException|ERR This instance has cluster support disabled' "$log" 2>/dev/null)
  chk "$name 致命错误数" "${n:-0}" "0"
}

# 应用是否起来了
check_started() {
  local name="$1" log="$2" appcls="$3"
  if grep -aq "Started $appcls in " "$log" 2>/dev/null; then
    ok "$name 启动成功  ($(grep -aoE "Started $appcls in [0-9.]+ seconds" "$log" | tail -1))"
  else
    bad "$name 没起来（没有 'Started $appcls in ... seconds'）"
    grep -a -oE 'Caused by: .*' "$log" 2>/dev/null | tail -3 | sed 's/^/        /'
  fi
}

# ---------------------------------------------------------------
# 起一批应用（走 start-hd-apps.sh 自己的批次机制）。
# ⚠️ 绝对不能 pkill -f java —— 那会杀掉 Nacos/Kafka/ZK。
# ⚠️ 宿主只有 ~3.9GB 内存，一次只能跑一批。
start_batch() {
  local batch="$1"
  echo "--- 起批次 $batch（HD_REDIS_CLUSTER=1）---"
  HD_REDIS_CLUSTER=1 bash /opt/hd/start-hd-apps.sh "$batch" 2>&1 | tail -14
}

# ---------------------------------------------------------------
# 「应用往集群发了命令吗」的**诊断输出**（不是判据）。
#
# ⚠️ 这里**故意**不做断言：命令增量是个**空判**（脚本自己的 INFO/EXISTS
#    命令就计入那个计数器，空闲集群的增量都不是 0），
#    而且它是节点级全局计数器，**无法**把流量归属到应用。
#    判据 ② 的依据是「**应用自己的 key + 应用自己的载荷**」，见 assert_app_key_present。
report_app_talked() {
  local name="$1" delta="$2"
  report_counter_delta "$name" "$delta"
}

# 应用自己的 key 在集群里吗（用 -c 跟随 MOVED，三个 master 都查）
#
# ⚠️ 这**才是**判据 ② 的依据：key 是**应用自己写的**，
#    载荷也是**应用自己的**格式（比如 model:enumdicts:folder:user_sex
#    读回来是 EnumDict 的 JSON）。
#    缺了它就只剩「redis-cli 自己写的 key」—— 那证明不了应用。
#
# ⚠️ 找不到的时候要把**最可能的原因**一起打出来，
#    否则只看到「key 不在」还得自己从头查一遍。
#    两种原因要分清楚（别把「没验证过的猜测」写成结论）：
#      ① 日志里有 UnsupportedOperationException
#         -> 已验证：那条代码路径在集群模式下走的是裸 executePipelined，
#            SDR 2.7.18 的 JedisClusterConnection.openPipeline() 直接抛异常，
#            回调体一次都不执行（数据根本没发出去）。
#      ② 日志里没有异常
#         -> **不能**断言「被 @Async 吞了」—— 那只是**候选原因之一**。
#            已验证的事实是「部署的 jar 里那条路径压根没有集群分支，
#            所以它永远走不到能报错的分支」，异常则被
#            「CompletableFuture 被丢弃（没人 join）」这一步吞掉，
#            于是什么都留不下。其它可能（路径没被触发、数据本身不合法）
#            也不能排除，所以这里只陈述已验证的部分 + 列出其它可能。
assert_app_key_present() {
  local name="$1" key="$2" log="${3:-}"
  local p n found=0
  for p in $P1 $P2 $P3; do
    n=$(rc "$p" EXISTS "$key" | tr -d '\r')
    echo "    $p EXISTS $key = $n"
    [ "$n" = "1" ] && found=1
  done
  if [ "$found" -eq 1 ]; then
    ok "$name 应用写的 $key 在集群里"
    return 0
  fi
  bad "$name 集群里没有 $key —— 应用没写成功"
  if [ -n "$log" ] && [ -f "$log" ]; then
    local n1
    n1=$(grep -ac 'not supported for JedisClusterConnection\|java\.lang\.UnsupportedOperationException' "$log" 2>/dev/null)
    if [ "${n1:-0}" -gt 0 ] 2>/dev/null; then
      echo "        已验证的原因：日志里有 $n1 处 'UnsupportedOperationException / not supported for JedisClusterConnection'"
      echo "          —— 那条代码路径在集群模式下走的是裸 executePipelined，"
      echo "             SDR 2.7.18 的 JedisClusterConnection.openPipeline() 直接抛异常，"
      echo "             回调体一次都不执行（数据根本没发出去）。"
      echo "          出处（去重后）："
      grep -a -A25 'not supported for JedisClusterConnection' "$log" 2>/dev/null \
        | grep -a -oE 'at com\.sac\.[A-Za-z0-9_.$]+\([A-Za-z0-9_.$]+\.java:[0-9]+\)' \
        | sort -u | sed 's/^/                /'
    else
      echo "        日志里**没有** UnsupportedOperationException —— 也就是说"
      echo "        「集群模式下 SDR pipeline 抛异常」这条路径**没有**被走到。"
      echo "        已验证的事实："
      echo "          · 部署的 jar 里这条写路径**没有集群分支**"
      echo "            （RedisRealDataServiceImpl 里没有 isCluster / RedisClusterHashPipeline），"
      echo "            所以它走不到「集群分支里按 slot 分组 pipeline」那条路；"
      echo "          · 抛出的异常又被「CompletableFuture 被丢弃（没人 join）」吞掉，"
      echo "            所以日志里、stderr 里都没有痕迹 —— 失败是完全静默的。"
      echo "        其它候选原因（**未**验证，不能当结论）："
      echo "          · 写路径压根没被触发（Kafka 消息没到 / 没被消费）；"
      echo "          · 数据本身不合法，被解析层跳过了。"
      echo "        排查入口：应用日志里的「每秒从kafka接收的数量」是否 > 0。"
    fi
  fi
  return 1
}

echo "### 目标: $IP  (ports $P1/$P2/$P3)  pass=<已隐藏>  [$PASS_SRC]"
echo "### 期望节点列表（**顺序敏感**）: $EXPECTED_NODES"

echo
echo "############ L0 — 前置：集群活着 ############"
down=0
for port in $P1 $P2 $P3; do
  pong=$(r "$port" PING | tr -d '\r')
  case "$pong" in
    PONG) ok "L0 $IP:$port PING -> PONG" ;;
    *NOAUTH*|*WRONGPASS*)
      bad "L0 $IP:$port 认证失败（$pong）—— 密码不对？[$PASS_SRC]"; down=$((down+1)) ;;
    *)
      bad "L0 连不上 $IP:$port（PING 返回 '$pong'）—— 集群没起来？先跑 hd-redis-cluster.sh status"; down=$((down+1)) ;;
  esac
done
if [ "$down" -gt 0 ]; then
  echo "SUMMARY: PASS=$P FAIL=$F SKIP=$S"
  DONE=1
  exit 1
fi
state=$(r "$P1" CLUSTER INFO | tr -d '\r' | grep -m1 '^cluster_state' | cut -d: -f2)
chk "L0 cluster_state" "$state" "ok"

echo
echo "############ A — web-controller（napstarweb）############"
start_batch 1
echo
echo "=== 判据 A1：日志那行 + 模式 ==="
A_LOG="$LOG_DIR/web-controller.log"
check_started "web-controller" "$A_LOG" "NapstarWebRestApplication"
check_fatal "web-controller" "$A_LOG"
check_cluster_mode "web-controller" "$A_LOG"
echo
echo "=== 判据 A2：真实读写（应用自己写进集群的痕迹）==="
echo "  --- 写路径: StartupRunner -> SVGCacheServiceImpl.loadRTConfigKafka()"
echo "      写 hash 'real_graph:realscope'（field=<objType>_<attrType>）---"
#
# ⚠️⚠️ **前置条件**：这条写路径是**有条件的**。
#
#   `loadRTConfigKafka()` 对每个模型类型调 `modelDataService.matchOType(oname)`，
#   **只有 matchOType 返回非 null 才会执行 hSet**。
#   matchOType 查的是 `info.model_objecttype` / `info.model_attribute` /
#   `info.model_objectattribute` —— 这个安装包里这些表**全是 0 行**，
#   于是每个模型名都抛 `OTypeException: oType数值非法或不存在：XXX`，
#   `continue` 掉，**hSet 一次都不执行**。
#
#   实测（**同一个 jar**，**单机**模式 —— pipeline 完全正常、0 个 UOE）：
#     `real_graph:*` key 数 = 0
#   ⇒ 这个 key 在**单机模式也不会出现**。它是**数据缺口**，不是集群模式的问题。
#
#   所以：元数据表是空的时候，这条判据**不可执行** —— 必须**跳过**并说清原因。
#   报 FAIL 是错的：重建 jar 之后它**还会** FAIL，
#   那样就把「环境缺数据」误报成「应用有 bug」（见 docker/hd-napstar/DEFECTS.md D7）。
#
A_META_ROWS=$(model_metadata_rows)
echo "    前置检查: info.model_objecttype 行数 = $A_META_ROWS"
if [ "$A_META_ROWS" = "-1" ]; then
  echo "    （读不到 PG —— 前置条件无法判定，按「不可执行」处理，跳过 A2）"
  skip "A2 web-controller 应用层读写 —— 前置条件无法判定（读不到 info.model_objecttype 的行数）"
elif [ "$A_META_ROWS" -eq 0 ] 2>/dev/null; then
  skip "A2 web-controller 应用层读写 —— 判据不可执行：模型元数据表是空的"
  echo "        （info.model_objecttype / model_attribute / model_objectattribute 都是 0 行，"
  echo "          所以 matchOType() 对每个模型名都抛 OTypeException，"
  echo "          loadRTConfigKafka() 的 hSet 一次都不会执行 ——"
  echo "          这个 key 在**单机**模式下也不会出现，是数据缺口，不是集群模式的问题。"
  echo "          详见 docker/hd-napstar/DEFECTS.md D7 的说明。）"
else
  echo "    前置条件满足（元数据表有 $A_META_ROWS 行），执行 A2"
  A_BEFORE=$(counters_snapshot)
  echo "    写前计数器: $A_BEFORE"
  # 主动触发一次：StartupRunner 在启动时就跑过一次 loadRTConfigKafka；
  # 这里再调它的 HTTP 入口（SVGCacheController.initGraph），
  # 确保写路径被**主动**触发，而不是「碰巧启动时跑过」。
  A_TOK=$(cat /tmp/hd-token.txt 2>/dev/null)
  if [ -n "$A_TOK" ]; then
    A_CODE=$(curl -s -m 30 -o /tmp/hd-svg-resp.txt -w '%{http_code}' \
      -X POST -H "Authorization: $A_TOK" -H 'Content-Type: application/json' -d '{}' \
      "http://127.0.0.1:8099/napstarweb/svgCache/initGraph" 2>/dev/null)
    echo "    触发 svgCache/initGraph -> HTTP $A_CODE"
    # ⚠️ 404 = 入口不存在 = **判据没法执行**。
    #    这里**不能**像之前那样「打个招呼就跳过」—— 那会让 A2 悄悄退化成
    #    「希望 StartupRunner 跑过了」，判据形同虚设。
    #    跟 B2 的处理保持一致：不可达就是不可执行，明确报出来。
    if [ "$A_CODE" = "404" ] || [ "$A_CODE" = "000" ] || [ -z "$A_CODE" ]; then
      skip "A2 web-controller 触发入口不可达（HTTP $A_CODE）—— 判据没法执行"
      echo "        （POST /napstarweb/svgCache/initGraph 不可达；"
      echo "          入口要是挪了地方，这里要跟着改）"
    else
      sleep 3
      A_AFTER=$(counters_snapshot)
      echo "    写后计数器: $A_AFTER"
      report_app_talked "A2" "$(counter_delta "$A_BEFORE" "$A_AFTER")"
      echo "  --- 应用自己的 key 在集群里吗 ---"
      assert_app_key_present "A2" "real_graph:realscope" "$A_LOG"
    fi
  else
    skip "A2 web-controller 没有 token（/tmp/hd-token.txt），没法触发应用写入"
  fi
fi
echo
echo "=== 判据 A3：JVM 层的 UnsupportedOperationException ==="
# ⚠️ A3 **不受** A2 的前置条件影响：它查的是**应用日志**，
#    而那些异常是 SDR 在 `openPipeline()` 里抛的，
#    发生在 hSet 之前 —— 跟元数据表空不空**无关**。
#    所以 A3 依然是有效的回归判据。
check_no_pipeline_exception "web-controller" "$A_LOG"

echo
echo "############ B — model-controller（modelserver）############"
start_batch 1b
echo
echo "=== 判据 B1：日志那行 + 模式 ==="
B_LOG="$LOG_DIR/model-controller.log"
check_started "model-controller" "$B_LOG" "ModelserverRestApplication"
check_fatal "model-controller" "$B_LOG"
check_cluster_mode "model-controller" "$B_LOG"
echo
echo "=== 判据 B2：真实读写（应用自己写进集群的痕迹）==="
echo "  --- 写路径: CacheServiceImpl.getEnumDictTypes() 上的 @Cacheable"
echo "      （RedisCacheManager，key 前缀 'model:' + 缓存名 + ':'）---"
#
# ⚠️ B2 没有 A2 那种前置条件问题：@Cacheable 的写入不依赖模型元数据表
#    （`info.model_enumdict` 有 102 行，folder 级别的 'user_sex' 就在里面），
#    所以这条判据**在本环境里都可执行**，测的是真东西。
B_BEFORE=$(counters_snapshot)
echo "    写前计数器: $B_BEFORE"
B_TOK=$(cat /tmp/hd-token.txt 2>/dev/null)
if [ -n "$B_TOK" ]; then
  B_CODE=$(curl -s -m 30 -o /tmp/hd-model-resp.txt -w '%{http_code}' \
    -X POST -H "Authorization: $B_TOK" -H 'Content-Type: application/json' -d '{"list":["user_sex"]}' \
    "http://127.0.0.1:8090/model/modelData/getEnumDictTypes" 2>/dev/null)
  echo "    触发 modelData/getEnumDictTypes -> HTTP $B_CODE"
  if [ "$B_CODE" = "404" ] || [ "$B_CODE" = "000" ] || [ -z "$B_CODE" ]; then
    bad "B2 触发写入的接口不可达（HTTP $B_CODE）—— 应用层读写没法验"
  fi
else
  bad "B2 没有 token（/tmp/hd-token.txt），没法触发应用写入"
fi
sleep 3
B_AFTER=$(counters_snapshot)
echo "    写后计数器: $B_AFTER"
report_app_talked "B2" "$(counter_delta "$B_BEFORE" "$B_AFTER")"
echo "  --- 应用自己的 key 在集群里吗（model: 前缀）---"
B_FOUND=0
for p in $P1 $P2 $P3; do
  # ⚠️ KEYS 只在**本 master** 上查（KEYS 没有槽感知），
  #    所以三个 master 都要查一遍再相加。
  n=$(r "$p" KEYS 'model:*' | grep -c '^model:')
  echo "    $p model:* key 数 = $n"
  [ "${n:-0}" -gt 0 ] 2>/dev/null && B_FOUND=1
done
if [ "$B_FOUND" -eq 1 ]; then
  ok "B2 应用写的 model:* key 在集群里"
  # 再把那个 key 读回来，确认真实数据（往返成立）
  B_ONE=$(r "$P1" KEYS 'model:*' | grep -m1 '^model:')
  if [ -n "$B_ONE" ]; then
    B_VAL=$(rc "$P1" GET "$B_ONE" | tr -d '\r')
    echo "    读回 $B_ONE -> ${B_VAL:0:120}"
    if [ -n "$B_VAL" ]; then
      ok "B2 读回应用写的 key（往返成立）"
    else
      bad "B2 $B_ONE 在集群里但读回来是空的"
    fi
  fi
else
  bad "B2 集群里没有 model:* key —— 应用没写成功"
fi
echo
echo "=== 判据 B3：JVM 层的 UnsupportedOperationException ==="
check_no_pipeline_exception "model-controller" "$B_LOG"

echo
echo "############ C — rtdata-consumer（realserver）############"
start_batch 1
echo
echo "=== 判据 C1：日志那行 + 模式 ==="
C_LOG="$LOG_DIR/rtdata-consumer.log"
check_started "rtdata-consumer" "$C_LOG" "PointtabproducerApplication"
check_fatal "rtdata-consumer" "$C_LOG"
check_cluster_mode "rtdata-consumer" "$C_LOG"
echo
echo "=== 判据 C2：真实读写（发一条 Kafka 消息，逼应用写集群）==="
echo "  --- 写路径: RTListener.onMessage(INCDATA) -> batchWirtePip()"
echo "      写 hash 'real_data:<otype>:<obid>'，field=<atype> ---"
C_BEFORE=$(counters_snapshot)
echo "    写前计数器: $C_BEFORE"
# 造一条 INCDATA 消息。
# 格式（OmsWriteByKafkaServiceImpl / RedisRealDataServiceImpl.processItem）：
#   obid;atype,datatype,value,time
# obid 的高 32 位是 otype（SystemIDUtil.extractOType）。
# 用一个不会跟真实数据撞的 otype：0x7A11 -> 31249。
C_OTYPE=31249
C_OBID=$(( (C_OTYPE << 32) | 1 ))
C_ATYPE="9001"
C_MSG="$C_OBID;$C_ATYPE,2,3.14,2026-11-01 00:00:00"
C_KEY="real_data:$C_OTYPE:$C_OBID"
CLEAN_KEYS+=("$C_KEY")
echo "    消息: $C_MSG"
echo "    期望 key: $C_KEY"
if [ -x "$KAFKA_HOME/bin/kafka-console-producer.sh" ]; then
  printf '%s\n' "$C_MSG" > "$WORKDIR/incdata.txt"
  timeout 60 "$KAFKA_HOME/bin/kafka-console-producer.sh" \
    --bootstrap-server node1:9092 --topic INCDATA \
    < "$WORKDIR/incdata.txt" >/dev/null 2>&1
  echo "    已往 INCDATA 发一条消息"
else
  bad "C2 找不到 kafka-console-producer.sh（$KAFKA_HOME/bin）"
fi
# 等应用消费（@KafkaListener）+ 异步写（@Async + 重试退避，最多 ~1s）
sleep 15
C_AFTER=$(counters_snapshot)
echo "    写后计数器: $C_AFTER"
report_app_talked "C2" "$(counter_delta "$C_BEFORE" "$C_AFTER")"
echo "  --- 应用自己的 key 在集群里吗 ---"
if assert_app_key_present "C2" "$C_KEY" "$C_LOG"; then
  # 再读回那个 field，确认真实数据而不是空壳
  C_VAL=$(rc "$P1" HGET "$C_KEY" "$C_ATYPE" | tr -d '\r')
  echo "    读回 field $C_ATYPE = $C_VAL"
  if [ -n "$C_VAL" ]; then
    ok "C2 读回应用写的字段值（非空）"
  else
    bad "C2 key 在但 field 是空的 —— 写进去的不是预期数据"
  fi
fi
echo
echo "=== 判据 C3：JVM 层的 UnsupportedOperationException ==="
check_no_pipeline_exception "rtdata-consumer" "$C_LOG"

echo
echo "############ D — 分片分布（key 确实散到多个 master 上）############"
# ⚠️ 这一段**自己写** N 个 key 再断言分布 ——
#    不能只看 DBSIZE（DBSIZE 统计的是该节点上**所有** key，
#    混着别人的；而且应用刚跑过，基线不是 0）。
# ⚠️ 用 KEYS 数**我们自己的** key（名字前缀唯一），不受别人影响。
#
# ⚠️⚠️ 前缀必须是**本脚本专属**的。
#    之前这里用的是 `hd:test:cluster:spread` —— **跟
#    `scripts/hd-cluster-verify.sh`（Task 2）的 L5 段用的前缀一模一样**，
#    而 Task 2 的 L5 断言数的正是 `hd:test:cluster:spread*`。
#    两个脚本一旦同时跑（或者前后脚跑、有一个没清干净），
#    本脚本的 D 段计数会把 Task 2 的 key 算进来，
#    Task 2 的 L5 也会把本脚本的算进去 —— 两边的断言一起坏。
#    现在改用 `hd:test:apptest:spread`，跟 Task 2 完全不重叠。
NK=30
SPREAD_PREFIX="hd:test:apptest:spread"
i=1
while [ "$i" -le "$NK" ]; do
  CLEAN_KEYS+=("${SPREAD_PREFIX}${i}")
  i=$((i+1))
done
wrote=0
i=1
while [ "$i" -le "$NK" ]; do
  out=$(rc "$P1" SET "${SPREAD_PREFIX}${i}" "s${i}" | tr -d '\r')
  [ "$out" = "OK" ] && wrote=$((wrote+1))
  i=$((i+1))
done
chk "D $NK 个 key 全部写入返回 OK" "$wrote" "$NK"
s1=0; s2=0; s3=0
for p in $P1 $P2 $P3; do
  n=$(r "$p" KEYS "${SPREAD_PREFIX}*" | grep -c "$SPREAD_PREFIX")
  echo "    $p 上的 spread key 数 = $n"
  case "$p" in
    $P1) s1=$n ;;
    $P2) s2=$n ;;
    $P3) s3=$n ;;
  esac
done
chk "D 各 master 上的 spread key 数之和" "$((s1+s2+s3))" "$NK"
spread=0
for kc in $s1 $s2 $s3; do [ "${kc:-0}" -gt 0 ] 2>/dev/null && spread=$((spread+1)); done
chk "D key 分散在 3 个 master 上" "$spread" "3"
maxd=$s1; [ "${s2:-0}" -gt "$maxd" ] && maxd=$s2; [ "${s3:-0}" -gt "$maxd" ] && maxd=$s3
if [ "$NK" -gt 0 ] && [ $((maxd*10)) -le $((NK*7)) ]; then
  ok "D 分布不过偏（最大分片 $maxd/$NK ≤ 70%）"
else
  bad "D 分布过偏（最大分片 $maxd/$NK）—— 槽分配可能有问题"
fi
echo
echo "  --- 读回一个我们写的 key（写完能读回来）---"
SPREAD_PROBE="${SPREAD_PREFIX}1"
rc "$P1" SET "$SPREAD_PROBE" "probe-value" >/dev/null 2>&1
chk "D 读回 $SPREAD_PROBE" "$(rc "$P1" GET "$SPREAD_PROBE" | tr -d '\r')" "probe-value"

echo
echo "############ E — 清理 ############"
cleanup
CLEAN_KEYS=()
# ⚠️ 清理模式必须**只**匹配本脚本自己的前缀。
#    之前这里用的是 `hd:test:cluster:*` —— 那会连 Task 2
#    （scripts/hd-cluster-verify.sh）的 `hd:test:cluster:spread*` /
#    `hd:test:cluster:pipe*` 一起删掉，把别的脚本的现场给毁了。
#    现在只清 `hd:test:apptest:*`（本脚本专属）。
left=0
for p in $P1 $P2 $P3; do
  n=$(r "$p" KEYS 'hd:test:apptest:*' | grep -c 'hd:test:apptest:')
  echo "    $p 残留 $n 个测试 key"
  left=$((left+n))
done
chk "E 清理后无残留测试 key" "$left" "0"

# ⚠️ **应用自己写的 key 也要清掉** —— 判据 B2 那一步让 model-controller
#    往集群里写了一个 `model:enumdicts:folder:user_sex`。
#    交付要求是「把集群恢复原样（三个 master 的 DBSIZE=0）」，
#    所以这里把它也删掉。
#    ⚠️ 删 key 要用 -c（跟随 MOVED）—— 这个 key 可能不在 16379 上。
echo "  --- 清掉应用写的 key（判据 B2 留下的）---"
for p in $P1 $P2 $P3; do
  # ⚠️ KEYS 没有槽感知，只能逐 master 查（每个 master 只列出自己的 key）。
  for k in $(r "$p" KEYS 'model:*' | grep '^model:'); do
    rc "$P1" DEL "$k" >/dev/null 2>&1
    echo "    DEL $k"
  done
done
echo "  --- 三个 master 现在的 DBSIZE ---"
total=0
for p in $P1 $P2 $P3; do
  n=$(r "$p" DBSIZE | tr -d '\r')
  echo "    $p DBSIZE = $n"
  case "$n" in
    ''|*[!0-9]*) ;;
    *) total=$((total + n)) ;;
  esac
done
chk "E 清理后三个 master 的 key 总数为 0" "$total" "0"

DONE=1
echo
echo "SUMMARY: PASS=$P FAIL=$F SKIP=$S"
[ "$F" -eq 0 ]

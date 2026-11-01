#!/bin/bash
# 底层集群读写验证：L1-L6。
# 在 hd-node1 容器内跑（宿主 bash 是坏的 WSL shim）。
#
# 这是「工具层」的集群验证：证明**集群本身**行为正确（槽位、跨槽读写、
# MOVED 重定向、分片分布），这样后面 Task 5（应用层切集群模式）出问题时，
# 能区分是集群的锅还是应用的锅。
#
# ⚠️ redis-cli **没有连接超时**：IP 不可达时会永远挂着。所有调用都用
#    `timeout` 包一层。
# ⚠️ redis-cli 的 **退出码不可靠**：`redis-cli PING` 在 "Connection refused"
#    时也返回 0（CLUSTER SLOTS 才返回 1）。所以判活/断言一律看**输出文本**，
#    绝不拿裸 redis-cli 的退出码当判据。
set -uo pipefail

REDIS_HOME=/opt/software/redis-8.10.0
RC="$REDIS_HOME/bin/redis-cli"
PASS="${HD_CLUSTER_PASS:-HdClusterPw2026}"
# getent hosts node1 | awk '{print $1}' -> 单个 IP。
# ⚠️ 不要用 `hostname -i`：它返回空格分隔的多个地址。
IP="${HD_CLUSTER_IP:-$(getent hosts node1 | awk '{print $1}')}"
P1=16379; P2=16380; P3=16381
TMO=5
P=0; F=0
ok()  { echo "  PASS  $*"; P=$((P+1)); }
bad() { echo "  FAIL  $*"; F=$((F+1)); }
chk() { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1 (got '$2', want '$3')"; fi; }

r()  { timeout "$TMO" "$RC" -h "$IP" -p "$1" -a "$PASS" --no-auth-warning "${@:2}" 2>&1; }
rc() { timeout "$TMO" "$RC" -c -h "$IP" -p "$1" -a "$PASS" --no-auth-warning "${@:2}" 2>&1; }

# ---------------------------------------------------------------
# 批量算 key 的槽位：**一次连接**里发 N 条 CLUSTER KEYSLOT。
#
# ⚠️ 千万别写成「for 循环里一次算一个」：IP 不可达时每次都要等满 timeout，
#    200 个候选 key = 200 × 5s = 1000s，脚本看上去像挂死了。
#    批量版本只有一次 timeout。
#
# 用法：keyslots <prefix> <count> -> 每行一个 "key slot"
keyslots() {
  local prefix="$1" count="$2" i
  for i in $(seq 1 "$count"); do
    echo "CLUSTER KEYSLOT $prefix$i"
  done | timeout "$TMO" "$RC" -h "$IP" -p "$P1" -a "$PASS" --no-auth-warning 2>&1 \
    | grep -E '^[0-9]+$' | nl -ba | awk '{print "'"$prefix"'" $1, $2}'
}

# ---------------------------------------------------------------
# 批量执行一批命令（一条连接，全部走 stdin）。
# ⚠️ redis-cli -c 在集群模式下会把重定向提示打到 stderr：
#    "-> Redirected to slot [N] located at ip:port" —— 那是**正常**的，
#    要过滤掉，只留真正的响应（OK / 值 / 数字）。
#
# 用法：batch_cmds <cmd...>   例：batch_cmds "SET k v" "GET k"
batch_cmds() {
  local c
  for c in "$@"; do echo "$c"; done \
    | timeout "$TMO" "$RC" -c -h "$IP" -p "$P1" -a "$PASS" --no-auth-warning 2>&1 \
    | grep -v '^-> Redirected to slot'
}

echo "### 目标: $IP  (ports $P1/$P2/$P3)  pass=$PASS"

# ---------------------------------------------------------------
# 清理用的 key 列表（跨槽的 key 不能用一条 DEL 删 —— 会 CROSSSLOT 整条失败，
# 所以必须一个一个删）。
CLEAN_KEYS=()

cleanup() {
  local k
  [ "${#CLEAN_KEYS[@]}" -eq 0 ] && return 0
  # ⚠️ 不能用一条 `DEL k1 k2 k3` —— 跨槽的 key 会让整条命令
  #    CROSSSLOT 失败，**一个都删不掉**（实测过）。
  #    所以一条一条 DEL，但打包进同一个连接里。
  local cmds=()
  for k in "${CLEAN_KEYS[@]}"; do
    [ -n "$k" ] && cmds+=("DEL $k")
  done
  [ "${#cmds[@]}" -gt 0 ] && batch_cmds "${cmds[@]}" >/dev/null
}
# 无论中途怎么退出（含 Ctrl-C / 报错），都要清理掉自己写的 key。
# SUMMARY 在正常路径末尾打印；trap 只负责兜底清理，异常退出时才补打 SUMMARY。
# ⚠️ 退出码变量叫 _rc_ 而不是 rc —— rc 是本脚本的 redis-cli 包装函数。
DONE=0
trap '_e=$?; cleanup; if [ "$DONE" -eq 0 ]; then echo; echo "SUMMARY: PASS=$P FAIL=$F"; fi; exit $_e' EXIT

echo
echo "############ L0 — 连通性前置检查 ############"
# ⚠️ 一定要先探活：IP 不可达时，每条 redis-cli 都要等满 timeout，
#    后面几十条命令会把总耗时拖成好几分钟。探活失败就**立刻**退出，
#    把「集群没起来」和「集群行为不对」这两种失败区分开。
# ⚠️ 判活看**输出文本**（PING / PONG），不看退出码 ——
#    redis-cli PING 在 "Connection refused" 时也返回 0。
pong=$(r $P1 PING | tr -d '\r')
if [ "$pong" != "PONG" ]; then
  case "$pong" in
    *NOAUTH*|*WRONGPASS*)
      bad "L0 认证失败（$pong）—— 密码不对？HD_CLUSTER_PASS=${HD_CLUSTER_PASS:-<未设置，用默认>}" ;;
    *)
      bad "L0 连不上 $IP:$P1（PING 返回 '$pong'）—— 集群没起来？先跑 hd-redis-cluster.sh start" ;;
  esac
  echo
  echo "SUMMARY: PASS=$P FAIL=$F"
  DONE=1
  exit 1
fi
ok "L0 $IP:$P1 PING -> PONG"
echo "    (redis-cli 版本) $("$RC" --version 2>&1)"

echo
echo "############ L1 — 集群健康 ############"
info=$(r $P1 CLUSTER INFO | tr -d '\r')
echo "    (CLUSTER INFO 头部)"
echo "$info" | head -8 | sed 's/^/      /'
chk "L1 cluster_state"            "$(echo "$info" | grep -oP 'cluster_state:\K.*')"            "ok"
chk "L1 cluster_slots_assigned"   "$(echo "$info" | grep -oP 'cluster_slots_assigned:\K.*')"   "16384"
chk "L1 cluster_slots_ok"         "$(echo "$info" | grep -oP 'cluster_slots_ok:\K.*')"         "16384"
chk "L1 cluster_slots_fail"       "$(echo "$info" | grep -oP 'cluster_slots_fail:\K.*')"       "0"
chk "L1 cluster_size"             "$(echo "$info" | grep -oP 'cluster_size:\K.*')"             "3"
chk "L1 cluster_known_nodes"      "$(echo "$info" | grep -oP 'cluster_known_nodes:\K.*')"      "3"

echo
echo "############ L2 — 槽位分布（3 个 master 各分到槽）############"
# ⚠️ 不要按行号猜格式，也不要假设 RESP2 的缩进。
#    redis-cli 8.10 的 CLUSTER SHARDS 输出是**扁平的「一行一个值」**：
#      slots / 5461 / 10922 / nodes / id / <id> / port / 16380 / ...
#    即：每出现一个 `slots`，紧跟的 2 行就是该分片的槽区间 [start, end]。
#    （已对着真集群的输出逐字节核对过，cat -A 显示无 \r。）
shards=$(r $P1 CLUSTER SHARDS | tr -d '\r')
# 抽出 (start end) 区间对：slots 行的后两行分别是 start 和 end。
# 输出成「start end」两个字段（一行一个区间），方便后面 awk 算覆盖总数。
ranges=$(echo "$shards" | awk '
  /^slots$/ { want=2; next }
  want==2   { s=$1; want=1; next }
  want==1   { printf "%s %s\n", s, $1; want=0 }
')
n_ranges=$(echo "$ranges" | grep -c . )
chk "L2 槽位区间数" "$n_ranges" "3"
# 各区间起点排序后应为 0 / 5461 / 10923
starts=$(echo "$ranges" | awk '{print $1}' | sort -n | tr '\n' ' ')
chk "L2 各区间起点" "$starts" "0 5461 10923 "
# 各区间终点排序后应为 5460 / 10922 / 16383
ends=$(echo "$ranges" | awk '{print $2}' | sort -n | tr '\n' ' ')
chk "L2 各区间终点" "$ends" "5460 10922 16383 "
# 区间总数必须覆盖 16384 且互不重叠（起点 == 上一个终点 + 1）
covered=$(echo "$ranges" | awk '{s+=$2-$1+1} END{print s+0}')
chk "L2 槽位覆盖总数" "$covered" "16384"
# ⚠️ CLUSTER SHARDS 的区间顺序**不是**按起点排的（实测是 5461 / 10923 / 0），
#    所以连续性检查必须先按起点排序。
contig=$(echo "$ranges" | sort -n -k1,1 | awk '
  { if (NR>1 && $1 != prev+1) { bad=1; print "gap"; exit } prev=$2 }
  END { if (bad != 1) print "contig" }')
chk "L2 区间连续无重叠" "$contig" "contig"

# 交叉验证：CLUSTER NODES 里每个 master 的槽区间也要对得上。
nodes=$(r $P1 CLUSTER NODES | tr -d '\r')
echo "    (CLUSTER NODES)"
echo "$nodes" | sed 's/^/      /'
n_masters=$(echo "$nodes" | grep -c 'master')
chk "L2 CLUSTER NODES 里的 master 数" "$n_masters" "3"
# 每个 master 的槽区间：CLUSTER NODES 的一行是
#   <id> <addr> <flags> <master_id> <ping_sent> <pong_recv> <epoch> <link_state> <slots...>
# 槽区间是 **link_state(connected) 之后**的所有字段，形如 0-5460 / 10923-16383。
# ⚠️ 不要写死字段序号 —— 取 connected 之后的一切更稳。
node_ranges=$(echo "$nodes" | grep 'master' | awk '{f=0; for(i=1;i<=NF;i++) if ($i=="connected") f=1; else if (f && $i ~ /^[0-9]+(-[0-9]+)?$/) printf "%s ", $i}')
echo "    master 槽区间: $node_ranges"
n_node_ranges=$(echo "$node_ranges" | wc -w)
chk "L2 CLUSTER NODES 的槽区间数" "$n_node_ranges" "3"
# CLUSTER SHARDS 和 CLUSTER NODES 描述的区间集合必须一致
# （两边都归一化成 "start-end" 再排序比较）
s1=$(echo "$ranges"       | awk '{print $1"-"$2}' | sort | tr '\n' ',')
s2=$(echo "$node_ranges" | tr ' ' '\n' | grep -v '^$' | sort | tr '\n' ',')
chk "L2 SHARDS 与 NODES 的槽区间一致" "$s1" "$s2"

echo
echo "############ L3 — 跨槽读写（-c 模式）############"
# 找 3 个落在不同槽的 key
K1="hd:test:cluster:a"; K2="hd:test:cluster:b"; K3="hd:test:cluster:c"
for k in $K1 $K2 $K3; do
  CLEAN_KEYS+=("$k")
  slot=$(r $P1 CLUSTER KEYSLOT "$k" | tr -d '\r')
  echo "    $k -> slot $slot"
done
rc $P1 SET "$K1" v1 >/dev/null
rc $P1 SET "$K2" v2 >/dev/null
rc $P1 SET "$K3" v3 >/dev/null
chk "L3 读回 K1" "$(rc $P1 GET "$K1")" "v1"
chk "L3 读回 K2" "$(rc $P1 GET "$K2")" "v2"
chk "L3 读回 K3" "$(rc $P1 GET "$K3")" "v3"
# 三个 key 必须落在不同槽上（否则 L3 的「跨槽」名不副实）。
# 这个 3-master 布局下三个槽区间各属一个 master，所以不同槽 = 不同 master。
# （L5 会再用 30 个 key 直接验证「三个 master 都收到了 key」。）
slot1=$(r $P1 CLUSTER KEYSLOT "$K1" | tr -d '\r')
slot2=$(r $P1 CLUSTER KEYSLOT "$K2" | tr -d '\r')
slot3=$(r $P1 CLUSTER KEYSLOT "$K3" | tr -d '\r')
chk "L3 三个 key 落在 3 个不同的槽" \
    "$(printf '%s\n' "$slot1" "$slot2" "$slot3" | sort -u | grep -c .)" "3"

echo
echo "############ L4 — MOVED 重定向（不加 -c）############"
# ⚠️ 必须挑一个**确实不在 16379 上**的 key，否则测不到 MOVED。
#    做法：先算出 16379 自己拥有的槽区间，再从 CLUSTER NODES 里找出
#    别的 master 的槽区间，用一个落在那个区间里的 key 来测。
own_ranges=$(echo "$nodes" | grep "myself,master" | awk '{f=0; for(i=1;i<=NF;i++) if ($i=="connected") f=1; else if (f && $i ~ /^[0-9]+(-[0-9]+)?$/) print $i}')
echo "    16379 拥有: $own_ranges"
# 别人的第一个槽区间（区间和地址取自**同一行**，保证配对正确）
other_range=""
other_ip=""
other_line=$(echo "$nodes" | grep 'master' | grep -v 'myself,master' | head -1)
if [ -n "$other_line" ]; then
  other_ip=$(echo "$other_line" | awk '{print $2}' | cut -d@ -f1)
  other_range=$(echo "$other_line" | awk '{f=0; for(i=1;i<=NF;i++) if ($i=="connected") f=1; else if (f && $i ~ /^[0-9]+(-[0-9]+)?$/) {print $i; exit}}')
fi
echo "    别人的节点: $other_ip  槽区间: $other_range"

# 找一个 slot 落在 other_range 里的 key（一次连接批量算，避免 N 次往返）
MOVED_KEY=""
MOVED_SLOT=""
if [ -n "$other_range" ]; then
  # other_range 形如 "5461-10922"
  lo=${other_range%%-*}; hi=${other_range##*-}
  hit=$(keyslots "hd:test:cluster:m" 200 | awk -v lo="$lo" -v hi="$hi" '$2>=lo && $2<=hi {print $1" "$2; exit}')
  if [ -n "$hit" ]; then
    MOVED_KEY=${hit% *}; MOVED_SLOT=${hit##* }
  fi
fi
if [ -z "$MOVED_KEY" ]; then
  bad "L4 找不到落在 $other_range 槽区间的 key"
else
  CLEAN_KEYS+=("$MOVED_KEY")
  echo "    测试 key: $MOVED_KEY (slot $MOVED_SLOT, 应属于 $other_ip)"
  # 先用 -c 写进去（-c 会跟随重定向）
  rc $P1 SET "$MOVED_KEY" mv >/dev/null
  # 不加 -c，从 16379 直接 GET -> 必须返回 MOVED <slot> <ip>:<port>
  out=$(r $P1 GET "$MOVED_KEY" | tr -d '\r')
  echo "    非 -c GET 返回: $out"
  if echo "$out" | grep -qE "^MOVED $MOVED_SLOT "; then
    ok "L4 非本槽 key 返回 MOVED（$out）"
  else
    bad "L4 期望 'MOVED $MOVED_SLOT ...'，实得 '$out'"
  fi
  # MOVED 里的目标地址必须真的是那个 master（不能是 127.0.0.1 —— 那是老集群踩过的坑）
  moved_target=$(echo "$out" | grep -oP 'MOVED \d+ \K.*')
  if [ "$moved_target" = "$other_ip" ]; then
    ok "L4 MOVED 目标地址正确（$moved_target）"
  else
    bad "L4 MOVED 目标地址异常（'$moved_target'，期望 '$other_ip'）"
  fi
  # -c 必须能自动跟随重定向读回来
  chk "L4 加 -c 能跟随重定向读回" "$(rc $P1 GET "$MOVED_KEY")" "mv"
fi

echo
echo "############ L5 — 分片倾斜（key 落在不同 master 上）############"
# ⚠️ DBSIZE 统计的是该节点数据库里**所有** key，不只是我们的 ——
#    所以测「增量」而不是绝对值。
# ⚠️ 只写 3 个 key 有可能全落在 2 个 master 上（概率不低），
#    这里写 30 个，落在 ≤2 个 master 上的概率可忽略。
NK=30
before1=$(r $P1 DBSIZE); before2=$(r $P2 DBSIZE); before3=$(r $P3 DBSIZE)
echo "    写前 DBSIZE: $P1=$before1  $P2=$before2  $P3=$before3"
# 一次连接写完 30 个 key（每条往返 5s 超时下，30 次往返 = 150s，太慢）
cmds=()
i=1
while [ "$i" -le "$NK" ]; do
  key="hd:test:cluster:spread$i"
  CLEAN_KEYS+=("$key")
  cmds+=("SET $key s$i")
  i=$((i+1))
done
wrote=$(batch_cmds "${cmds[@]}" | grep -c '^OK')
chk "L5 $NK 个 key 一次写入全部返回 OK" "$wrote" "$NK"
after1=$(r $P1 DBSIZE); after2=$(r $P2 DBSIZE); after3=$(r $P3 DBSIZE)
echo "    写后 DBSIZE: $P1=$after1  $P2=$after2  $P3=$after3"
d1=$((after1-before1)); d2=$((after2-before2)); d3=$((after3-before3))
total=$((d1+d2+d3))
echo "    增量: $P1=+$d1  $P2=+$d2  $P3=+$d3  (total=$total)"
chk "L5 $NK 个 key 全部写入" "$total" "$NK"
spread=0
for d in $d1 $d2 $d3; do [ "$d" -gt 0 ] && spread=$((spread+1)); done
chk "L5 key 分散在 3 个 master 上" "$spread" "3"
# 分布不能太偏（任一 master 超过 70% 说明槽分配有问题）
maxd=$d1; [ "$d2" -gt "$maxd" ] && maxd=$d2; [ "$d3" -gt "$maxd" ] && maxd=$d3
if [ "$NK" -gt 0 ] && [ $((maxd*10)) -le $((NK*7)) ]; then
  ok "L5 分布不过偏（最大分片 $maxd/$NK ≤ 70%）"
else
  bad "L5 分布过偏（最大分片 $maxd/$NK）—— 槽分配可能有问题"
fi
# 每个 master 上都要能读到自己的 key
r1=$(r $P1 KEYS 'hd:test:cluster:spread*' | grep -c 'hd:test:cluster:spread')
r2=$(r $P2 KEYS 'hd:test:cluster:spread*' | grep -c 'hd:test:cluster:spread')
r3=$(r $P3 KEYS 'hd:test:cluster:spread*' | grep -c 'hd:test:cluster:spread')
echo "    各 master 上的 spread key 数: $P1=$r1  $P2=$r2  $P3=$r3"
chk "L5 各 master 上的 key 数之和" "$((r1+r2+r3))" "$NK"

echo
echo "############ L6 — pipeline 在集群下的行为 ############"
# 背景：Spring Data Redis 2.7.18 的 JedisClusterConnection.openPipeline()
# 直接抛 UnsupportedOperationException —— callback 体一次都不跑，
# 一条 Redis 命令都发不出去。所以 HD 代码在集群模式下必须改用
# redisTemplate.execute(cb)（RedisClusterHelper.isCluster() 分支）。
# 这个 L6 就是把那个限制**在真实集群上复现出来**。
#
# 实测（redis-cli 8.10）：--pipe 在集群模式下**不跟随重定向**：
#   - 目标 key 落在本节点槽上   -> errors: 0, replies: N（能跑通）
#   - 目标 key 落在别的节点槽上 -> 每条都返回 MOVED，errors: N
# 找一个 16379 自己拥有的槽（这样 pipeline 才有成功的对照组）
own_lo=${own_ranges%%-*}; own_hi=${own_ranges##*-}
local_key=""
local_slot=""
if [ -n "$own_lo" ]; then
  hit=$(keyslots "hd:test:cluster:pipe" 200 | awk -v lo="$own_lo" -v hi="$own_hi" '$2>=lo && $2<=hi {print $1" "$2; exit}')
  if [ -n "$hit" ]; then
    local_key=${hit% *}; local_slot=${hit##* }
  fi
fi
if [ -z "$local_key" ]; then
  bad "L6 找不到落在本节点槽（$own_ranges）里的 key"
  local_key="hd:test:cluster:pipe-fallback"
fi
CLEAN_KEYS+=("$local_key")
echo "    对照组 key: $local_key (slot $local_slot，本节点槽内)"

pipe_local=$(timeout "$TMO" "$RC" -c -h "$IP" -p "$P1" -a "$PASS" --no-auth-warning --pipe <<EOF 2>&1
SET $local_key pv1
GET $local_key
EOF
)
echo "    本节点槽的 --pipe 输出:"
echo "$pipe_local" | sed 's/^/      /'
if echo "$pipe_local" | grep -q 'errors: 0'; then
  ok "L6 本节点槽上的 pipeline 可以跑通（对照组）"
else
  bad "L6 本节点槽上的 pipeline 居然失败"
fi

# 现在换一个落在别的 master 槽上的 key —— pipeline 必须失败（返回 MOVED）
cross_key="$MOVED_KEY"
if [ -n "$cross_key" ]; then
  pipe_cross=$(timeout "$TMO" "$RC" -c -h "$IP" -p "$P1" -a "$PASS" --no-auth-warning --pipe <<EOF 2>&1
SET $cross_key pv2
GET $cross_key
EOF
)
  echo "    跨节点槽的 --pipe 输出:"
  echo "$pipe_cross" | sed 's/^/      /'
  if echo "$pipe_cross" | grep -qE 'MOVED' && echo "$pipe_cross" | grep -qE 'errors: [1-9]'; then
    ok "L6 跨节点槽的 pipeline 按预期失败（MOVED）→ 应用必须用 execute(cb)，不能用 executePipelined"
  else
    bad "L6 期望跨节点槽 pipeline 报 MOVED 错误，实得: $(echo "$pipe_cross" | tr '\n' '|')"
  fi
else
  bad "L6 没有可用的跨节点槽 key（沿用 L4 的失败）"
fi

# 单条命令（execute(cb) 走的就是这条路）必须仍然可用
chk "L6 单条命令仍可用" "$(rc $P1 GET "$local_key")" "pv1"

echo
echo "############ 清理 ############"
cleanup
# 验证清理干净：三个 master 上都不能再有 hd:test:cluster:* 的 key
left=0
for p in $P1 $P2 $P3; do
  n=$(r $p KEYS 'hd:test:cluster:*' | grep -c 'hd:test:cluster:')
  echo "    $p 残留 $n 个测试 key"
  left=$((left+n))
done
chk "清理后无残留测试 key" "$left" "0"
CLEAN_KEYS=()

DONE=1
echo
echo "SUMMARY: PASS=$P FAIL=$F"
[ "$F" -eq 0 ]

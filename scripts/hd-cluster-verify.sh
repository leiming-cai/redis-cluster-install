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
# ⚠️ 编号必须在**过滤之前**做（`nl -ba` 在前，`grep` 在后）。
#    反过来的话，一旦中间某条 CLUSTER KEYSLOT 失败，grep 会把那一行滤掉，
#    后面的行序号全部前移 —— key 和 slot 就**错位配对**了，
#    而且是静默的（不会报错，只会算出一个错的槽）。
#    这里先用 nl 编号，再过滤数值行，序号永远对应原始命令的位置。
#
# 用法：keyslots <prefix> <count> -> 每行一个 "key slot"
# 返回码：0 = 结果条数与命令数一致（配对可信）；1 = 有命令失败，输出不可信。
keyslots() {
  local prefix="$1" count="$2" i tmp
  tmp=$(mktemp)
  for i in $(seq 1 "$count"); do
    echo "CLUSTER KEYSLOT $prefix$i"
  done | timeout "$TMO" "$RC" -h "$IP" -p "$P1" -a "$PASS" --no-auth-warning 2>&1 \
    | nl -ba > "$tmp"
  # 期望 count 行（每条命令一行响应），且每行第 2 列都是槽号。
  local got
  got=$(awk '$2 ~ /^[0-9]+$/' "$tmp" | wc -l)
  if [ "$got" -ne "$count" ]; then
    rm -f "$tmp"
    return 1
  fi
  awk -v p="$prefix" '$2 ~ /^[0-9]+$/ {print p $1, $2}' "$tmp"
  rm -f "$tmp"
  return 0
}

# ---------------------------------------------------------------
# 在「一组槽区间」里找一个落在其中的 key。
#
# ⚠️ 区间集合可能不止一个（例如某 master 拥有 "0-5460 10923-16383"）。
#    早先的写法 own_lo=${own_ranges%%-*}; own_hi=${own_ranges##*-} 会把它
#    展开成 0..16383 —— **横跨了本节点并不拥有的槽**，
#    于是「本节点对照组」的 key 可能落到别人的槽里，
#    对照组就会假失败。这里老老实实按区间逐个比对。
#
# 用法：find_key_in_ranges <prefix> <count> <ranges...>
#   ranges 是**空格分隔**的区间列表，形如 "0-5460 10923-16383"
#   （awk 的 split 用 " " 切分 —— 换行/制表符也算分隔符，
#     但调用方统一用空格分隔，免得两处约定不一致。）
#   输出: "<key> <slot>"（第一个命中的）；没命中则输出空。
#   返回码: 0 = 成功；1 = 批量 KEYSLOT 有命令失败（配对不可信）。
find_key_in_ranges() {
  local prefix="$1" count="$2"; shift 2
  local ranges="$*"
  local pairs
  pairs=$(keyslots "$prefix" "$count") || return 1
  echo "$pairs" | awk -v r="$ranges" '
    BEGIN { n=split(r, a, " "); for (i=1;i<=n;i++) { split(a[i], b, "-");
             if (b[2] == "") { lo[i]=b[1]; hi[i]=b[1] } else { lo[i]=b[1]; hi[i]=b[2] } } }
    { for (i=1;i<=n;i++) if ($2 >= lo[i] && $2 <= hi[i]) { print $1" "$2; exit } }'
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
# 兜底清理：脚本退出时把自己写的 key 删掉。
#
# 这个 EXIT trap **覆盖什么、不覆盖什么**（实测结论，别再想当然）：
#   - 正常退出 / 报错退出        -> 触发
#   - SIGTERM (kill -TERM)       -> 触发，且是**立刻**触发（不等前台子进程）
#   - SIGINT  (kill -INT)       -> **被推迟**：bash 正在等前台子进程时，
#                                  SIGINT 会排队等到子进程结束才处理。
#                                  所以 Ctrl-C 实际上会让脚本**跑完**，
#                                  清理在正常退出时发生，而不是中途。
#   - SIGKILL (kill -9)          -> 捕不到（内核直接杀），残留无法避免。
#
# 所以「Ctrl-C 之后一定没有残留」这个说法只在脚本正常跑完时成立；
# kill -9 之后可能留残留，需要手工再跑一次本脚本（或手工 DEL）。
#
# SUMMARY 在正常路径末尾打印；trap 只在异常退出时补打一份。
# ⚠️ 退出码变量叫 _e_ 而不是 rc —— rc 是本脚本的 redis-cli 包装函数。
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
chk "L2 槽位区间数（3 个 master 各一段）" "$n_ranges" "3"
# ⚠️ 这里**不能**写死 "0 5461 10923" / "5460 10922 16383"。
#    规格只要求「3 个 master 各分到槽位，覆盖 0-16383」——
#    至于怎么切（比如 0-5460/5461-10922/10923-16383 还是别的切法）
#    是**实现细节**，换一个同样合法的 rebalance 就不该挂。
#    所以下面查的是**结构**（几段、覆盖全不全、有没有缝/重叠、头尾对不对），
#    具体边界只打印出来给人看。
echo "    实际槽区间（仅供参考，不作为判据）:"
echo "$ranges" | sort -n -k1,1 | awk '{printf "      %s - %s\n", $1, $2}'
starts=$(echo "$ranges" | awk '{print $1}' | sort -n | tr '\n' ' ')
ends=$(echo "$ranges" | awk '{print $2}' | sort -n | tr '\n' ' ')
echo "    各区间起点: $starts"
echo "    各区间终点: $ends"
# 区间总数必须覆盖 16384 且互不重叠（起点 == 上一个终点 + 1）
covered=$(echo "$ranges" | awk '{s+=$2-$1+1} END{print s+0}')
chk "L2 槽位覆盖总数" "$covered" "16384"
# ⚠️ CLUSTER SHARDS 的区间顺序**不是**按起点排的（实测是 5461 / 10923 / 0），
#    所以连续性检查必须先按起点排序。
contig=$(echo "$ranges" | sort -n -k1,1 | awk '
  { if (NR>1 && $1 != prev+1) { bad=1; print "gap"; exit } prev=$2 }
  END { if (bad != 1) print "contig" }')
chk "L2 区间连续无重叠（无缝隙）" "$contig" "contig"
# 头尾必须正好卡住 0 和 16383（这是「覆盖 0-16383」的结构性判据）
first_start=$(echo "$ranges" | sort -n -k1,1 | head -1 | awk '{print $1}')
last_end=$(echo "$ranges" | sort -n -k1,1 | tail -1 | awk '{print $2}')
chk "L2 第一个区间从 0 开始" "$first_start" "0"
chk "L2 最后一个区间到 16383 结束" "$last_end" "16383"

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
# 三个 master 必须是**不同的**节点（不能三个区间都归到同一个 master 上）
n_distinct_master=$(echo "$nodes" | grep 'master' | awk '{print $2}' | sort -u | wc -l)
chk "L2 三个 master 是三个不同的节点" "$n_distinct_master" "3"

# CLUSTER SLOTS —— 人读视图（槽 -> master 地址 的经典列表）。
# ⚠️ 这里的行数/块数随节点数变，**不能**按行号去解析它；
#    判据一律用上面的 CLUSTER SHARDS / CLUSTER NODES。
echo "    (CLUSTER SLOTS —— 人读视图，仅供参考)"
r $P1 CLUSTER SLOTS | sed 's/^/      /'

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
# ⚠️ 用 printf " " 而不是 print：own_ranges 要跟 node_ranges 一样是
#    **空格分隔**的一串区间（find_key_in_ranges 按空格切分）。
own_ranges=$(echo "$nodes" | grep "myself,master" | awk '{f=0; for(i=1;i<=NF;i++) if ($i=="connected") f=1; else if (f && $i ~ /^[0-9]+(-[0-9]+)?$/) printf "%s ", $i}')
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
slots_failed=0
if [ -n "$other_range" ]; then
  hit=$(find_key_in_ranges "hd:test:cluster:m" 200 "$other_range")
  rc_find=$?
  # rc_find 非 0 = 批量 KEYSLOT 里有命令失败了。这时候 key↔slot 的配对不可信
  # （keyslots 会拒绝输出），不能硬着头皮拿一个错的槽去测 MOVED。
  if [ "$rc_find" -ne 0 ]; then
    bad "L4 批量 CLUSTER KEYSLOT 有命令失败，key↔slot 配对不可信"
    slots_failed=1
  elif [ -n "$hit" ]; then
    MOVED_KEY=${hit% *}; MOVED_SLOT=${hit##* }
  fi
fi
if [ -z "$MOVED_KEY" ] && [ "$slots_failed" -eq 0 ]; then
  bad "L4 找不到落在 $other_range 槽区间的 key"
elif [ -n "$MOVED_KEY" ]; then
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
# 这个 L6 能证明什么、不能证明什么 —— 先说清楚，免得误读：
#
# 【它证明的是】在集群模式下，一个**不做槽感知**的客户端把多条命令打包
# 一次性发给**单个节点**时，跨槽的那几条会拿到 MOVED 错误 ——
# 因为整个 pipeline 只落在那一个节点上，而它只能服务自己名下的槽。
#
# 【它不能证明的是】Spring Data Redis 2.7.18 的
# JedisClusterConnection.openPipeline() 抛 UnsupportedOperationException。
# 那是**客户端库**的行为（callback 体一次都不跑），命令行层面复现不了。
# JVM 层面的那个异常由 Task 5（应用层）验证。
# 本测试是那个限制的**协议层原因**：集群不会替你在 pipeline 里做重定向，
# 所以客户端库干脆不给你开这个口子。
#
# ⚠️ redis-cli 的 **--pipe 会忽略 -c**（实测：加不加 -c，输出完全一样）。
#    -c 只对「一条命令一次往返」的调用有意义。所以这里刻意**不加** -c，
#    测的正是「单节点、无槽感知」的 pipeline 行为。
#    （早先的版本在这里加了 -c，那个标志是**空转**的，等于没加。）
#
# ⚠️ --pipe 的 MOVED 是**按槽算**的，跟 key 存不存在无关。
#    所以这里先把 key **真的写进去**并断言能读回来，
#    这样 pipeline 的失败才是「一条真实数据的 pipeline 失败了」，
#    而不是「槽算术算出了个 MOVED」。

# --- 准备一个本节点槽内的 key（对照组） ---
# ⚠️ own_ranges 可能有**多个**区间（例如 "0-5460 10923-16383"）。
#    早先的 own_lo=${own_ranges%%-*}; own_hi=${own_ranges##*-} 会展开成
#    0..16383 —— 横跨了本节点并不拥有的槽，对照组的 key 就可能落到
#    别人的槽里，对照组假失败。这里用 find_key_in_ranges 逐区间比对。
local_key=""
local_slot=""
local_slots_failed=0
if [ -n "$own_ranges" ]; then
  hit=$(find_key_in_ranges "hd:test:cluster:pipe" 200 "$own_ranges")
  if [ $? -ne 0 ]; then
    bad "L6 批量 CLUSTER KEYSLOT 有命令失败，key↔slot 配对不可信"
    local_slots_failed=1
  elif [ -n "$hit" ]; then
    local_key=${hit% *}; local_slot=${hit##* }
  fi
fi
if [ -z "$local_key" ] && [ "$local_slots_failed" -eq 0 ]; then
  bad "L6 找不到落在本节点槽（$own_ranges）里的 key"
fi
if [ -z "$local_key" ]; then
  local_key="hd:test:cluster:pipe-fallback"
else
  echo "    对照组 key: $local_key (slot $local_slot，本节点槽内)"
fi
CLEAN_KEYS+=("$local_key")

# --- 准备一个跨槽的 key，并且**真的写进去** ---
cross_key=""
cross_slot=""
cross_slots_failed=0
if [ -n "$other_range" ]; then
  hit=$(find_key_in_ranges "hd:test:cluster:pipex" 200 "$other_range")
  if [ $? -ne 0 ]; then
    bad "L6 批量 CLUSTER KEYSLOT 有命令失败，key↔slot 配对不可信"
    cross_slots_failed=1
  elif [ -n "$hit" ]; then
    cross_key=${hit% *}; cross_slot=${hit##* }
  fi
fi
if [ -z "$cross_key" ] && [ "$cross_slots_failed" -eq 0 ]; then
  bad "L6 找不到落在别的 master 槽（$other_range）里的 key"
fi
if [ -n "$cross_key" ]; then
  CLEAN_KEYS+=("$cross_key")
  echo "    跨节点槽 key: $cross_key (slot $cross_slot，应属于 $other_ip)"
  # ⚠️ 必须先写进去并确认能读回来 —— 否则 pipeline 的 MOVED 只是槽算术，
  #    证明不了「对真实数据的 pipeline 会失败」。
  rc $P1 SET "$cross_key" xv >/dev/null
  chk "L6 跨节点槽的 key 事先写入且能读回" "$(rc $P1 GET "$cross_key")" "xv"
fi

# --- 对照组：多条命令**全部**落在本节点槽内 -> 必须一条错都没有 ---
pipe_local=$(timeout "$TMO" "$RC" -h "$IP" -p "$P1" -a "$PASS" --no-auth-warning --pipe <<EOF 2>&1
SET $local_key pv1
GET $local_key
SET $local_key pv2
GET $local_key
EOF
)
echo "    对照组（4 条命令全在本节点槽）的 --pipe 输出:"
echo "$pipe_local" | sed 's/^/      /'
if echo "$pipe_local" | grep -q 'errors: 0'; then
  ok "L6 对照组：本节点槽内的多条命令 pipeline 全部成功（errors: 0）"
else
  bad "L6 对照组：本节点槽内的 pipeline 居然有错误"
fi
# ⚠️ --pipe 只打印出错的回复，成功的回复被吞掉；
#    所以对照组也要看**回复数** = 发出的命令数，才说明 4 条都回来了。
rep_local=$(echo "$pipe_local" | grep -oP 'replies: \K[0-9]+')
chk "L6 对照组的回复数 = 发出的命令数" "${rep_local:-0}" "4"

# --- 主体：多条命令里**混进跨槽**的 -> 跨槽的那几条必须报 MOVED ---
if [ -n "$cross_key" ]; then
  pipe_cross=$(timeout "$TMO" "$RC" -h "$IP" -p "$P1" -a "$PASS" --no-auth-warning --pipe <<EOF 2>&1
GET $local_key
GET $cross_key
GET $local_key
GET $cross_key
EOF
)
  echo "    混合（2 本地 + 2 跨槽）的 --pipe 输出:"
  echo "$pipe_cross" | sed 's/^/      /'
  n_moved=$(echo "$pipe_cross" | grep -c 'MOVED')
  err_line=$(echo "$pipe_cross" | grep -oP 'errors: \K[0-9]+')
  err_line=${err_line:-0}
  rep_line=$(echo "$pipe_cross" | grep -oP 'replies: \K[0-9]+')
  rep_line=${rep_line:-0}
  chk "L6 跨槽命令返回 MOVED 的条数" "$n_moved" "2"
  if [ "${err_line:-0}" -gt 0 ]; then
    ok "L6 跨槽 pipeline 的 errors 计数 > 0（$err_line）"
  else
    bad "L6 跨槽 pipeline 的 errors 计数应为 > 0，实得 '$err_line'"
  fi
  # ⚠️ redis-cli --pipe **只打印出错的回复**，成功的回复被吞掉了。
  #    所以「本节点槽的那两条成功了」不能靠看到值来判断，
  #    要靠回复数：发了 4 条，收到 4 条回复，其中只有 2 条是错误
  #    —— 另外 2 条（本地槽的）就是成功的。
  chk "L6 混合 pipeline 的回复数 = 发出的命令数" "$rep_line" "4"
  if [ "$rep_line" -eq 4 ] && [ "${err_line:-0}" -eq 2 ]; then
    ok "L6 同一条 pipeline 里本节点槽的命令成功了（4 条命令 - 2 个错误 = 2 条成功）"
  else
    bad "L6 同一条 pipeline 里本节点槽的命令应该成功（replies=$rep_line errors=$err_line）"
  fi
  if [ "$n_moved" -gt 0 ] && [ "${err_line:-0}" -gt 0 ]; then
    ok "L6 结论：集群模式下不做槽感知的 pipeline，跨槽命令必失败（MOVED）→ 应用必须用 execute(cb)，不能用 executePipelined"
  else
    bad "L6 跨槽 pipeline 未按预期失败"
  fi
  echo "    注：JedisClusterConnection.openPipeline() 抛 UnsupportedOperationException"
  echo "        属于客户端库行为，本命令行测试复现不了；"
  echo "        那个 JVM 层面的异常由 Task 5（应用层）验证。"
else
  bad "L6 没有可用的跨节点槽 key（沿用 L4 的失败）"
fi

# 单条命令（execute(cb) 走的就是这条路）必须仍然可用。
# ⚠️ 用**独立的 key**，不要复用 $local_key ——
#    $local_key 的值是被上面的 pipeline 改过的（pv1 -> pv2），
#    复用会让这条断言依赖前面的 pipeline 成功，前面的检查一挂，
#    这里就跟着报一个看不懂的错。
single_key="hd:test:cluster:pipe-single"
CLEAN_KEYS+=("$single_key")
rc $P1 SET "$single_key" single-ok >/dev/null
chk "L6 单条命令仍可用" "$(rc $P1 GET "$single_key")" "single-ok"

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

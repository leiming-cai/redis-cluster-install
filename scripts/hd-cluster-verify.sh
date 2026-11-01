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
# ⚠️ 密码的语义必须跟 start-hd-apps.sh / hd-redis-cluster.sh **完全一致**：
#    用 `${VAR-...}`（只认**没设**）而不是 `${VAR:-...}`（没设**或**空串都算）。
#    显式设了空值是一种"我以为配了"的错误状态，应该报错，
#    而不是悄悄回退到默认值 —— 那会让操作的人以为设成功了，
#    实际连上去的是 NOAUTH（三个脚本对同一个空密码给两种解释，
#    就必然会分叉）。
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
# ⚠️ 不要用 `hostname -i`：它返回空格分隔的多个地址。
# ⚠️ `awk '{print $1}'` 也不行：它打印**每一行**的第一个字段，
#    多行输出（getent ahosts node1 在这台机器上就是 3 行 STREAM/DGRAM/RAW）
#    会得到多个 IP -> 命令行被拆开 -> 断言打到错误的节点上。
#    `awk 'NF{print $1; exit}'` 只取第一个非空行。
#    三个脚本（hd-cluster-verify.sh / hd-redis-cluster.sh / start-hd-apps.sh）
#    必须用**同一种**写法，否则 IP 推导会分叉。
#
# ⚠️ 用 `${VAR-...}`（只认**没设**）而不是 `${VAR:-...}`（没设**或**空串都算）：
#    显式设了空值是一种"我以为配了"的错误状态，应该报错，
#    而不是悄悄回退到 getent 的结果 —— 那会让操作的人以为设成功了。
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
# ⚠️ 守卫要查**两件事**，缺一不可：
#    1) 数字行的条数 == 命令数  -> 挡住「某条命令失败」（少了一行）
#    2) **原始行数** == 命令数   -> 挡住「多出一行非数字输出」
#       （只查 1 挡不住这个：多出来的那行被过滤掉了，
#         数字行条数照样等于命令数，但编号已经整体错位。）
#    两条都过了，配对才是可信的。
#    （万一还是错位了，后果是**假 FAIL 而不是假 PASS** ——
#      L4 会拿上报的槽去比对 "MOVED <slot> "，对不上就 FAIL。）
#
# ---------------------------------------------------------------
# 本次运行的临时目录。
# ⚠️ mktemp 出来的单个文件在 kill -9 之后会留在 /tmp 里（SIGKILL 捕不到，
#    没法在 trap 里清）。所以统一放进一个**本次运行专属**的目录，
#    由 cleanup() 整个删掉 —— 就算脚本被 kill -9，
#    下次运行也不会越积越多（而且这种残留不影响功能）。
WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/hd-cluster-verify.XXXXXX" 2>/dev/null)
# ⚠️ mktemp -d 失败的话 WORKDIR 是空的。
#    **不能**退回到 /tmp 本身 —— cleanup() 会 `rm -rf "$WORKDIR"`，
#    那会把整个 /tmp 删掉！退回到一个固定的子目录名，
#    并且用 OWNRUN_DIR 标记「这个目录是我们建的，可以整个删」。
OWNRUN_DIR=0
if [ -n "${WORKDIR:-}" ] && [ -d "${WORKDIR:-}" ]; then
  OWNRUN_DIR=1
else
  WORKDIR="${TMPDIR:-/tmp}/hd-cluster-verify.fallback.$$"
  mkdir -p "$WORKDIR" 2>/dev/null && OWNRUN_DIR=1
fi

# 用法：keyslots <prefix> <count> -> 每行一个 "key slot"
# 返回码：0 = 结果条数与命令数一致（配对可信）；1 = 有命令失败，输出不可信。
keyslots() {
  local prefix="$1" count="$2" i tmp
  tmp=$(mktemp "$WORKDIR/keyslots.XXXXXX" 2>/dev/null) || return 1
  for i in $(seq 1 "$count"); do
    echo "CLUSTER KEYSLOT $prefix$i"
  done | timeout "$TMO" "$RC" -h "$IP" -p "$P1" -a "$PASS" --no-auth-warning 2>&1 \
    | nl -ba > "$tmp"
  # 每条命令应该正好回一行。数字行数 == count 且 原始行数 == count 才算可信。
  local got total
  got=$(awk '$2 ~ /^[0-9]+$/' "$tmp" | wc -l)
  total=$(wc -l < "$tmp")
  if [ "$total" -ne "$count" ] || [ "$got" -ne "$count" ]; then
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

# ⚠️ **不要把密码打到 stdout**。日志会被贴到 issue / 工单里。
#    只说密码的**来源**（环境变量设了没），不说值。
# ⚠️ 用 `${VAR+set}` 判断，跟上面取密码的语义**一致**：
#    "已设置"包含"设成了空串" —— 但空串在上面已经被拒了，
#    所以走到这里的一定是个真值。
if [ -n "${HD_CLUSTER_PASS+set}" ]; then
  PASS_SRC="HD_CLUSTER_PASS 已设置"
else
  PASS_SRC="HD_CLUSTER_PASS 未设置（用内置默认值）"
fi
echo "### 目标: $IP  (ports $P1/$P2/$P3)  pass=<已隐藏>  [$PASS_SRC]"

# ---------------------------------------------------------------
# 清理用的 key 列表（跨槽的 key 不能用一条 DEL 删 —— 会 CROSSSLOT 整条失败，
# 所以必须一个一个删）。
CLEAN_KEYS=()

cleanup() {
  local k
  # 临时目录整个删掉（keyslots 的中间文件都在里面）。
  # 放在最后：删 key 要用 redis-cli，跟临时目录没关系，但顺序上先清 key 更直观。
  if [ "${#CLEAN_KEYS[@]}" -gt 0 ]; then
    # ⚠️ 不能用一条 `DEL k1 k2 k3` —— 跨槽的 key 会让整条命令
    #    CROSSSLOT 失败，**一个都删不掉**（实测过）。
    #    所以一条一条 DEL，但打包进同一个连接里。
    local cmds=()
    for k in "${CLEAN_KEYS[@]}"; do
      [ -n "$k" ] && cmds+=("DEL $k")
    done
    [ "${#cmds[@]}" -gt 0 ] && batch_cmds "${cmds[@]}" >/dev/null
  fi
  # ⚠️ 只有**我们建的**目录才能整个删。
  #    万一 WORKDIR 指向了 /tmp 本身，`rm -rf` 会把整个 /tmp 删掉。
  if [ "${OWNRUN_DIR:-0}" -eq 1 ] && [ -n "${WORKDIR:-}" ] && [ -d "${WORKDIR:-}" ]; then
    rm -rf "$WORKDIR"
  fi
  return 0
}
# 兜底清理：脚本退出时把自己写的 key 删掉。
#
# 这个 EXIT trap **覆盖什么、不覆盖什么**（实测结论，别再想当然）：
#   - 正常退出 / 报错退出        -> 触发
#   - SIGTERM (kill -TERM)       -> 触发，且是**立刻**触发（不等前台子进程）
#   - SIGINT  (kill -INT)       -> 行为**取决于 bash 版本和当时在等什么**：
#                                  有的是立刻触发，有的会被推迟到前台子进程
#                                  结束才处理。实测（本容器 bash 5.1.16）：
#                                  脚本正在等外部子进程时，SIGINT 被**推迟**，
#                                  脚本会**跑完**，清理在正常退出时发生，
#                                  退出码 0（**不算失败**）。
#                                  真实的 Ctrl-C 是给**整个进程组**发 SIGINT，
#                                  同样会被推迟 —— 所以 Ctrl-C 之后脚本
#                                  通常还是会把活干完再清理。
#   - SIGKILL (kill -9)          -> 捕不到（内核直接杀），残留无法避免。
#
# ⚠️ 收到 TERM/INT/HUP 时，脚本会以 **128+n** 的退出码结束
#    （TERM=143 / INT=130 / HUP=129）—— 见下面那三个显式的信号 trap。
#    所以那种情况下**不会**再打印 "FAIL=0"：
#    EXIT trap 会看到非零的 $_e，把 FAIL 加到 >=1 再打 SUMMARY。
#    （这就是下面为什么要显式 trap 信号：光靠 EXIT trap 里的 $?，
#      被信号杀死时它是 0，bump 不会触发 —— 详见下面那三个 trap 的注释。）
#
# 所以「Ctrl-C 之后一定没有残留」这个说法只在脚本正常跑完时成立；
# kill -9 之后可能留残留，需要手工再跑一次本脚本（或手工 DEL）。
#
# SUMMARY 在正常路径末尾打印；trap 只在异常退出时补打一份。
# ⚠️ 退出码变量叫 _e_ 而不是 rc —— rc 是本脚本的 redis-cli 包装函数。
DONE=0
trap '_e=$?; cleanup; if [ "$DONE" -eq 0 ]; then
        # ⚠️ 异常退出时**绝不能**打印 "FAIL=0" ——
        #    脚本崩了（比如 set -u 触发 unbound variable），
        #    计数器还没来得及加，SUMMARY 就成了「假绿」。
        #    计划里就是靠 grep "FAIL=0" 判断成败的，假绿会骗过人。
        if [ "$_e" -ne 0 ] && [ "$F" -eq 0 ]; then
          F=$((F+1))
          echo "  FAIL  脚本异常退出（exit=$_e）—— 上面那条错误才是根因"
        fi
        echo; echo "SUMMARY: PASS=$P FAIL=$F"
      fi; exit $_e' EXIT

# ⚠️ **必须显式处理信号**，否则被信号杀死时还是假绿。
#
# 坑在哪：bash 被信号杀死时，EXIT trap 里的 `$?` 是 **0**，不是 128+n ——
# bash 是在 trap **返回之后**才把信号状态（128+n）算进去的。
# 所以光靠上面那个 `[ "$_e" -ne 0 ]` 的判断，被信号杀死时它是 0，
# 永远不加 FAIL —— 于是脚本中途被杀，却打印出 "SUMMARY: PASS=25 FAIL=0"
# 然后带着 143/129 的退出码走人。计划里就是靠 grep "FAIL=0" 判断成败的，
# 那种假绿会直接骗过人。
#
# 这三个 trap 的作用就是把信号**转成一个普通的非零退出**：
# 收到 TERM/INT/HUP -> exit 128+n -> 触发 EXIT trap 时 $_e 就是 143/130/129
# -> 上面的 bump 生效 -> FAIL >= 1。
#
# ⚠️ **位置很重要**：这三个 trap 必须写在 EXIT trap **之后**
#    （也就是 `fi; exit $_e' EXIT` 这一行的下面）。
#    插到 EXIT trap 的多行 body 里面会把 trap 弄坏 ——
#    那样连正常路径都会挂（body 会被当成脚本文本执行）。
#    而且 `bash -n` **查不出**这种错误，只能实跑看正常路径还对不对。
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP

echo
echo "############ L0 — 连通性前置检查 ############"
# ⚠️ 一定要先探活：IP 不可达时，每条 redis-cli 都要等满 timeout，
#    后面几十条命令会把总耗时拖成好几分钟。探活失败就**立刻**退出，
#    把「集群没起来」和「集群行为不对」这两种失败区分开。
# ⚠️ 判活看**输出文本**（PING / PONG），不看退出码 ——
#    redis-cli PING 在 "Connection refused" 时也返回 0。
#
# ⚠️ 必须探**三个** master，不能只探 $P1。
#    半死集群（16379 活着、16380 挂了）如果只探 $P1 就会漏过去，
#    然后 L5 的 DBSIZE 拿到的是一句 "Could not connect to Redis at ..."，
#    拿它做算术 -> set -u 报 "Could: unbound variable" -> 脚本崩掉，
#    而计数器还没加 -> trap 打印 "FAIL=0"（假绿）。
#    三个都探，死掉的那个当场就被点名。
down=0
for port in $P1 $P2 $P3; do
  pong=$(r "$port" PING | tr -d '\r')
  case "$pong" in
    PONG)
      ok "L0 $IP:$port PING -> PONG" ;;
    *NOAUTH*|*WRONGPASS*)
      bad "L0 $IP:$port 认证失败（$pong）—— 密码不对？[$PASS_SRC]"
      down=$((down+1)) ;;
    *)
      bad "L0 连不上 $IP:$port（PING 返回 '$pong'）—— 这个 master 没起来？先跑 hd-redis-cluster.sh status"
      down=$((down+1)) ;;
  esac
done
if [ "$down" -gt 0 ]; then
  echo "SUMMARY: PASS=$P FAIL=$F"
  DONE=1
  exit 1
fi
echo "    (redis-cli 版本) $(timeout "$TMO" "$RC" --version 2>&1)"

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
#
# ⚠️ DBSIZE 的增量里混着**所有** key —— 不只是我们写的。
#    所以「增量 == 30」这种精确判据只在**独占集群**时成立：
#    Task 5 把 HD 应用接上集群之后，应用写的 key 会混进增量，
#    total 就 > 30 了那时候报「集群丢 key 了」纯属冤枉。
#    所以下面用「>= 30」：只要我们那 30 个都写进去了就算过，
#    多出来的（别人的）不归我们管，也不该让这个测试挂掉。
#    代价是：如果集群**真的**少写了 key，而同时恰好有别人补写了别的 key，
#    这个判据会看不出来。独占集群时（现在）不存在这个问题；
#    Task 5 之后这个检查的灵敏度会下降 —— 那时以 Task 5 的应用层断言为准。
NK=30
before1=$(r $P1 DBSIZE | tr -d '\r'); before2=$(r $P2 DBSIZE | tr -d '\r'); before3=$(r $P3 DBSIZE | tr -d '\r')
echo "    写前 DBSIZE: $P1=$before1  $P2=$before2  $P3=$before3"
# ⚠️ **先验证再算术**：redis-cli 连不上时会返回一句人话
#    "Could not connect to Redis at ..."，那不是数字。
#    直接拿它做 $(( )) 会在 set -u 下报 "Could: unbound variable"，
#    脚本当场崩掉 —— 而且崩的时候计数器还没加，trap 会打印 "FAIL=0"（假绿）。
#    所以这里先确认三个值都是纯数字，不是就直接报清楚并跳过算术。
dbsize_ok=1
for v in "$before1" "$before2" "$before3"; do
  case "$v" in
    ''|*[!0-9]*) dbsize_ok=0 ;;
  esac
done
if [ "$dbsize_ok" -eq 0 ]; then
  bad "L5 拿不到某个 master 的 DBSIZE（节点没起来？先看 hd-redis-cluster.sh status）"
  echo "    跳过 L5 的增量/分布计算（拿到的不是数字：'$before1' '$before2' '$before3'）"
  after1=""; after2=""; after3=""
else
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
  after1=$(r $P1 DBSIZE | tr -d '\r'); after2=$(r $P2 DBSIZE | tr -d '\r'); after3=$(r $P3 DBSIZE | tr -d '\r')
  echo "    写后 DBSIZE: $P1=$after1  $P2=$after2  $P3=$after3"
  dbsize_ok=1
  for v in "$after1" "$after2" "$after3"; do
    case "$v" in
      ''|*[!0-9]*) dbsize_ok=0 ;;
    esac
  done
  if [ "$dbsize_ok" -eq 0 ]; then
    bad "L5 写完之后拿不到某个 master 的 DBSIZE（节点掉了？）"
    echo "    跳过 L5 的增量/分布计算"
    after1=""; after2=""; after3=""
  fi
fi

if [ "$dbsize_ok" -eq 1 ]; then
  d1=$((after1-before1)); d2=$((after2-before2)); d3=$((after3-before3))
  total=$((d1+d2+d3))
  echo "    增量: $P1=+$d1  $P2=+$d2  $P3=+$d3  (total=$total)"
  # ⚠️ 用 >= 而不是 ==（见上面「前置条件」那段）：
  #    增量里可能混着别的客户端写的 key，那不是我们的问题。
  if [ "$total" -ge "$NK" ]; then
    ok "L5 $NK 个 key 全部写入（增量 $total >= $NK）"
  else
    bad "L5 只写进 $total 个（期望至少 $NK）"
  fi
  # 每个 master 上都要能读到自己的 key
  # ⚠️ 用 KEYS 数**我们自己的** key（名字前缀唯一），不用 DBSIZE 增量 ——
  #    增量里混着别人的 key，别的客户端一写就可能把分布比例带偏，
  #    报一个「槽分配有问题」的假 FAIL。
  r1=$(r $P1 KEYS 'hd:test:cluster:spread*' | grep -c 'hd:test:cluster:spread')
  r2=$(r $P2 KEYS 'hd:test:cluster:spread*' | grep -c 'hd:test:cluster:spread')
  r3=$(r $P3 KEYS 'hd:test:cluster:spread*' | grep -c 'hd:test:cluster:spread')
  echo "    各 master 上的 spread key 数: $P1=$r1  $P2=$r2  $P3=$r3"
  chk "L5 各 master 上的 key 数之和" "$((r1+r2+r3))" "$NK"
  # 「key 有没有分散到 3 个 master 上」也用 KEYS 数判断 ——
  # 用 DBSIZE 增量的话，别的客户端往某个 master 上写一个 key，
  # 就能让「那个 master 一个都没拿到」的假象被掩盖过去。
  spread=0
  for kc in $r1 $r2 $r3; do [ "$kc" -gt 0 ] && spread=$((spread+1)); done
  chk "L5 key 分散在 3 个 master 上" "$spread" "3"
  # 分布不能太偏（任一 master 超过 70% 说明槽分配有问题）
  # ⚠️ 同样基于 KEYS 数（只算我们自己的 key），不受别的客户端影响。
  maxd=$r1; [ "$r2" -gt "$maxd" ] && maxd=$r2; [ "$r3" -gt "$maxd" ] && maxd=$r3
  if [ "$NK" -gt 0 ] && [ $((maxd*10)) -le $((NK*7)) ]; then
    ok "L5 分布不过偏（最大分片 $maxd/$NK ≤ 70%）"
  else
    bad "L5 分布过偏（最大分片 $maxd/$NK）—— 槽分配可能有问题"
  fi
else
  echo "    （L5 的增量/分布检查已跳过）"
fi

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
# ⚠️ 找不到就**不找替身**了。
#    早先的版本用 "hd:test:cluster:pipe-fallback" 顶上，但没检查过它的槽
#    归不归 16379 —— 万一不归，对照组就会因为「key 在别人的槽上」而失败，
#    报出来的是一个和真因无关的错。现在没有对照组就**明说**，
#    并把对照组的检查整体跳过（下面的 L6_CONTROL 标志）。
L6_CONTROL=0
if [ -z "$local_key" ]; then
  echo "    没有本节点槽内的 key -> 跳过 L6 对照组（跨槽部分仍然会跑）"
else
  L6_CONTROL=1
  echo "    对照组 key: $local_key (slot $local_slot，本节点槽内)"
fi
[ -n "$local_key" ] && CLEAN_KEYS+=("$local_key")

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
# 没有本节点槽内的 key 时跳过（原因上面已经报过了）。
if [ "$L6_CONTROL" -eq 1 ]; then
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
else
  echo "    （L6 对照组已跳过）"
fi

# --- 主体：多条命令里**混进跨槽**的 -> 跨槽的那几条必须报 MOVED ---
# 跨槽的 pipeline 里也放本节点槽的命令（如果找得到），
# 这样能证明「不是整条 pipeline 全废，而是只有跨槽的那几条失败」。
if [ -n "$cross_key" ]; then
  if [ "$L6_CONTROL" -eq 1 ]; then
    pipe_cross=$(timeout "$TMO" "$RC" -h "$IP" -p "$P1" -a "$PASS" --no-auth-warning --pipe <<EOF 2>&1
GET $local_key
GET $cross_key
GET $local_key
GET $cross_key
EOF
)
  else
    pipe_cross=$(timeout "$TMO" "$RC" -h "$IP" -p "$P1" -a "$PASS" --no-auth-warning --pipe <<EOF 2>&1
GET $cross_key
GET $cross_key
EOF
)
  fi
  if [ "$L6_CONTROL" -eq 1 ]; then
    echo "    混合（2 本地 + 2 跨槽）的 --pipe 输出:"
  else
    echo "    全跨槽（2 条，没有本节点槽的命令可混入）的 --pipe 输出:"
  fi
  echo "$pipe_cross" | sed 's/^/      /'
  n_moved=$(echo "$pipe_cross" | grep -c 'MOVED')
  err_line=$(echo "$pipe_cross" | grep -oP 'errors: \K[0-9]+')
  err_line=${err_line:-0}
  rep_line=$(echo "$pipe_cross" | grep -oP 'replies: \K[0-9]+')
  rep_line=${rep_line:-0}
  n_cmd=2; n_local=0; n_cross=2
  if [ "$L6_CONTROL" -eq 1 ]; then n_cmd=4; n_local=2; n_cross=2; fi
  # MOVED 的条数 = **跨槽**命令的条数（不是命令总数）
  chk "L6 跨槽命令返回 MOVED 的条数" "$n_moved" "$n_cross"
  if [ "${err_line:-0}" -gt 0 ]; then
    ok "L6 跨槽 pipeline 的 errors 计数 > 0（$err_line）"
  else
    bad "L6 跨槽 pipeline 的 errors 计数应为 > 0，实得 '$err_line'"
  fi
  # ⚠️ redis-cli --pipe **只打印出错的回复**，成功的回复被吞掉了。
  #    所以「本节点槽的那两条成功了」不能靠看到值来判断，
  #    要靠回复数：发了 N 条，收到 N 条回复，其中只有 2 条是错误
  #    —— 另外 N-2 条（本地槽的）就是成功的。
  if [ "$L6_CONTROL" -eq 1 ]; then
    chk "L6 混合 pipeline 的回复数 = 发出的命令数" "$rep_line" "$n_cmd"
    if [ "$rep_line" -eq "$n_cmd" ] && [ "${err_line:-0}" -eq 2 ]; then
      ok "L6 同一条 pipeline 里本节点槽的命令成功了（$n_cmd 条命令 - 2 个错误 = 2 条成功）"
    else
      bad "L6 同一条 pipeline 里本节点槽的命令应该成功（replies=$rep_line errors=$err_line）"
    fi
  else
    # ⚠️ 没有本节点槽的 key -> 这条 pipeline 里**一条本地命令都没有**，
    #    「0 条成功」在算术上没错，但等于宣称了一个从没验证过的成功 ——
    #    那是「永远不会失败的检查」。所以这里不报 PASS，只说明跳过。
    chk "L6 跨槽 pipeline 的回复数 = 发出的命令数" "$rep_line" "$n_cmd"
    echo "    （没有本节点槽的命令可验证对照组 —— 对照组已跳过，见上面）"
  fi
  # ⚠️ 这里**不用** ok/bad 报「结论」—— 结论跟上面的断言是同一批数据，
  #    再报一次 ok 只会让人以为又多了一项独立的证据，
  #    而且同一段里出现 FAIL 时还会夹着一个 PASS，看着像矛盾。
  #    结论用普通注释行输出（不计入 PASS/FAIL）。
  echo "    结论: 集群模式下不做槽感知的 pipeline，跨槽命令必失败（MOVED）"
  echo "          → 应用必须用 execute(cb)，不能用 executePipelined"
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

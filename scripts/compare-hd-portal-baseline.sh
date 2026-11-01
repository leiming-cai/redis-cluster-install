#!/bin/bash
# 把当前的门户快照跟「2026-11-01 会话文档里记录的门户基线」逐项比对。
# 基线值来自 docs/superpowers/sessions/2026-11-01-hd-napstar-docker-deploy.md §六 的表格。
#
# 用法（在 rc-e2e-runner:local 里跑，仓库挂 /repo、.hd-work 挂 /out）：
#   bash /repo/scripts/compare-hd-portal-baseline.sh /out/portal-snapshot-cluster.txt
#
# ⚠️ **这是一个门禁脚本**：任何一项不一致、或快照读不到，退出码都必须非 0。
#    一个「打印了差异却仍然 exit 0」的脚本，等于一个假绿 —— 那比没有门禁更糟。
set -uo pipefail

# 默认路径跟 verify-hd-portal-untouched.sh 的输出约定一致：
#   verify-hd-portal-untouched.sh /out/portal-snapshot-<name>.txt
# 那个脚本在容器里跑，/out 是宿主 .hd-work 的挂载点。
SNAP="${1:-/out/portal-snapshot-cluster.txt}"

# ---------------------------------------------------------------
# 快照必须读得到 —— 读不到就直接失败，不往下走。
#
# ⚠️ 之前这里没有这个检查：`cat "$SNAP"` 报错，脚本继续跑，
#    每个 sed 都拿到空串 → 每一项都 DIFF → 但退出码是 0。
#    「快照根本没读到」和「快照读到了、内容不符」是**两种**情况，
#    前者是**没测**，不能伪装成后者，更不能是成功。
# ---------------------------------------------------------------
if [ ! -f "$SNAP" ]; then
  echo "!! 找不到门户快照文件: $SNAP" >&2
  echo "   先跑（宿主上）：" >&2
  echo "     docker run --rm -v \"<repo>:/repo:ro\" -v \"<repo>/.hd-work:/out\" \\" >&2
  echo "       -v /var/run/docker.sock:/var/run/docker.sock rc-e2e-runner:local \\" >&2
  echo "       bash /repo/scripts/verify-hd-portal-untouched.sh /out/portal-snapshot-cluster.txt" >&2
  exit 2
fi
if [ ! -r "$SNAP" ]; then
  echo "!! 门户快照文件读不了（权限？）: $SNAP" >&2
  exit 2
fi

echo "=== 当前快照: $SNAP ==="
cat "$SNAP"
echo
echo "=== 跟 2026-11-01 文档基线逐项比 ==="

fail=0
chk() {
  local label="$1" want="$2" got="$3"
  if [ -z "$got" ]; then
    # ⚠️ **值取不到 ≠ 值不对** —— 前者是「没测到」，必须单独点名，
    #    否则会跟「真的变了」混在一起，掩盖成一条普通的 DIFF。
    echo "  MISS $label —— 快照里找不到这一项（期望 '$want'）"
    fail=$((fail+1))
    return
  fi
  if [ "$want" = "$got" ]; then
    echo "  OK   $label = $got"
  else
    echo "  DIFF $label: 基线='$want' 现在='$got'"
    fail=$((fail+1))
  fi
}

# ---------------------------------------------------------------
# 取值：**按内容取**，不按行号取。
#
# ⚠️ 之前的写法是 `sed -n '/### 2\./{n;p;}'` —— 「标题行的下一行」。
#    两个问题：
#      1. **位置式**：中间插一行（空行、噪声、说明），读到的就是**错的行**，
#         而且**静默** —— 读到一个看起来合法的值，比读不到更糟。
#      2. `.` 没转义：`/### 1\./` 会连 `### 1b.` 一起匹配（正则里的 `.` 是通配符）。
#         快照里 `### 1b. oom / restarts` 正好紧挨着 `### 1.`。
#
# 现在的做法：**先把标题之后、下一个 '### ' 标题之前的那一段取出来，
# 再从这一段里按内容筛出要的那个值**（数字 / PONG / 镜像 ID / …）。
# 这样：
#   - 中间插几行噪声都不影响（噪声不是要的那个形状）；
#   - 找不到就是**找不到**（MISS），不会读成别的行；
#   - 标题里的点不再需要转义。
#
# ⚠️ **标题用 index() 做「字面量」匹配，不用正则**：
#    `index($0, h) > 0` 是纯字面比较，没有正则元字符要转义。
#    （用 `$0 ~ h` 的话，`\.` / `\(` / `\)` 这些转义会被 awk 当成
#    「无效的转义序列」→ 每次都打一行 warning → 而且 `\.` 在动态
#    正则里语义跟直觉不同 → 匹配结果不可信。）
#    字面量匹配同时解决了两个问题：
#      - `### 2. cpspg info table count` 里的 `.` 是**字面的点**，
#        不会被当成通配符 → 不会误命中 `### 2x ...`；
#      - `### 1b. oom / restarts` 里的 `b` 让它**不可能**被
#        `### 1.` 命中（那正是要用字面量而不是正则的原因）。
#    段落的**结束**分**两级**（这是快照的真实结构）：
#
#      ### N. xxx          ← **顶层**段，结束于下一个 '### '
#        --- yyy           ← **子段**（只在 '### 7.' 里面），结束于下一个 '--- '
#          zzz
#
#    ⚠️ 之前只在 '### ' 上结束 → '--- java process count' 那一段会
#    一路吃到文件末尾，把 '--- java processes'、'--- listening ports'、
#    '--- redis dbsize' 全吞进去 ⇒ 取出来的数是别的段的数。
#    ⚠️ 但如果改成「'--- ' 也结束段落」，那 '--- ' 级噪声插在 header 和
#    值之间时，段落会变成**空的** → 取不到值 → 又是误报。
#
#    ⇒ 正确做法：**按 header 自己的层级决定边界**：
#      - header 是 '### ' → 结束于下一个 '### '；
#      - header 是 '--- ' → 结束于下一个 '--- '（**子段**）。
#      这样每个段只包含**自己那一小块**内容，互不干扰。
#
#    ⚠️ 取值取**第一个**匹配形状的值（段内的第一个）——
#       噪声插在 header 和值之间是「多了一行」，不是「换了值」。
#       （段边界正确之后，段内不会混进别的段的值。）
#
#    （`###` 和 `---` 都不是正则元字符，不需要转义。）
# ---------------------------------------------------------------
section() {
  local header="$1"
  # 边界由 header 的前缀决定：'### ' 找 '### '，'--- ' 找 '--- '。
  local term='### '
  case "$header" in
    '--- '*) term='--- ' ;;
  esac
  awk -v h="$header" -v t="$term" '
    index($0, h) > 0 { insec=1; next }
    insec && index($0, t) == 1 { insec=0 }
    insec { print }
  ' "$SNAP"
}

# 表头（**字面量**，见上面 section() 的说明）
H_CPSPG='### 2. cpspg info table count'
H_PING='### 3. redis ping'
H_NAPSTAR='### 4. portal napstar info table count'
H_NACOS='### 5. nacos readiness http code'
H_IMAGE='### 6. image id'
H_RESTARTS='### 1b. oom / restarts'
H_JAVA='--- java process count'
H_DBSIZE='--- redis dbsize (6379)'

# 段里取值：**取最后一个**匹配形状的值。
#
# ⚠️ 为什么不是「第一个」：
#    header 和值之间插一行噪声（还带一个数字）时，「第一个」会取到**噪声里那个数**。
#    实测（噪声插在 '### 2.' 和它的值之间）：
#        第一个 → 42（❌ 应该是 36）
#        最后一个 → 36（✅）
#    ⇒ 取「最后一个」。
#
# ⚠️ 这个规则**只有在段落边界正确时才成立** ——
#    边界按 header 的层级定（'### ' 找下一个 '### '，'--- ' 找下一个 '--- '），
#    段里**不会**混进别的段的值，所以「最后一个」就是本段的值。
#    ⚠️ 如果边界是「都吃到文件末尾」，'--- java process count' 段就会
#    把后面的 '--- redis dbsize' 的 0 也吃进来 → 最后一个就变成 0（❌）。
#    ⇒ **边界和取值规则是一套**，不能分开改。
num_in()   { grep -oE '[0-9]+'      | tail -1; }
pong_in()  { grep -oE 'PONG'        | tail -1; }
code_in()  { grep -oE '[0-9]{3}'    | tail -1; }
imgid_in() { grep -oE '[0-9a-f]{12}' | tail -1; }
# 「key=value」形式的取值（比如 started=… / restarts=0 / oom=true）。
kv_in() { echo "$1" | grep -oP "(?<=^|\s)$2=\K[^[:space:]]+"; }

# 2. cpspg info 表数 —— 一个纯数字
got=$(section "$H_CPSPG"   | num_in);  chk "cpspg info 表数" "36" "$got"
# 3. redis ping —— PONG（门户 Redis 还活着）
got=$(section "$H_PING"   | pong_in); chk "门户 Redis PING" "PONG" "$got"
# 4. portal napstar info 表数
got=$(section "$H_NAPSTAR" | num_in);  chk "门户 napstar info 表数" "30" "$got"
# 5. nacos readiness —— 3 位 http code
# ⚠️ **000 和 200 都算通过**。
#    门户的 Nacos 早就被宿主机 OOM killer 杀了（2026-11-01 01:10）→ 恒为 000。
#    但如果哪次门户的 Nacos **活过来了**，那就是 200 ——
#    那是个**良性变化**，不是「门户被人动过」。
#    ⚠️ 别把它硬编码成 000：那会让「门户恢复正常」变成一条 DIFF，
#    跟 DBSIZE=4 那个坑一模一样 —— 一个永远/经常误报的门禁等于没有门禁。
got=$(section "$H_NACOS"  | code_in)
case "$got" in
  000|200) echo "  OK   门户 Nacos readiness = $got（000=被 OOM 杀掉，200=活着，都正常）" ;;
  '')      echo "  MISS 门户 Nacos readiness —— 快照里找不到这一项"; fail=$((fail+1)) ;;
  *)       echo "  DIFF 门户 Nacos readiness: 期望 000 或 200，现在='$got'"; fail=$((fail+1)) ;;
esac
# 6. image id —— 12 位十六进制
got=$(section "$H_IMAGE"  | imgid_in); chk "镜像 ID" "07c4dac1a041" "$got"
# 7. java 进程数
got=$(section "$H_JAVA"   | num_in);  chk "java 进程数" "2" "$got"

# ---------------------------------------------------------------
# ⚠️ **门户容器有没有被重启过** —— 这一条**必须查**。
#
# 这个脚本取代的是 2026-11-01 会话文档 §六 的那套「前后各快照一次、
# 逐项比对」的流程。那套流程的结论是：
#
#   「**唯一的差异是 uptime（14h → 15h）→ 说明容器从未被重启**」
#
# ⇒ 也就是说，**「容器没被重启」是那套流程真正证明的东西之一**。
#    这个新脚本刚出来的时候**没有查** `### 1b. oom / restarts`
#    （也没查 `### 1. container status` 和 `--- listening ports`）
#    ⇒ 门户容器**被重启了**它照样报「逐项一致 —— 门户没被动过」。
#    ⇒ 那是**把一个已经能证明的东西弄丢了**。
#
# 判据：`restarts=0`（docker 自己记的重启次数）。
# ⚠️ 为什么不用 `started=`：那个时间戳**每次快照都不一样**（它是启动时刻，
#    而快照之间隔了多久就差多久）→ 没法当基线比。
#    `restarts=0` 才是「自启动以来一次都没重启过」的判据。
#    `oom=` 也要看：它说明「这个容器**曾经**被 OOM 杀掉过」——
#    门户的 oom=true 是 2026-11-01 之前就有的状态（宿主 OOM 杀的），
#    如果它变成 false，说明门户**被重建过**（那更要紧了）。
# ---------------------------------------------------------------
# ⚠️ 取**最后一行**（跟其他段一个规则）：噪声插在 header 和这行之间时，
#    「第一行」会取到噪声行。'### 1b.' 那一行本身是
#    「started=… restarts=… oom=…」一整行，三个值都在里面。
RESTART_LINE=$(section "$H_RESTARTS" | grep -v '^$' | tail -1)
RESTARTS=$(kv_in "$RESTART_LINE" "restarts")
OOM=$(kv_in "$RESTART_LINE" "oom")
STARTED=$(kv_in "$RESTART_LINE" "started")
if [ -z "$RESTARTS" ]; then
  echo "  MISS 门户容器重启次数 —— 快照里读不到（快照不完整）"
  fail=$((fail+1))
elif [ "$RESTARTS" = "0" ]; then
  echo "  OK   门户容器重启次数 = 0（自启动以来从未被重启）"
else
  echo "  DIFF 门户容器重启次数: 期望 0，现在='$RESTARTS' —— 门户**被重启过**！"
  fail=$((fail+1))
fi
if [ -z "$OOM" ]; then
  echo "  MISS 门户容器 OOM 标记 —— 快照里读不到（快照不完整）"
  fail=$((fail+1))
elif [ "$OOM" = "true" ]; then
  echo "  OK   门户容器 OOM 标记 = true（2026-11-01 之前宿主 OOM 杀过门户的 Nacos，已知状态）"
else
  echo "  DIFF 门户容器 OOM 标记: 期望 true（历史状态），现在='$OOM' —— 门户**被重建过**！"
  fail=$((fail+1))
fi
if [ -z "$STARTED" ]; then
  echo "  MISS 门户容器启动时间 —— 快照里读不到（快照不完整）"
  fail=$((fail+1))
else
  echo "  OK   门户容器启动时间 = $STARTED（每次快照都会不同，只作留痕，不作判据）"
fi

# ---------------------------------------------------------------
# 门户 Redis 的 DBSIZE —— **不是跟「4」比**。
#
# 2026-11-01 的基线是 4，但那 4 个 key 全是**带 TTL 的模型元数据缓存**
# （model:objecttypes:* / model:attributetypes:*，见 DEFECTS.md D8 备注），
# 而门户自己的 Nacos 在 2026-11-01 01:10 被**宿主机 OOM killer** 杀了
# → 没人再去续期 → 它们自然过期 → 现在恒为 0。
#
# `redis-check-rdb` 对门户的 dump.rdb 的原话：
#     [info] 4 keys read / 4 expires / 4 already expired
#
# ⇒ 「DBSIZE == 4」这个判据**永远不可能再成立**。
#    硬编码它 = 让这个脚本**永远**报一条 DIFF = 让它的结论行
#    「逐项一致」**永远不可达** = 一个只会说「有问题」的门禁，
#    那还不如没有（真出问题时它照样报同样的 DIFF，没人能区分）。
#
# 现在的判据：**门户 Redis 读得到、keyspace 可读** —— 也就是
# 「门户的 Redis 还活着，而且我们能问它问题」。
# 4 → 0 这件事本身是**已解释、已接受**的变化，不参与门禁。
#
# ⚠️ 但**不是完全不看它**：DBSIZE 的**取值本身**要能取到
#    （取不到 = 快照不完整 = MISS），并且如果它变成**非 0**，
#    说明门户的 Redis 里**又出现了数据** —— 那可能是门户真的活了，
#    也可能是别的东西写进去了。**报出来，但不作为失败**。
# ---------------------------------------------------------------
DBSIZE_RAW=$(section "$H_DBSIZE" | grep -oE '[0-9]+' | tail -1)
if [ -z "$DBSIZE_RAW" ]; then
  echo "  MISS 门户 Redis DBSIZE —— 快照里读不到（快照不完整）"
  fail=$((fail+1))
elif [ "$DBSIZE_RAW" = "0" ]; then
  echo "  OK   门户 Redis DBSIZE = 0（已解释：门户 Nacos 被 OOM 杀掉后，"
  echo "         那 4 个带 TTL 的模型缓存 key 自然过期 —— 见 DEFECTS.md D8 备注）"
else
  echo "  NOTE 门户 Redis DBSIZE = $DBSIZE_RAW（不再是 0 —— 门户的 Redis 里"
  echo "        又出现数据了。不作为失败，但要人看一眼：门户的 Nacos 是不是活了？）"
fi

echo
echo "=== 结论 ==="
if [ "$fail" -eq 0 ]; then
  echo "  与 2026-11-01 基线**逐项一致** —— 门户没被动过。"
else
  echo "  $fail 项与基线不同或取不到（逐条看上面）"
fi

# ⚠️ **退出码是门禁的最后一环**。
#    上面打了「N 项不同」还 exit 0，等于告诉调用方「没问题」——
#    那就**没有门禁**。任何一项不符都必须非 0。
[ "$fail" -eq 0 ]

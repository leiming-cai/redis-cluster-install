#!/bin/bash
# 华盾容器内的 Redis 集群（3 master，只给 HD 用）。
#
# ⚠️ 为什么不在宿主那套（16379-16384）上测：
#    宿主那套的 cluster-announce-ip = 127.0.0.1 -> 从 HD 容器里连 127.0.0.1
#    连的是 HD 容器自己，会被拒（Connection refused）。
#    证据：docs/superpowers/specs/2026-11-01-hd-redis-cluster-test-design.md §2.1
#    （"宿主集群的 announce-ip | 全部 127.0.0.1"）、
#    docs/superpowers/sessions/2026-11-01-hd-napstar-docker-deploy.md §六/§三。
#    所以这里自建一套，announce-ip 填容器内可达的地址。
#
# ⚠️ 端口号和宿主撞了，但没关系：
#    docs/OPERATIONS.md:1717 把 16379-16384 记成**宿主集群的总线端口**
#    （业务端口 + 10000）；这里 16379/16380/16381 是**容器内**的业务端口。
#    容器端口没发布到宿主，所以今天不冲突。哪天要是把容器端口发布出去，
#    就会和宿主的总线端口撞车 —— 到时候换端口，别闷声不响地撞。
#
# 用法：
#   bash hd-redis-cluster.sh start     起 3 个节点并组集群
#   bash hd-redis-cluster.sh stop      停掉并清干净
#   bash hd-redis-cluster.sh status    看状态
#
# 退出码：
#   0 = 成功
#   1 = 失败（start：节点没起来 / 组集群失败 / 集群状态没收敛 / 端口被别的节点占着
#             stop ：有节点连 SIGKILL 都杀不掉
#             status：集群不是 cluster_state:ok）
#   2 = 用法错误（子命令不认识）
# 下游脚本请用 `&&` 串起来，别只看输出：
#   bash hd-redis-cluster.sh start && bash hd-cluster-verify.sh
set -uo pipefail

REDIS_HOME=/opt/software/redis-8.10.0
RS="$REDIS_HOME/bin/redis-server"
RC="$REDIS_HOME/bin/redis-cli"
DATA=/opt/hd/redis-cluster
PASS="${HD_CLUSTER_PASS:-HdClusterPw2026}"

# ⚠️ redis-cli **没有内置的连接超时**：地址不可达时它会一直挂着。
#    所以凡是"不该被卡住"的调用都必须套 timeout：
#      - 探活 / 读身份 / SHUTDOWN：TMO（短，失败要快）
#      - --cluster create：CREATE_TMO（长，这个操作本身就要几十秒）
#    没有 timeout 的话：HD_CLUSTER_IP 指错了、或者容器 IP 在 start/stop 之间变了，
#    start 会挂 90 秒，stop 更糟 —— 它卡在 SHUTDOWN 上，永远到不了 pkill 兜底，
#    结果是节点还活着、数据目录也没清。
TMO=5
CREATE_TMO=60

# 容器内可达的地址 —— 必须不是 127.0.0.1
# ⚠️ 不能用 `hostname -i`：它返回**空格分隔的多个值**（"172.22.0.2 172.22.0.2"），
#    传给 redis-cli -h 会变成 "Could not connect to Redis at 172.22.0.2 172.22.0.2:16379"。
#    `getent hosts node1 | awk '{print $1}'` 稳定返回单个 IP（实测一致）。
ANNOUNCE_IP="${HD_CLUSTER_IP:-$(getent hosts node1 | awk '{print $1}')}"
PORTS="16379 16380 16381"

# 每个节点 64MB 上限 —— 宿主只剩 ~1.7GB，不能让 Redis 吃光
MAXMEM=64mb

# cluster bus 端口 = 客户端端口 + 10000（Redis 默认约定）。
# ⚠️ 别把 bus 端口设成跟客户端端口一样（`--cluster-announce-bus-port "$p"`）：
#    实测（临时端口 17101-17103 上验证）：这样起得来、也 PING 得通，但三个节点
#    互相认不出来 —— CLUSTER NODES 里只有 myself，cluster_known_nodes 一直是 1，
#    cluster_size 也一直是 1；`redis-cli --cluster create` 会卡在
#    "Waiting for the cluster to join" 一直等下去，集群组不起来。
#    所以 bus 端口必须跟客户端端口错开。

# 普通 redis-cli 调用，**带超时**。
# ⚠️ 一定要带 timeout：redis-cli 连不上时会一直挂着（实测连 10.99.99.99 直接挂死），
#    探活、读身份、SHUTDOWN 这几个地方都不能被它拖住。
rc() { timeout "$TMO" "$RC" -h "$ANNOUNCE_IP" -p "$1" -a "$PASS" --no-auth-warning "${@:2}"; }

# 同上，但可以指定超时（用于 CLUSTER INFO 这种稍微重一点的读）
rc_t() { local t="$1"; shift; timeout "$t" "$RC" -h "$ANNOUNCE_IP" -p "$1" -a "$PASS" --no-auth-warning "${@:2}"; }

die() { echo "!! $*" >&2; exit 1; }

# 端口上有没有活的东西在应答。
# ⚠️ redis-cli 永远返回 0（连不上也是 0！），所以只能看**输出文本**：
#    连不上会打 "Could not connect to Redis at ..."，这一行不能当成"有东西在跑"。
#    不带密码问，这样密码不对的情况也能被认出来（输出是 WRONGPASS / NOAUTH）。
# ⚠️ timeout 掐掉的（退出码 124）输出是空的 —— 那是"连不上"，
#    要跟"连上了但返回了奇怪的东西"区分开，所以单独判一下 124。
port_alive() {
  local out rc
  out="$(timeout "$TMO" "$RC" -h "$ANNOUNCE_IP" -p "$1" --no-auth-warning PING 2>&1)"
  rc=$?
  # 124 = timeout 掐掉了 = 不可达，当成"没活着"
  [ "$rc" -eq 124 ] && return 1
  case "$out" in
    "Could not connect"*|"*Connection refused"*|"*Name or service not known"*|"*No route to host"*|"*Connection timed out"*) return 1 ;;
  esac
  [ -n "$out" ] && return 0
  return 1
}

start_nodes() {
  echo "=== 起 3 个 cluster-enabled 节点（announce-ip=$ANNOUNCE_IP）==="
  mkdir -p "$DATA"
  for p in $PORTS; do
    if port_alive "$p"; then
      # ⚠️ 这里必须验**身份**，不能只看"活着"：
      #    端口上有东西在跑，可能是我们上次起的（那就跳过），
      #    也可能是密码/announce-ip 跟我们对不上的**别人的**节点。
      #    认错了还往下走，就会对着一个错的节点喊 cluster create，
      #    最后报出来的是一堆看不懂的东西。
      local got
      got="$(rc "$p" CONFIG GET cluster-announce-ip 2>/dev/null | tail -1 | tr -d '\r')"
      if [ "$got" = "$ANNOUNCE_IP" ]; then
        echo "  端口 $p 已经在跑，且 announce-ip=$got —— 是我们这套，跳过"
        continue
      fi
      if [ -z "$got" ]; then
        die "端口 $p 上有东西在应答，但拿不到它的 cluster-announce-ip（密码不对？HD_CLUSTER_PASS 设错了吧）。不会往这个端口上再起一个，先停下来。"
      fi
      die "端口 $p 上跑着的不是我们这套集群（它的 announce-ip=$got，我们要的是 $ANNOUNCE_IP）。不会往这个端口上再起一个，先停下来。"
    fi
    mkdir -p "$DATA/$p"
    "$RS" --port "$p" \
      --cluster-enabled yes \
      --cluster-config-file "$DATA/$p/nodes.conf" \
      --cluster-announce-ip "$ANNOUNCE_IP" \
      --cluster-announce-port "$p" \
      --cluster-announce-bus-port "$((p + 10000))" \
      --cluster-require-full-coverage no \
      --requirepass "$PASS" \
      --masterauth "$PASS" \
      --maxmemory $MAXMEM \
      --maxmemory-policy noeviction \
      --save '' \
      --appendonly no \
      --protected-mode no \
      --dir "$DATA/$p" \
      --daemonize yes \
      --logfile "$DATA/$p/redis.log"
    # ⚠️ 这个返回码**不能**当成功信号：redis-server --daemonize yes
    #    就算 bind 失败（端口被占）也返回 0。真正的判据是下面那次 PING。
    echo "  端口 $p 启动返回码 = $?"
  done
  sleep 3
  echo "  --- 起来没有（这才是真的判据）---"
  local bad=""
  for p in $PORTS; do
    local r
    r="$(rc "$p" PING 2>&1 | head -1 | tr -d '\r')"
    printf "  %s -> %s\n" "$p" "$r"
    [ "$r" = "PONG" ] || bad="$bad $p"
  done
  if [ -n "$bad" ]; then
    echo "!! 端口$bad 没起来。各节点的日志在 $DATA/<端口>/redis.log，常见原因：端口被占、announce-ip 不可达、内存不够。" >&2
    exit 1
  fi
}

create_cluster() {
  echo "=== 组集群（3 master，0 副本）==="
  local args=""
  for p in $PORTS; do args="$args $ANNOUNCE_IP:$p"; done
  # ⚠️ 密码两路都给：-a 和 REDISCLI_AUTH 都带上。
  #    实测（临时端口 17001-17003 上验证）：`--cluster create` 是认 -a 的 ——
  #    只给 -a、不给 REDISCLI_AUTH 也能正常组出集群（[OK] All 16384 slots covered）。
  #    所以 REDISCLI_AUTH 不是"必须"，这里两道都带上是因为 --cluster 这个 helper
  #    自己会开一堆连接（每个节点好几句 CLUSTER 命令），两条腿走路更稳。
  local out rc
  # ⚠️ --cluster create 也要套 timeout：节点不可达时，实测每个节点要等 ~21 秒，
  #    三个节点就是 60 秒往上。不套的话，配错 IP 的 start 会拖成 90 秒+ 的假死。
  out="$(timeout "$CREATE_TMO" env REDISCLI_AUTH="$PASS" "$RC" -a "$PASS" --no-auth-warning \
          --cluster create $args --cluster-replicas 0 --cluster-yes 2>&1)"
  rc=$?
  echo "$out" | tail -20
  echo
  # ⚠️ create 的退出码不能直接当失败：对着一个**已经成型的**集群再跑一次 create，
  #    它会报 "[ERR] Node ... is not empty" 并返回非 0 —— 但集群本身是好的
  #    （实测：对已成型集群再 create，退出码=1，集群照样 cluster_state:ok）。
  #    这种情况交给下面的等待循环去确认，不当致命错误。
  if [ "$rc" -ne 0 ]; then
    if echo "$out" | grep -q 'is not empty'; then
      echo "  [注意] create 报 'is not empty' —— 集群可能已经是成型状态了，下面用 cluster_state 来确认。"
    else
      echo "!! redis-cli --cluster create 失败（退出码=$rc）。完整输出：" >&2
      echo "$out" >&2
      exit 1
    fi
  fi

  echo "=== 等 cluster_state:ok（刚组完的一瞬间还是 fail，要给它收敛的时间）==="
  # 拿 $PORTS 的第一个端口去问，别写死 16379 —— 端口是变量。
  local first="${PORTS%% *}"
  local i st reached=0
  for i in 1 2 3 4 5 6 7 8 9 10; do
    # 这里用长一点的超时：刚 create 完、集群正在收敛，节点可能短暂不响应，
    # 太短会把"正在收敛"误判成"读不到"。
    st="$(rc_t 10 "$first" CLUSTER INFO 2>/dev/null | grep -m1 '^cluster_state' | tr -d '\r' | cut -d: -f2)"
    echo "  尝试 $i: cluster_state=$st"
    if [ "$st" = "ok" ]; then reached=1; break; fi
    sleep 3
  done
  if [ "$reached" -ne 1 ]; then
    echo "!! 等了 10 次（约 30 秒）cluster_state 都没到 ok，最后一次是 '${st:-<没读出来>}'。集群没起来。" >&2
    echo "   排查：$DATA/$first/redis.log、CLUSTER NODES、容器内存。" >&2
    exit 1
  fi

  echo
  echo "=== 组完后检查 ==="
  for p in $PORTS; do
    echo "  --- $p ---"
    rc "$p" CLUSTER INFO 2>/dev/null | grep -E 'cluster_state|cluster_slots_assigned|cluster_size|cluster_known_nodes' | sed 's/^/    /'
  done
}

stop_cluster() {
  echo "=== 停掉并清干净 ==="
  local p graceful="" out
  # 先走优雅路径（SHUTDOWN NOSAVE）。密码不对的话这步会被拒，
  # 那就只能靠后面的 pkill 硬杀 —— 得让操作的人知道是哪种。
  # ⚠️ redis-cli 永远返回 0，所以只能看输出：被拒时输出是
  #    "NOAUTH Authentication required." 或 "WRONGPASS ..."。
  # ⚠️ SHUTDOWN **成功时输出是空的**（0 字节、退出码 0），
  #    所以"输出为空"不等于"连不上" —— 得看退出码：
  #    124 = timeout 掐掉的 = 地址不可达，SHUTDOWN 根本没送出去。
  local unreachable="" srrc
  for p in $PORTS; do
    out="$(rc "$p" SHUTDOWN NOSAVE 2>&1)"
    srrc=$?
    case "$out" in
      *NOAUTH*|*WRONGPASS*|*NOPERM*) graceful="$graceful $p" ;;
    esac
    if [ "$srrc" -eq 124 ]; then
      unreachable="$unreachable $p"
    fi
  done
  if [ -n "$graceful" ]; then
    echo "  注意：端口$graceful 的优雅关闭被拒了（多半是 HD_CLUSTER_PASS 跟节点实际密码对不上），这些节点将被强杀。"
  fi
  if [ -n "$unreachable" ]; then
    echo "  注意：端口$unreachable 连不上（$ANNOUNCE_IP 不可达？），优雅关闭没送出去，这些节点将被强杀。"
  fi
  sleep 2

  # 兜底：按端口精确匹配（绝不用 pkill -f java）
  # ⚠️ 模式里不能写成 "[-]redis-server"：那个字符类要求 "redis-server" 前面
  #    紧挨着一个字面的 "-"，可实际 cmdline 是
  #    "/opt/software/redis-8.10.0/bin/redis-server *:16379" —— 前面是 "/"，
  #    所以匹配不到任何进程，兜底等于没写（SHUTDOWN 一旦失败，节点会带着
  #    已被 rm -rf 掉的目录继续跑）。
  #    实测（pgrep 干跑）："redis-server \*:16379" 只命中集群那一个 pid；
  #    6379 / 6389 各自只命中自己的 pid，互不串。
  local left
  for p in $PORTS; do
    pkill -f "redis-server \*:$p" 2>/dev/null || true
  done
  sleep 1

  # ⚠️ SIGTERM 之后 Redis 可能还在退出中；这时候 rm -rf 掉它的数据目录，
  #    它就可能往一个已经不存在的目录里写。所以先确认进程真没了，
  #    没没干净就升级到 SIGKILL，确认干净了再删目录。
  left=""
  for p in $PORTS; do
    if pgrep -f "redis-server \*:$p" >/dev/null 2>&1; then
      left="$left $p"
    fi
  done
  if [ -n "$left" ]; then
    echo "  端口$left 的进程还活着，升级到 SIGKILL。"
    for p in $PORTS; do
      pkill -9 -f "redis-server \*:$p" 2>/dev/null || true
    done
    sleep 2
    left=""
    for p in $PORTS; do
      if pgrep -f "redis-server \*:$p" >/dev/null 2>&1; then
        left="$left $p"
      fi
    done
    if [ -n "$left" ]; then
      echo "!! 端口$left 的进程连 SIGKILL 都杀不掉，先不删数据目录，人工处理。" >&2
      exit 1
    fi
  fi
  echo "  已确认停止的端口：$PORTS"

  rm -rf "$DATA"
  echo "  数据目录已删除：$DATA"
  echo "  剩余 redis-server 进程："
  ps -eo pid,args 2>/dev/null | grep '[r]edis-server' | cut -c1-100 | sed 's/^/    /'
}

status() {
  echo "=== 集群状态 ==="
  local first="${PORTS%% *}"
  for p in $PORTS; do
    echo "  --- $ANNOUNCE_IP:$p ---"
    rc "$p" CLUSTER INFO 2>/dev/null | grep -E 'cluster_state|cluster_slots_assigned|cluster_size' | sed 's/^/    /'
  done
  echo
  echo "=== CLUSTER NODES ==="
  rc "$first" CLUSTER NODES 2>/dev/null | sed 's/^/  /'
  echo
  echo "=== CLUSTER SLOTS ==="
  rc "$first" CLUSTER SLOTS 2>/dev/null | sed 's/^/  /'
  echo
  # ⚠️ 退出码是**故意**判的，不是碰巧：
  #    之前它靠 pipefail 把 redis-cli 的失败透传出来（连不上时 redis-cli
  #    对 CLUSTER SLOTS 返回 1），但那纯属副作用 —— 谁要是以后"顺手"给管道
  #    加个 || true，status 就会在一个坏掉的集群上返回 0，骗人。
  #    所以这里显式检查 cluster_state。
  local st
  st="$(rc "$first" CLUSTER INFO 2>/dev/null | grep -m1 '^cluster_state' | tr -d '\r' | cut -d: -f2)"
  if [ "$st" = "ok" ]; then
    echo "  结论：集群正常（cluster_state=ok）。"
    return 0
  fi
  echo "!! 集群不正常（cluster_state=${st:-<读不到，多半是连不上>}）。" >&2
  return 1
}

# ⚠️ 拿不到容器 IP 就直接失败：空 IP 传给 redis-cli -h 会报
#    "Could not connect to Redis at :16379: Name or service not known"，
#    看起来像 DNS 出问题，其实是自己没拿到地址 —— 换个说法，别误导人。
[ -n "$ANNOUNCE_IP" ] || { echo "!! 拿不到容器 IP（getent hosts node1 无结果，HD_CLUSTER_IP 也没给）。" >&2; exit 1; }

case "${1:-start}" in
  start)  start_nodes; create_cluster ;;
  stop)   stop_cluster ;;
  status) status ;;
  *) echo "usage: $0 {start|stop|status}" >&2; exit 2 ;;
esac

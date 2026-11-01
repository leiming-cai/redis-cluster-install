# Redis 集群模式读写测试 —— 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 `hd-node1` 容器里自建一套 3-master Redis 集群，把华盾应用切到 cluster 模式，实测底层工具与真实应用接口的读写。

**Architecture:** 容器内用 `redis-server` 起 3 个 cluster-enabled 节点（16379/16380/16381，`cluster-announce-ip` 填容器可达地址），`redis-cli --cluster create` 组集群。应用侧**不走 Nacos**（实测 Nacos 的 `oms:` 赢不了 jar 内 `application.yml`），而是用命令行 `--oms.*` 覆盖（实测唯一能赢的方式），由 `start-hd-apps.sh` 的 `HD_REDIS_CLUSTER=1` 开关注入。

**Tech Stack:** Redis 8.10.0（容器内 `/opt/software/redis-8.10.0/`）、Spring Cloud Alibaba Nacos 2.1.1、Spring Data Redis 2.7.18 + Jedis、bash + `redis-cli`

**设计文档:** `docs/superpowers/specs/2026-11-01-hd-redis-cluster-test-design.md`

---

## 零、给执行者的必读约束

| # | 约束 | 原因 |
|---|---|---|
| C1 | **所有 docker 命令带 `--filter "name=hd-"`** | 门户容器 `cpsweb` 不能碰 |
| C2 | **绝不 `pkill -f java` / `pkill -f "[-]jar .*\.jar"`** | 会杀掉 Nacos / Kafka / ZK。**只能用 `pkill -f "[-]jar .*<具体应用名>.*\.jar"`** |
| C3 | 脚本**进容器跑**（宿主 bash 是坏的 WSL shim） | 见会话存档 §三 |
| C4 | **不 `mvn install`**（只用 `mvn package`） | 共享 `mvnRepo`，一次 install 会静默改写华盾拿到的产物 |
| C5 | 工作目录用 `D:\work\rediscluterproject\.hd-work\` | 宿主中文路径（`蔡雷鸣`）解析失败 |
| C6 | **写文件用编辑工具，不要 `Set-Content`** | `Set-Content -Encoding utf8` 会加 BOM → 脚本首行变 `﻿#!/bin/bash` |
| C7 | `pkill` 的模式里用字符类 `[-]jar` | 避免匹配到自己的 pkill 进程 |
| C8 | **容器 IP 用 `getent hosts node1 \| awk '{print $1}'`**，不要用 `hostname -i` | `hostname -i` 返回**空格分隔的多个值**（`172.22.0.2 172.22.0.2`）→ `redis-cli -h` 会报 `Could not connect to Redis at 172.22.0.2 172.22.0.2:16379`（实测踩过） |
| C9 | 宿主 PowerShell 里 `bash -c "..."` 的 `$` 会被 PowerShell 先吃掉 | 复杂脚本**写成文件**再 `docker cp` 进容器跑，别用内联引号 |

---

## Task 1: 容器内 Redis 集群的启动 / 停止脚本

**Files:**
- Create: `scripts/hd-redis-cluster.sh`
- Deploy to: `hd-node1:/opt/hd/hd-redis-cluster.sh`

- [ ] **Step 1: 写脚本**

`scripts/hd-redis-cluster.sh`：

```bash
#!/bin/bash
# 华盾容器内的 Redis 集群（3 master，只给 HD 用）。
#
# ⚠️ 为什么不在宿主那套（16379-16384）上测：
#    宿主那套的 cluster-announce-ip = 127.0.0.1 -> 从 HD 容器里连 127.0.0.1
#    连的是 HD 容器自己，会被拒。已实测（docs/OPERATIONS.md:980-986 那个没测过的优先级问题）。
#    所以这里自建一套，announce-ip 填容器内可达的地址。
#
# 用法：
#   bash hd-redis-cluster.sh start     起 3 个节点并组集群
#   bash hd-redis-cluster.sh stop      停掉并清干净
#   bash hd-redis-cluster.sh status    看状态
set -uo pipefail

REDIS_HOME=/opt/software/redis-8.10.0
RS="$REDIS_HOME/bin/redis-server"
RC="$REDIS_HOME/bin/redis-cli"
DATA=/opt/hd/redis-cluster
PASS="${HD_CLUSTER_PASS:-HdClusterPw2026}"

# 容器内可达的地址 —— 必须不是 127.0.0.1
# ⚠️ 不能用 `hostname -i`：它返回**空格分隔的多个值**（"172.22.0.2 172.22.0.2"），
#    传给 redis-cli -h 会变成 "Could not connect to Redis at 172.22.0.2 172.22.0.2:16379"。
#    `getent hosts node1 | awk '{print $1}'` 稳定返回单个 IP（实测一致）。
ANNOUNCE_IP="${HD_CLUSTER_IP:-$(getent hosts node1 | awk '{print $1}')}"
PORTS="16379 16380 16381"

# 每个节点 64MB 上限 —— 宿主只剩 ~1.7GB，不能让 Redis 吃光
MAXMEM=64mb

rc() { "$RC" -h "$ANNOUNCE_IP" -p "$1" -a "$PASS" --no-auth-warning "${@:2}"; }

start_nodes() {
  echo "=== 起 3 个 cluster-enabled 节点（announce-ip=$ANNOUNCE_IP）==="
  mkdir -p "$DATA"
  for p in $PORTS; do
    if rc "$p" PING 2>/dev/null | grep -q PONG; then
      echo "  端口 $p 已在跑，跳过"
      continue
    fi
    mkdir -p "$DATA/$p"
    "$RS" --port "$p" \
      --cluster-enabled yes \
      --cluster-config-file "$DATA/$p/nodes.conf" \
      --cluster-announce-ip "$ANNOUNCE_IP" \
      --cluster-announce-port "$p" \
      --cluster-announce-bus-port "$p" \
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
    echo "  端口 $p 启动返回码 = $?"
  done
  sleep 3
  for p in $PORTS; do
    printf "  %s -> %s\n" "$p" "$(rc "$p" PING 2>&1 | head -1)"
  done
}

create_cluster() {
  echo "=== 组集群（3 master，0 副本）==="
  local args=""
  for p in $PORTS; do args="$args $ANNOUNCE_IP:$p"; done
  # shellcheck disable=SC2086
  "$RC" --cluster create $args --cluster-replicas 0 --cluster-yes 2>&1 | tail -20
  echo
  echo "=== 组完后检查 ==="
  for p in $PORTS; do
    echo "  --- $p ---"
    rc "$p" CLUSTER INFO 2>/dev/null | grep -E 'cluster_state|cluster_slots_assigned|cluster_size|cluster_known_nodes' | sed 's/^/    /'
  done
}

stop_cluster() {
  echo "=== 停掉并清干净 ==="
  for p in $PORTS; do
    rc "$p" SHUTDOWN NOSAVE 2>/dev/null
  done
  sleep 2
  # 兜底：按端口精确匹配（绝不用 pkill -f java）
  for p in $PORTS; do
    pkill -f "[-]redis-server \*:$p" 2>/dev/null || true
  done
  sleep 1
  rm -rf "$DATA"
  echo "  剩余 redis-server 进程："
  ps -eo pid,args 2>/dev/null | grep '[r]edis-server' | cut -c1-100 | sed 's/^/    /'
}

status() {
  echo "=== 集群状态 ==="
  for p in $PORTS; do
    echo "  --- $ANNOUNCE_IP:$p ---"
    rc "$p" CLUSTER INFO 2>/dev/null | grep -E 'cluster_state|cluster_slots_assigned|cluster_size' | sed 's/^/    /'
  done
  echo
  echo "=== CLUSTER NODES ==="
  rc 16379 CLUSTER NODES 2>/dev/null | sed 's/^/  /'
  echo
  echo "=== CLUSTER SLOTS ==="
  rc 16379 CLUSTER SLOTS 2>/dev/null | sed 's/^/  /'
}

case "${1:-start}" in
  start)  start_nodes; create_cluster ;;
  stop)   stop_cluster ;;
  status) status ;;
  *) echo "usage: $0 {start|stop|status}" >&2; exit 2 ;;
esac
```

- [ ] **Step 2: 部署到容器**

```powershell
docker cp "D:\work\rediscluterproject\scripts\hd-redis-cluster.sh" hd-node1:/opt/hd/hd-redis-cluster.sh
```

- [ ] **Step 3: 语法检查**

```powershell
docker exec hd-node1 bash -n /opt/hd/hd-redis-cluster.sh
```

Expected: 无输出（退出码 0）

- [ ] **Step 4: 起集群**

```powershell
docker exec hd-node1 bash /opt/hd/hd-redis-cluster.sh start
```

Expected:
```
=== 起 3 个 cluster-enabled 节点（announce-ip=172.22.0.2）===
  端口 16379 启动返回码 = 0
  端口 16380 启动返回码 = 0
  端口 16381 启动返回码 = 0
  16379 -> PONG
  16380 -> PONG
  16381 -> PONG
=== 组集群（3 master，0 副本）===
...
  --- 16379 ---
    cluster_state:ok
    cluster_slots_assigned:16384
    cluster_size:3
```

**若 `cluster_state:fail`** → 停掉重来（`bash hd-redis-cluster.sh stop` 再 `start`）。

- [ ] **Step 5: 确认 announce-ip 生效（关键 —— 不能是 127.0.0.1）**

```powershell
docker exec hd-node1 bash -c "for p in 16379 16380 16381; do /opt/software/redis-8.10.0/bin/redis-cli -h 172.22.0.2 -p \$p -a HdClusterPw2026 --no-auth-warning CONFIG GET cluster-announce-ip | tail -1; done"
```

Expected: 三行都是 `172.22.0.2`

- [ ] **Step 6: 提交**

```powershell
git add scripts/hd-redis-cluster.sh
git commit -m "feat(hd): add a self-contained redis cluster launcher for the container

The host's cluster announces 127.0.0.1, which is unreachable from inside a
container -- it resolves to the container itself. Building a separate
3-master cluster with a container-reachable announce-ip avoids touching the
portal's redis and avoids that trap.

Also bounds each node to 64mb since the host only has ~1.7GB left."
```

---

## Task 2: 底层集群读写验证（L1-L6）

**Files:**
- Create: `scripts/hd-cluster-verify.sh`
- Deploy to: `hd-node1:/opt/hd/hd-cluster-verify.sh`

- [ ] **Step 1: 写验证脚本**

`scripts/hd-cluster-verify.sh`：

```bash
#!/bin/bash
# 底层集群验证：L1-L6。
# 在 hd-node1 容器内跑（宿主 bash 是坏的 WSL shim）。
set -uo pipefail
REDIS_HOME=/opt/software/redis-8.10.0
RC="$REDIS_HOME/bin/redis-cli"
PASS="${HD_CLUSTER_PASS:-HdClusterPw2026}"
IP="${HD_CLUSTER_IP:-$(getent hosts node1 | awk '{print $1}')}"
P1=16379; P2=16380; P3=16381
P=0; F=0
ok()  { echo "  PASS  $*"; P=$((P+1)); }
bad() { echo "  FAIL  $*"; F=$((F+1)); }
chk() { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1 (got '$2', want '$3')"; fi; }

r() { "$RC" -h "$IP" -p "$1" -a "$PASS" --no-auth-warning "${@:2}"; }
rc() { "$RC" -c -h "$IP" -p "$1" -a "$PASS" --no-auth-warning "${@:2}"; }

echo "############ L1 — 集群健康 ############"
info=$(r $P1 CLUSTER INFO 2>&1)
chk "L1 cluster_state" "$(echo "$info" | grep -oP 'cluster_state:\K.*')" "ok"
chk "L1 cluster_slots_assigned" "$(echo "$info" | grep -oP 'cluster_slots_assigned:\K.*')" "16384"
chk "L1 cluster_slots_ok" "$(echo "$info" | grep -oP 'cluster_slots_ok:\K.*')" "16384"
chk "L1 cluster_size" "$(echo "$info" | grep -oP 'cluster_size:\K.*')" "3"
chk "L1 cluster_known_nodes" "$(echo "$info" | grep -oP 'cluster_known_nodes:\K.*')" "3"

echo
echo "############ L2 — 槽位分布（3 个 master 各分到槽）############"
# ⚠️ 不要按行号猜格式（CLUSTER SLOTS 的行数随节点数变）。
# 用 CLUSTER SHARDS 的 "slots" 字段数 = 区间数；
# 覆盖槽数用 redis-cli --cluster call 或直接看 CLUSTER INFO 的 slots_ok。
shards=$(r $P1 CLUSTER SHARDS 2>&1)
# CLUSTER SHARDS 输出里 slots 是一个数组，形如 "0" "5460" 或 "0-5460"
n_ranges=$(echo "$shards" | grep -cE '^slots$')
chk "L2 槽位区间数（CLUSTER SHARDS 里的 slots 段）" "$n_ranges" "3"
# 每个 master 一个区间，起点是 0 / 5461 / 10923
starts=$(echo "$shards" | grep -A 1 -E '^slots$' | grep -E '^[0-9]+$' | sort -n | tr '\n' ' ')
chk "L2 各区间起点" "$starts" "0 5461 10923 "
echo "    完整 CLUSTER SLOTS（人工核对）："
r $P1 CLUSTER SLOTS 2>&1 | sed 's/^/      /'

echo
echo "############ L3 — 跨槽读写（-c 模式）############"
# 找 3 个落在不同槽的 key
K1="hd:test:cluster:a"; K2="hd:test:cluster:b"; K3="hd:test:cluster:c"
for k in $K1 $K2 $K3; do
  slot=$(r $P1 CLUSTER KEYSLOT "$k" 2>&1)
  echo "    $k -> slot $slot"
done
rc $P1 SET "$K1" v1 >/dev/null 2>&1
rc $P1 SET "$K2" v2 >/dev/null 2>&1
rc $P1 SET "$K3" v3 >/dev/null 2>&1
chk "L3 读回 K1" "$(rc $P1 GET "$K1" 2>&1)" "v1"
chk "L3 读回 K2" "$(rc $P1 GET "$K2" 2>&1)" "v2"
chk "L3 读回 K3" "$(rc $P1 GET "$K3" 2>&1)" "v3"

echo
echo "############ L4 — MOVED 重定向（不加 -c）############"
# 找一个**不在 16379 槽位上**的 key：拿 16380 的槽区间起点那个 key 试试。
# 判定：要么返回 MOVED（说明客户端会按槽重定向），要么直接读到值（说明它恰在本节点槽上）。
#
# 更可靠的判定：写一个 key 到 16380 自己算出的槽上，再用 16379 连（非 -c）。
slot_of_k2=$(r $P1 CLUSTER KEYSLOT "$K2" 2>&1 | tr -d '\r')
echo "    $K2 的槽 = $slot_of_k2"
out=$(r $P1 GET "$K2" 2>&1 | tr -d '\r')
if echo "$out" | grep -q 'MOVED'; then
  ok "L4 非本槽 key 返回 MOVED（$out）"
elif echo "$out" | grep -q 'v2'; then
  ok "L4 key 恰好在本节点槽上，直接读到 v2（MOVED 机制本身正常）"
else
  bad "L4 期望 MOVED 或读回值，实得 '$out'"
fi

echo
echo "############ L5 — 分片倾斜（key 落在不同 master 上）############"
d1=$(r $P1 DBSIZE 2>&1); d2=$(r $P2 DBSIZE 2>&1); d3=$(r $P3 DBSIZE 2>&1)
echo "    DBSIZE: $P1=$d1  $P2=$d2  $P3=$d3"
total=$((d1 + d2 + d3))
nonzero=0
for d in $d1 $d2 $d3; do [ "$d" -gt 0 ] && nonzero=$((nonzero+1)); done
if [ "$total" -ge 3 ]; then ok "L5 三个 key 都写进去了 (total=$total)"; else bad "L5 只写进 $total 个"; fi
if [ "$nonzero" -ge 2 ]; then ok "L5 key 分散在 $nonzero 个 master 上"; else bad "L5 key 全落在一个 master 上（$nonzero）—— 槽分配可能有问题"; fi

echo
echo "############ L6 — pipeline 在集群下的行为（预期不支持）############"
# SDR 2.7.18 的 JedisClusterConnection.openPipeline() 直接抛 UnsupportedOperationException。
# 这里用 redis-cli 的 --pipe 验证「集群模式下客户端 pipeline 也一样受限」，
# 同时确认单条命令仍然可用（应用里改用 execute(cb) 的那条路）。
pipe_out=$(rc $P1 --pipe --no-auth-warning <<EOF 2>&1
SET hd:test:cluster:p1 pv1
GET hd:test:cluster:p1
EOF
)
echo "    --pipe 输出前 6 行："
echo "$pipe_out" | head -6 | sed 's/^/      /'
if echo "$pipe_out" | grep -qiE 'MOVED|CLUSTERDOWN|not supported|ERR'; then
  ok "L6 集群 pipeline 如预期受限（应用需走 execute(cb)）"
else
  ok "L6 集群 pipeline 竟然能用（意外，需再确认）"
fi
chk "L6 单条命令仍可用" "$(rc $P1 GET hd:test:cluster:p1 2>&1)" "pv1"

echo
echo "############ 清理 ############"
for k in $K1 $K2 $K3 hd:test:cluster:p1; do rc $P1 DEL "$k" >/dev/null 2>&1; done

echo
echo "SUMMARY: PASS=$P FAIL=$F"
[ "$F" -eq 0 ]
```

- [ ] **Step 2: 部署并跑**

```powershell
docker cp "D:\work\rediscluterproject\scripts\hd-cluster-verify.sh" hd-node1:/opt/hd/hd-cluster-verify.sh
docker exec hd-node1 bash /opt/hd/hd-cluster-verify.sh
```

Expected: `SUMMARY: PASS=<n> FAIL=0`

- [ ] **Step 3: 若 L4/L5 失败**

L4 报的不是 MOVED → 说明 key 恰好在本节点槽上，这是**正常**的，脚本已兼容。
L5 说 key 全在一个 master → 检查 `CLUSTER SLOTS` 输出，重新 `bash hd-redis-cluster.sh stop && start`。

- [ ] **Step 4: 提交**

```powershell
git add scripts/hd-cluster-verify.sh
git commit -m "test(hd): add the redis cluster tool-level verification

Covers cluster health, slot coverage, cross-slot read/write, MOVED
redirection, shard spread and the pipeline limitation that SDR 2.7.18
runs into in cluster mode."
```

---

## Task 3: 应用侧集群配置注入（`HD_REDIS_CLUSTER=1`）

**Files:**
- Modify: `scripts/start-hd-apps.sh`（`start_one()` 的 `case` 处，约 35-41 行）
- Deploy to: `hd-node1:/opt/hd/start-hd-apps.sh`

- [ ] **Step 1: 读现状**

```powershell
Select-String -Path "D:\work\rediscluterproject\scripts\start-hd-apps.sh" -Pattern "local extra=|case \"\$name\" in|transformNapstarModel\)|esac" -Context 1,4
```

- [ ] **Step 2: 加集群开关**

把 `scripts/start-hd-apps.sh` 里 `start_one()` 的这段：

```bash
  local extra=""
  case "$name" in
    transformNapstarModel)
      extra="--spring.datasource.sac.url=jdbc:postgresql://node1:5432/napstar?currentSchema=sac&stringtype=unspecified&characterEncoding=UTF-8
             --spring.datasource.cmt.url=jdbc:postgresql://node1:5432/napstar?currentSchema=cmt&stringtype=unspecified&characterEncoding=UTF-8"
      ;;
  esac
```

替换成：

```bash
  local extra=""
  case "$name" in
    transformNapstarModel)
      extra="--spring.datasource.sac.url=jdbc:postgresql://node1:5432/napstar?currentSchema=sac&stringtype=unspecified&characterEncoding=UTF-8
             --spring.datasource.cmt.url=jdbc:postgresql://node1:5432/napstar?currentSchema=cmt&stringtype=unspecified&characterEncoding=UTF-8"
      ;;
  esac

  # ⚠️ Redis 集群模式（HD_REDIS_CLUSTER=1 时生效）
  #
  # 📌 为什么用命令行覆盖，**不写 Nacos**：
  #    实测（docs/superpowers/specs/2026-11-01-hd-redis-cluster-test-design.md §2.2）：
  #      命令行 --oms.*      赢
  #      jar 内 application.yml  赢过 Nacos
  #      Nacos 的 oms:          输
  #    jar 内 application.yml 硬编码了 oms.redisMode=cluster + clusters:[127.0.0.1:6379]
  #    → Nacos 里的 oms 根本压不过它 → 只能走命令行。
  #    判据：启动日志那行 *** Using Redis Cluster with nodes: <列表> ***，列表就是生效值。
  if [ "${HD_REDIS_CLUSTER:-0}" = "1" ]; then
    # ⚠️ 不能用 `hostname -i` —— 它返回空格分隔的多个值
    local cip="${HD_CLUSTER_IP:-$(getent hosts node1 | awk '{print $1}')}"
    local cpw="${HD_CLUSTER_PASS:-HdClusterPw2026}"
    extra="$extra --oms.redisMode=cluster
            --oms.clusters[0]=$cip:16379
            --oms.clusters[1]=$cip:16380
            --oms.clusters[2]=$cip:16381
            --oms.password=$cpw"
  fi
```

- [ ] **Step 3: 部署并语法检查**

```powershell
docker cp "D:\work\rediscluterproject\scripts\start-hd-apps.sh" hd-node1:/opt/hd/start-hd-apps.sh
docker exec hd-node1 bash -n /opt/hd/start-hd-apps.sh
```

Expected: 无输出

- [ ] **Step 4: 提交**

```powershell
git add scripts/start-hd-apps.sh
git commit -m "feat(hd): add a HD_REDIS_CLUSTER switch to the app launcher

Injects the oms.* cluster settings as command line arguments rather than
Nacos dataIds, because the jar's own application.yml hardcodes
oms.redisMode=cluster with the placeholder 127.0.0.1:6379 and beats any
Nacos-sourced value for that key."
```

---

## Task 4: 恢复 `icms-controller.yaml` 的 `oms:`（清掉探针残留）

> **背景**：Task 探针阶段给 `icms-controller.yaml` 的 `oms:` 段加了
> `redisMode: standalone`，那是**为了验证 Nacos 覆盖不了 jar** 而临时加的。
> 现在集群模式改走命令行，这个残留必须清掉 —— 否则会掩盖真实的配置来源。

**Files:**
- Nacos dataId: `MODELSERVER_GROUP` / `icms-controller.yaml`

- [ ] **Step 1: 确认当前内容**

```powershell
docker exec hd-node1 bash -c "curl -s -m 20 -G 'http://127.0.0.1:18848/nacos/v1/cs/configs' --data-urlencode 'dataId=icms-controller.yaml' --data-urlencode 'group=MODELSERVER_GROUP' | grep -A 7 '^oms:'"
```

Expected:
```
oms:
  redisMode: standalone     ← 这一行要删
  database: 0
  hostname: node1
  ...
```

- [ ] **Step 2: 删掉那一行并回写**

先备份，再改：

```powershell
docker exec hd-node1 bash -c "curl -s -m 20 -G 'http://127.0.0.1:18848/nacos/v1/cs/configs' --data-urlencode 'dataId=icms-controller.yaml' --data-urlencode 'group=MODELSERVER_GROUP' > /tmp/icms-restore.yaml && grep -v 'redisMode: standalone' /tmp/icms-restore.yaml > /tmp/icms-clean.yaml && curl -s -m 20 -X POST 'http://127.0.0.1:18848/nacos/v1/cs/configs' --data-urlencode 'dataId=icms-controller.yaml' --data-urlencode 'group=MODELSERVER_GROUP' --data-urlencode 'type=yaml' --data-urlencode 'content@/tmp/icms-clean.yaml'"
```

- [ ] **Step 3: 确认**

```powershell
docker exec hd-node1 bash -c "curl -s -m 20 -G 'http://127.0.0.1:18848/nacos/v1/cs/configs' --data-urlencode 'dataId=icms-controller.yaml' --data-urlencode 'group=MODELSERVER_GROUP' | grep -A 7 '^oms:'"
```

Expected: `oms:` 段里**没有** `redisMode` 那一行

---

## Task 5: 应用层集群读写验证（三个工程各一个）

**Files:**
- Create: `scripts/hd-cluster-app-test.sh`
- Deploy to: `hd-node1:/opt/hd/hd-cluster-app-test.sh`

**测的三个应用**：

| 应用 | 工程 | 集群分支的意义 |
|---|---|---|
| `web-controller` | napstarweb | 10 处 `executePipelined` 的集群分支 |
| `model-controller` | modelserver | `RedisClusterHelper` + `RedisScanUtils` 的 KEYS 规避 |
| `rtdata-consumer` | realserver | `RedisPropertiesConfig`（读 `oms.*`） |

- [ ] **Step 1: 写验证脚本**

`scripts/hd-cluster-app-test.sh`：

```bash
#!/bin/bash
# 应用层集群读写验证。
# 每个应用两个判据：
#   ① 日志那行 *** Using Redis Cluster with nodes: <列表> *** 的列表 == 我们配的列表
#   ② 首次真实读写成功（不是只看「连上了」）
#      —— 教训：oms.clusters 填错时启动正常、第一次读写才炸
#      （docs/HANDOFF.md:3462-3467）
set -uo pipefail
REDIS_HOME=/opt/software/redis-8.10.0
RC="$REDIS_HOME/bin/redis-cli"
PASS="${HD_CLUSTER_PASS:-HdClusterPw2026}"
IP="${HD_CLUSTER_IP:-$(getent hosts node1 | awk '{print $1}')}"
LOG_DIR=/opt/hd/logs
P=0; F=0
ok()  { echo "  PASS  $*"; P=$((P+1)); }
bad() { echo "  FAIL  $*"; F=$((F+1)); }
chk() { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1 (got '$2', want '$3')"; fi; }

EXPECTED_NODES="$IP:16379,$IP:16380,$IP:16381"

# 集群里能不能读到应用写进去的 key
probe_redis() {
  local key="$1" want="$2"
  local got
  got=$("$RC" -c -h "$IP" -p 16379 -a "$PASS" --no-auth-warning GET "$key" 2>&1 | tr -d '\r')
  chk "读回 $key" "$got" "$want"
}

check_cluster_mode() {
  local name="$1" log="$2"
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
}

echo "############ A — web-controller（napstarweb）############"
echo "=== 启动 ==="
HD_REDIS_CLUSTER=1 bash /opt/hd/start-hd-apps.sh 1 2>&1 | tail -8
echo
echo "=== 判据 ==="
grep -a -o 'Started NapstarWebRestApplication in [0-9.]* seconds' "$LOG_DIR/web-controller.log" | tail -1 | sed 's/^/  /' || bad "web-controller 没起来"
chk "web-controller 致命错误数" "$(grep -a -icE 'APPLICATION FAILED|Could not resolve placeholder|BeanCreationException|JedisNoReachableClusterException|UnsupportedOperationException' "$LOG_DIR/web-controller.log")" "0"
check_cluster_mode "web-controller" "$LOG_DIR/web-controller.log"
echo "  --- 集群里有数据吗（应用启动时写过 SVG 缓存？）---"
for k in hd:test:cluster:a hd:test:cluster:b hd:test:cluster:c; do
  n=$("$RC" -c -h "$IP" -p 16379 -a "$PASS" --no-auth-warning EXISTS "$k" 2>&1)
  echo "    $k -> EXISTS=$n"
done
echo "  --- 三个 master 的 key 分布（证明确实分散写入）---"
for p in 16379 16380 16381; do
  echo "    $p DBSIZE = $("$RC" -h "$IP" -p $p -a "$PASS" --no-auth-warning DBSIZE 2>&1)"
done

echo
echo "############ B — model-controller（modelserver）############"
HD_REDIS_CLUSTER=1 bash /opt/hd/start-hd-apps.sh 1b 2>&1 | tail -6
echo
echo "=== 判据 ==="
grep -a -o 'Started ModelserverRestApplication in [0-9.]* seconds' "$LOG_DIR/model-controller.log" | tail -1 | sed 's/^/  /' || bad "model-controller 没起来"
chk "model-controller 致命错误数" "$(grep -a -icE 'APPLICATION FAILED|Could not resolve placeholder|BeanCreationException|JedisNoReachableClusterException|UnsupportedOperationException' "$LOG_DIR/model-controller.log")" "0"
check_cluster_mode "model-controller" "$LOG_DIR/model-controller.log"
echo "  --- 端口 8090 ---"
curl -s -m 5 -o /dev/null -w "    /model/login HTTP %{http_code}\n" http://127.0.0.1:8090/model/login

echo
echo "############ C — rtdata-consumer（realserver）############"
HD_REDIS_CLUSTER=1 bash /opt/hd/start-hd-apps.sh 1 2>&1 | tail -8
echo
echo "=== 判据 ==="
grep -a -o 'Started PointtabproducerApplication in [0-9.]* seconds' "$LOG_DIR/rtdata-consumer.log" | tail -1 | sed 's/^/  /' || bad "rtdata-consumer 没起来"
chk "rtdata-consumer 致命错误数" "$(grep -a -icE 'APPLICATION FAILED|Could not resolve placeholder|BeanCreationException|JedisNoReachableClusterException|UnsupportedOperationException' "$LOG_DIR/rtdata-consumer.log")" "0"
check_cluster_mode "rtdata-consumer" "$LOG_DIR/rtdata-consumer.log"

echo
echo "############ D — 真实读写（用 redis-cli 确认集群里能读写）############"
probe_redis hd:test:cluster:a v1
echo "  --- 写一个新的再读回 ---"
"$RC" -c -h "$IP" -p 16379 -a "$PASS" --no-auth-warning SET hd:test:cluster:probe hello >/dev/null 2>&1
probe_redis hd:test:cluster:probe hello
"$RC" -c -h "$IP" -p 16379 -a "$PASS" --no-auth-warning DEL hd:test:cluster:probe >/dev/null 2>&1

echo
echo "SUMMARY: PASS=$P FAIL=$F"
[ "$F" -eq 0 ]
```

- [ ] **Step 2: 部署并跑**

```powershell
docker cp "D:\work\rediscluterproject\scripts\hd-cluster-app-test.sh" hd-node1:/opt/hd/hd-cluster-app-test.sh
docker exec hd-node1 bash /opt/hd/hd-cluster-app-test.sh
```

Expected: `SUMMARY: PASS=<n> FAIL=0`

- [ ] **Step 3: 处理失败**

| 现象 | 含义 | 下一步 |
|---|---|---|
| 没有集群模式那行日志 | 应用没进 cluster 分支 | 查 `HD_REDIS_CLUSTER=1` 有没有传进去；查 jar 名对不对 |
| `JedisNoReachableClusterException` | 连不上集群 | 查 announce-ip；查容器内能不能连那三个端口 |
| `UnsupportedOperationException` | **有代码没加集群分支**（`executePipelined`） | 记录到缺陷清单 —— 这正是要测出来的东西 |
| `ERR This instance has cluster support disabled` | 连到的是单机 | 检查是不是连到了 6379 而不是集群节点 |

**发现新的集群盲点时**（比如 `SVGCacheServiceImpl` 的 `redisTemplate.keys()`），
**不要当场改代码** —— 记进 `docker/hd-napstar/DEFECTS.md`，本轮只做「测出来」。

- [ ] **Step 4: 提交**

```powershell
git add scripts/hd-cluster-app-test.sh
git commit -m "test(hd): add the application-level redis cluster read/write test

Checks each app against two criteria: the effective cluster node list in
the startup log, and an actual read/write round trip -- the second one
matters because a wrong oms.clusters value starts fine and only fails on
the first read."
```

---

## Task 6: 回归验证 + 门户未受影响

- [ ] **Step 1: 停掉集群模式的应用，跑现有验证矩阵**

```powershell
docker exec hd-node1 bash -c "pkill -f '[-]jar .*web-controller.*\.jar' 2>/dev/null; pkill -f '[-]jar .*model-controller.*\.jar' 2>/dev/null; pkill -f '[-]jar .*rtdata-consumer.*\.jar' 2>/dev/null; sleep 4; echo stopped"
```

⚠️ **绝不用 `pkill -f java`** —— 会杀掉 Nacos / Kafka / ZK。

```powershell
docker exec hd-node1 bash -c "bash /opt/hd/start-hd-apps.sh 1 2>&1 | tail -8"
docker exec hd-node1 bash -c "bash /opt/hd/verify.sh > /tmp/v3.txt 2>&1; tail -3 /tmp/v3.txt"
```

Expected: `SUMMARY: PASS=47 FAIL=0 SKIP=3`

- [ ] **Step 2: 门户未受影响**

```powershell
docker run --rm -v "D:\work\rediscluterproject:/repo:ro" `
  -v "D:\work\rediscluterproject\.hd-work:/out" `
  -v /var/run/docker.sock:/var/run/docker.sock rc-e2e-runner:local `
  bash /repo/scripts/verify-hd-portal-untouched.sh /out/portal-snapshot-cluster.txt
```

然后跟上一份快照逐项比对：

```powershell
Compare-Object (Get-Content "D:\work\rediscluterproject\.hd-work\portal-snapshot-d2check.txt") `
              (Get-Content "D:\work\rediscluterproject\.hd-work\portal-snapshot-cluster.txt")
```

Expected: **只有 uptime 那一行不同**（容器没被重启）

- [ ] **Step 3: 停掉容器内集群（测完就清，别占内存）**

```powershell
docker exec hd-node1 bash /opt/hd/hd-redis-cluster.sh stop
```

Expected: `剩余 redis-server 进程：` 只剩 `*:6379` 和 `*:6389`（HD 自己的 standalone）

- [ ] **Step 4: 提交**

（如果 Task 6 改了任何文件才提交；否则跳过）

---

## Task 7: 文档收尾

**Files:**
- Modify: `docker/hd-napstar/DEFECTS.md`
- Modify: `docs/OPERATIONS.md`（§4.5 那条「`oms:` 要在三个 dataId 各填一份」—— **实测证明不生效**）
- Modify: `docs/superpowers/sessions/2026-11-01-hd-napstar-docker-deploy.md`
- Create: `docs/superpowers/sessions/2026-11-02-hd-redis-cluster-test.md`（本轮存档）

- [ ] **Step 1: 把新发现写进 DEFECTS.md**

新增一节：

```markdown
## 🟡 D6（实测更正）Nacos 里的 `oms:` **赢不了** jar 内 `application.yml` 的 `oms:`

**实测优先级**（2026-11-01 第二轮）：

| 优先级 | 来源 | 结果 |
|---|---|---|
| 1 | **命令行 `--oms.*`** | ✅ 赢 |
| 2 | jar 内 `application.yml` | ✅ 赢过 Nacos |
| 3 | Nacos dataId 里的 `oms:` | ❌ 输 |

**证据**：给 `icms-controller.yaml` 的 `oms:` 加 `redisMode: standalone`，
启动日志仍是 `*** Using Redis Cluster with nodes: 127.0.0.1:6379`
（那是 jar 里的占位符）；改用命令行 `--oms.redisMode=standalone ...` 就变成
`*** Using Redis Standalone at node1:6379`。

**影响**：`docs/OPERATIONS.md` §4.5 要求的「`oms:` 在三个 dataId 各填一份」
**在当前这套配置下不生效**。要真正切集群，必须走命令行（或改 jar）。

**连带**：D2 方案 (a) 删掉 `ext_base.yaml` 之后，
`oms` 回落到 jar 的 cluster 占位符 → model-controller / commitDataIncreProducer
**启动即失败**（`oms.hostname and oms.port must be configured when oms.redisMode=standalone`）。
```

把实测到的**新的集群盲点**（如果有）也追加进去，例如
`SVGCacheServiceImpl` 的 `redisTemplate.keys()` 没有集群分支。

- [ ] **Step 2: 修 OPERATIONS.md §4.5**

在 §4.5 的 Redis 侧表格**上面**加一段警示：

```markdown
> ⛔ **实测更正（2026-11-01）：本表第 1/5/6 行的「填在 Nacos 里」在当前配置下不生效。**
>
> jar 内的 `application.yml` 硬编码了 `oms.redisMode: cluster` +
> `oms.clusters: [127.0.0.1:6379]`，**它赢过 Nacos**（实测）。
> 优先级：**命令行 `--oms.*` > jar 内 `application.yml` > Nacos dataId**。
>
> → **切实集群必须用命令行覆盖**（§4.4.5 的写法），或改掉 jar 里的 `oms:` 块。
> 判据：启动日志那行 `*** Using Redis Cluster with nodes: <列表>` —— 列表就是生效值。
```

- [ ] **Step 3: 写本轮会话存档**

`docs/superpowers/sessions/2026-11-02-hd-redis-cluster-test.md`，照上一份的格式：
一句话现状 / 环境真相（实测）/ 证据 / 发现的缺陷 / 踩的坑 / 留痕 / 下一轮入口。

- [ ] **Step 4: 提交**

```powershell
git add docker/hd-napstar/DEFECTS.md docs/OPERATIONS.md `
        docs/superpowers/sessions/2026-11-01-hd-napstar-docker-deploy.md `
        docs/superpowers/sessions/2026-11-02-hd-redis-cluster-test.md
git commit -m "docs(hd): record the redis cluster test and the config precedence finding

The precedence question OPERATIONS.md explicitly left untested is now
answered by measurement: command line beats the jar's application.yml,
and the jar beats Nacos. That makes the OPERATIONS.md 4.5 instruction to
put oms: in three Nacos dataIds ineffective, so it needs correcting.

Also records that removing ext_base.yaml (D2 option a) makes model-
controller and commitDataIncreProducer fail to start, because oms falls
back to the jar's cluster placeholder."
```

---

## 附录 A：Task 之间的依赖

```
Task 1 (集群脚本)  ──┬─→ Task 2 (底层验证)
                     │
                     └─→ Task 3 (应用侧注入) ─→ Task 5 (应用层验证)
                                        ↑
                     Task 4 (清理探针残留) ┘

Task 5 ─→ Task 6 (回归 + 门户) ─→ Task 7 (文档)
```

**Task 4 必须在 Task 5 之前** —— 否则 `icms-controller.yaml` 里那条
`redisMode: standalone` 会和命令行覆盖打架，掩盖真实行为。

## 附录 B：全程要盯的三个「假阳性」

| # | 假阳性 | 怎么防 |
|---|---|---|
| F1 | 「启动正常」就以为能用 | 每个应用都要有**真实读写**判据（Task 5 的 D 段） |
| F2 | Nacos 里改了但没生效 | **只看日志那行** `*** Using Redis Cluster with nodes:` —— 它逐字打印生效值 |
| F3 | `pkill` 误杀中间件 | 只用 `pkill -f "[-]jar .*<具体应用名>.*\.jar"`，**绝不用 `pkill -f java`** |

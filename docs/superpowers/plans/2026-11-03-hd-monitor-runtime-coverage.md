# 给 `monitor` 的集群分支补运行时覆盖 —— 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给 `monitor` 的 6 处集群分支补上**运行时**覆盖 —— 用 27 行最小模型元数据让 `SVGCacheServiceImpl` 的写路径在集群模式下真正执行一次，并用**正向判据**（field 数 + field 名逐个比对）证明集群分支与单机分支行为等价。

**Architecture:** 种子数据脚本（`scripts/seed-hd-model-metadata.sh`）把 Nacos `kafkabus.yaml` 里点名的 3 个类型 + 12 个属性灌进 `info` 的三张表，`source_code='HDTEST'` 标记、编号用 `900001+` 显眼段、可重复执行可一键清除。判据脚本（`scripts/hd-monitor-runtime-verify.sh`）**单机跑一遍、集群跑一遍**，把 `real_graph:realscope` 这个 hash 的 field 名与值分别取出来**逐个比对** —— 这是排除「集群分支其实走的是单机分支」的唯一办法。

**Tech Stack:** bash 5.1 / PostgreSQL 14（`psql`）/ Redis 8.10（`redis-cli -c` 集群模式）/ curl / jq 不用（纯 bash + `sort`）

**设计文档：** `docs/superpowers/specs/2026-11-03-hd-monitor-runtime-coverage-design.md`
**相关：** `docker/hd-napstar/DEFECTS.md` §七 #1 · `docs/superpowers/sessions/2026-11-02-tree-map.md`

---

## ⚠️ 开工前必读

### 范围（只有 1 处，不是 6 处）

6 处集群分支里，**只有 `SVGCacheServiceImpl` 这一处**能靠灌数据到达：

| 档 | 位置 | 到达它需要什么 | 本轮 |
|---|---|---|---|
| **A** | `SVGCacheServiceImpl:85` | `matchOType(oname)` 成功 | ✅ **本轮做** |
| B | `RTListener:142` | 一条 Kafka `COMMITDATAINCRE` 消息 | ⏸ **不做**（用户已定最小集） |
| C/D/E/F | `CalculateService`×2、`SVGParseService`×2 | **SVG 文件**（容器里一个都没有）或 websocket 订阅 | ⏸ **不做** |

⇒ **DEFECTS.md 里要诚实写明**：C/D/E/F 四处**仍无运行时覆盖**。

### 已实测的关键事实（不要再重复踩）

| 事实 | 值 | 怎么测的 |
|---|---|---|
| `info.model_objecttype` 等三张表 | **0 行** | `psql -Atc "select count(*) from info.model_objecttype"` |
| `info.model_datatype` | **19 行**（`dt_type` 0–18） | 同上 ⇒ **直接用，不造** |
| `info.model_source` | **2 行**（`NAPStar` / `MSystem`） | 同上 |
| `info.base_user` | **2 行**（`id=1561967773586952192` 超级用户） | 同上 |
| web-controller 的 `OTypeException` | **23 次**，其中 `MVPoint`/`DPSPoint`/`Machine` **各 1 次**，其余 20 次是别的类型 | `grep -ac` + 按类型名分组 |
| Redis 里 `objecttypes*` 缓存 | **0 个 key** | `redis-cli KEYS 'objecttypes*'` ⇒ **失败不写缓存**，清缓存只是防御性 |
| `kafkabus.yaml` | 在 `NAPSTARWEB_GROUP`，**HTTP 200**，241 字节 | `curl "$NACOS/v1/cs/configs?dataId=kafkabus.yaml&group=NAPSTARWEB_GROUP"` |
| 写路径的 Redis key | `real_graph:realscope`（`RedisKey.BASE_SVG_REALSCOPE`） | `RedisKey.java:42` |
| field 命名 | `<objType>_<attrType>` | `SVGCacheServiceImpl.java` 的 `hSet(..., (objectType.getObjType() + "_" + oa.getAttrType())...)` |
| 触发入口 | `POST /napstarweb/svgCache/initGraph`（端口 8099，**需要 token**） | `SVGCacheController.java:72` + `javap` 确认它调 `loadRTConfigKafka()` |
| 集群里读 hash | `redis-cli -c -h $IP -p 16379 -a $PASS HKEYS <key>` | 实测 `HLEN`/`HKEYS`/`HGETALL`/`HGET`/`EXISTS` 都可用 |

### ⚠️ 三个必须避开的坑

1. **PowerShell 5.1 对 UTF-8 无 BOM 的中文按 ANSI 解码** ⇒ `.ps1` 里出现中文路径时 `Test-Path` **恒为 false**。**所有容器内操作都用 `docker cp` + `docker exec`**，文本替换放容器里用 `perl` 做（字节级安全）。
2. **`.ps1` 文件里只写 ASCII**（中文用 `[System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes(...))` 读）。
3. **`git apply` 不用于本轮**（本轮只改仓库里的脚本与文档，不碰树 A 源码）。

---

## 文件结构

| 文件 | 责任 |
|---|---|
| `scripts/seed-hd-model-metadata.sh` | **只做一件事**：把 27 行种子灌进 `info` 三张表，或把它们删掉。两个动作：`--seed` / `--clean` |
| `scripts/hd-monitor-runtime-verify.sh` | **只做一件事**：单机跑一遍 + 集群跑一遍，取 `real_graph:realscope` 的 field 并**逐个比对**。输出自己的 `SUMMARY` |
| `scripts/test-hd-monitor-runtime-verify.sh` | 判据脚本的**边界自测**（假绿防线）：证明「字段数不对就报 FAIL」「集群比单机少字段就报 FAIL」 |
| `docker/hd-napstar/DEFECTS.md` | 更新 §七 #1 的状态 + 诚实声明 C/D/E/F 仍无覆盖 |

**为什么不改 `hd-cluster-app-test.sh`**：那个脚本是**纯集群**判据（`HD_REDIS_CLUSTER=1` 起批）。本轮要**单机 vs 集群对比** ⇒ 必须能自己控制两种模式 ⇒ 独立脚本更清楚，且不动已通过的脚本（降低回归风险）。

**为什么不改树 A 的源码**：本轮**一行 Java 都不改**。集群分支上轮已经加好了（`isCluster` 分支实测 6/4/1/1 处俱在）。本轮只补数据 + 补判据。

---

## Task 1: 种子脚本 `scripts/seed-hd-model-metadata.sh`

**Files:**
- Create: `scripts/seed-hd-model-metadata.sh`
- Test: `scripts/test-hd-monitor-runtime-verify.sh`（Task 4 写；Task 1 先手工验）

- [ ] **Step 1: 写脚本**

```bash
#!/bin/bash
# 华盾 napstar2.0 —— 最小模型元数据种子（**只为了让 monitor 的集群分支跑到**）
#
# ⚠️ **这不是产品数据，是测试夹具。**
#    `sac` / `cmt` / `hds` 是第三方系统的表（只读），
#    `info` 是本项目自有域 —— 本脚本只动 `info` 的三张表。
#
# 数据来源：**Nacos 里的 `kafkabus.yaml`**（NAPSTARWEB_GROUP）——
#    应用自己声明它要哪些对象类型和属性，这里照抄，不另造。
#
# 用法:
#   bash scripts/seed-hd-model-metadata.sh --seed    # 灌进去
#   bash scripts/seed-hd-model-metadata.sh --clean   # 删掉（只删 source_code='HDTEST'）
#   bash scripts/seed-hd-model-metadata.sh --status  # 只看行数
#
# ⚠️ **幂等**：--seed 会先删掉同 source_code 的旧行再插 ⇒ 连跑两次结果一致。
# ⚠️ **编号用 900001+ 显眼段** —— obj_type 会进 Redis field 名（`<objType>_<attrType>`），
#    不能撞真实业务编号。
set -uo pipefail

PSQL="psql -U postgres -h 127.0.0.1 -d napstar -At"
export PGPASSWORD="${PGPASSWORD:-postgres}"
REDIS_CLI=/opt/software/redis-8.10.0/bin/redis-cli

# 标记：所有种子行都带这个 source_code ⇒ 清理时只删自己那批
SEED_SRC=HDTEST
# 超级用户的 id（info.base_user 里那行）
OPERATOR=1561967773586952192

usage() {
  echo "用法: $0 --seed | --clean | --status" >&2
  exit 2
}

[ $# -eq 1 ] || usage
ACTION="$1"

# ---------------------------------------------------------------
# 灌数据
# ---------------------------------------------------------------
# ⚠️ **属性名必须与 kafkabus.yaml 逐字相同** ——
#    `loadRTConfigKafka()` 是拿 `aname` 跟 `oa.getAttrName()` 做 `equals` 比的，
#    差一个字符就匹配不上 ⇒ hSet 一次都不执行。
#    （MVPoint=2 个 / DPSPoint=2 个 / Machine=8 个 ⇒ 共 12 个属性）
seed() {
  echo "=== 清理旧的种子行（source_code='$SEED_SRC'）==="
  $PSQL -c "delete from info.model_objectattribute where source_code='$SEED_SRC'" 2>&1 | sed 's/^/  /'
  $PSQL -c "delete from info.model_attribute where source_code='$SEED_SRC'" 2>&1 | sed 's/^/  /'
  $PSQL -c "delete from info.model_objecttype where source_code='$SEED_SRC'" 2>&1 | sed 's/^/  /'

  echo "=== 插入种子 ==="
  # --- 1) model_objecttype：3 个类型 ---
  $PSQL -c "
insert into info.model_objecttype
  (id, obj_type, obj_name, obj_desc, sort_attribute_type, source_code, isused,
   create_time, update_time, create_operator, update_operator)
values
  (900001, 900001, 'MVPoint',  'HDTEST seed: kafkabus MVPoint',  900001, '$SEED_SRC', 1, now(), now(), $OPERATOR, $OPERATOR),
  (900002, 900002, 'DPSPoint', 'HDTEST seed: kafkabus DPSPoint', 900002, '$SEED_SRC', 1, now(), now(), $OPERATOR, $OPERATOR),
  (900003, 900003, 'Machine',  'HDTEST seed: kafkabus Machine',  900003, '$SEED_SRC', 1, now(), now(), $OPERATOR, $OPERATOR);
" 2>&1 | sed 's/^/  /'

  # --- 2) model_attribute：12 个属性（dt_type 挂现成的 model_datatype）---
  $PSQL -c "
insert into info.model_attribute
  (id, attr_type, attr_name, attr_desc, dt_type, wiringtable, source_code,
   create_time, update_time, create_operator, update_operator)
values
  (900101, 900101, 'Value',          'HDTEST seed', 4, null, '$SEED_SRC', now(), now(), $OPERATOR, $OPERATOR),
  (900102, 900102, 'Quality',        'HDTEST seed', 4, null, '$SEED_SRC', now(), now(), $OPERATOR, $OPERATOR),
  (900103, 900103, 'State',          'HDTEST seed', 9, null, '$SEED_SRC', now(), now(), $OPERATOR, $OPERATOR),
  (900104, 900104, 'Unacknowledged', 'HDTEST seed', 9, null, '$SEED_SRC', now(), now(), $OPERATOR, $OPERATOR),
  (900105, 900105, 'CPUStatus',      'HDTEST seed', 1, null, '$SEED_SRC', now(), now(), $OPERATOR, $OPERATOR),
  (900106, 900106, 'MemStatus',      'HDTEST seed', 1, null, '$SEED_SRC', now(), now(), $OPERATOR, $OPERATOR),
  (900107, 900107, 'CPUSystemEx',    'HDTEST seed', 9, null, '$SEED_SRC', now(), now(), $OPERATOR, $OPERATOR),
  (900108, 900108, 'DiskSystem',     'HDTEST seed', 9, null, '$SEED_SRC', now(), now(), $OPERATOR, $OPERATOR),
  (900109, 900109, 'DiskCPS',        'HDTEST seed', 4, null, '$SEED_SRC', now(), now(), $OPERATOR, $OPERATOR),
  (900110, 900110, 'MemSystemEx',    'HDTEST seed', 9, null, '$SEED_SRC', now(), now(), $OPERATOR, $OPERATOR),
  (900111, 900111, 'SyncStatus',     'HDTEST seed', 9, null, '$SEED_SRC', now(), now(), $OPERATOR, $OPERATOR),
  (900112, 900112, 'SyncPhase',      'HDTEST seed', 1, null, '$SEED_SRC', now(), now(), $OPERATOR, $OPERATOR);
" 2>&1 | sed 's/^/  /'

  # --- 3) model_objectattribute：12 条关联 ---
  $PSQL -c "
insert into info.model_objectattribute
  (obj_type, attr_type, attr_order, data_scope, strlen, enumtype_code,
   numeric_precision, numeric_scale, source_code, isused, isprimkey,
   create_time, update_time, create_operator, update_operator)
values
  (900001, 900101, 1, 0, null, null, null, null, '$SEED_SRC', 1, 0, now(), now(), $OPERATOR, $OPERATOR),
  (900001, 900102, 2, 0, null, null, null, null, '$SEED_SRC', 1, 0, now(), now(), $OPERATOR, $OPERATOR),
  (900002, 900103, 1, 0, null, null, null, null, '$SEED_SRC', 1, 0, now(), now(), $OPERATOR, $OPERATOR),
  (900002, 900104, 2, 0, null, null, null, null, '$SEED_SRC', 1, 0, now(), now(), $OPERATOR, $OPERATOR),
  (900003, 900105, 1, 0, null, null, null, null, '$SEED_SRC', 1, 0, now(), now(), $OPERATOR, $OPERATOR),
  (900003, 900106, 2, 0, null, null, null, null, '$SEED_SRC', 1, 0, now(), now(), $OPERATOR, $OPERATOR),
  (900003, 900107, 3, 0, null, null, null, null, '$SEED_SRC', 1, 0, now(), now(), $OPERATOR, $OPERATOR),
  (900003, 900108, 4, 0, null, null, null, null, '$SEED_SRC', 1, 0, now(), now(), $OPERATOR, $OPERATOR),
  (900003, 900109, 5, 0, null, null, null, null, '$SEED_SRC', 1, 0, now(), now(), $OPERATOR, $OPERATOR),
  (900003, 900110, 6, 0, null, null, null, null, '$SEED_SRC', 1, 0, now(), now(), $OPERATOR, $OPERATOR),
  (900003, 900111, 7, 0, null, null, null, null, '$SEED_SRC', 1, 0, now(), now(), $OPERATOR, $OPERATOR),
  (900003, 900112, 8, 0, null, null, null, null, '$SEED_SRC', 1, 0, now(), now(), $OPERATOR, $OPERATOR);
" 2>&1 | sed 's/^/  /'

  echo "=== 灌完的行数（期望 3 / 12 / 12）==="
  status

  echo "=== 清 Redis 的 objecttypes 缓存（防御性：实测失败不写缓存，这里只是以防万一）==="
  local_keys=$($REDIS_CLI -h 127.0.0.1 -p 6379 -a sac888 --no-auth-warning KEYS 'objecttypes*' 2>/dev/null | grep -c 'objecttypes')
  echo "  找到 objecttypes* key: $local_keys 个"
  if [ "${local_keys:-0}" -gt 0 ]; then
    $REDIS_CLI -h 127.0.0.1 -p 6379 -a sac888 --no-auth-warning KEYS 'objecttypes*' 2>/dev/null \
      | grep 'objecttypes' \
      | while read -r k; do $REDIS_CLI -h 127.0.0.1 -p 6379 -a sac888 --no-auth-warning DEL "$k" >/dev/null 2>&1; done
    echo "  已清"
  else
    echo "  没有要清的（符合预期：matchOTypeCode 失败时不写缓存）"
  fi
}

# ---------------------------------------------------------------
# 清理
# ---------------------------------------------------------------
clean() {
  echo "=== 删除种子行（source_code='$SEED_SRC'）==="
  $PSQL -c "delete from info.model_objectattribute where source_code='$SEED_SRC'" 2>&1 | sed 's/^/  /'
  $PSQL -c "delete from info.model_attribute where source_code='$SEED_SRC'" 2>&1 | sed 's/^/  /'
  $PSQL -c "delete from info.model_objecttype where source_code='$SEED_SRC'" 2>&1 | sed 's/^/  /'
  echo "=== 剩余行数（期望 0 / 0 / 0）==="
  status
}

# ---------------------------------------------------------------
# 状态
# ---------------------------------------------------------------
status() {
  local o a oa
  o=$($PSQL -c "select count(*) from info.model_objecttype where source_code='$SEED_SRC'" 2>/dev/null | tr -d '\r')
  a=$($PSQL -c "select count(*) from info.model_attribute where source_code='$SEED_SRC'" 2>/dev/null | tr -d '\r')
  oa=$($PSQL -c "select count(*) from info.model_objectattribute where source_code='$SEED_SRC'" 2>/dev/null | tr -d '\r')
  echo "  model_objecttype     = ${o:-ERR}"
  echo "  model_attribute      = ${a:-ERR}"
  echo "  model_objectattribute= ${oa:-ERR}"
}

case "$ACTION" in
  --seed)   seed ;;
  --clean)  clean ;;
  --status) status ;;
  *)        usage ;;
esac
```

- [ ] **Step 2: 语法检查**

```powershell
docker cp "D:\work\rediscluterproject\scripts\seed-hd-model-metadata.sh" hd-node1:/opt/hd/seed-hd-model-metadata.sh
docker exec hd-node1 bash -n /opt/hd/seed-hd-model-metadata.sh
```

Expected: 无输出，退出码 0。

- [ ] **Step 3: 灌种子并核对行数**

```powershell
docker exec hd-node1 bash /opt/hd/seed-hd-model-metadata.sh --seed
```

Expected:
```
  model_objecttype     = 3
  model_attribute      = 12
  model_objectattribute= 12
```

- [ ] **Step 4: 幂等性验证（连跑两次，行数不变）**

```powershell
docker exec hd-node1 bash /opt/hd/seed-hd-model-metadata.sh --seed
docker exec hd-node1 bash /opt/hd/seed-hd-model-metadata.sh --seed
docker exec hd-node1 bash /opt/hd/seed-hd-model-metadata.sh --status
```

Expected: 仍然是 `3 / 12 / 12`（不是 `6 / 24 / 24`）。

- [ ] **Step 5: 用应用自己的查询路径验证数据能被读出来**

```powershell
docker exec hd-node1 bash -c "PGPASSWORD=postgres psql -U postgres -h 127.0.0.1 -d napstar -c \"
SELECT o.obj_name, a.attr_name, oa.obj_type, oa.attr_type
FROM info.model_objectattribute oa
JOIN info.model_objecttype o ON oa.obj_type = o.obj_type
JOIN info.model_attribute  a ON oa.attr_type = a.attr_type
WHERE o.source_code = 'HDTEST'
ORDER BY o.obj_type, oa.attr_order;\""
```

Expected: **12 行**，且 `obj_name` 恰好是 `MVPoint`(2) / `DPSPoint`(2) / `Machine`(8)。

> ⚠️ 这一步用的是 `CacheServiceImpl.matchOType` 里**同样那套 JOIN**（`model_objectattribute oa LEFT JOIN model_attribute a ON oa.attr_type = a.attr_type`）⇒ 能读出来 = 应用能读出来。

- [ ] **Step 6: 提交**

```powershell
git -C "D:\work\rediscluterproject" add scripts/seed-hd-model-metadata.sh
git -C "D:\work\rediscluterproject" commit -m "feat(hd): add the minimal model metadata seed for the monitor cluster branches"
```

---

## Task 2: 判据脚本 `scripts/hd-monitor-runtime-verify.sh`（单机 + 集群对比）

**Files:**
- Create: `scripts/hd-monitor-runtime-verify.sh`

- [ ] **Step 1: 写脚本**

```bash
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
dump_fields() {
  local out="$1" mode="$2" p f
  : > "$out"
  if [ "$mode" = cluster ]; then
    for p in $P1 $P2 $P3; do
      f=$(rcc "$p" HKEYS "$KEY")
      echo "$f" | grep -v '^$' >> "$out"
    done
  else
    f=$(rs 6379 HKEYS "$KEY")
    echo "$f" | grep -v '^$' >> "$out"
  fi
  sort -u -o "$out" "$out"
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
bash /opt/hd/start-hd-apps.sh 1 >/tmp/mrv-standalone-app.log 2>&1
sleep 5
# 触发写路径（StartupRunner 启动时也会跑一次，这里主动再跑一次）
TOK=$(cat /tmp/hd-token.txt 2>/dev/null)
if [ -n "$TOK" ]; then
  CODE=$(curl -s -m 30 -o /tmp/mrv-standalone-resp.txt -w '%{http_code}' \
    -X POST -H "Authorization: $TOK" -H 'Content-Type: application/json' -d '{}' \
    "http://127.0.0.1:8099/napstarweb/svgCache/initGraph" 2>/dev/null)
  echo "  触发 svgCache/initGraph -> HTTP $CODE"
  if [ "$CODE" = "404" ] || [ "$CODE" = "000" ] || [ -z "$CODE" ]; then
    echo "!! 触发入口不可达（HTTP $CODE）—— 判据没法执行"; exit 3
  fi
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
HD_REDIS_CLUSTER=1 bash /opt/hd/start-hd-apps.sh 1 >/tmp/mrv-cluster-app.log 2>&1
sleep 5
CODE=$(curl -s -m 30 -o /tmp/mrv-cluster-resp.txt -w '%{http_code}' \
  -X POST -H "Authorization: $TOK" -H 'Content-Type: application/json' -d '{}' \
  "http://127.0.0.1:8099/napstarweb/svgCache/initGraph" 2>/dev/null)
echo "  触发 svgCache/initGraph -> HTTP $CODE"
if [ "$CODE" = "404" ] || [ "$CODE" = "000" ] || [ -z "$CODE" ]; then
  echo "!! 触发入口不可达（HTTP $CODE）—— 判据没法执行"; exit 3
fi
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
if diff -u /tmp/mrv-standalone-fields.txt /tmp/mrv-cluster-fields.txt > /tmp/mrv-field-diff.txt 2>&1; then
  ok "C2 集群模式的 field 名与单机模式**逐个相等**（$(grep -c . /tmp/mrv-cluster-fields.txt) 个）"
else
  bad "C2 集群模式的 field 名与单机模式**不一致**："
  sed 's/^/      /' /tmp/mrv-field-diff.txt
fi

# ---------------------------------------------------------------
# 判据 4：kafkabus 那 3 个类型的 OTypeException 归零
# ---------------------------------------------------------------
echo
echo "############ 4) OTypeException（kafkabus 那 3 个类型） ############"
A_LOG="$LOG_DIR/web-controller.log"
N3=$(grep -ac 'oType数值非法或不存在：\(MVPoint\|DPSPoint\|Machine\)' "$A_LOG" 2>/dev/null)
NTOT=$(grep -ac 'OTypeException' "$A_LOG" 2>/dev/null)
echo "  kafkabus 3 个类型的异常数 = $N3   （总数 = $NTOT）"
echo "  ⚠️ 总数**不会**归零：另外那些来自 SVG 解析路径的其它类型，不在本轮范围"
if [ "${N3:-0}" -eq 0 ]; then
  ok "C3 kafkabus 那 3 个类型的 OTypeException 已归零（总数仍有 $NTOT，来自其它类型）"
else
  bad "C3 kafkabus 那 3 个类型还有 $N3 个 OTypeException"
fi

# ---------------------------------------------------------------
# 判据 5：集群模式下没有 UOE
# ---------------------------------------------------------------
echo
echo "############ 5) JVM 层的 UnsupportedOperationException ############"
NU=$(grep -ac 'java\.lang\.UnsupportedOperationException\|not supported for JedisClusterConnection' "$A_LOG" 2>/dev/null)
if [ "${NU:-0}" -eq 0 ]; then
  ok "C4 集群模式下无 UnsupportedOperationException"
else
  bad "C4 集群模式下有 $NU 个 UnsupportedOperationException"
fi

echo
echo "SUMMARY: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: 语法检查**

```powershell
docker cp "D:\work\rediscluterproject\scripts\hd-monitor-runtime-verify.sh" hd-node1:/opt/hd/hd-monitor-runtime-verify.sh
docker exec hd-node1 bash -n /opt/hd/hd-monitor-runtime-verify.sh
```

Expected: 无输出，退出码 0。

- [ ] **Step 3: 先验「前置条件不满足时必须非 0 退出且不打印 SUMMARY」**

```powershell
docker exec hd-node1 bash /opt/hd/seed-hd-model-metadata.sh --clean
docker exec hd-node1 bash /opt/hd/hd-monitor-runtime-verify.sh; Write-Output "exit=$LASTEXITCODE"
```

Expected: 打印「元数据表是空的 —— 判据不可执行」，**退出码 3**，**不打印 `SUMMARY:`**。

- [ ] **Step 4: 灌种子后跑判据**

```powershell
docker exec hd-node1 bash /opt/hd/seed-hd-model-metadata.sh --seed
docker exec hd-node1 bash /opt/hd/hd-monitor-runtime-verify.sh; Write-Output "exit=$LASTEXITCODE"
```

Expected:
```
  单机 field 数 = 12
  集群 field 数 = 12
SUMMARY: PASS=6 FAIL=0
```
退出码 0。

> ⚠️ **如果 field 数是 0** ⇒ 说明 `matchOType` 还是失败 ⇒ 查：
> `grep -a 'oType数值非法或不存在' /opt/hd/logs/web-controller.log | tail -5`
> —— 如果报的是**别的类型名**（不是 MVPoint/DPSPoint/Machine），说明种子的**属性名对不上**，
> 回 Task 1 Step 5 核对 `attr_name` 与 `kafkabus.yaml` 是否逐字相同。

- [ ] **Step 5: 提交**

```powershell
git -C "D:\work\rediscluterproject" add scripts/hd-monitor-runtime-verify.sh
git -C "D:\work\rediscluterproject" commit -m "feat(hd): verify the monitor cluster branch by comparing standalone and cluster output"
```

---

## Task 3: 判据脚本的自测 `scripts/test-hd-monitor-runtime-verify.sh`

**Files:**
- Create: `scripts/test-hd-monitor-runtime-verify.sh`

> ⚠️ **为什么要有这个**：本轮的判据如果只会「报 PASS」，那它跟上一轮那个「假绿」的判据没区别。
> 这个自测要证明：**给坏的输入，判据必须报 FAIL**。

- [ ] **Step 1: 写脚本**

```bash
#!/bin/bash
# hd-monitor-runtime-verify.sh 的**边界情况**测试（防假绿）
#
# ⚠️ **这个测试测的是「判据会不会把坏的当成好的」**：
#    如果判据在「集群比单机少字段」「字段数不对」「前置条件不满足」时
#    仍然报 PASS，那它就是上一轮那个假绿判据的翻版。
#
# 用法:
#   bash scripts/test-hd-monitor-runtime-verify.sh
set -uo pipefail

TPASS=0; TFAIL=0
ok()  { echo "  PASS  $*"; TPASS=$((TPASS+1)); }
bad() { echo "  FAIL  $*"; TFAIL=$((TFAIL+1)); }

T=$(mktemp -d "${TMPDIR:-/tmp}/hd-mrv-test.XXXXXX") || { echo "mktemp 失败" >&2; exit 2; }
cleanup() { [ -n "${T:-}" ] && [ -d "$T" ] && rm -rf "$T"; return 0; }
trap cleanup EXIT

# 被测代码里那两个「比对」函数 —— 从判据脚本里**抽出来**，
# 测的时候 source 判据脚本的**副本**。
# ⚠️ 这里**不 source 判据脚本本身** —— 它会立刻跑起来（起应用、连集群）。
#     判据脚本必须把「纯逻辑」的部分放进一个可 source 的库里 ——
#     所以判据脚本要拆成两个文件：
#       hd-monitor-runtime-verify.sh   —— 编排（起应用、跑两遍）
#       hd-monitor-runtime-lib.sh      —— 纯逻辑（比对 field、判异常数）
#     这个测试 source 的是**后者**（发布的那份，不是复制品）。

LIB=/opt/hd/hd-monitor-runtime-lib.sh
[ -f "$LIB" ] || LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hd-monitor-runtime-lib.sh"
if [ ! -f "$LIB" ]; then
  echo "!! 找不到 hd-monitor-runtime-lib.sh" >&2
  exit 2
fi
echo "被测代码: $LIB"
# shellcheck source=/dev/null
. "$LIB"

# ---- 场景 1：两边 field 完全相同 ⇒ 必须判「一致」 ----
cat > "$T/a.txt" <<'EOF'
900001_900101
900001_900102
900002_900103
EOF
cp "$T/a.txt" "$T/b.txt"
if mrv_fields_match "$T/a.txt" "$T/b.txt"; then
  ok "场景1 两边相同 ⇒ 判一致"
else
  bad "场景1 两边相同却判不一致"
fi

# ---- 场景 2：集群少一个 field ⇒ 必须判「不一致」----
cat > "$T/c.txt" <<'EOF'
900001_900101
900002_900103
EOF
if mrv_fields_match "$T/a.txt" "$T/c.txt"; then
  bad "场景2 少一个 field 却判一致 —— 这是假绿！"
else
  ok "场景2 少一个 field ⇒ 判不一致"
fi

# ---- 场景 3：集群多一个 field ⇒ 必须判「不一致」----
cat > "$T/d.txt" <<'EOF'
900001_900101
900001_900102
900002_900103
900003_900105
EOF
if mrv_fields_match "$T/a.txt" "$T/d.txt"; then
  bad "场景3 多一个 field 却判一致 —— 这是假绿！"
else
  ok "场景3 多一个 field ⇒ 判不一致"
fi

# ---- 场景 4：field 数不对 ⇒ 必须判「不对」----
if mrv_field_count_ok "$T/a.txt" 3; then
  ok "场景4 field 数对 ⇒ 判对"
else
  bad "场景4 field 数对却判不对"
fi
if mrv_field_count_ok "$T/c.txt" 3; then
  bad "场景5 field 数不对却判对 —— 这是假绿！"
else
  ok "场景5 field 数不对 ⇒ 判不对"
fi

# ---- 场景 6：空文件 ⇒ 必须判「不对」（0 个 field 不等于期望的 N）----
: > "$T/empty.txt"
if mrv_field_count_ok "$T/empty.txt" 3; then
  bad "场景6 空文件却判对 —— 这是假绿！"
else
  ok "场景6 空文件 ⇒ 判不对"
fi

# ---- 场景 7：objType 段是不是种子编号 ----
if mrv_field_is_seed "900001_900101" "900001 900002 900003"; then
  ok "场景7 种子编号的 field ⇒ 认得"
else
  bad "场景7 种子编号的 field 却认不得"
fi
if mrv_field_is_seed "12345_67890" "900001 900002 900003"; then
  bad "场景8 非种子编号的 field 却认得 —— 这是假绿！"
else
  ok "场景8 非种子编号的 field ⇒ 认不得"
fi

echo
echo "TEST SUMMARY: PASS=$TPASS FAIL=$TFAIL"
[ "$TFAIL" -eq 0 ]
```

- [ ] **Step 2: 把判据脚本拆出可 source 的库**

**新建 `scripts/hd-monitor-runtime-lib.sh`**（从 Task 2 的判据脚本里抽出**纯逻辑**部分）：

```bash
#!/bin/bash
# hd-monitor-runtime-verify.sh 的**纯逻辑**部分（可被 source）
#
# ⚠️ **为什么要拆出来**：
#    判据脚本本身会立刻起应用、连集群 —— 不能被 source（否则一 source 就跑起来了）。
#    把「比对」这层拆出来，才能对它写边界测试（假绿防线）。
#
# 这个文件**不做任何 IO**，只处理「已经取到本地的 field 列表」。

# 两个 field 列表是否**逐个相等**（两边都已排序去重）
mrv_fields_match() {
  local a="$1" b="$2"
  [ -f "$a" ] || return 1
  [ -f "$b" ] || return 1
  diff -q "$a" "$b" >/dev/null 2>&1
}

# field 数是否等于期望值
mrv_field_count_ok() {
  local f="$1" want="$2" n
  [ -f "$f" ] || return 1
  n=$(grep -c . "$f" 2>/dev/null)
  [ "${n:-0}" -eq "$want" ]
}

# 某个 field 的 objType 段（`_` 前面那半）是不是种子编号之一
mrv_field_is_seed() {
  local field="$1" seeds="$2" ot
  ot="${field%%_*}"
  case " $seeds " in
    *" $ot "*) return 0 ;;
    *) return 1 ;;
  esac
}
```

**然后改 `scripts/hd-monitor-runtime-verify.sh`**：把 `dump_fields` 后面那些判据改成调用库函数。改动点（Task 2 的脚本里）：

```bash
# 顶部加一行 source
LIB_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hd-monitor-runtime-lib.sh"
[ -f "$LIB_SELF" ] || LIB_SELF=/opt/hd/hd-monitor-runtime-lib.sh
if [ ! -f "$LIB_SELF" ]; then echo "!! 找不到 hd-monitor-runtime-lib.sh" >&2; exit 3; fi
# shellcheck source=/dev/null
. "$LIB_SELF"
```

并把这三处替换：

```bash
# 原：
#   if [ "$S_FIELDS" -eq "$EXPECT_FIELDS" ]; then
# 改：
if mrv_field_count_ok /tmp/mrv-standalone-fields.txt "$EXPECT_FIELDS"; then

# 原：
#   if diff -u /tmp/mrv-standalone-fields.txt /tmp/mrv-cluster-fields.txt > /tmp/mrv-field-diff.txt 2>&1; then
# 改：
if mrv_fields_match /tmp/mrv-standalone-fields.txt /tmp/mrv-cluster-fields.txt; then
  diff -u /tmp/mrv-standalone-fields.txt /tmp/mrv-cluster-fields.txt > /tmp/mrv-field-diff.txt 2>&1

# 原：
#   case " $SEED_OTYPES " in *" $ot "*) SEEN_SEED=$((SEEN_SEED+1)) ;; esac
# 改：
#   if mrv_field_is_seed "$f" "$SEED_OTYPES"; then SEEN_SEED=$((SEEN_SEED+1)); fi
```

- [ ] **Step 3: 语法检查两个文件**

```powershell
docker cp "D:\work\rediscluterproject\scripts\hd-monitor-runtime-lib.sh" hd-node1:/opt/hd/hd-monitor-runtime-lib.sh
docker cp "D:\work\rediscluterproject\scripts\hd-monitor-runtime-verify.sh" hd-node1:/opt/hd/hd-monitor-runtime-verify.sh
docker cp "D:\work\rediscluterproject\scripts\test-hd-monitor-runtime-verify.sh" hd-node1:/opt/hd/test-hd-monitor-runtime-verify.sh
docker exec hd-node1 bash -n /opt/hd/hd-monitor-runtime-lib.sh
docker exec hd-node1 bash -n /opt/hd/hd-monitor-runtime-verify.sh
docker exec hd-node1 bash -n /opt/hd/test-hd-monitor-runtime-verify.sh
```

Expected: 三条都无输出。

- [ ] **Step 4: 跑自测**

```powershell
docker exec hd-node1 bash /opt/hd/test-hd-monitor-runtime-verify.sh; Write-Output "exit=$LASTEXITCODE"
```

Expected: `TEST SUMMARY: PASS=8 FAIL=0`，退出码 0。

- [ ] **Step 5: 确认判据脚本仍能跑通（拆库没拆坏）**

```powershell
docker exec hd-node1 bash /opt/hd/hd-monitor-runtime-verify.sh; Write-Output "exit=$LASTEXITCODE"
```

Expected: `SUMMARY: PASS=6 FAIL=0`，退出码 0。
（6 条判据：S1 / S2 / C1 / C2 / C3 / C4 —— 计划里原先写的「PASS=5」是**数错了**，
脚本里是 6 个 `ok()`；已按实测改正。）

- [ ] **Step 6: 提交**

```powershell
git -C "D:\work\rediscluterproject" add scripts/hd-monitor-runtime-lib.sh scripts/hd-monitor-runtime-verify.sh scripts/test-hd-monitor-runtime-verify.sh
git -C "D:\work\rediscluterproject" commit -m "test(hd): guard the monitor runtime verdict against false green"
```

---

## Task 4: 文档收尾

**Files:**
- Modify: `docker/hd-napstar/DEFECTS.md`（§七 #1 那一条 + 汇总表加一行）
- Modify: `docs/superpowers/sessions/2026-11-02-hd-redis-cluster-fix.md`（追加第九节）

- [ ] **Step 1: 更新 DEFECTS.md 的 §七 #1**

把这一行：

```
| **1** | **`monitor` 的 6 处补运行时覆盖** | 🟡 | 本轮只做了静态核验。**要补模型元数据表的数据**（`info.model_objecttype` / `model_attribute` / `model_objectattribute`），或在有真实模型数据的环境上再跑一次集群模式。**「启动无 UOE」不能当判据**（假绿） |
```

改成：

```
| **1** | **`monitor` 的 6 处补运行时覆盖** | 🟡 | **部分完成（2026-11-03）**：灌了 **27 行最小模型元数据**（`scripts/seed-hd-model-metadata.sh`，数据源 = Nacos 的 `kafkabus.yaml`）⇒ **`SVGCacheServiceImpl` 的写路径（6 处里的 1 处）拿到了运行时覆盖**，`real_graph:realscope` 在单机与集群模式下**各有 12 个 field 且逐个相等**（`scripts/hd-monitor-runtime-verify.sh`）。⚠️ **另外 4 处（`CalculateService`×2、`SVGParseService`×2）仍无运行时覆盖** —— 它们需要 **SVG 文件**（容器里一个 `*-ScheFile.svg` 都没有）或 websocket 订阅才能到达，那是**图形侧**的数据准备。`RTListener` 那处只差一条 Kafka `COMMITDATAINCRE` 消息，未做。**「启动无 UOE」依然不能当判据**（假绿） |
```

- [ ] **Step 2: 在 DEFECTS.md 汇总表加一行**

在 `| D10 |` 那行**后面**加：

```
| D11 | 🟡 | 本轮夹具 | **`monitor` 的 6 处集群分支只覆盖了 1 处**（`SVGCacheServiceImpl`）。另外 4 处缺 SVG 文件/订阅，`RTListener` 那处缺 Kafka 消息 ⇒ **6 处里有 5 处仍未在集群模式下真正执行过**。「jar 里 `isCluster` 的 class 数 = 4」这个静态判据**不代表**运行时正确 |
```

- [ ] **Step 3: 会话存档追加第九节**

在 `docs/superpowers/sessions/2026-11-02-hd-redis-cluster-fix.md` 末尾追加：

```markdown
---

## 九、2026-11-03 追加轮：给 `monitor` 的集群分支补运行时覆盖

> 承接 §八 #1（「`monitor` 的 6 处补运行时覆盖」）。

### 9.1 先把「假绿」坐实

上轮说「6 处已修」，验收只有**静态**证据（jar 里 `isCluster` 的 class 数 0 → 4）。
本轮实测确认：**那 6 处一次都没在集群模式下真正执行过**。

- `info.model_objecttype` / `model_attribute` / `model_objectattribute` **全是 0 行**
- ⇒ `CacheServiceImpl.matchOTypeCode(name)` 走 `else` → **`throw new OTypeException(name)`**
- ⇒ 写路径在 `matchOType(...)` 就抛了，**走不到那行 Redis 调用**
- ⇒ 「日志里没有 UOE」是「**没跑**」换来的

**实测佐证**：web-controller 日志里 `OTypeException` **23 次**
（`MVPoint`/`DPSPoint`/`Machine` 各 1 次，其余 20 次是别的类型，来自 SVG 解析路径），
`UnsupportedOperationException` **0 次**。

### 9.2 逐处追调用链 ⇒ 6 处分三档

| 档 | 位置 | 到达它需要什么 | 本轮 |
|---|---|---|---|
| **A** | `SVGCacheServiceImpl:85` | `matchOType(oname)` 成功 —— `oname` 就在 **Nacos 的 `kafkabus.yaml`** 里 | ✅ **做了** |
| B | `RTListener:142` | 一条 Kafka `COMMITDATAINCRE` 消息 | ⏸ 未做（用户定最小集） |
| C/D/E/F | `CalculateService`×2、`SVGParseService`×2 | **SVG 文件**（容器里一个都没有）或 websocket 订阅 | ⏸ 未做 |

### 9.3 做了什么

| 文件 | 内容 |
|---|---|
| `scripts/seed-hd-model-metadata.sh` | 灌 / 清 **27 行**种子（3 objecttype + 12 attribute + 12 关联），`source_code='HDTEST'`，编号 `900001+`，幂等可清除 |
| `scripts/hd-monitor-runtime-verify.sh` | **单机 + 集群**两遍跑，比对 `real_graph:realscope` 的 field **逐个相等** |
| `scripts/hd-monitor-runtime-lib.sh` | 判据的纯逻辑（可 source） |
| `scripts/test-hd-monitor-runtime-verify.sh` | 判据的**边界自测**（假绿防线） |

**数据源不用编**：Nacos 的 `kafkabus.yaml`（`NAPSTARWEB_GROUP`，HTTP 200）就是应用自己声明的清单
（`MVPoint`/`DPSPoint`/`Machine` + 12 个属性）⇒ 照抄，不另造。

**实测数字**：
- 单机模式 `real_graph:realscope` = **12 个 field**
- 集群模式 = **同样的 12 个 field**（field 名逐个相等）
- `kafkabus` 那 3 个类型的 `OTypeException` → **0**（总数仍 20，来自其它类型）
- 判据自测 `PASS=8 FAIL=0`

### 9.4 本轮踩的坑

| # | 坑 | 对策 |
|---|---|---|
| 18 | **PS 5.1 的 `Get-Content`/`-File` 对 UTF-8 无 BOM 的中文按 ANSI 解码** ⇒ `.ps1` 里写中文路径时 `Test-Path` **恒为 false** | 一律用 `docker cp` + `docker exec`；文本替换放容器里用 `perl`（字节级安全）；`.ps1` 只写 ASCII |
| 19 | **shell 里写含 `\|` `(` `'` 的中文替换串 ⇒ 引号地狱**（连续踩了 3 次） | 替换文本放**独立文件**，脚本按行号/前缀定位替换，不在 shell 里拼长串 |
| 20 | **全局 `perl -0777 -pe` 替换会误伤刚写的说明文字** | 保护标记 → 替换 → 还原；改完逐行 `diff` |

### 9.5 下一轮照做

> **灌 27 行元数据，换 6 处里的 1 处真正在集群模式下跑一次。**
> **另外 5 处仍缺运行时覆盖** —— 已记进 DEFECTS 的 D11，**不假装覆盖了**。
> 要覆盖剩下 5 处，得先解决「SVG 文件从哪来」和「COMMITDATAINCRE 消息格式」两个输入问题。
```

- [ ] **Step 4: 核对文档的编码与格式**

```powershell
docker run --rm -v "D:\work\rediscluterproject:/repo:ro" rc-e2e-runner:local bash -c '
for f in /repo/docker/hd-napstar/DEFECTS.md /repo/docs/superpowers/sessions/2026-11-02-hd-redis-cluster-fix.md; do
  printf "  %-46s utf8=%s bom=%s crlf=%s\n" "$(basename $f)" \
    "$(iconv -f UTF-8 -t UTF-8 $f >/dev/null 2>&1 && echo OK || echo BAD)" \
    "$(head -c 3 $f | od -An -tx1 | tr -d " \n")" \
    "$(grep -c $'"'"'\r'"'"' $f)"
done'
```

Expected: 三个文件都 `utf8=OK`、`bom=2320e5`（不是 `efbbbf`）、`crlf=0`。

- [ ] **Step 5: 提交**

```powershell
git -C "D:\work\rediscluterproject" add docker/hd-napstar/DEFECTS.md docs/superpowers/sessions/2026-11-02-hd-redis-cluster-fix.md
git -C "D:\work\rediscluterproject" commit -m "docs(hd): record the runtime coverage result and the remaining gap"
```

---

## Task 5: 收尾 —— 跑完整回归，确认没有退化

> ⚠️ **顺序固定**（上一轮踩过）：**跑完集群测试 → 停集群 → 再跑 base 矩阵**。
> 集群在跑时 base 矩阵的 C 段会把集群的计数并进来 ⇒ SUMMARY 数字与基线**不可比**。

- [ ] **Step 1: 起集群 + 跑集群层测试**

```powershell
docker exec hd-node1 bash /opt/hd/hd-redis-cluster.sh start
docker exec hd-node1 bash /opt/hd/hd-cluster-app-test.sh 2>&1 | Select-Object -Last 40
```

Expected: `SUMMARY: PASS=34 FAIL=0 SKIP=1`
（⚠️ **A2 那条要从 SKIP 变成 PASS** —— 这正是本轮的目的。
若仍是 SKIP ⇒ `info.model_objecttype` 还是 0 行 ⇒ 回 Task 1 Step 3。）

- [ ] **Step 2: 跑底层集群验证**

```powershell
docker exec hd-node1 bash /opt/hd/hd-cluster-verify.sh 2>&1 | Select-Object -Last 5
```

Expected: `SUMMARY: PASS=39 FAIL=0`

- [ ] **Step 3: 跑脚本自测（⚠️ 必须在集群停之前 —— `merge-wiring` 那条要集群在跑）**

⚠️ **前三个在 `hd-node1` 里跑；第四个（`test-hd-portal-baseline.sh`）必须在 `rc-e2e-runner` 里跑** —— 它要读 `/out/portal-snapshot-cluster.txt`（`/out` 是宿主 `.hd-work` 的挂载点，**`hd-node1` 里没有这个挂载**）。在 `hd-node1` 里跑会因「找不到真实快照」**退出码 2**。

```powershell
# 前三个 —— hd-node1 里（此时集群还在跑 ⇒ merge-wiring 测得到「合并」那一步）
docker exec hd-node1 bash /opt/hd/test-hd-cluster-summary.sh 2>&1 | Select-Object -Last 2
docker exec hd-node1 bash /opt/hd/test-hd-cluster-merge-wiring.sh 2>&1 | Select-Object -Last 2
docker exec hd-node1 bash /opt/hd/test-hd-monitor-runtime-verify.sh 2>&1 | Select-Object -Last 2
# 第四个 —— rc-e2e-runner 里（需要 /repo 和 /out 两个挂载）
docker run --rm -v "D:\work\rediscluterproject:/repo:ro" `
  -v "D:\work\rediscluterproject\.hd-work:/out" `
  -v /var/run/docker.sock:/var/run/docker.sock rc-e2e-runner:local `
  bash /repo/scripts/test-hd-portal-baseline.sh 2>&1 | Select-Object -Last 2
```

Expected:
```
TEST SUMMARY: PASS=19 FAIL=0
TEST SUMMARY: PASS=8 FAIL=0
TEST SUMMARY: PASS=8 FAIL=0
TEST SUMMARY: PASS=40 FAIL=0
```

> ⚠️ **`test-hd-cluster-merge-wiring.sh` 的坑**：集群没跑时它会**静默跳过**（退出码 0 但 `PASS=0`）——
> 「退出码 0」**不等于**「测到了」。
> ⇒ 看到 `PASS=0` 就是集群没在跑，**补跑**：`docker exec hd-node1 bash /opt/hd/hd-redis-cluster.sh start` 再跑一次。
> ⇒ 这就是它必须排在「停集群」**之前**的原因。

- [ ] **Step 4: 停集群**

```powershell
docker exec hd-node1 bash /opt/hd/hd-redis-cluster.sh stop
docker exec hd-node1 bash -lc "ps -eo args | grep '[r]edis-server' | sed 's/.*redis-server //'"
```

Expected: 只有 `*:6379` 和 `*:6389`。

- [ ] **Step 5: 起单机应用 + 跑 base 回归矩阵**

```powershell
docker exec hd-node1 bash -c "pkill -f '[-]jar .*web-controller.*\.jar' 2>/dev/null; pkill -f '[-]jar .*realalarmconsumer.*\.jar' 2>/dev/null; pkill -f '[-]jar .*model-controller.*\.jar' 2>/dev/null; pkill -f '[-]jar .*rtdata-consumer.*\.jar' 2>/dev/null; sleep 4; echo stopped"
docker exec hd-node1 bash -c "bash /opt/hd/start-hd-apps.sh 1 2>&1 | tail -20"
docker exec hd-node1 bash -c "cd /opt/napstar_app && nohup /opt/software/jdk-21.0.2/bin/java -Xms64m -Xmx192m -server -XX:+UseG1GC -XX:MaxGCPauseMillis=20 -XX:InitiatingHeapOccupancyPercent=35 -XX:MaxMetaspaceSize=160m -Dfile.encoding=UTF-8 -jar model-controller-3.0.0.jar > /opt/hd/logs/model-controller.log 2>&1 & sleep 40; echo started"
docker exec hd-node1 bash -c "bash /opt/hd/verify.sh > /tmp/v5.txt 2>&1; grep '^SUMMARY' /tmp/v5.txt; grep -cE '^  FAIL' /tmp/v5.txt"
```

Expected: `SUMMARY: PASS=47 FAIL=0 SKIP=4`

- [ ] **Step 6: 与上一轮基线逐条比对**

```powershell
docker exec hd-node1 bash -lc "grep -E '^(  (PASS|FAIL|SKIP))' /tmp/v5.txt | sed -E 's/\(.*\)//' > /tmp/base-new.txt; grep -E '^(  (PASS|FAIL|SKIP))' /tmp/m2.txt | sed -E 's/\(.*\)//' > /tmp/base-old.txt; diff /tmp/base-old.txt /tmp/base-new.txt && echo 'IDENTICAL'"
```

Expected: `IDENTICAL`

> ⚠️ **如果 base 矩阵的 SKIP 数变了**（灌了元数据 ⇒ 原本 SKIP 的判据可能变成 PASS），
> **必须逐条解释差异**，不能当成「退化」。上一轮的基线是 `47 PASS / 0 FAIL / 4 SKIP`；
> `SKIP` 变少、`PASS` 变多 ⇒ 是**预期内的**（元数据到位了）。

- [ ] **Step 7: 清理种子（可选）**

```powershell
docker exec hd-node1 bash /opt/hd/seed-hd-model-metadata.sh --clean
```

> ⚠️ **建议保留种子** —— 删了的话 A2 又变回 SKIP，下一轮又要重灌。
> 如果要删，**先确认 base 矩阵的数字已经记录**。

- [ ] **Step 8: 最终提交**

```powershell
git -C "D:\work\rediscluterproject" status --porcelain
git -C "D:\work\rediscluterproject" log --oneline -8
```

Expected: 工作区干净；本轮的提交都在。

---

## 附:本轮**不做**的事（及理由）

| 不做 | 理由 |
|---|---|
| 改树 A 的 Java 源码 | 上轮已经加好集群分支（实测 `isCluster` 分支 6/4/1/1 处俱在）。本轮只补数据 + 补判据 |
| 改 `hd-cluster-app-test.sh` | 它是**纯集群**判据。本轮要单机 vs 集群对比 ⇒ 独立脚本更清楚，且不动已通过的脚本 |
| 覆盖 C/D/E/F 四处 | 需要 SVG 文件 / websocket 订阅（图形侧数据准备）⇒ 不是「集群分支对不对」的问题 |
| 覆盖 B（`RTListener`） | 用户已定最小集（只做 3 个类型） |
| 造 `model_datatype` / `model_source` / `base_user` | 它们**已经够了**（19 + 2 + 2 行）⇒ 一行不动 |
| 用产品自带的 XML 导入通道 | 要 `base_modelversion` 有行（现在 0 行）且匹配 `modelfile_path` ⇒ 比灌 27 行麻烦得多 |
| 碰 `sac` / `cmt` / `hds` | 第三方只读域，与本轮无关（见 D10 的新定性） |

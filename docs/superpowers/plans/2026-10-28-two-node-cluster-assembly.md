# 两台机器 6 实例 Redis 集群：显式主从装配 — 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让现有的 `cluster-config.sh` 能把两台机器上的 6 个 Redis 实例装配成「主从映射显式指定、副本与 master 异机」的集群，并在本地 Docker 中用会真的失败的断言验证它。

**Architecture:** 新增纯函数库 `lib/topology.sh` 负责算 master 集合与副本映射；`cluster-config.sh` 第 9 步从「单条 `redis-cli --cluster create --cluster-replicas 1`」改成两阶段（先用 `--cluster-replicas 0` 建主，再逐个 `--cluster add-node --cluster-slave` 加副本）；新增配置键 `cluster_require_full_coverage` 贯通到 `redis.conf`；Docker E2E 增加 A1–A6 六条断言。

**Tech Stack:** bash 4.0+、bats 1.2.1、Redis 8（官方 `redis:8` 镜像，redis-cli 8.10.2）、Docker、systemd（容器内）

> **执行后的补注（2026-10-28）** —— 计划里以下几处与实际执行不同，以实际为准：
>
> 1. **Task 1 的两条测试写法有误**：bats 1.2.1 的 `run` 是 `output="$("$@" 2>&1)"`
>    （命令替换 = 子 shell），函数里设的全局变量随子 shell 消失，所以
>    `run topology_plan ...` 之后断言 `$TOPO_ERROR` 会报 unbound variable。
>    实际改成直接调用 + `|| rc=$?`。
> 2. **Task 1 的 Step 5 预测不准**：只把 `gi` 固定成 0 时，第 5 条用例仍然绿
>    （`TOPO_SURVIVES` 在两种布局下都是 `no,yes`）。实际补了「前提」断言
>    （第 1 台 2 个 master、第 2 台 1 个），才让它变红。
> 3. **Task 6 多了一条 A0**（实际映射 == 计划映射）和一条反空转守卫（A6 的
>    「被拒 > 0」），单靠 A1/A2 抓不住「退回旧的单条 create」。
> 4. **Task 7 是 5 个探针脚本**，不是 4 个（另有 `probe-final.sh`）。
> 5. **Task 5 额外改了 `--dry-run`**：原本第 2 步就退出，看不到拓扑；现在纯计算
>    的拓扑规划提前到 dry-run 之前，正式运行只在第 9 步打印一次（避免重复）。
> 6. **`check-bash-compat.sh` 从容器里跑**要设 `BASH_COMPAT_HOST_REPO`。

---

## 0. 执行环境（必读）

**宿主机没有可用的 bash**（`bash.exe` 是坏的 WSL shim），所有 bash 命令必须走容器：

```powershell
$wt="D:\work\rediscluterproject"
docker run --rm --user 1000:1000 -v "${wt}:/repo" -w /repo rc-control:bats bash -c "bats tests/lib/topology.bats"
```

- **必须用 `--user 1000:1000`**（非特权）。整套 bats 开了 `set -u`，以 root 跑会掩盖以非特权用户跑才暴露的问题（第六轮就有一条测试因此在本地绿、在 CI 红）。
- `rc-control:bats` = Ubuntu 22.04 + **bats 1.2.1** + sshpass + redis-tools。
- **改动前先跑基线**：`find tests -name '*.bats' -print0 | xargs -0 bats` → 期望 **163 通过 / 0 失败**（本计划写完时的实测值）。
- E2E 需要 `rc-e2e-runner:local`（带静态 docker CLI）+ `rc-e2e-node:local` / `rc-e2e-control:local`（脚本会自己 build）。
- 写文件**必须用编辑工具**，不要用 PowerShell 的 `Out-File` / `Set-Content` / `echo >>`（会引入 BOM 或 CRLF，bash 立刻挂）。
- 推送到 GitHub 走 SSH（PAT 没有 `workflow` scope）：
  ```powershell
  $env:GIT_SSH="C:\Windows\System32\OpenSSH\ssh.exe"
  git -c remote.origin.pushurl=git@github.com:leiming-cai/redis-cluster-install.git push origin main
  ```

**不要改的东西**：`install.sh`、`add-node.sh`、`status.sh`、`uninstall.sh`、`lib/ssh.sh`（密码登录已支持，不动）。

---

## 1. 文件结构

| 文件 | 职责 | 本轮动作 |
|---|---|---|
| `lib/topology.sh` | **纯函数**：算 master 集合、副本映射、不变式自检、故障存活判定。不碰网络/文件系统/环境变量 | **新建** |
| `tests/lib/topology.bats` | 上面那个函数的单测 | **新建** |
| `lib/conf.sh` | 解析 `cluster.conf` | 加 `cluster_require_full_coverage` 键 |
| `lib/config_gen.sh` | 渲染 `redis.conf` | 渲染函数加一个参数 |
| `config/redis.conf.template` | `redis.conf` 模板 | 加 `%REQUIRE_FULL_COVERAGE%` |
| `tests/fixtures/cluster-config.redis.conf.template` | 渲染测试用的小 fixture | 加同一行 |
| `lib/cluster.sh` | 解析/检查集群状态、拼 redis-cli 命令 | 加 `build_add_replica_command`、`cluster_nodes_index`、`cluster_role_of`、`cluster_replica_master_of`、`cluster_exists`；`build_create_command` 参数化 |
| `cluster-config.sh` | 主流程（9 步） | 第 9 步改两阶段 + 幂等 + 打印拓扑 |
| `scripts/e2e-cluster-config.sh` | Docker E2E | 加 A1–A6 + 重建集群的 helper |
| `tests/probes/*.sh` | spec §3 里那些实测的探针脚本 | **新建**（让事实可复现） |
| `cluster.conf.example` / `README.md` / `docs/USAGE.md` / `docs/HANDOFF.md` | 文档 | 见 Task 8 |

---

### Task 1: `lib/topology.sh` —— 主从映射算法

**Files:**
- Create: `lib/topology.sh`
- Test: `tests/lib/topology.bats`

这是整个方案的核心：**主从映射必须显式算出来**，因为 `redis-cli --cluster create --cluster-replicas 1` 的自动分配实测会把 3 个 master 全塞到一台机器上（spec §3.3）。

- [ ] **Step 1: 写失败的测试**

创建 `tests/lib/topology.bats`：

```bats
load '../setup'
load_lib common
load_lib topology

# The layout algorithm is a pure function, so every rule in the spec can be
# pinned here without a cluster, a network or a container.
#
# The reference layout is the one this project ships: 6 instances, 3 on each
# of 2 hosts.
#
# Every TOPO_* array is 1-BASED, the same convention CONF_NODE_* uses.
REF="10.0.0.1:6379,6380,6381 10.0.0.2:6382,6383,6384"

@test "topology_plan selects the masters round-robin over the node groups" {
    topology_plan "$REF"
    [ "$TOPO_MASTER_COUNT" -eq 3 ]
    [ "${TOPO_MASTER[1]}" = "10.0.0.1:6379" ]
    [ "${TOPO_MASTER[2]}" = "10.0.0.2:6382" ]
    [ "${TOPO_MASTER[3]}" = "10.0.0.1:6380" ]
}

@test "topology_plan attaches every replica to a master on ANOTHER host" {
    topology_plan "$REF"
    [ "$TOPO_REPLICA_COUNT" -eq 3 ]
    for (( i = 1; i <= TOPO_REPLICA_COUNT; i++ )); do
        [ "${TOPO_REPLICA[$i]%%:*}" != "${TOPO_REPLICA_MASTER[$i]%%:*}" ]
    done
}

@test "topology_plan gives every master exactly one replica" {
    topology_plan "$REF"
    for (( m = 1; m <= TOPO_MASTER_COUNT; m++ )); do
        n=0
        for (( r = 1; r <= TOPO_REPLICA_COUNT; r++ )); do
            [ "${TOPO_REPLICA_MASTER[$r]}" = "${TOPO_MASTER[$m]}" ] && n=$((n + 1))
        done
        [ "$n" -eq 1 ]
    done
}

@test "topology_plan accounts for every instance exactly once" {
    topology_plan "$REF"
    [ "$TOPO_TOTAL_INSTANCES" -eq 6 ]
    [ $(( TOPO_MASTER_COUNT + TOPO_REPLICA_COUNT )) -eq "$TOPO_TOTAL_INSTANCES" ]
}

@test "topology_plan marks the host holding fewer masters as the survivable one" {
    # 3 masters over 2 hosts: one host holds 2 and the other holds 1.
    # A replica can only be promoted when a majority of the masters is alive,
    # so the host with 1 master is the one whose failure the cluster survives.
    topology_plan "$REF"
    [ "${TOPO_SURVIVES[1]}" = "no" ]
    [ "${TOPO_SURVIVES[2]}" = "yes" ]
}

@test "topology_plan reports no warnings for the reference layout" {
    topology_plan "$REF"
    [ "${#TOPO_WARNINGS[@]}" -eq 0 ]
    [ "$TOPO_UNPROTECTED_COUNT" -eq 0 ]
}

@test "topology_plan warns about a master that cannot get a replica" {
    # 5 instances -> 3 masters but only 2 replicas: one master is
    # geometrically unable to get one. That is a limitation to report, not
    # an algorithm error.
    topology_plan "10.0.0.1:6379,6380,6381 10.0.0.2:6382,6383"
    [ "$TOPO_MASTER_COUNT" -eq 3 ]
    [ "$TOPO_REPLICA_COUNT" -eq 2 ]
    [ "$TOPO_UNPROTECTED_COUNT" -ge 1 ]
    [ "${#TOPO_WARNINGS[@]}" -ge 1 ]
}

@test "topology_plan refuses a node group that is not HOST:PORT" {
    run topology_plan "10.0.0.1"
    [ "$status" -ne 0 ]
    [ -n "$TOPO_ERROR" ]
}

@test "topology_plan refuses a node group with an invalid port" {
    run topology_plan "10.0.0.1:6379,abc"
    [ "$status" -ne 0 ]
    [ -n "$TOPO_ERROR" ]
}

@test "topology_plan refuses an empty group list" {
    run topology_plan ""
    [ "$status" -ne 0 ]
    [ -n "$TOPO_ERROR" ]
}
```

- [ ] **Step 2: 运行测试，确认失败**

```powershell
$wt="D:\work\rediscluterproject"
docker run --rm --user 1000:1000 -v "${wt}:/repo" -w /repo rc-control:bats bash -c "bats tests/lib/topology.bats"
```

预期：全部失败（`lib/topology.sh` 不存在 → `load_lib topology` 报错，bats 报 `setup failed` / 每个用例都红）。

- [ ] **Step 3: 实现 `lib/topology.sh`**

创建 `lib/topology.sh`：

```bash
#!/usr/bin/env bash
# lib/topology.sh — plan the master/replica layout of a Redis cluster.
#
# Pure functions: the input comes from an argument, the output goes to
# globals. Nothing here touches the network, the filesystem or the
# environment, which is what makes the whole layout algorithm unit-testable.
#
# WHY THIS FILE EXISTS
# --------------------
# `redis-cli --cluster create --cluster-replicas 1` picks the roles itself,
# and its pick is NOT spread across hosts. Measured on redis-cli 8.10.2 with
# 6 instances on 2 hosts (docs/superpowers/specs/
# 2026-10-28-two-node-cluster-assembly-design.md, section 3.3):
#
#   node order A,A,A,B,B,B  -> 3 masters on A, 3 replicas on B
#                              -> killing A leaves 0 masters: CLUSTERDOWN
#   node order A,B,A,B,A,B  -> A:2 masters, B:1 master
#                              -> killing A leaves 1 master, fewer than the
#                                 majority a replica needs to be promoted:
#                                 CLUSTERDOWN
#   node order A,B,B,A,B,A  -> A:1 master, B:2 masters
#                              -> killing A leaves 2 masters: the replica is
#                                 promoted and the cluster keeps serving
#
# So the master set has to be chosen first, and every replica has to be
# attached to a master ON ANOTHER HOST, explicitly. That is what this file
# computes.
#
# Source from another script. Do not execute.

# Replicas per master. Fixed at 1, matching lib/conf.sh's CONF_REPLICAS.
TOPOLOGY_REPLICAS=1

# topology_plan GROUPS
#
# GROUPS is a space-separated list of "HOST:PORT,PORT,PORT" entries, one per
# node group, in configuration order:
#
#   topology_plan "10.0.0.1:6379,6380,6381 10.0.0.2:6382,6383,6384"
#
# On success it sets these globals. ALL of the arrays are 1-BASED, the same
# convention lib/conf.sh uses for CONF_NODE_* — a 0-based array next to a
# 1-based one is an off-by-one waiting to happen, and the caller maps group i
# to TOPO_SURVIVES[i] directly.
#
#   TOPO_GROUP_COUNT         number of node groups
#   TOPO_GROUP_HOST[i]       host of group i
#   TOPO_GROUP_LABEL[i]      "host:port,port,port" as it was given
#   TOPO_TOTAL_INSTANCES     instances across all groups
#   TOPO_MASTER_COUNT        number of masters
#   TOPO_MASTER[i]           "host:port" of master i, in SELECTION order
#   TOPO_REPLICA_COUNT       number of replicas
#   TOPO_REPLICA[i]          "host:port" of replica i
#   TOPO_REPLICA_MASTER[i]   "host:port" of the master replica i belongs to
#   TOPO_SURVIVES[i]         "yes" if the cluster keeps serving when group i
#                            dies, "no" otherwise
#   TOPO_UNPROTECTED_COUNT   masters that have no replica at all
#   TOPO_WARNINGS[]          human-readable warnings
#
# Returns 0 when the layout is consistent. Returns 1 when a hard invariant
# is violated — TOPO_ERROR then says which one — and the caller must not
# assemble anything.
topology_plan() {
    local groups="$1"

    TOPO_GROUP_COUNT=0
    # The empty first element makes every array 1-based.
    TOPO_GROUP_HOST=("")
    TOPO_GROUP_LABEL=("")
    TOPO_TOTAL_INSTANCES=0
    TOPO_MASTER_COUNT=0
    TOPO_MASTER=("")
    TOPO_REPLICA_COUNT=0
    TOPO_REPLICA=("")
    TOPO_REPLICA_MASTER=("")
    TOPO_SURVIVES=("")
    TOPO_UNPROTECTED_COUNT=0
    TOPO_WARNINGS=()
    TOPO_ERROR=""

    # --- input ----------------------------------------------------------
    local -a g_host=() g_ports=()
    local item
    for item in $groups; do
        case "$item" in
            *:*) ;;
            *) TOPO_ERROR="node group '$item' is not HOST:PORT[,PORT...]"; return 1 ;;
        esac
        g_host+=("${item%%:*}")
        g_ports+=("${item#*:}")
    done
    local ngroups="${#g_host[@]}"
    if [ "$ngroups" -eq 0 ]; then
        TOPO_ERROR="no node groups given"
        return 1
    fi

    # --- flatten to instances, remembering where each group starts -------
    local -a inst_host=() inst_port=()
    local -a grp_start=()
    local gi p
    for (( gi = 0; gi < ngroups; gi++ )); do
        grp_start+=("${#inst_host[@]}")
        local -a ports=()
        IFS=',' read -r -a ports <<< "${g_ports[$gi]}"
        for p in "${ports[@]+"${ports[@]}"}"; do
            case "$p" in
                ''|*[!0-9]*)
                    TOPO_ERROR="node group $gi has an invalid port '$p'"
                    return 1
                    ;;
            esac
            inst_host+=("${g_host[$gi]}")
            inst_port+=("$p")
        done
    done
    local total="${#inst_host[@]}"
    if [ "$total" -eq 0 ]; then
        TOPO_ERROR="no instances in the given node groups"
        return 1
    fi

    # --- pick the masters: round-robin over the node groups -------------
    # masters = ceil(instances / (1 + replicas))
    local masters=$(( (total + TOPOLOGY_REPLICAS) / (1 + TOPOLOGY_REPLICAS) ))
    local -a is_master=()
    for (( p = 0; p < total; p++ )); do is_master+=(0); done
    local -a cursor=()
    for (( gi = 0; gi < ngroups; gi++ )); do cursor+=(0); done

    # sel keeps the SELECTION order. It is the order the tie-breaks below use
    # ("same candidate count -> the one chosen first"), and it is the order
    # TOPO_MASTER reports — the flat instance order would be a different
    # order, and the two must not be confused.
    local -a sel=()
    local m=0 g=0 guard=0
    while [ "$m" -lt "$masters" ] && [ "$guard" -lt 10000 ]; do
        guard=$((guard + 1))
        gi=$(( g % ngroups ))
        local -a ports=()
        IFS=',' read -r -a ports <<< "${g_ports[$gi]}"
        local c="${cursor[$gi]}"
        if [ "$c" -lt "${#ports[@]}" ]; then
            local idx=$(( grp_start[gi] + c ))
            is_master[$idx]=1
            sel+=("$idx")
            cursor[$gi]=$(( c + 1 ))
            m=$((m + 1))
        fi
        g=$((g + 1))
    done
    if [ "$m" -ne "$masters" ]; then
        TOPO_ERROR="cannot select $masters master(s): the node groups hold only $total instance(s)"
        return 1
    fi
    local nmasters="${#sel[@]}"

    # --- attach the replicas --------------------------------------------
    # assigned[instance] = instance index of the master it belongs to, or -1.
    local -a assigned=()
    for (( p = 0; p < total; p++ )); do assigned+=(-1); done

    # The master with the fewest cross-host candidates goes first: it is the
    # one that would otherwise be left without a replica.
    local -a done_m=()
    for (( p = 0; p < nmasters; p++ )); do done_m+=(0); done
    local round mi k c best bestc pi
    for (( round = 0; round < nmasters; round++ )); do
        best=-1; bestc=-1
        for (( k = 0; k < nmasters; k++ )); do
            [ "${done_m[$k]}" = "1" ] && continue
            mi="${sel[$k]}"
            c=0
            for (( pi = 0; pi < total; pi++ )); do
                [ "${is_master[$pi]}" = "1" ] && continue
                [ "${assigned[$pi]}" != "-1" ] && continue
                [ "${inst_host[$pi]}" != "${inst_host[$mi]}" ] && c=$((c + 1))
            done
            if [ "$bestc" -lt 0 ] || [ "$c" -lt "$bestc" ]; then
                best=$k; bestc=$c
            fi
        done
        [ "$best" -ge 0 ] || break
        done_m[$best]=1
        mi="${sel[$best]}"
        for (( pi = 0; pi < total; pi++ )); do
            [ "${is_master[$pi]}" = "1" ] && continue
            [ "${assigned[$pi]}" != "-1" ] && continue
            [ "${inst_host[$pi]}" != "${inst_host[$mi]}" ] || continue
            assigned[$pi]=$mi
            break
        done
    done

    # Whatever is left becomes an additional replica of the cross-host master
    # that has the fewest replicas so far.
    local mi2 best2 bestc2 c2 pj
    for (( pi = 0; pi < total; pi++ )); do
        [ "${is_master[$pi]}" = "1" ] && continue
        [ "${assigned[$pi]}" = "-1" ] || continue
        best2=-1; bestc2=-1
        for (( k = 0; k < nmasters; k++ )); do
            mi2="${sel[$k]}"
            [ "${inst_host[$mi2]}" != "${inst_host[$pi]}" ] || continue
            c2=0
            for (( pj = 0; pj < total; pj++ )); do
                [ "${assigned[$pj]}" = "$mi2" ] && c2=$((c2 + 1))
            done
            if [ "$bestc2" -lt 0 ] || [ "$c2" -lt "$bestc2" ]; then
                best2=$mi2; bestc2=$c2
            fi
        done
        if [ "$best2" -lt 0 ]; then
            TOPO_ERROR="instance ${inst_host[$pi]}:${inst_port[$pi]} has no master on another host to attach to; the node groups do not span enough hosts"
            return 1
        fi
        assigned[$pi]=$best2
    done

    # --- output ----------------------------------------------------------
    TOPO_GROUP_COUNT=$ngroups
    for (( gi = 0; gi < ngroups; gi++ )); do
        TOPO_GROUP_HOST[$((gi + 1))]="${g_host[$gi]}"
        TOPO_GROUP_LABEL[$((gi + 1))]="${g_host[$gi]}:${g_ports[$gi]}"
    done
    TOPO_TOTAL_INSTANCES=$total
    TOPO_MASTER_COUNT=$masters
    for (( p = 0; p < nmasters; p++ )); do
        mi="${sel[$p]}"
        TOPO_MASTER[$((p + 1))]="${inst_host[$mi]}:${inst_port[$mi]}"
    done
    for (( p = 0; p < total; p++ )); do
        [ "${is_master[$p]}" = "1" ] && continue
        mi="${assigned[$p]}"
        if [ "$mi" -lt 0 ]; then
            TOPO_ERROR="instance ${inst_host[$p]}:${inst_port[$p]} was not attached to any master"
            return 1
        fi
        TOPO_REPLICA[$((TOPO_REPLICA_COUNT + 1))]="${inst_host[$p]}:${inst_port[$p]}"
        TOPO_REPLICA_MASTER[$((TOPO_REPLICA_COUNT + 1))]="${inst_host[$mi]}:${inst_port[$mi]}"
        TOPO_REPLICA_COUNT=$(( TOPO_REPLICA_COUNT + 1 ))
    done

    # --- invariants ------------------------------------------------------
    # I2: the master count is the one the formula gives.
    if [ "${#TOPO_MASTER[@]}" -ne $(( masters + 1 )) ]; then
        TOPO_ERROR="expected $masters master(s), got $(( ${#TOPO_MASTER[@]} - 1 ))"
        return 1
    fi
    # I4: every instance is either a master or an attached replica.
    if [ $(( TOPO_MASTER_COUNT + TOPO_REPLICA_COUNT )) -ne "$total" ]; then
        TOPO_ERROR="master + replica count (${TOPO_MASTER_COUNT}+${TOPO_REPLICA_COUNT}) does not cover the $total instance(s)"
        return 1
    fi
    # I1: no replica shares a host with its master. A host failure would take
    # both down at once, which is exactly what a replica is there to prevent.
    local ri
    for (( ri = 1; ri <= TOPO_REPLICA_COUNT; ri++ )); do
        if [ "${TOPO_REPLICA[$ri]%%:*}" = "${TOPO_REPLICA_MASTER[$ri]%%:*}" ]; then
            TOPO_ERROR="replica ${TOPO_REPLICA[$ri]} would live on the same host as its master ${TOPO_REPLICA_MASTER[$ri]}; a failure of that host would take both down at once"
            return 1
        fi
    done

    # I3: a master without a replica is a WARNING, not an error. With fewer
    # instances than 2 x masters it is geometrically impossible, so this
    # reports a limitation of the layout instead of failing the run.
    TOPO_UNPROTECTED_COUNT=0
    local mc
    for (( mc = 0; mc < nmasters; mc++ )); do
        mi="${sel[$mc]}"
        c=0
        for (( pi = 0; pi < total; pi++ )); do
            [ "${assigned[$pi]}" = "$mi" ] && c=$((c + 1))
        done
        if [ "$c" -eq 0 ]; then
            TOPO_UNPROTECTED_COUNT=$(( TOPO_UNPROTECTED_COUNT + 1 ))
            TOPO_WARNINGS+=("master ${TOPO_MASTER[$((mc + 1))]} has no replica; if it fails, its slots are not covered")
        fi
    done

    # --- would the cluster survive the loss of each group? ---------------
    # A replica can only be promoted when a majority of the masters is alive,
    # so a host holding too many masters cannot be lost without taking the
    # cluster down. Two hosts and three masters ALWAYS leave one host with
    # the majority — that is arithmetic, not a configuration mistake.
    local majority=$(( TOPO_MASTER_COUNT / 2 + 1 ))
    local alive protected
    for (( gi = 0; gi < ngroups; gi++ )); do
        alive=0
        for (( mc = 0; mc < nmasters; mc++ )); do
            mi="${sel[$mc]}"
            [ "${inst_host[$mi]}" = "${g_host[$gi]}" ] && continue
            alive=$((alive + 1))
        done
        protected=1
        for (( mc = 0; mc < nmasters; mc++ )); do
            mi="${sel[$mc]}"
            [ "${inst_host[$mi]}" = "${g_host[$gi]}" ] || continue
            c=0
            for (( pi = 0; pi < total; pi++ )); do
                [ "${assigned[$pi]}" = "$mi" ] && c=$((c + 1))
            done
            [ "$c" -ge 1 ] || protected=0
        done
        if [ "$alive" -ge "$majority" ] && [ "$protected" -eq 1 ]; then
            TOPO_SURVIVES[$((gi + 1))]="yes"
        else
            TOPO_SURVIVES[$((gi + 1))]="no"
        fi
    done

    return 0
}
```

- [ ] **Step 4: 运行测试，确认全绿**

```powershell
docker run --rm --user 1000:1000 -v "${wt}:/repo" -w /repo rc-control:bats bash -c "bats tests/lib/topology.bats"
```

预期：**10 通过 / 0 失败**。

- [ ] **Step 5: 变异检验**（确认这些断言不是空转）

把 `lib/topology.sh` 里的 master 选择改成「全部取第一个节点组」（即把 round-robin 换成 `cursor` 不轮转），确认第 1、5 条用例变红：

```powershell
# 临时把 while 循环里的 gi=$(( g % ngroups )) 改成 gi=0，再跑
docker run --rm --user 1000:1000 -v "${wt}:/repo" -w /repo rc-control:bats bash -c "bats tests/lib/topology.bats"
```

预期：**第 1 条和第 5 条失败**（master 分布变了）。改回来，重新跑，全绿。

- [ ] **Step 6: 提交**

```powershell
git add lib/topology.sh tests/lib/topology.bats
git commit -m "feat(topology): compute the master set and the cross-host replica map"
```

---

### Task 2: `cluster_require_full_coverage` 配置键

**Files:**
- Modify: `lib/conf.sh`（默认值 L246–254、全局键分支 L418–435）
- Test: `tests/lib/conf.bats`

- [ ] **Step 1: 写失败的测试**

在 `tests/lib/conf.bats` 末尾追加：

```bats
@test "parse_conf defaults cluster_require_full_coverage to yes" {
    write_conf <<'EOF'
cluster_password = pw
[node.a]
host  = h1
ports = 6379,6380,6381
[node.b]
host  = h2
ports = 6382,6383,6384
EOF
    parse_conf "$CONF_TMP/cluster.conf"
    [ "$CONF_REQUIRE_FULL_COVERAGE" = "yes" ]
}

@test "parse_conf reads cluster_require_full_coverage" {
    write_conf <<'EOF'
cluster_password = pw
cluster_require_full_coverage = no
[node.a]
host  = h1
ports = 6379,6380,6381
[node.b]
host  = h2
ports = 6382,6383,6384
EOF
    parse_conf "$CONF_TMP/cluster.conf"
    [ "$CONF_REQUIRE_FULL_COVERAGE" = "no" ]
}

@test "parse_conf rejects a cluster_require_full_coverage that is not yes or no" {
    write_conf <<'EOF'
cluster_password = pw
cluster_require_full_coverage = maybe
[node.a]
host  = h1
ports = 6379,6380,6381
[node.b]
host  = h2
ports = 6382,6383,6384
EOF
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
}

@test "parse_conf rejects a duplicate cluster_require_full_coverage" {
    write_conf <<'EOF'
cluster_password = pw
cluster_require_full_coverage = no
cluster_require_full_coverage = yes
[node.a]
host  = h1
ports = 6379,6380,6381
[node.b]
host  = h2
ports = 6382,6383,6384
EOF
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: 运行测试，确认失败**

```powershell
docker run --rm --user 1000:1000 -v "${wt}:/repo" -w /repo rc-control:bats bash -c "bats tests/lib/conf.bats"
```

预期：4 条新用例失败（前 3 条因为变量是空，第 4 条因为键不被识别 → 落到 unknown-keys 分支，不会 die）。

- [ ] **Step 3: 实现**

在 `lib/conf.sh` 的默认��区（`CONF_BIND_ADDR="0.0.0.0"` 那一行后面）加：

```bash
    # cluster-require-full-coverage: yes (default) means a cluster whose slots
    # are not all covered refuses every write. On a two-machine deployment
    # that turns "one master died" into "the whole cluster is down", so the
    # value is configurable. `no` keeps the surviving slots writable.
    CONF_REQUIRE_FULL_COVERAGE="yes"
```

在全局键的 `case` 里（`bind_addr)` 分支之后）加：

```bash
                cluster_require_full_coverage)
                    conf_reject_duplicate "$file" "$lineno" "the top level" "$key" "$seen_coverage_line"
                    seen_coverage_line="$lineno"
                    case "$value" in
                        yes|no) CONF_REQUIRE_FULL_COVERAGE="$value" ;;
                        *) die "$file:$lineno: invalid value for key 'cluster_require_full_coverage': '$value'; expected 'yes' or 'no'" ;;
                    esac
                    ;;
```

并在声明行（`local seen_prefix_line="" seen_password_line="" seen_bind_line=""`）后面加：

```bash
    local seen_coverage_line=""
```

同时把文件头部的 Outputs 注释补一行：

```bash
#   CONF_REDIS_PREFIX CONF_PASSWORD CONF_BIND_ADDR CONF_REPLICAS
#   CONF_REQUIRE_FULL_COVERAGE
```

- [ ] **Step 4: 运行测试，确认全绿**

```powershell
docker run --rm --user 1000:1000 -v "${wt}:/repo" -w /repo rc-control:bats bash -c "bats tests/lib/conf.bats"
```

预期：全部通过。

- [ ] **Step 5: 提交**

```powershell
git add lib/conf.sh tests/lib/conf.bats
git commit -m "feat(conf): make cluster_require_full_coverage configurable"
```

---

### Task 3: 把新键渲染进 `redis.conf`

**Files:**
- Modify: `config/redis.conf.template`、`lib/config_gen.sh`
- Modify: `tests/fixtures/cluster-config.redis.conf.template`
- Test: `tests/cluster_config_render.bats`

- [ ] **Step 1: 写失败的测试**

在 `tests/cluster_config_render.bats` 末尾追加：

```bats
@test "rendered redis.conf carries the configured cluster-require-full-coverage" {
    out="$(render_redis_conf "$FIXTURE_CONF" 6379 "$PASS" "node-6379" "0.0.0.0" "$PREFIX" "no")"
    [[ "$out" == *"cluster-require-full-coverage no"* ]]
    [[ "$out" != *"cluster-require-full-coverage yes"* ]]
}

@test "rendered redis.conf defaults cluster-require-full-coverage to yes" {
    out="$(render_redis_conf "$FIXTURE_CONF" 6379 "$PASS" "node-6379" "0.0.0.0" "$PREFIX")"
    [[ "$out" == *"cluster-require-full-coverage yes"* ]]
}

@test "the real redis.conf renders cluster-require-full-coverage without leaving a placeholder" {
    out="$(render_redis_conf "$REAL_CONF" 6380 "$PASS" "node-6380" "0.0.0.0" "$PREFIX" "no")"
    [[ "$out" == *"cluster-require-full-coverage no"* ]]
    [[ "$out" != *"%REQUIRE_FULL_COVERAGE%"* ]]
}
```

- [ ] **Step 2: 运行测试，确认失败**

```powershell
docker run --rm --user 1000:1000 -v "${wt}:/repo" -w /repo rc-control:bats bash -c "bats tests/cluster_config_render.bats"
```

预期：3 条新用例失败（渲染函数还不认第 7 个参数，模板里还没有那一行）。

- [ ] **Step 3: 实现**

`config/redis.conf.template`：把

```
cluster-require-full-coverage yes
```

改成

```
cluster-require-full-coverage %REQUIRE_FULL_COVERAGE%
```

`tests/fixtures/cluster-config.redis.conf.template`：同样改成

```
cluster-require-full-coverage %REQUIRE_FULL_COVERAGE%
```

`lib/config_gen.sh`：改函数头与转义那一段：

```bash
# render_redis_conf TEMPLATE PORT PASSWORD NODE_NAME BIND_ADDR [REDIS_PREFIX] [REQUIRE_FULL_COVERAGE]
# Echoes the rendered config to stdout.
# REDIS_PREFIX (default /opt/software/redis) is expanded into %REDIS_PREFIX%
# and must match the prefix used for the systemd unit and the install step,
# so that cluster-config-file / logfile / ExecStart all agree.
# REQUIRE_FULL_COVERAGE (default yes) is expanded into
# %REQUIRE_FULL_COVERAGE%: `yes` means the cluster refuses every write while
# any slot is uncovered, `no` keeps the surviving slots writable.
# Aborts (exit 1) if the template file is missing.
render_redis_conf() {
    local template="$1"
    local port="$2"
    local password="$3"
    local node_name="$4"
    local bind_addr="$5"
    local redis_prefix="${6:-/opt/software/redis}"
    local require_full_coverage="${7:-yes}"
    ...
    require_full_coverage="$(printf '%s' "$require_full_coverage" | sed -e 's/[&|\\]/\\&/g')"
    ...
        -e "s|%REQUIRE_FULL_COVERAGE%|$require_full_coverage|g" \
```

- [ ] **Step 4: 运行测试，确认全绿**

```powershell
docker run --rm --user 1000:1000 -v "${wt}:/repo" -w /repo rc-control:bats bash -c "bats tests/cluster_config_render.bats tests/lib/conf.bats"
```

预期：全部通过。

- [ ] **Step 5: 提交**

```powershell
git add config/redis.conf.template lib/config_gen.sh tests/fixtures/cluster-config.redis.conf.template tests/cluster_config_render.bats
git commit -m "feat(config): render cluster-require-full-coverage into redis.conf"
```

---

### Task 4: `lib/cluster.sh` —— 拼命令 + 解析集群状态

**Files:**
- Modify: `lib/cluster.sh`
- Test: `tests/lib/cluster.bats`、`tests/validate_libs.sh`

- [ ] **Step 1: 写失败的测试**

在 `tests/lib/cluster.bats` 末尾追加：

```bats
# --- the two-phase assembly -------------------------------------------
#
# `redis-cli --cluster create --cluster-replicas 1` picks the roles itself,
# and its pick is not spread across hosts. So the cluster is built in two
# phases: create the masters with 0 replicas, then attach each replica with
# `--cluster add-node --cluster-slave`.

@test "build_create_command accepts an explicit replica count" {
    out=$(build_create_command "secret" 0 "10.0.0.1:6379" "10.0.0.2:6382")
    [[ "$out" == *"--cluster-replicas"* ]]
    [[ "$out" == *$'--cluster-replicas\n0'* ]]
}

@test "build_create_command still defaults to one replica" {
    out=$(build_create_command "secret" "10.0.0.1:6379")
    [[ "$out" == *$'--cluster-replicas\n1'* ]]
}

@test "build_add_replica_command names the new node, its master and --cluster-slave" {
    out=$(build_add_replica_command "secret" "10.0.0.2:6383" "10.0.0.1:6379")
    [[ "$out" == *"redis-cli"* ]]
    [[ "$out" == *"--cluster"* ]]
    [[ "$out" == *"add-node"* ]]
    [[ "$out" == *"10.0.0.2:6383"* ]]
    [[ "$out" == *"10.0.0.1:6379"* ]]
    [[ "$out" == *"--cluster-slave"* ]]
    [[ "$out" == *$'-a\nsecret'* ]]
}

@test "build_eval_argv quotes every argument so eval cannot be tricked by it" {
    # The password is arbitrary user input: lib/conf.sh only requires it to be
    # non-empty. An unquoted eval would let a password containing a quote or
    # a semicolon run as a command.
    out=$(printf '%s\n' "redis-cli" "-a" "pw'; rm -rf /;'" | build_eval_argv)
    [ "$out" = "'redis-cli' '-a' 'pw'\''; rm -rf /;'\'''" ]
}

@test "build_eval_argv round-trips an argument that contains a single quote" {
    out=$(printf '%s\n' "a'b" | build_eval_argv)
    eval "set -- $out"
    [ "$1" = "a'b" ]
}

# --- reading the cluster's current roles -------------------------------
#
# `redis-cli cluster nodes` prints:
#   <id> <ip:port@bus-port[,hostname]> <flags> <master-id> ...
# A master carries the master id all zeroes; a replica carries its master's id.

NODES=$'421018a0575212623c289749ed20e83ddecf65c1 10.0.0.1:6379@16379 myself,master - 0 0 1 connected 0-5460\n32b1facc82951483e09626c50c68e8a9ed72e5f7 10.0.0.2:6383@16379 slave 421018a0575212623c289749ed20e83ddecf65c1 0 0 2 connected'

@test "cluster_nodes_index reports the role and the master of every node" {
    out=$(cluster_nodes_index <<<"$NODES")
    [[ "$out" == *"10.0.0.1:6379 master"* ]]
    [[ "$out" == *"10.0.0.2:6383 replica 421018a0575212623c289749ed20e83ddecf65c1"* ]]
}

@test "cluster_role_of finds the role of an instance" {
    [ "$(cluster_role_of "$NODES" 10.0.0.1 6379)" = "master" ]
    [ "$(cluster_role_of "$NODES" 10.0.0.2 6383)" = "replica" ]
}

@test "cluster_role_of reports none for an instance that is not a member" {
    [ "$(cluster_role_of "$NODES" 10.0.0.3 6385)" = "none" ]
}

@test "cluster_replica_master_of resolves the master address of a replica" {
    [ "$(cluster_replica_master_of "$NODES" 10.0.0.2 6383)" = "10.0.0.1:6379" ]
}

@test "cluster_exists is false for an instance that has not joined a cluster" {
    run cluster_exists <<<"cluster_state:fail
cluster_slots_assigned:0
cluster_known_nodes:1"
    [ "$status" -ne 0 ]
}

@test "cluster_exists is true once the cluster has slots assigned" {
    run cluster_exists <<<"cluster_state:ok
cluster_slots_assigned:16384
cluster_known_nodes:6"
    [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: 运行测试，确认失败**

```powershell
docker run --rm --user 1000:1000 -v "${wt}:/repo" -w /repo rc-control:bats bash -c "bats tests/lib/cluster.bats"
```

预期：新增的 11 条失败（`build_add_replica_command` / `build_eval_argv` / `cluster_nodes_index` / `cluster_role_of` / `cluster_replica_master_of` / `cluster_exists` 都还不存在）。

- [ ] **Step 3: 实现**

在 `lib/cluster.sh` 里替换 `build_create_command`，并追加新函数：

```bash
# build_create_command PASSWORD [REPLICAS] NODE...
# Echoes a fully-formed `redis-cli --cluster create ...` argv list (one arg per
# line). Caller is responsible for eval or backgrounded exec.
#
# REPLICAS is optional and defaults to 1. A node address always contains a
# ':', so a bare integer as the second argument can only be the replica
# count. Pass 0 to create the masters only: the replicas are then attached
# one by one with --cluster add-node --cluster-slave, which is the only way
# to control WHICH master each replica follows.
build_create_command() {
    local pass="$1"
    shift
    local replicas=1
    if [ "$#" -gt 0 ]; then
        case "$1" in
            ''|*[!0-9]*) ;;
            *) replicas="$1"; shift ;;
        esac
    fi
    printf 'redis-cli\n--cluster\ncreate\n'
    for arg in "$@"; do
        printf '%s\n' "$arg"
    done
    printf -- '--cluster-replicas\n%s\n--cluster-yes\n-a\n%s\n' "$replicas" "$pass"
}

# build_add_replica_command PASSWORD NEW_NODE MASTER_NODE
# Echoes a `redis-cli --cluster add-node NEW MASTER --cluster-slave` argv
# list (one arg per line). Naming the master explicitly is what makes the
# replica map deterministic; left to itself redis-cli picks one.
build_add_replica_command() {
    local pass="$1" new_node="$2" master_node="$3"
    printf 'redis-cli\n--cluster\nadd-node\n%s\n%s\n--cluster-slave\n-a\n%s\n' \
        "$new_node" "$master_node" "$pass"
}

# build_eval_argv
# Reads one argument per line on stdin and echoes a single shell-quoted
# string, safe to `eval`. Every argument is wrapped in single quotes and any
# single quote inside it is closed, escaped and reopened, so a password
# holding ' ; $(...) or a backtick stays one argument instead of becoming a
# command.
build_eval_argv() {
    local line first=1 quoted
    while IFS= read -r line; do
        quoted="$(printf '%s' "$line" | sed "s/'/'\\\\''/g")"
        if [ "$first" = "1" ]; then
            printf "'%s'" "$quoted"
            first=0
        else
            printf " '%s'" "$quoted"
        fi
    done
}

# cluster_nodes_index
# Reads `redis-cli cluster nodes` on stdin and emits, for every node:
#   <node-id> <host:port> <master|replica> <master-node-id>
# The bus port and the optional hostname are stripped from the address, and
# the master's own id is kept so a replica can be matched to it.
cluster_nodes_index() {
    awk '
        NF >= 4 {
            addr = $2
            sub(/@.*$/, "", addr)
            role = ($3 ~ /master/) ? "master" : "replica"
            printf "%s %s %s %s\n", $1, addr, role, $4
        }
    '
}

# cluster_role_of NODES_TEXT HOST PORT
# Echoes "master", "replica" or "none" (not a member of the cluster).
cluster_role_of() {
    local nodes="$1" host="$2" port="$3"
    printf '%s\n' "$nodes" | cluster_nodes_index | awk -v want="$host:$port" '
        $2 == want { print $3; found = 1; exit }
        END { if (!found) print "none" }
    '
}

# cluster_replica_master_of NODES_TEXT HOST PORT
# Echoes the "host:port" of the master a replica follows, or nothing when the
# node is not a replica.
cluster_replica_master_of() {
    local nodes="$1" host="$2" port="$3"
    printf '%s\n' "$nodes" | cluster_nodes_index | awk -v want="$host:$port" '
        { addr[$1] = $2; role[$1] = $3; mid[$1] = $4 }
        END {
            for (id in addr) {
                if (role[id] == "replica" && addr[id] == want && (mid[id] in addr)) {
                    print addr[mid[id]]
                    exit
                }
            }
        }
    '
}

# cluster_exists
# Reads `redis-cli cluster info` on stdin. Returns 0 when the instance has
# already joined a cluster (more than one known node, or any slot assigned)
# and 1 when it is still a lone instance.
cluster_exists() {
    local info known slots
    info=$(cat)
    known=$(printf '%s\n' "$info" | cluster_known_nodes)
    slots=$(printf '%s\n' "$info" | grep -E '^cluster_slots_assigned:' | awk -F: '{print $2}' | tr -d '[:space:]')
    [ "${known:-1}" -gt 1 ] || [ "${slots:-0}" -gt 0 ]
}
```

- [ ] **Step 4: 同步 `tests/validate_libs.sh`**

那里有一条断言写死了 `--cluster-replicas 1`（第 181–182 行）。`build_create_command` 的默认行为没变，所以**那条断言仍然成立**，不用改。但要给它加一条参数化的断言，追加在第 187 行之后：

```bash
out=$(build_create_command "mypass" 0 "127.0.0.1:6379")
assert_contains "build_create_command honours an explicit replica count" "--cluster-replicas
0" "$out"

out=$(build_add_replica_command "mypass" "127.0.0.1:6383" "127.0.0.1:6379")
assert_contains "build_add_replica_command names the new node" "127.0.0.1:6383" "$out"
assert_contains "build_add_replica_command names the master" "127.0.0.1:6379" "$out"
assert_contains "build_add_replica_command asks for a slave" "--cluster-slave" "$out"
```

- [ ] **Step 5: 运行测试，确认全绿**

```powershell
docker run --rm --user 1000:1000 -v "${wt}:/repo" -w /repo rc-control:bats bash -c "bats tests/lib/cluster.bats"
docker run --rm --user 1000:1000 -v "${wt}:/repo" -w /repo rc-control:bats bash -c "bash tests/validate_libs.sh"
```

预期：bats 全绿；`validate_libs.sh` → `PASS` 增加、`FAIL=0`。

- [ ] **Step 6: 提交**

```powershell
git add lib/cluster.sh tests/lib/cluster.bats tests/validate_libs.sh
git commit -m "feat(cluster): build the add-replica command and read the cluster's roles"
```

---

### Task 5: `cluster-config.sh` 第 9 步 —— 两阶段装配

**Files:**
- Modify: `cluster-config.sh`（第 573–649 行）
- Modify: `cluster-config.sh`（在 `cluster_info_from` 后面加 `cluster_nodes_from`）

- [ ] **Step 1: 写失败的测试**

`tests/cluster_config.bats` 是文本级测试（比脚本里有没有某段逻辑）。追加：

```bats
@test "cluster-config.sh assembles the cluster in two phases" {
    run cat "$REPO_ROOT/cluster-config.sh"
    [ "$status" -eq 0 ]
    # The masters are created on their own ...
    [[ "$output" == *"--cluster-replicas 0"* ]]
    # ... and the replicas are attached one by one.
    [[ "$output" == *"--cluster-slave"* ]]
    # The old single-command form must be gone.
    [[ "$output" != *"--cluster-replicas 1"* ]]
}

@test "cluster-config.sh sources the topology planner" {
    run grep -c 'lib/topology.sh' "$REPO_ROOT/cluster-config.sh"
    [ "$output" -ge 1 ]
}

@test "cluster-config.sh prints which host the cluster cannot survive losing" {
    run cat "$REPO_ROOT/cluster-config.sh"
    [[ "$output" == *"STOPS serving"* ]]
    [[ "$output" == *"keeps serving"* ]]
}
```

- [ ] **Step 2: 运行测试，确认失败**

```powershell
docker run --rm --user 1000:1000 -v "${wt}:/repo" -w /repo rc-control:bats bash -c "bats tests/cluster_config.bats"
```

预期：3 条新用例失败。

- [ ] **Step 3: 实现**

**(3a) 加 source。** 在 `cluster-config.sh` 顶部 `. "$REPO_ROOT/lib/cluster.sh"` 之后加：

```bash
# shellcheck source=lib/topology.sh
. "$REPO_ROOT/lib/topology.sh"
```

**(3b) 加 `cluster_nodes_from`。** 在 `cluster_info_from` 函数之后加：

```bash
# cluster_nodes_from USER PASS HOST SSH_PORT REDIS_PORT
# Echoes `redis-cli cluster nodes` for one instance. The cluster password
# travels as a positional argument, never interpolated into the remote
# command string — lib/conf.sh accepts any non-empty cluster_password, so a
# password holding a quote, ';' or '$(...)' would be executed by the remote
# shell.
cluster_nodes_from() {
    local user="$1" pass="$2" host="$3" ssh_port="$4" redis_port="$5"
    ssh_run "$user" "$pass" "$host" "$ssh_port" \
        bash -s "$CONF_PASSWORD" "$redis_port" "$REDIS_BIN" 2>/dev/null <<'CLNODES'
set -u
CLUSTER_PASS="$1"
PORT="$2"
REDIS_BIN="$3"
"$REDIS_BIN/redis-cli" -a "$CLUSTER_PASS" -p "$PORT" cluster nodes
CLNODES
}
```

**(3c) 替换第 9 步。** 把 `cluster-config.sh` 从 `# === Create cluster ===` 到 `[ "$health_ok" -eq 1 ] || die "cluster health check failed...` 之间的全部内容，替换成：

```bash
# === Create cluster ===
#
# The master set and the replica attachment are computed by lib/topology.sh,
# a pure function. `redis-cli --cluster create --cluster-replicas 1` picks
# the roles itself and its pick is NOT spread across hosts: with 6 instances
# on 2 hosts it put all 3 masters on one of them, and the failure of that
# host then left the cluster with no quorum at all (measured — see
# docs/superpowers/specs/2026-10-28-two-node-cluster-assembly-design.md,
# section 3.3).
#
# So the cluster is assembled in two phases:
#   9a  create the MASTERS only  (--cluster-replicas 0)
#   9b  attach each replica to its master (--cluster add-node --cluster-slave)
#
# Every address travels as a positional argument — never interpolated into a
# command string.

TOPO_GROUPS=""
for (( i = 1; i <= CONF_NODE_COUNT; i++ )); do
    [ -n "$TOPO_GROUPS" ] && TOPO_GROUPS="$TOPO_GROUPS "
    TOPO_GROUPS="${TOPO_GROUPS}${CONF_NODE_HOST[$i]}:${CONF_NODE_PORTS[$i]}"
done

if ! topology_plan "$TOPO_GROUPS"; then
    die "cannot plan the cluster topology: $TOPO_ERROR"
fi

log_info "[9/9] Cluster topology:"
for (( i = 1; i <= TOPO_MASTER_COUNT; i++ )); do
    log_info "  master  ${TOPO_MASTER[$i]}"
done
for (( i = 1; i <= TOPO_REPLICA_COUNT; i++ )); do
    log_info "  replica ${TOPO_REPLICA[$i]} -> master ${TOPO_REPLICA_MASTER[$i]}"
done
for (( i = 1; i <= CONF_NODE_COUNT; i++ )); do
    if [ "${TOPO_SURVIVES[$i]}" = "yes" ]; then
        log_info "  host ${CONF_NODE_HOST[$i]}: if it fails the cluster keeps serving (degraded)"
    else
        log_warn "  host ${CONF_NODE_HOST[$i]}: if it fails the cluster STOPS serving (it holds too many masters for a quorum to survive)"
    fi
done
for w in "${TOPO_WARNINGS[@]+"${TOPO_WARNINGS[@]}"}"; do
    log_warn "  $w"
done

# The TOPO_* arrays are 1-based, so "${TOPO_MASTER[@]}" would hand the
# create command an empty first argument. Copy the masters into a plain
# 0-based list first.
CREATE_MASTERS=()
for (( i = 1; i <= TOPO_MASTER_COUNT; i++ )); do
    CREATE_MASTERS+=("${TOPO_MASTER[$i]}")
done

# Query the first node's first port to decide whether to create.
FIRST_HOST="${CRED_HOST[1]}"
FIRST_SSH_PORT="${CRED_SSH_PORT[1]}"
FIRST_USER="${CRED_USER[1]}"
FIRST_PASS="${CRED_PASS[1]}"
_first_ports=()
IFS=',' read -r -a _first_ports <<< "${CONF_NODE_PORTS[1]}"
FIRST_REDIS_PORT="${_first_ports[0]}"

cluster_info="$(cluster_info_from "$FIRST_USER" "$FIRST_PASS" "$FIRST_HOST" "$FIRST_SSH_PORT" "$FIRST_REDIS_PORT" || true)"

if printf '%s\n' "$cluster_info" | is_cluster_healthy "$CONF_TOTAL_INSTANCES"; then
    log_ok "Cluster already healthy — skipping create"
else
    # --- 9a: the masters ---
    if printf '%s\n' "$cluster_info" | cluster_exists; then
        # A cluster already exists but is not healthy: either a previous run
        # was interrupted, or the roles on the nodes are not the ones this
        # plan asks for. Both are checked rather than assumed.
        cluster_nodes="$(cluster_nodes_from "$FIRST_USER" "$FIRST_PASS" "$FIRST_HOST" "$FIRST_SSH_PORT" "$FIRST_REDIS_PORT" || true)"
        for (( i = 1; i <= TOPO_MASTER_COUNT; i++ )); do
            m_node="${TOPO_MASTER[$i]}"
            m_host="${m_node%%:*}"
            m_port="${m_node##*:}"
            m_role="$(cluster_role_of "$cluster_nodes" "$m_host" "$m_port")"
            if [ "$m_role" != "master" ]; then
                die "$m_node is part of the cluster but its role is '$m_role', not 'master'.
   The plan says it should be a master. Fix the cluster by hand (or remove the
   instance from the cluster) before running this again."
            fi
        done
        log_info "  the $TOPO_MASTER_COUNT master(s) are already in place — skipping create"
    else
        log_info "  creating $TOPO_MASTER_COUNT master(s)..."
        if command -v redis-cli >/dev/null 2>&1; then
            # The command is built by lib/cluster.sh, so the unit tests cover
            # it, and build_eval_argv single-quotes every argument before
            # the eval: the cluster password is arbitrary user input.
            eval "$(build_create_command "$CONF_PASSWORD" 0 "${CREATE_MASTERS[@]}" | build_eval_argv)" \
                || die "redis-cli --cluster create failed"
        else
            log_warn "redis-cli not on control machine; running create from $FIRST_HOST"
            # Node addresses arrive as positional args too, so the remote
            # script never re-parses a string this process built by
            # concatenation.
            rc=0
            ssh_run "$FIRST_USER" "$FIRST_PASS" "$FIRST_HOST" "$FIRST_SSH_PORT" \
                bash -s "$CONF_PASSWORD" "$REDIS_BIN" "${CREATE_MASTERS[@]}" <<'CREATE' || rc=$?
set -u
CLUSTER_PASS="$1"
REDIS_BIN="$2"
shift 2
exec "$REDIS_BIN/redis-cli" --cluster create "$@" \
    --cluster-replicas 0 --cluster-yes -a "$CLUSTER_PASS"
CREATE
            [ "$rc" -eq 0 ] || die "redis-cli --cluster create from $FIRST_HOST failed"
        fi
    fi

    # --- 9b: the replicas ---
    # Re-read the node list: phase 9a changed it, and a previous interrupted
    # run may have attached some of the replicas already.
    cluster_nodes="$(cluster_nodes_from "$FIRST_USER" "$FIRST_PASS" "$FIRST_HOST" "$FIRST_SSH_PORT" "$FIRST_REDIS_PORT" || true)"

    for (( i = 1; i <= TOPO_REPLICA_COUNT; i++ )); do
        new_node="${TOPO_REPLICA[$i]}"
        master_node="${TOPO_REPLICA_MASTER[$i]}"
        new_host="${new_node%%:*}"
        new_port="${new_node##*:}"

        current_role="$(cluster_role_of "$cluster_nodes" "$new_host" "$new_port")"
        if [ "$current_role" = "replica" ]; then
            current_master="$(cluster_replica_master_of "$cluster_nodes" "$new_host" "$new_port")"
            if [ "$current_master" = "$master_node" ]; then
                log_info "  replica $new_node already follows $master_node — skipping"
                continue
            fi
            die "replica $new_node already follows $current_master, but the plan says $master_node.
   Refusing to re-point a replica: detach it from the cluster by hand first."
        fi
        if [ "$current_role" = "master" ]; then
            die "$new_node is already a master in the cluster, but the plan says it should be a
   replica of $master_node. Refusing to demote a master that holds slots."
        fi

        log_info "  attaching replica $new_node to $master_node..."
        if command -v redis-cli >/dev/null 2>&1; then
            eval "$(build_add_replica_command "$CONF_PASSWORD" "$new_node" "$master_node" | build_eval_argv)" \
                || die "redis-cli --cluster add-node failed for $new_node"
        else
            log_warn "redis-cli not on control machine; running add-node from $FIRST_HOST"
            rc=0
            ssh_run "$FIRST_USER" "$FIRST_PASS" "$FIRST_HOST" "$FIRST_SSH_PORT" \
                bash -s "$CONF_PASSWORD" "$REDIS_BIN" "$new_node" "$master_node" <<'ADDREPLICA' || rc=$?
set -u
CLUSTER_PASS="$1"
REDIS_BIN="$2"
NEW_NODE="$3"
MASTER_NODE="$4"
exec "$REDIS_BIN/redis-cli" --cluster add-node "$NEW_NODE" "$MASTER_NODE" \
    --cluster-slave -a "$CLUSTER_PASS"
ADDREPLICA
            [ "$rc" -eq 0 ] || die "redis-cli --cluster add-node from $FIRST_HOST failed for $new_node"
        fi
    done
fi
```

**(3d) 把新配置键传给渲染。** 在 `deploy_configs()` 里，`render_redis_conf` 的调用改成多传一个参数：

```bash
        render_redis_conf "$CONF_TEMPLATE" "$p" "$CONF_PASSWORD" "node-$p" "$CONF_BIND_ADDR" "$REDIS_PREFIX" "$CONF_REQUIRE_FULL_COVERAGE" > "$tmpf" \
```

- [ ] **Step 4: 运行测试，确认全绿**

```powershell
docker run --rm --user 1000:1000 -v "${wt}:/repo" -w /repo rc-control:bats bash -c "bats tests/cluster_config.bats"
docker run --rm --user 1000:1000 -v "${wt}:/repo" -w /repo rc-control:bats bash -c "bash tests/check_syntax.sh; bash tests/validate_libs.sh"
```

预期：bats 全绿；`check_syntax.sh` → `FAIL=0`；`validate_libs.sh` → `FAIL=0`。

**特别注意**：`cluster-config.sh` 里原来的 `BUILD_CREATE_ARGS` 数组已经不再使用，删掉它（留着会让 `shellcheck` 报未使用变量）。

- [ ] **Step 5: 提交**

```powershell
git add cluster-config.sh tests/cluster_config.bats
git commit -m "feat(cluster-config): assemble the cluster as masters plus explicit replicas"
```

---

### Task 6: Docker E2E —— A1–A6 断言

**Files:**
- Modify: `scripts/e2e-cluster-config.sh`

现有的 E2E 已经是 2 节点 × 3 实例（`node.a` = 6379/6380/6381，`node.b` = 6382/6383/6384），正好就是本轮的目标形态，直接扩展。

- [ ] **Step 1: 加重建集群的 helper**

在 `scripts/e2e-cluster-config.sh` 的 `run_config` 函数之后加：

```bash
# reset_cluster — throw the cluster away and build it again from scratch.
#
# The host-failure cases each need a cluster that has never been broken:
# once a master has been killed, the surviving topology no longer matches the
# plan, and the next case would measure the previous case's leftovers.
# Wiping nodes.conf AND the data directory is what makes the instances come
# back as fresh nodes — the AOF in the data dir would otherwise make them
# rejoin the old cluster.
reset_cluster() {
    local logfile="$1"
    log "Resetting the cluster"
    local spec host port
    for spec in "$A_IP:6379" "$A_IP:6380" "$A_IP:6381" \
                "$B_IP:6382" "$B_IP:6383" "$B_IP:6384"; do
        host="${spec%:*}"
        port="${spec##*:}"
        ssh_root "$host" "systemctl stop redis-$port" >/dev/null 2>&1 || true
    done
    sleep 2
    for spec in "$A_IP:6379" "$A_IP:6380" "$A_IP:6381" \
                "$B_IP:6382" "$B_IP:6383" "$B_IP:6384"; do
        host="${spec%:*}"
        port="${spec##*:}"
        ssh_root "$host" "rm -rf $PREFIX/cluster/$port /var/lib/redis/cluster/$port /var/run/redis/cluster/$port" \
            >/dev/null 2>&1 || true
    done
    run_config "$logfile" || fail "rebuilding the cluster failed"
}

# cluster_nodes_index — "id host:port role master-id" per node.
cluster_nodes_index() {
    ssh_root "$A_IP" "$PREFIX/bin/redis-cli -a $PASS --no-auth-warning \
              -h $A_IP -p 6379 cluster nodes" \
        | awk 'NF>=4 { addr=$2; sub(/@.*$/,"",addr); role=($3 ~ /master/)?"master":"replica"; print $1, addr, role, $4 }'
}

# host_of_master_count HOST — how many masters HOST holds.
#
# The separator is space AND colon, so the line
#   "421018a0... 10.0.0.1:6379 master 421018a0..."
# splits into $1=id, $2=host, $3=port, $4=role, $5=master-id. The role is
# therefore $4, NOT $3.
host_of_master_count() {
    cluster_nodes_index | awk -v h="$1" -F'[ :]' '$2==h && $4=="master"' | wc -l
}
```

- [ ] **Step 2: 加 A1–A3（拓扑不变式）**

在 `log "DoD7: idempotent re-run"` 之前插入：

```bash
# --- A1/A2/A3: the topology invariants ---------------------------------
#
# These three are the whole point of the two-phase assembly. `redis-cli
# --cluster create --cluster-replicas 1` used to pick the roles itself, and
# its pick put all 3 masters on ONE host: killing that host then left the
# cluster with no quorum at all (measured).
#
# A3 deliberately recomputes the fragile host here, with its own awk, rather
# than reading the script's own answer: using one implementation to check
# itself proves nothing.

log "A1: every master has at least one replica"
nodes="$(cluster_nodes_index)"
[ -n "$nodes" ] || fail "could not read cluster nodes"
for mid in $(awk '$3=="master" {print $1}' <<< "$nodes"); do
    maddr="$(awk -v id="$mid" '$1==id {print $2}' <<< "$nodes")"
    nrep="$(awk -v id="$mid" '$3=="replica" && $4==id' <<< "$nodes" | wc -l)"
    [ "$nrep" -ge 1 ] || fail "master $maddr has no replica"
    echo "  OK master $maddr has $nrep replica(s)"
done

log "A2: every replica lives on a different host than its master"
bad="$(awk '
    { addr[$1]=$2; role[$1]=$3; mid[$1]=$4 }
    END {
        n = 0
        for (id in addr) {
            if (role[id] == "replica" && (mid[id] in addr)) {
                split(addr[id], a, ":"); split(addr[mid[id]], b, ":")
                if (a[1] == b[1]) {
                    print "replica " addr[id] " is on the same host as its master " addr[mid[id]]
                    n++
                }
            }
        }
        exit (n > 0) ? 1 : 0
    }
' <<< "$nodes")" || fail "a replica shares a host with its master: $bad"
echo "  OK"

log "A3: the script names the host the cluster cannot survive losing"
a_masters="$(host_of_master_count "$A_IP")"
b_masters="$(host_of_master_count "$B_IP")"
if [ "$a_masters" -gt "$b_masters" ]; then
    fragile="$A_IP"; fragile_ports="6379 6380 6381"
    protected="$B_IP"; protected_ports="6382 6383 6384"
elif [ "$b_masters" -gt "$a_masters" ]; then
    fragile="$B_IP"; fragile_ports="6382 6383 6384"
    protected="$A_IP"; protected_ports="6379 6380 6381"
else
    fail "both hosts hold $a_masters master(s); the layout is not the one this test expects"
fi
echo "  fragile host: $fragile ($a_masters / $b_masters masters)"
grep -q "host $fragile: if it fails the cluster STOPS serving" "$WORK/install.log" \
    || fail "cluster-config.sh did not name $fragile as the host the cluster cannot survive losing:
$(grep -i 'if it fails' "$WORK/install.log" || true)"
grep -q "host $protected: if it fails the cluster keeps serving" "$WORK/install.log" \
    || fail "cluster-config.sh did not name $protected as the survivable host"
echo "  OK"
```

- [ ] **Step 3: 加 A5（脆弱侧 → 集群停写）**

在 `log "DoD5: kill a master, expect its replica to be promoted"` 之后、收尾之前插入：

```bash
# --- A5: the fragile host takes the cluster down -------------------------
#
# This asserts a LIMITATION, not a goal: with 3 masters spread over 2 hosts
# one host always holds the majority, and a replica can only be promoted
# when a majority of the masters is alive. So the host holding more masters
# cannot be lost without stopping the cluster.
#
# It is asserted anyway: if a future change made the cluster survive that
# too, this assertion would go red and the limit would have to be
# re-documented. A test that can never fail is not a test.

log "A5: killing the fragile host ($fragile) must stop the cluster"
for p in $fragile_ports; do
    ssh_root "$fragile" "systemctl stop redis-$p" >/dev/null 2>&1 || true
done
sleep 25
survivor_ip="$protected"
survivor_port="${protected_ports%% *}"
out="$(ssh_root "$survivor_ip" "$PREFIX/bin/redis-cli -a $PASS --no-auth-warning \
          -h $survivor_ip -p $survivor_port -c SET e2e:fragile v" 2>&1 | tr -d '\r')"
case "$out" in
    *CLUSTERDOWN*) echo "  OK: the cluster refuses writes ($out)" ;;
    *) fail "the cluster still accepted writes after the fragile host died: '$out'" ;;
esac
```

- [ ] **Step 4: 加 A4（受保护侧 → 集群仍可用）与 A6（`require_full_coverage=no`）**

在 A5 之后加：

```bash
# --- A4: the protected host leaves the cluster serving -------------------
#
# A fresh cluster is needed: A5 killed a host, so the surviving topology is
# no longer the one the plan describes.

log "A4: killing the protected host ($protected) must leave the cluster serving"
reset_cluster "$WORK/rebuild-a4.log" || fail "rebuilding the cluster for A4 failed"
nodes="$(cluster_nodes_index)"
a_masters="$(host_of_master_count "$A_IP")"
b_masters="$(host_of_master_count "$B_IP")"
if [ "$a_masters" -gt "$b_masters" ]; then
    fragile="$A_IP"; fragile_ports="6379 6380 6381"
    protected="$B_IP"; protected_ports="6382 6383 6384"
else
    fragile="$B_IP"; fragile_ports="6382 6383 6384"
    protected="$A_IP"; protected_ports="6379 6380 6381"
fi
for p in $protected_ports; do
    ssh_root "$protected" "systemctl stop redis-$p" >/dev/null 2>&1 || true
done
# The surviving host is the fragile one — query ITS first port, not a fixed
# 6379: 6379 lives on whichever host was the fragile one, and that host may
# be the one that just died.
fragile_first_port="${fragile_ports%% *}"
promoted=0
for _ in $(seq 1 12); do
    sleep 5
    state="$(ssh_root "$fragile" "$PREFIX/bin/redis-cli -a $PASS --no-auth-warning \
             -h $fragile -p $fragile_first_port cluster info" 2>&1 | grep '^cluster_state:' | cut -d: -f2 | tr -d '[:space:]')"
    if [ "$state" = "ok" ]; then promoted=1; break; fi
done
[ "$promoted" -eq 1 ] || fail "the cluster did not recover after the protected host died (state=$state)"
out="$(ssh_root "$fragile" "$PREFIX/bin/redis-cli -a $PASS --no-auth-warning \
          -h $fragile -p $fragile_first_port -c SET e2e:protected v" 2>&1 | tr -d '\r')"
[ "$out" = "OK" ] || fail "the cluster refused writes after the protected host died: '$out'"
echo "  OK: the cluster kept serving"

# --- A6: cluster_require_full_coverage=no --------------------------------
#
# With the default (yes) a master failure stops EVERY write, because the
# slots it owned are not covered. With `no` the surviving slots stay
# writable.
#
# The setting has to come from the config file: `CONFIG SET` only changes
# the parameter on the node it runs on, and Redis reads it per node (measured
# on 8.10.2), so a runtime CONFIG SET on one node would prove nothing.

log "A6: cluster_require_full_coverage=no keeps the surviving slots writable"
cat > "$WORK/cluster-nocov.conf" <<CONF
redis_prefix     = $PREFIX
cluster_password = $PASS
bind_addr        = 0.0.0.0
cluster_require_full_coverage = no

[node.a]
host     = $A_IP
ssh_port = 22
ports    = 6379,6380,6381

[node.b]
host     = $B_IP
ssh_port = 22
ports    = 6382,6383,6384
CONF
export CLUSTER_CONF="$(cat "$WORK/cluster-nocov.conf")"
reset_cluster "$WORK/rebuild-a6.log" || fail "rebuilding the cluster for A6 failed"

rendered="$(ssh_root "$A_IP" "grep -h 'cluster-require-full-coverage' /etc/redis/cluster/redis-6379.conf" | tr -d '\r')"
[ "$rendered" = "cluster-require-full-coverage no" ] \
    || fail "the rendered redis.conf does not carry the setting: '$rendered'"

for i in $(seq 1 20); do
    ssh_root "$A_IP" "$PREFIX/bin/redis-cli -a $PASS --no-auth-warning \
        -h $A_IP -p 6379 -c SET e2e:cov:$i v$i" >/dev/null
done
ssh_root "$A_IP" "systemctl stop redis-6379" >/dev/null 2>&1 || true
sleep 25
writable=0
for i in $(seq 1 20); do
    out="$(ssh_root "$A_IP" "$PREFIX/bin/redis-cli -a $PASS --no-auth-warning \
              -h $A_IP -p 6380 -c SET e2e:cov:$i v$i" 2>&1 | tr -d '\r')"
    [ "$out" = "OK" ] && writable=$((writable + 1))
done
[ "$writable" -gt 0 ] \
    || fail "no key could be written after a master died, even with cluster-require-full-coverage=no"
echo "  OK: $writable of 20 keys were still writable"
```

- [ ] **Step 5: 运行 E2E**

```powershell
$wt="D:\work\rediscluterproject"
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock `
  -v "${wt}:/repo" -e E2E_HOST_REPO="${wt}" `
  rc-e2e-runner:local bash /repo/scripts/e2e-cluster-config.sh
```

预期：最后一行 `=== E2E PASSED ===`，退出码 0。A1–A6 全部出现并通过。

**A7 = 现有 DoD1–DoD5、DoD7 全部保持绿。** 它们没有改动，但两阶段装配改变了
主从分配，DoD5（杀一个 master 看副本是否被提升）**依赖副本确实存在且挂在
对的主上** —— 所以 A7 不是「什么都没做」，它是被新装配方式直接影响的。
逐条确认输出里仍然有：

```
DoD1: all 6 instances PING
DoD2/3: cluster check + info
DoD4: cross-machine read/write
DoD7: idempotent re-run
DoD5: kill a master, expect its replica to be promoted
```

**这个 E2E 会跑 3 次集群装配**（初始 + A4 重建 + A6 重建），耗时比原来长，注意别把超时设太短。

- [ ] **Step 6: 变异检验（关键）**

每条新断言都要证明它**真的会失败**。至少做这三条：

```bash
# 变异 1：把 lib/topology.sh 的副本分配改成同机（去掉异机限制）
#   → A2 必须失败
# 变异 2：把 A5 的 cluster-info 查询指向一个已经死掉的端口
#   → A5 必须失败（而不是"因为集群本来就坏了"）
# 变异 3：把 cluster.conf 里的 cluster_require_full_coverage 改成 yes
#   → A6 的 rendered 检查必须失败
```

逐个做完，确认变红，再改回来。**这一步不能跳** —— 仓库里已经有三次「断言一直是绿的，但它从没观测过它该观测的东西」。

- [ ] **Step 7: 提交**

```powershell
git add scripts/e2e-cluster-config.sh
git commit -m "test(e2e): assert the topology invariants and both host-failure outcomes"
```

---

### Task 7: 探针脚本入仓

**Files:**
- Create: `tests/probes/probe-4node.sh`
- Create: `tests/probes/probe-3m1r.sh`
- Create: `tests/probes/probe-order.sh`
- Create: `tests/probes/probe-coverage.sh`

spec §3 的每一条事实都是量出来的，不是推理出来的。把探针脚本放进仓库，那些事实才能被重跑验证 —— 而不是只以文字形式躺在 spec 里。

- [ ] **Step 1: 把探针脚本复制进仓库**

本轮测量用的 4 个探针脚本在会话临时目录里。用编辑工具把它们**逐个**写成
`tests/probes/` 下的文件（不要用 `Copy-Item`：PowerShell 不会改动内容，
但要确认换行是 LF —— `.gitattributes` 已经对 `*.bash` 强制 LF，
这 4 个文件是 `.sh`，新建后要确认 `git diff` 里没有整文件重写）：

| 源文件 | 目标 | 内容 |
|---|---|---|
| `%TEMP%\opencode\probe-4node.sh` | `tests/probes/probe-4node.sh` | 4 节点 + `--cluster-replicas 1` 报错 / `+ 0` 成功 |
| `%TEMP%\opencode\probe-3m1r.sh` | `tests/probes/probe-3m1r.sh` | 3 主 + `add-node --cluster-slave`，杀 master 看提升 |
| `%TEMP%\opencode\probe-order.sh` | `tests/probes/probe-order.sh` | 6 节点两种顺序的整机故障对比 |
| `%TEMP%\opencode\probe-coverage.sh` | `tests/probes/probe-coverage.sh` | `cluster-require-full-coverage` 的 `CONFIG GET`/`CONFIG SET` 与行为 |

每个脚本顶部加一段说明（`probe-4node.sh` 为例）：

```bash
#!/usr/bin/env bash
# probe-4node.sh — what does `redis-cli --cluster create` do with 4 nodes?
#
# Measures (redis-cli 8.10.2, official redis:8 image):
#   A: 4 nodes + --cluster-replicas 1 -> "At least 6 nodes are required.", exit 1
#   B: 4 nodes + --cluster-replicas 0 -> 4 masters, all 16384 slots covered
#
# This is the measurement behind the decision to assemble the cluster in two
# phases. Re-run it with:
#   docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
#     -v "D:/work/rediscluterproject:/repo" -v "<temp>:/v" \
#     rc-e2e-runner:local bash /v/probe-4node.sh
#
# The script cleans up its own containers and network.
```

> `%TEMP%` 里的原脚本在本会话结束时可能消失。**如果已经不在了，照着上表的
> 「内容」列重写** —— 那 4 个脚本的完整输出已经记录在 spec §3 里，
> 照着重写即可复现。

- [ ] **Step 2: 语法检查**

`tests/check_syntax.sh` 的第三段只覆盖 `tests/setup.bash` 和 `tests/helpers/*.sh`。把探针脚本也纳入检查 —— 在 `tests/check_syntax.sh` 的那一行改成：

```bash
for f in tests/setup.bash tests/helpers/*.sh tests/probes/*.sh; do
```

- [ ] **Step 3: 跑一遍确认探针仍然成立**

```powershell
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock `
  -v "${wt}:/repo" -v "C:/Users/蔡雷鸣/AppData/Local/Temp/opencode:/v" `
  rc-e2e-runner:local bash /repo/tests/probes/probe-4node.sh
```

预期：与 spec §3.1 一致（A 报错、B 成功）。

- [ ] **Step 4: 提交**

```powershell
git add tests/probes tests/check_syntax.sh
git commit -m "test(probes): keep the measurements behind the topology decision"
```

---

### Task 8: 文档

**Files:**
- Modify: `cluster.conf.example`
- Modify: `README.md`
- Modify: `docs/USAGE.md`
- Modify: `docs/HANDOFF.md`

- [ ] **Step 1: `cluster.conf.example`**

在 `bind_addr` 那一段之后加：

```
# 槽位全覆盖策略。yes（默认）= 有槽位没被覆盖时，集群拒绝一切写入；
# no = 存活 master 负责的槽位仍然可读写。
#
# 两台机器的部署建议用 no：master 挂掉时，yes 会让整个集群停写，
# no 则只是那一部分槽位不可用。实测（redis 8.10.2）：yes 时 master 挂掉
# 后 SET 返回 CLUSTERDOWN，no 时存活槽位的 SET/GET 正常。
cluster_require_full_coverage = yes
```

在节点段之后加一份两台机器的样例：

```
# ---------------------------------------------------------------------------
# 两台机器 6 实例（每台 3 个）的样例
# ---------------------------------------------------------------------------
#
# 拓扑由脚本按上面的节点组顺序推导，副本会落在**另一台机器**上：
#   master  A:6379  <- replica B:6383
#   master  A:6380  <- replica B:6384
#   master  B:6382  <- replica A:6381
#
# 6 个实例里 3 个是 master，而副本提升需要过半 master 存活，所以**两台机器
# 必然有一台承担 2 个 master** —— 那台挂掉集群就会停写，另一台挂掉集群
# 仍可用（降级）。这是多数派决定的，不是配置能绕过的；要两头都活，至少
# 要 3 台机器。脚本每次运行都会把这两个结论打印出来。

# [node.a]
# host     = <A机IP>
# ssh_port = 22
# ports    = 6379,6380,6381
#
# [node.b]
# host     = <B机IP>
# ssh_port = 22
# ports    = 6382,6383,6384
```

- [ ] **Step 2: `docs/USAGE.md` 新增一节**

在 `docs/USAGE.md` 末尾加「## 两台机器部署 6 实例集群」一节，内容：

````markdown
## 两台机器部署 6 实例集群

### 前置条件

两台机器上都要有：

| 项 | 检查命令 | 期望 |
|---|---|---|
| Redis 二进制 | `ls /opt/software/redis/bin/redis-server /opt/software/redis/bin/redis-cli` | 两个文件都在且可执行 |
| redis 用户 | `id redis` | 有输出 |
| systemd | `systemctl --version` | 有版本号 |
| 两台之间互通 | 机器 A 上 `ping -c1 <B机IP>`、`nc -z <B机IP> 6379` | 通 |

脚本不会替你装 Redis、也不会替你建 redis 用户 —— 这两项必须先做好，
`cluster-config.sh` 的 preflight 会检查并指名报告缺哪一项。

### 第 1 步：写 cluster.conf

```bash
cp cluster.conf.example cluster.conf
```

把两台机器的信息填进去：

```ini
redis_prefix     = /opt/software/redis
cluster_password = <你的集群密码>
bind_addr        = 0.0.0.0
cluster_require_full_coverage = no     # 两台机器建议 no，理由见下

[node.a]
host     = <A机IP>
ssh_port = 22
ports    = 6379,6380,6381

[node.b]
host     = <B机IP>
ssh_port = 22
ports    = 6382,6383,6384
```

`cluster.conf` 含密码，**不要提交到版本库**（已经在 `.gitignore` 里）。

### 第 2 步：设好 SSH 密码

脚本优先读环境变量，缺了才交互式问。批量执行时直接设：

```powershell
$env:NODE_A_SSH_USER = "root"
$env:NODE_A_SSH_PASS = "<A机的ssh密码>"
$env:NODE_B_SSH_USER = "root"
$env:NODE_B_SSH_PASS = "<B机的ssh密码>"
```

### 第 3 步：先看计划，不动任何东西

```bash
bash cluster-config.sh --dry-run
```

它会打印解析出来的节点、端口和将要建的集群布局。

### 第 4 步：检查拓扑推导

正式跑之前先看一眼脚本算出来的拓扑（正式运行也会打印同样的一段）：

```
=== 集群拓扑 ===
  master  A:6379   replica: B:6383
  master  A:6380   replica: B:6384
  master  B:6382   replica: A:6381
  脆弱主机：A（2 个 master）—— A 故障时集群不可用
  受保护主机：B（1 个 master）—— B 故障时集群仍可用（降级）
```

**如果受保护的那台不是你想要的**，把 `cluster.conf` 里 `[node.a]` 和
`[node.b]` 两段对调，脚本会重新推导。

### 第 5 步：执行

```bash
bash cluster-config.sh
```

脚本分 9 步：读配置 → 计划 → 凭证 → preflight → 建目录 → 下发 auth.conf →
下发 redis.conf 和 systemd unit → 启动并 PING → 建集群。

第 9 步是**两阶段装配**：先用 `--cluster-replicas 0` 建 3 个 master，再逐个
`--cluster add-node --cluster-slave` 把副本挂到指定的 master 上。

**可以重复执行**：重跑会重新下发配置并重启实例，已存在的集群会跳过建集群
这一步（打印 `Cluster already healthy — skipping create`），中途失败也可以
重跑，会从断点继续。

### 第 6 步：验证

```bash
redis-cli -c -a '<集群密码>' -h <A机IP> -p 6379 PING
redis-cli -c -a '<集群密码>' -h <A机IP> -p 6379 cluster info
```

`cluster info` 里应当看到：

```
cluster_state:ok
cluster_slots_assigned:16384
cluster_known_nodes:6
cluster_size:3
```

跨机读写：

```bash
redis-cli -c -a '<集群密码>' -h <A机IP> -p 6379 SET demo:key from-A
redis-cli -c -a '<集群密码>' -h <B机IP> -p 6382 GET demo:key     # -> from-A
```

### 关于容错：两台机器的硬限制

| 故障 | 结果 |
|---|---|
| 挂 1 个实例 | 有副本接管，集群可用 |
| 挂「master 数少」的那台 | 副本被提升，集群仍可用（降级） |
| 挂「master 数多」的那台 | 只剩 1 个 master，达不到多数派，**副本无权提升，集群停写** |

原因是 Redis 集群的**多数派规则**：副本提升需要过半 master 存活授权。
3 个 master 分到 2 台机器，必有一台承担 2 个 —— 这是算术，不是配置问题。
**要两头都活，至少需要 3 台机器。**

`cluster_require_full_coverage = yes`（默认）时，任一 master 挂掉就全集群停写；
设成 `no` 之后，存活 master 负责的槽位仍然可读写，只有死掉那个 master 的
槽位不可用。两台机器的部署建议用 `no`。

### 回滚

```bash
bash uninstall.sh --force
```

### 常见问题

| 现象 | 原因 |
|---|---|
| `MISSING_BIN: /opt/software/redis/bin/redis-server` | Redis 没装在这个前缀下，改 `cluster.conf` 的 `redis_prefix` |
| `MISSING_USER: redis` | 机器上没有 redis 用户：`useradd -r -s /usr/sbin/nologin redis` |
| `cannot plan the cluster topology` | 拓扑推不出来（通常是两个节点组在同一台机器上，副本无法跨机） |
| 机器重启后 cluster_state 是 fail | 多数派没满足。检查是不是有一台的 master 挂了 |
````

- [ ] **Step 3: `README.md` 加快速上手**

在 README 的用法一节加：

```markdown
### 两台机器，6 个实例

```bash
cp cluster.conf.example cluster.conf   # 填上两台机器的 IP、端口和密码
export NODE_A_SSH_PASS=... NODE_B_SSH_PASS=...
bash cluster-config.sh --dry-run        # 先看计划
bash cluster-config.sh                  # 执行
```

完整说明（含拓扑推导、容错边界、回滚）见 [docs/USAGE.md](docs/USAGE.md)。
```

- [ ] **Step 4: `docs/HANDOFF.md` 记录本轮**

在 `docs/HANDOFF.md` 开头加「第十二轮」一节，内容包含：

- 一句话现状：两台机器 6 实例的部署需求 → 复用 `cluster-config.sh`，第 9 步改成两阶段装配
- 实测矩阵（spec §3 的四组数字）
- 改动清单（9 个文件 + 提交号）
- **明确的限制**：两台机器做不到对称容错，主数多的那台故障即停写
- 下一步：填真实 IP/密码 → 上真机 → 演练一次单机故障

- [ ] **Step 5: 提交**

```powershell
git add cluster.conf.example README.md docs/USAGE.md docs/HANDOFF.md
git commit -m "docs: the two-machine six-instance deployment, its topology and its limits"
```

---

## 9. 收尾验收

- [ ] **Step 1: 整套 bats**

```powershell
docker run --rm --user 1000:1000 -v "${wt}:/repo" -w /repo rc-control:bats bash -c "find tests -name '*.bats' -print0 | xargs -0 bats"
```

预期：**0 失败**（用例数 = 163 + Task 1 的 10 + Task 2 的 4 + Task 3 的 3 + Task 4 的 11 + Task 5 的 3 = **194**）。

- [ ] **Step 2: 语法 + 契约**

```powershell
docker run --rm --user 1000:1000 -v "${wt}:/repo" -w /repo rc-control:bats bash -c "bash tests/check_syntax.sh; bash tests/validate_libs.sh"
```

预期：`FAIL=0` / `FAIL=0`。

- [ ] **Step 3: bash 4.3 兼容**

```powershell
docker run --rm -v "${wt}:/repo" -w /repo rc-control:bats bash scripts/check-bash-compat.sh
```

预期：`BASH_COMPAT: PASS`。**`lib/topology.sh` 里用到了 bash 4.0+ 的数组语法，这一步专门抓它。**

- [ ] **Step 4: Docker E2E**

```powershell
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock `
  -v "${wt}:/repo" -e E2E_HOST_REPO="${wt}" `
  rc-e2e-runner:local bash /repo/scripts/e2e-cluster-config.sh
```

预期：`=== E2E PASSED ===`，退出码 0。

- [ ] **Step 5: 推送**

```powershell
$env:GIT_SSH="C:\Windows\System32\OpenSSH\ssh.exe"
git -c remote.origin.pushurl=git@github.com:leiming-cai/redis-cluster-install.git push origin main
```

- [ ] **Step 6: 上真机**

把 `cluster.conf` 里的 `<A机IP>` / `<B机IP>` / 密码换成真值，先 `--dry-run`，
再正式执行，然后按 `docs/USAGE.md` 的「第 6 步：验证」核对。

**真机上额外要注意的**：真机的 `cluster-node-timeout` 是模板默认的 15000ms，
故障转移比 E2E 里慢，演练时给足等待时间（E2E 用的是 5 秒）。

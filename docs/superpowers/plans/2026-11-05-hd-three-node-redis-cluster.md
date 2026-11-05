# 华盾 Redis 集群三台化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把华盾生产的 Redis 目标形态从「两台 × 3 实例」改成「**三台 × 2 实例（每台 6379+6380）**」，并让**脚本的容错提示**、**配置样例**、**运维手册**三者一致且不说假话。

**Architecture:** 拓扑算法（`lib/topology.sh`）实测已经是 N 台通用，**行为一行都不用改**（本轮只改了它文件头一句注释）—— 本轮改的是三处「说错了话」的地方：(1) `cluster-config.sh` 打印的容错结论不看 `cluster-require-full-coverage`，在 `yes` 下会撒谎（**已修**：Task 3 把 `print_topology` 接到了 `lib/cluster.sh` 的 `cluster_failure_verdict` 上）；(2) 没有三台机器的样例配置；(3) `docs/HD-OPERATIONS.md` 通篇按「两台」写。

**Tech Stack:** Bash 4+ · bats（`tests/*.bats`）· `tests/validate_libs.sh`（纯 bash 断言）· `tests/check_syntax.sh`（`bash -n`）· Redis 8.10.0（现场版本）

**规格：** `docs/superpowers/specs/2026-11-05-hd-three-node-redis-cluster-design.md`

---

## ⚠️ 动手之前必须知道的三件事

### 1. 本机的 `bash` 是 **WSL2**，路径形式是 `/mnt/d/...`

```bash
cd /mnt/d/work/rediscluterproject
```

### 2. 本机**没有** `bats`，要自己装（CI 里有）

```bash
git clone --depth 1 https://github.com/bats-core/bats-core.git /mnt/d/work/bats-core
# Windows 上 clone 下来是 CRLF，bash 会报 `$'\r': command not found` —— 必须转成 LF：
cd /mnt/d/work/bats-core
find . -type f \( -name '*.bash' -o -name 'bats' -o -name 'bats-*' \) -print0 | xargs -0 -r sed -i "s/\r$//"
cd /mnt/d/work/rediscluterproject
bash /mnt/d/work/bats-core/bin/bats tests/
```

### 3. ⚠️⚠️ **工作区的行尾必须是 LF**，否则 bash 直接崩

仓库有 `.gitattributes`（`*.sh` / `*.bash` / `*.bats` / `*.md` 全部 `text eol=lf`），
所以**提交时** git 会自动归一化；但**工作区里**如果出现了 CRLF，症状是：

```
cluster-config.sh: line 41: $'\r': command not found
cluster-config.sh: line 42: set: pipefail: invalid option name
```

⇒ 症状是「脚本莫名其妙地 status 2 / 一堆测试变红」，而**根因是换行符不是代码**。
⇒ **用编辑器改完先跑 `bash -n <file>` 确认**，再跑测试。
⇒ Python 写文件时必须显式 `newline=""`（否则 Windows 上默认写 CRLF）：
```python
with open(path, "w", encoding="utf-8", newline="") as f:
    f.write(text)
```

---

## ✅ 本计划的 Task 1~3 代码**已预验证**（写计划时实跑过）

| 验证 | 结果 |
|---|---|
| Task 1 的 3 条表征测试 | **一次就绿**（`lib/topology.sh` 本来就支持三机） |
| Task 2 的 5 条 verdict 测试 | 加实现前 **红**（`command not found`，status 127）→ 加实现后 **全绿** |
| Task 3 的 2 条行为测试 | 改 `print_topology` 前 **红** → 改后 **全绿** |
| 全量 bats | `bats tests/` → **51/51**（⚠️ **不递归** `tests/lib/`）· CI 等价的 `find tests -name '*.bats' \| xargs bats` → **211/211** |
| `bash tests/check_syntax.sh` | `TOTAL=46 FAIL=0`（Task 4 后为 47） |
| `bash tests/validate_libs.sh` | `SUMMARY: PASS=54 FAIL=0` |

⇒ **计划里的代码块是跑通过的，不是伪代码。** 实施时若出现不同的失败，
先怀疑**行尾**（见上第 3 条），再怀疑代码。

---

## 前置：文件结构

| 文件 | 动作 | 职责 |
|---|---|---|
| `lib/cluster.sh` | 修改 | 新增纯函数 `cluster_failure_verdict`（容错结论的唯一出处） |
| `lib/topology.sh` | 修改 | 只改 `TOPO_SURVIVES` 的含义说明（**纯注释**，不改行为） |
| `cluster-config.sh` | 修改 | `print_topology` 调用上面那个函数 |
| `tests/lib/cluster.bats` | 修改 | `cluster_failure_verdict` 的 4 种组合各一条 + 1 条 fail-closed 守卫 |
| `tests/lib/topology.bats` | 修改 | 锁定三机布局的推导结果（表征测试） |
| `tests/cluster_config.bats` | 修改 | 把「grep 脚本文本」改成「跑 `--dry-run` 看输出」 |
| `tests/check_syntax.sh` | 修改 | 把 `cluster-config.sh` 加进语法检查清单 |
| `cluster.conf.hd.example` | **新建** | 三台机器的样例配置 |
| `cluster.conf.example` | 修改 | 加一行指路（主线两台样例保持不动） |
| `docs/HD-OPERATIONS.md` | 修改 | Redis 相关章节「两台」→「三台」+ 容错边界重写 |
| `scripts/e2e-cluster-config.sh` | 修改 | A3 断言跟随新措辞；A6 加一条 `no` 的断言 |

⚠️ **`lib/conf.sh` / `config/*.template` / `install.sh` 一行都不改**；
**`lib/topology.sh` 只改注释**（`TOPO_SURVIVES` 的含义说明，不改行为）—— 实测它不需要改行为（spec §3.1 / §3.3）。

⚠️ **`scripts/e2e-cluster-config.sh` 的改动需要 Docker 才能验证** —— 本机 Docker Desktop 未启动时，Task 7 只做 `bash -n` 与人工核对，**并如实记录「未在 Docker 里跑过」**。

---

### Task 1: 锁定三机布局的推导结果（表征测试）

`lib/topology.sh` 实测**已经**支持三机（spec §3.1）。本任务把那个结果钉成测试，
让后面改手册时有一份可执行的「真相」可对照。

**Files:**
- Modify: `tests/lib/topology.bats`（在文件末尾追加）
- Test: `tests/lib/topology.bats`

- [ ] **Step 1: 在 `tests/lib/topology.bats` 末尾追加测试**

```bash

# --- the three-host layout (huading) ------------------------------------
#
# Three machines, two instances each, and the SAME port numbers on every
# machine. The cluster identifies a node by IP:port, so repeating the ports
# is safe (lib/cluster.sh matches on "host:port").
#
# This is the layout the huading deployment is moving to. It is the first one in
# which losing ANY single host keeps the cluster serving: every host holds
# exactly one master, and that master's replica lives on another host, so a
# failure leaves a live replica to be promoted. The promotion mechanism is what
# the Docker E2E measured (DoD5 "kill a master, expect its replica to be
# promoted"), on the two-host layout.
THREE="10.0.0.1:6379,6380 10.0.0.2:6379,6380 10.0.0.3:6379,6380"

@test "topology_plan spreads three masters over three hosts, one each" {
    topology_plan "$THREE"
    [ "$TOPO_MASTER_COUNT" -eq 3 ]
    [ "$TOPO_REPLICA_COUNT" -eq 3 ]
    [ "$TOPO_TOTAL_INSTANCES" -eq 6 ]
    # The name says "one each", so pin the spread itself: the counts above
    # cannot see it. A layout with two masters on the first host and none on
    # the third has the same three counts -- the "marks the host holding
    # fewer masters" test above spells out exactly that trap for the
    # two-host layout.
    [ "${TOPO_MASTER[1]%%:*}" = "10.0.0.1" ]
    [ "${TOPO_MASTER[2]%%:*}" = "10.0.0.2" ]
    [ "${TOPO_MASTER[3]%%:*}" = "10.0.0.3" ]
}

@test "topology_plan gives every master a replica on another host" {
    topology_plan "$THREE"
    [ "$TOPO_UNPROTECTED_COUNT" -eq 0 ]
    local i
    for (( i = 1; i <= TOPO_REPLICA_COUNT; i++ )); do
        [ "${TOPO_REPLICA[$i]%%:*}" != "${TOPO_REPLICA_MASTER[$i]%%:*}" ]
    done
}

@test "topology_plan marks every host of the three-host layout as survivable" {
    topology_plan "$THREE"
    [ "${TOPO_SURVIVES[1]}" = "yes" ]
    [ "${TOPO_SURVIVES[2]}" = "yes" ]
    [ "${TOPO_SURVIVES[3]}" = "yes" ]
}
```

> 📌 **这段代码块已按代码审查的结论改过**（提交 `5aeaadd` 就是它的落地版本）：
> ① 断言了 **master 的主机**（不只是数量）—— 数量看不出「2 个 master 挤在第 1 台」；
> ② 副本循环改成**按 `TOPO_REPLICA_COUNT` 驱动 + `local i`**（与文件里已有的写法一致，
> 且不漏掉将来多出来的副本）；③ 措辞改成「is moving to」（手册要到 Task 6 才改）；
> ④ DoD5 那句补上「on the two-host layout」，免得被读成「这个三机布局在 Docker 里验过」。

- [ ] **Step 2: 跑测试**

Run: `bats tests/lib/topology.bats`
Expected: **全部通过**（含新增 3 条）。

> ⚠️ 这一步**不是** red-green：新测试**第一次跑就绿**是**预期**的 ——
> `lib/topology.sh` 本来就支持三机（spec §3.1 实测）。它是**表征测试**：
> 把「已经对的行为」钉住，让后面的文档改动有可执行的对照物。
> 若这里**失败**，说明 `lib/topology.sh` 与 spec 的实测记录不符 ⇒ **停下来查，不要改测试迁就实现**。

- [ ] **Step 3: 提交**

```bash
git add tests/lib/topology.bats
git commit -m "test(hd): pin the three-host redis cluster layout"
```

---

### Task 2: `lib/cluster.sh` 新增 `cluster_failure_verdict`（TDD）

**要解决的缺陷**（spec §3.5）：`cluster-config.sh` 打印「挂掉这台机器会怎样」时
**完全不看** `cluster-require-full-coverage` ⇒ 在 `yes` 下它说「keeps serving」，
而 `yes` 的语义是「有槽位没被覆盖就拒绝一切写入」。
（Task 2 只把措辞抽成纯函数；**真正修好的是 Task 3** —— 它才把这个函数接到 `print_topology` 上。）

**Files:**
- Modify: `lib/cluster.sh`（在文件末尾追加函数）
- Modify: `lib/topology.sh`（只改 `TOPO_SURVIVES` 的注释，不改行为）
- Modify: `tests/lib/cluster.bats`（在文件末尾追加 5 条测试）
- Test: `tests/lib/cluster.bats`

- [ ] **Step 1: 在 `tests/lib/cluster.bats` 末尾追加 5 条失败的测试**

```bash

# --- the failure verdict -------------------------------------------------
#
# What happens when a host dies depends on TWO things, and the old code
# looked at only one of them:
#
#   survives  — will the slots that just lost their master ever be covered
#               again? "no" has two causes: no quorum to promote with, or the
#               master has no replica at all. lib/topology.sh computes the
#               flag as "a quorum survives AND the master has a replica", so
#               both causes collapse into this one flag.
#   coverage  — `cluster-require-full-coverage`. With `yes` the cluster
#               refuses EVERY write while any slot is uncovered; with `no`
#               only the uncovered slots are refused.
#
# The combination decides everything, so all four are pinned here. Each case
# asserts a marker no other case contains, so a rewording of one verdict
# cannot make two of them overlap.

@test "cluster_failure_verdict keeps serving when a quorum survives and coverage is off" {
    out=$(cluster_failure_verdict yes no)
    [[ "$out" == *"keeps serving (degraded)"* ]]
    [[ "$out" == *"promoted"* ]]
    [[ "$out" != *"never covered"* ]]
    [[ "$out" != *"refuses every write"* ]]
}

@test "cluster_failure_verdict warns about the write outage while coverage is on" {
    out=$(cluster_failure_verdict yes yes)
    [[ "$out" == *"refuses every write"* ]]
    [[ "$out" == *"cluster-node-timeout"* ]]
    [[ "$out" != *"keeps serving"* ]]
    [[ "$out" != *"never covered"* ]]
}

@test "cluster_failure_verdict stops the cluster when the slots are never covered and coverage is on" {
    out=$(cluster_failure_verdict no yes)
    [[ "$out" == *"STOPS serving"* ]]
    [[ "$out" == *"never covered"* ]]
    [[ "$out" != *"keeps serving"* ]]
}

@test "cluster_failure_verdict keeps the surviving masters writable when coverage is off" {
    out=$(cluster_failure_verdict no no)
    [[ "$out" == *"surviving masters"* ]]
    [[ "$out" == *"never covered"* ]]
    [[ "$out" != *"STOPS serving"* ]]
    [[ "$out" != *"refuses every write"* ]]
}

@test "cluster_failure_verdict fails closed on an unknown coverage value" {
    # An unknown value must not read as the optimistic one: "keeps serving"
    # is the reading that hides a cluster-wide write outage.
    out=$(cluster_failure_verdict yes maybe)
    [[ "$out" == *"refuses every write"* ]]
    out=$(cluster_failure_verdict yes "")
    [[ "$out" == *"refuses every write"* ]]
    out=$(cluster_failure_verdict no maybe)
    [[ "$out" == *"STOPS serving"* ]]
}
```

- [ ] **Step 2: 跑测试，确认失败（red）**

Run: `bats tests/lib/cluster.bats`
Expected: **新增的 5 条 FAIL**（报 `cluster_failure_verdict: command not found`），
其余 PASS。

- [ ] **Step 3: 在 `lib/cluster.sh` 末尾追加实现**

```bash

# cluster_failure_verdict SURVIVES REQUIRE_FULL_COVERAGE
# Echoes what happens to the cluster when the host holding these nodes dies.
#
#   SURVIVES               "yes" | "no"  — will the slots that just lost their
#                                             master ever be covered again?
#                                             "yes" = a quorum survives AND the
#                                             master has a replica to promote.
#                                             "no" = they stay uncovered forever
#                                             -- either no quorum to promote
#                                             with, or the master has no
#                                             replica at all.
#   REQUIRE_FULL_COVERAGE  "yes" | "no"  — the value of
#                                             cluster-require-full-coverage.
#                                             With `yes` the cluster refuses
#                                             EVERY write while any slot is
#                                             uncovered; with `no` only the
#                                             uncovered slots are refused.
#
# The two are independent, so there are four outcomes and none of them may
# be collapsed into a single sentence: the old code printed "keeps serving
# (degraded)" for every case, which is wrong for coverage=yes.
#
# The strings state the EFFECT, not the cause: SURVIVES=no has two possible
# causes (no quorum, or no replica for the dead master) and only the effect is
# the same for both.
cluster_failure_verdict() {
    local survives="$1" coverage="$2"
    # An unrecognised coverage value must not fail OPEN: the optimistic
    # reading ("keeps serving") is the one that hides a cluster-wide write
    # outage. lib/conf.sh only ever produces yes|no, but this prints an
    # operator-facing verdict, so it defaults to the safe side.
    case "$coverage" in
        yes|no) ;;
        *) coverage=yes ;;
    esac
    if [ "$survives" = "yes" ]; then
        if [ "$coverage" = "yes" ]; then
            printf 'the cluster refuses every write once the failure is detected, until the replicas are promoted (detection takes cluster-node-timeout, 15s in the shipped template)'
        else
            printf 'the cluster keeps serving (degraded): the slots that just lost their master are unavailable until a replica is promoted'
        fi
    else
        if [ "$coverage" = "yes" ]; then
            printf 'the cluster STOPS serving (the slots of at least one master on that host are never covered, and cluster-require-full-coverage=yes refuses every write)'
        else
            printf "the cluster keeps serving the surviving masters' slots only (the slots of at least one master on that host are never covered)"
        fi
    fi
}
```

> 📌 **`SURVIVES` 不是「多数派还在不在」，而是「那台机刚失去 master 的槽位还会不会被接管」**
> —— `lib/topology.sh` 的判定是 `alive >= majority && protected == 1`，
> 所以 `no` 有两个成因（没有多数派 / 那个 master 没有副本），
> 措辞因此只说**效果**不说**成因**。
> 📌 `~15s` 那个数字来自模板里的 `cluster-node-timeout 15000`，**是配置值不是常量**
> （仓库里 `scripts/smoke-test.sh` 用的是 5000）⇒ 消息里**点配置名**，不写死数字。
> ⚠️ 而且故障**不是立刻被发现的**：在 `cluster-node-timeout` 到期之前，
> 集群可能**看起来还健康、还在接受写入**（`scripts/e2e-cluster-config.sh` 的实测注释），
> 所以措辞是「**故障被发现之后**拒绝写入」，不是「拒绝写入直到副本被提升（~15s）」。
> 📌 覆盖率是**配置值**，不是常量 ⇒ 遇到**不认识的值**必须**fail closed**
> （往 `yes` 靠），因为「keeps serving」恰好是那个会**掩盖全集群停写**的读法。

- [ ] **Step 3b: 把 `lib/topology.sh` 里 `TOPO_SURVIVES` 的注释改准确（纯注释）**

`lib/topology.sh` 的**行为一行都不改** —— 只改它文件头对 `TOPO_SURVIVES` 的说明。
旧说明（*"yes if the cluster keeps serving when group i dies"*）与 `lib/cluster.sh` 里
`cluster_failure_verdict` 用的定义**不是一回事**（`TOPO_SURVIVES` 还要求「该机的每个
master 都有副本」），而且在 `coverage=yes` 下旧说法是**错的**：

```bash
#   TOPO_SURVIVES[i]  'yes' if group i's masters all have a replica AND a quorum
#                     would survive group i's death -- i.e. the slots that just
#                     lost their master would be covered again. (The
#                     operator-facing wording is lib/cluster.sh's
#                     cluster_failure_verdict.)
```

- [ ] **Step 4: 跑测试，确认通过（green）**

Run: `bats tests/lib/cluster.bats`
Expected: **全部通过**。

- [ ] **Step 5: 跑纯 bash 断言集，确认没碰坏别的**

Run: `bash tests/validate_libs.sh`
Expected: `SUMMARY: PASS=54 FAIL=0`（本任务不新增断言，应仍是 54）。

- [ ] **Step 6: 提交**

```bash
git add lib/cluster.sh tests/lib/cluster.bats
git commit -m "feat(cluster): add the coverage-aware failure verdict"
```

---

### Task 3: `cluster-config.sh` 的 `print_topology` 用上新函数（TDD）

**Files:**
- Modify: `cluster-config.sh:130-148`（`print_topology` 函数）
- Modify: `tests/cluster_config.bats:239-243`（把「grep 脚本文本」改成「跑 `--dry-run` 看输出」）
- Test: `tests/cluster_config.bats`

- [ ] **Step 1: 在 `tests/cluster_config.bats` 里替换掉那条靠 grep 文件文本的测试**

把文件末尾这条：

```bash
@test "cluster-config.sh prints which host the cluster cannot survive losing" {
    run cat "$REPO_ROOT/cluster-config.sh"
    [[ "$output" == *"STOPS serving"* ]]
    [[ "$output" == *"keeps serving"* ]]
}
```

替换成下面两条。**注意这是行为测试，不是文本测试** —— 断言的是脚本**打印出来的话**，
而不是源码里有没有那几个字母（措辞以后还能改，行为不能变）：

```bash
# --- the failure verdict the operator reads --------------------------------
#
# The verdict depends on cluster-require-full-coverage, so the same layout
# produces different words. Grepping the source for "keeps serving" proved
# nothing: the text can be in the file and never reach the operator.

@test "cluster-config.sh --dry-run says the cluster keeps serving when coverage is off" {
    cat > "$CONF_TMP/three-no.conf" <<'EOF'
cluster_password = pw
cluster_require_full_coverage = no
[node.a]
host  = 10.0.0.1
ports = 6379,6380
[node.b]
host  = 10.0.0.2
ports = 6379,6380
[node.c]
host  = 10.0.0.3
ports = 6379,6380
EOF
    run bash "$REPO_ROOT/cluster-config.sh" --config "$CONF_TMP/three-no.conf" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"10.0.0.1: if it fails the cluster keeps serving (degraded)"* ]]
    [[ "$output" == *"10.0.0.2: if it fails the cluster keeps serving (degraded)"* ]]
    [[ "$output" == *"10.0.0.3: if it fails the cluster keeps serving (degraded)"* ]]
}

@test "cluster-config.sh --dry-run warns about the write outage when coverage is on" {
    cat > "$CONF_TMP/three-yes.conf" <<'EOF'
cluster_password = pw
cluster_require_full_coverage = yes
[node.a]
host  = 10.0.0.1
ports = 6379,6380
[node.b]
host  = 10.0.0.2
ports = 6379,6380
[node.c]
host  = 10.0.0.3
ports = 6379,6380
EOF
    run bash "$REPO_ROOT/cluster-config.sh" --config "$CONF_TMP/three-yes.conf" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"10.0.0.1: if it fails the cluster refuses every write once the failure is detected"* ]]
    [[ "$output" == *"cluster-node-timeout"* ]]
    [[ "$output" != *"keeps serving"* ]]
}
```

- [ ] **Step 2: 跑测试，确认新测试失败（red）、旧测试通过**

Run: `bats tests/cluster_config.bats`
Expected: **新增的 `coverage = yes` 那条 FAIL**（当前脚本对 `yes` 也打印 `keeps serving (degraded)`）；
**新增的 `coverage = no` 那条 PASS** —— 旧措辞在那条路径上本来就对，
这正是「靠 grep 源码证明不了什么」的原因（那句话在文件里，却从没被打印出来）；
其余 PASS（含 `--dry-run prints the plan` 那条）。

- [ ] **Step 3: 改 `cluster-config.sh` 的 `print_topology`**

把 `cluster-config.sh` 里 `print_topology()` 的这一段：

```bash
    for (( j = 1; j <= TOPO_GROUP_COUNT; j++ )); do
        if [ "${TOPO_SURVIVES[$j]}" = "yes" ]; then
            log_info "  host ${TOPO_GROUP_HOST[$j]}: if it fails the cluster keeps serving (degraded)"
        else
            log_warn "  host ${TOPO_GROUP_HOST[$j]}: if it fails the cluster STOPS serving (it holds too many masters for a quorum to survive)"
        fi
    done
```

换成：

```bash
    # The verdict comes from lib/cluster.sh, which knows about BOTH inputs:
    # whether the slots that just lost their master will be covered again, and
    # what cluster-require-full-coverage is. The old code looked at the first
    # one only and printed "keeps serving" even with coverage=yes, where the
    # cluster refuses every write once the failure is detected.
    #
    # log_info only when nothing has to be acted on: the slots are covered
    # again AND coverage is off. Everything else is a warning.
    for (( j = 1; j <= TOPO_GROUP_COUNT; j++ )); do
        verdict="$(cluster_failure_verdict "${TOPO_SURVIVES[$j]}" "$CONF_REQUIRE_FULL_COVERAGE")"
        if [ "${TOPO_SURVIVES[$j]}" = "yes" ] && [ "$CONF_REQUIRE_FULL_COVERAGE" != "yes" ]; then
            log_info "  host ${TOPO_GROUP_HOST[$j]}: if it fails $verdict"
        else
            log_warn "  host ${TOPO_GROUP_HOST[$j]}: if it fails $verdict"
        fi
    done
```

并把函数头的 `local j` 改成 `local j verdict`：

```bash
print_topology() {
    local j verdict
```

- [ ] **Step 4: 跑测试，确认通过（green）**

Run: `bats tests/cluster_config.bats`
Expected: **全部通过**。

- [ ] **Step 5: 跑纯 bash 断言集 + 语法检查**

Run: `bash tests/validate_libs.sh` → Expected: `SUMMARY: PASS=54 FAIL=0`
Run: `bash -n cluster-config.sh` → Expected: 无输出（退出码 0）

- [ ] **Step 6: 提交**

```bash
git add cluster-config.sh tests/cluster_config.bats
git commit -m "fix(cluster): make the failure verdict honour cluster-require-full-coverage"
```

---

### Task 4: `tests/check_syntax.sh` 补上 `cluster-config.sh`

**为什么要做**：`tests/check_syntax.sh` 的脚本清单是**硬编码**的，而
`cluster-config.sh` **从来不在里面** ⇒ 本轮改的正是这个脚本，而它的语法**从来没有被检查过**。

**Files:**
- Modify: `tests/check_syntax.sh:11`
- Test: `tests/check_syntax.sh`

- [ ] **Step 1: 把 `cluster-config.sh` 加进清单**

把 `tests/check_syntax.sh` 的这一行：

```bash
for f in install.sh status.sh uninstall.sh add-node.sh scripts/smoke-test.sh scripts/e2e-cluster-config.sh scripts/e2e-cpsweb-nodes.sh scripts/e2e-kafka-cluster.sh scripts/bench-consumer-write.sh scripts/check-bash-compat.sh tests/validate_libs.sh tests/validate_java_pipelines.sh; do
```

改成（`cluster-config.sh` 放在最前面，它是被 `status.sh` / `add-node.sh` 之外最常被直接调用的大脚本）：

```bash
for f in cluster-config.sh install.sh status.sh uninstall.sh add-node.sh scripts/smoke-test.sh scripts/e2e-cluster-config.sh scripts/e2e-cpsweb-nodes.sh scripts/e2e-kafka-cluster.sh scripts/bench-consumer-write.sh scripts/check-bash-compat.sh tests/validate_libs.sh tests/validate_java_pipelines.sh; do
```

- [ ] **Step 2: 跑语法检查**

Run: `bash tests/check_syntax.sh`
Expected: 末尾 `TOTAL=47 FAIL=0`（原 46，+1），且输出里有 `OK: cluster-config.sh`。

- [ ] **Step 3: 提交**

```bash
git add tests/check_syntax.sh
git commit -m "test(hd): put cluster-config.sh under the syntax check"
```

---

### Task 5: 三台机器的样例配置

**Files:**
- Create: `cluster.conf.hd.example`
- Modify: `cluster.conf.example`（末尾加指路注释）
- Modify: `tests/cluster_config.bats`（追加 1 条）
- Test: `tests/cluster_config.bats`

- [ ] **Step 1: 新建 `cluster.conf.hd.example`**

````markdown
# cluster.conf.hd.example — 华盾生产环境 Redis 集群（三台机器）
#
# 用法：cp cluster.conf.hd.example cluster.conf，然后按实际情况修改。
# cluster.conf 含集群密码，不应提交到版本库（已在 .gitignore 里）。
#
# 解析器不会执行本文件中的任何内容，只做键值切分。
# '#' 只能出现在一整行的开头，即只支持整行注释。值后面写 '# ...'
# 会直接报错而不是被吞进值里 —— 密码里出现 '#' 是合法字符，静默截断比
# 报错更危险。注释请单独写一行。

# ---------------------------------------------------------------------------
# 全局配置
# ---------------------------------------------------------------------------

# Redis 安装根目录。必须与三台目标机上的实际路径一致，否则生成的配置与
# systemd 单元会指向不同目录，在 ProtectSystem=strict 下导致无法启动。
#
# ⚠️ 安装包里写的是 redis-6.0.6，而现场装的是 8.10.0 —— 先查：
#     ls -d /opt/software/redis-*
redis_prefix = /opt/software/redis-8.10.0

# 集群密码。必填。同时用作 redis.conf 的 requirepass 与 masterauth。
# ⚠️ 必须与 Nacos 里 4 个 dataId 的 oms.password 完全一致
#    （见 docs/HD-OPERATIONS.md §4.7）
cluster_password = CHANGE_ME

# redis.conf 的 bind 地址。
bind_addr = 0.0.0.0

# 槽位全覆盖策略，取值只能是 yes 或 no。
#
#   yes —— 只要有槽位没被覆盖，集群就拒绝一切写入。
#   no  —— 只有没被覆盖的那些槽位不可写，其余照常。
#
# 这里必须是 no：三台机器里挂掉任意一台之后，那台 master 的副本会被提升
# （副本在别的机器上）。
#
# ⚠️ 时间线要分清两段：
#   1) master 挂掉 → 故障被发现（cluster-node-timeout 15000，约 15 秒）：
#      这段里集群还「看起来健康」、照常接受写入，只有死掉的 master 的槽位
#      写不进去（见 scripts/e2e-cluster-config.sh 的实测注释）。
#   2) 被发现 → 副本被提升、槽位重新被接管（通常远小于 15 秒）：
#      这段里 `yes` 会变成**全集群停写**（CLUSTERDOWN），`no` 只影响那些槽位。
cluster_require_full_coverage = no

# ---------------------------------------------------------------------------
# 节点配置
# ---------------------------------------------------------------------------
# [node.X] 的 X 仅作标签，用于映射环境变量 NODE_X_*，不影响语义。
# 节点按文件中出现顺序处理，段名必须以小写 node. 开头且 X 非空、不含空白。
#
# 计数单位是「实例数」而不是「节点组数」：每个端口就是一个集群实例。
# 本脚本固定 replicas=1，master 数 = ceil(实例数 / 2)，
# 而 redis-cli --cluster create 要求至少 3 个 master，
# 因此实例总数必须 >= 5 —— 下面是 3 个节点组、共 6 个实例（3 主 3 从）。
#
# ---------------------------------------------------------------------------
# ⭐ 为什么每台机器都用同样的端口号（6379,6380）
# ---------------------------------------------------------------------------
#
# 集群按 **IP:port** 区分节点，所以同一个端口号出现在多台机器上完全合法
# （lib/cluster.sh 的 cluster_role_of 就是按 "host:port" 匹配的）。
#
# 好处是防火墙只要放行 4 个端口：
#     6379, 6380        业务端口
#     16379, 16380      集群总线端口（业务端口 + 10000）
#
# ⚠️ **总线端口最容易漏**：只放行业务端口的话，节点能启动但**组不成集群**，
# 报错是 `Cluster join failed: Cannot find master to join` 或
# `Unable to connect to any of the peers`。
#
# ---------------------------------------------------------------------------
# ⭐ 这套布局推出来的拓扑（`cluster-config.sh --dry-run` 的实测输出）
# ---------------------------------------------------------------------------
#
#   master  node1:6379   <- replica node2:6380
#   master  node2:6379   <- replica node3:6380
#   master  node3:6379   <- replica node1:6380
#
# 每台机器恰好 1 个 master + 1 个副本，副本都在**另一台**机器上。
#
# ⇒ **挂掉任意一台，集群都还能全量可写**：那台 master 的副本在别的机器上
#   活着，提升后它的槽位被接管（仓库 E2E 的 DoD5 实测过这个机制）。
# ⇒ **node1:6379 就是 master #1** —— 生产现有的那个有数据的单机实例
#   原地复用，不做副本。
#
# ⚠️ **别按直觉推映射** —— 贪心分配按「候选数相同取先选中者」打破平局，
#   实际是「每台的副本跟随**上一台**的 master」。以 `--dry-run` 的输出为准。

[node.node1]
host     = 192.168.1.10
ssh_port = 22
ports    = 6379,6380

[node.node2]
host     = 192.168.1.11
ssh_port = 22
ports    = 6379,6380

[node.node3]
host     = 192.168.1.12
ssh_port = 22
ports    = 6379,6380

# ---------------------------------------------------------------------------
# 跑之前
# ---------------------------------------------------------------------------
#
# 1) 三台机器都要有 Redis 二进制 + `redis` 用户（cluster-config.sh 会校验，
#    缺了就指名报错）：
#        ls /opt/software/redis-*/bin/redis-server
#        id redis
#
# 2) node1 上现有的那个单机 6379 **必须先停掉**，否则新节点抢不到端口。
#    详见 docs/HD-OPERATIONS.md §2.3 第 0 步。
#
# 3) SSH 密码从环境变量来（每组节点一个前缀）：
#        export NODE_NODE1_SSH_USER=root NODE_NODE1_SSH_PASS='...'
#        export NODE_NODE2_SSH_USER=root NODE_NODE2_SSH_PASS='...'
#        export NODE_NODE3_SSH_USER=root NODE_NODE3_SSH_PASS='...'
#
# 4) 先干跑看拓扑：
#        bash cluster-config.sh --config cluster.conf --dry-run
````

- [ ] **Step 2: 在 `cluster.conf.example` 末尾加指路注释**

在 `cluster.conf.example` 的最后一行之后追加：

```

# ---------------------------------------------------------------------------
# 三台机器的写法
# ---------------------------------------------------------------------------
#
# 本文件是**两台机器**（主线产品）的样例。三台机器（华盾生产环境）的样例在
# `cluster.conf.hd.example`，细节见 `docs/HD-OPERATIONS.md` §2.2。
#
# 两者不能合在一个文件里 —— 一个样例文件只能放一套拓扑，
# 两套写在一起会变成「一台五机集群」。
```

- [ ] **Step 3: 在 `tests/cluster_config.bats` 末尾追加样例自检**

```bash
@test "cluster.conf.hd.example describes three hosts with two instances each" {
    run bash "$REPO_ROOT/cluster-config.sh" --config "$REPO_ROOT/cluster.conf.hd.example" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"3 node(s), 6 instance(s)"* ]]
    [[ "$output" == *"192.168.1.10:6379"* ]]
    [[ "$output" == *"192.168.1.12:6379"* ]]
}

@test "cluster.conf.hd.example keeps coverage off so a host failure does not stop all writes" {
    run bash "$REPO_ROOT/cluster-config.sh" --config "$REPO_ROOT/cluster.conf.hd.example" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"keeps serving (degraded)"* ]]
}
```

- [ ] **Step 4: 跑测试**

Run: `bats tests/cluster_config.bats`
Expected: **全部通过**（含新增 2 条）。

- [ ] **Step 5: 脱敏自查**

Run:
```bash
grep -nE '([0-9]{1,3}\.){3}[0-9]{1,3}' cluster.conf.hd.example
```
Expected: 只有 `192.168.1.10` / `.11` / `.12` 三个**保留段**地址，无真实内网 IP；
密码位是 `CHANGE_ME`。

- [ ] **Step 6: 提交**

```bash
git add cluster.conf.hd.example cluster.conf.example tests/cluster_config.bats
git commit -m "feat(hd): add the three-host cluster.conf example"
```

---

### Task 6: `docs/HD-OPERATIONS.md` —— Redis 相关章节

**只改 Redis，§3（ZK/Kafka 两节点）整章不动。**

分 6 个小步，每步改完都能自检。

**Files:**
- Modify: `docs/HD-OPERATIONS.md`
- Test: `tests/check_syntax.sh`（确保没碰坏别的）+ 手工核对

- [ ] **Step 1: 改文首现状表 + §0.3 术语 + §1.1 拓扑图 + §1.3 扩容顺序**

文首那张表里目标形态那一行，改成：

```
> | Redis | 一台机器上**一个**单机（6379） | **三台**机器，每台 2 个实例（3 master + 3 replica） |
```

§0.3 术语表里补一行 `node3`（与 `node1`/`node2` 同格式）。

§1.1 的拓扑图：把「目标：两台 node1 + node2」改成「目标：三台 node1 + node2 + node3」，
并把 Redis 那一块从「每台 3 个实例」改成「每台 2 个实例（6379/6380）」。

§1.3 的扩容顺序里，第 [2] 步改成：

```
[2] 装 Redis 集群（扩到**三台**）  → §2
```

- [ ] **Step 2: 改 §2.1 与 §2.2**

§2.1 那张「现状 vs 集群」的表，「机器数」那行的目标改成 `**3** 台`，
「实例数」那行的目标改成 `**6** 个**（每台 2 个：6379/6380）`。

§2.2 的 `cluster.conf` 模板，整段换成：

```ini
# Redis 安装根目录。必须与生产机上完全一致
# ⚠️ 安装包写的是 redis-6.0.6，但现场装的是 8.10.0 ⇒ 先查：
#     ls -d /opt/software/redis-*
redis_prefix = <现场实际的 redis 安装目录>

# 集群密码。必填。
# ⚠️ 必须与 Nacos 里 oms.password 完全一致（见 §4.7）
cluster_password = <集群密码>

# redis.conf 的 bind 地址
bind_addr = 0.0.0.0

# 必须是 no。原因见 §2.5
cluster_require_full_coverage = no

[node.node1]
host     = <node1 的 IP>
ssh_port = 22
ports    = 6379,6380

[node.node2]
host     = <node2 的 IP>
ssh_port = 22
ports    = 6379,6380

[node.node3]
host     = <node3 的 IP>
ssh_port = 22
ports    = 6379,6380
```

并在这段模板后面加一句指路：

> 📌 **完整的样例见 `cluster.conf.hd.example`**（含防火墙端口、主从映射、
> 前置条件清单）。`cluster.conf.example` 是**两台**机器的主线样例，别拿错。

- [ ] **Step 3: 重写 §2.2.1 端口规划**

把 §2.2.1 里那张「现状 → 目标」的表换成：

| 项 | 现状 | 目标 | 怎么处置 |
|---|---|---|---|
| node1 的 **6379** | 一个独立单机，**有数据** | 集群的 **master #1** | **停掉 → 清空数据目录 → 重新以集群节点身份起**（数据在 §2.3 的迁移步骤里进集群） |
| node1 的 **6380** | 空闲 | 集群的 **replica**（跟随 node3 的 master） | 新建 |
| node2 的 **6379** | 空闲（node2 还没有 Redis） | 集群的 **master #2** | 新建 |
| node2 的 **6380** | 空闲 | 集群的 **replica**（跟随 node1 的 master） | 新建 |
| node3 的 **6379** | 空闲（node3 还没有 Redis） | 集群的 **master #3** | 新建 |
| node3 的 **6380** | 空闲 | 集群的 **replica**（跟随 node2 的 master） | 新建 |

紧接着的两条提示改成：

> 📌 **目标拓扑是「3 master + 3 replica」，6 个实例分布在 3 台机器上，每台 1 主 1 从。**
> ⇒ **现状那个 6379 就是 master #1**（端口复用），不需要「退役」任何实例。
>
> 📌 **端口可以重复**：集群按 **IP:port** 区分节点，同一个端口号出现在多台机器上
> 是合法的 ⇒ **每台机器都用 6379 + 6380**。
> ⇒ **防火墙每台只需放行 4 个端口**：`6379,6380` + 总线 `16379,16380`。
>
> ⚠️ **端口复用有坑**：`cluster-config.sh` 会往节点自己的 `redis.conf` 里写
> `cluster-enabled yes` 与 `cluster-config-file`，**但不会清理旧的 `nodes.conf`**。
> ⇒ 旧的 `/opt/software/redis-*/logs/`（数据目录）里若残留
> `nodes.conf`，新节点会带着**旧集群的身份**启动 ⇒ 表现为「节点认不出自己」。
> ⇒ **重建前务必把数据目录清空**（§2.3 第 1 步）。

- [ ] **Step 4: 改 §2.3 的第 1/2/3 步**

第 1 步「前置条件逐项核对」里那句「**两台节点上**（逐台检查）」改成
「**三台节点上**（逐台检查）」，并把 node2 那条告警改成：

> ⚠️ **node2 和 node3 上都还没有 Redis** —— 它们连 Redis 都没装。
> ⇒ 扩容的**第 0 步之外**，node2 与 node3 还要先装 Redis 二进制 + 建 `redis` 用户
> （`cluster-config.sh` 会**校验**这两项，缺了就指名报错）。

第 2 步的环境变量改成三组：

```bash
export NODE_NODE1_SSH_USER=root NODE_NODE1_SSH_PASS='<node1 的 ssh 密码>'
export NODE_NODE2_SSH_USER=root NODE_NODE2_SSH_PASS='<node2 的 ssh 密码>'
export NODE_NODE3_SSH_USER=root NODE_NODE3_SSH_PASS='<node3 的 ssh 密码>'
```

> 📌 **环境变量前缀是段名的大写化**：`[node.node1]` ⇒ `NODE_NODE1_`，
> `[node.a]` ⇒ `NODE_A_`。前缀写错的话，脚本会**静默**改用配置文件里的 host
> 和交互式提示，而不是报错。

第 3 步的判据表里加一行：

| 判据 | 期望 |
|---|---|
| 每个 master 都有副本 | 打印的主从映射里每个 master 都有 replica |
| 副本与 master **不同机** | 同上 |
| `CLUSTER INFO` | `cluster_state:ok` · `cluster_slots_assigned:16384` · `cluster_size:3` |
| `CLUSTER NODES` | `cluster_known_nodes:6`（3 master + 3 replica） |

- [ ] **Step 5: 重写 §2.5 容错硬边界**

把 §2.5 整节换成（**四个象限都要写，缺一维就又变成「只说一半」**）：

```markdown
### 2.5 ⭐ 容错边界（**两个维度一起看**）

扩容后是 **3 master + 3 replica 跨 3 台机器**，每台机器恰好 1 个 master + 1 个副本
（`cluster-config.sh` 推导出的布局）：

```
master node1:6379  <- replica node2:6380
master node2:6379  <- replica node3:6380
master node3:6379  <- replica node1:6380
```

**结论先说**：**三台机器下，挂掉任意一台，集群都还能全量可写**（**副本被提升之后**；提升之前只有那个 master 的槽位短暂不可写，见 §6.2）。

**为什么**（两台做不到的事）：

| 步骤 | 分析 |
|---|---|
| 挂掉 node1 | 死的是 `node1:6379`（master）和 `node1:6380`（node3 的副本） |
| 多数派？ | 存活 master = node2:6379、node3:6379 = **2/3** ✅ ⇒ 副本**有权提升** |
| node1:6379 的槽位 | 它的副本 `node2:6380` **活着，在另一台** ✅ ⇒ 提升 ⇒ **槽位被接管** |
| node3:6379 的槽位 | master **自己活着** ✅（它只是没了副本，不影响槽位覆盖） |
| 结论 | **16384 个槽位全覆盖** ⇒ `cluster_state:ok` ⇒ **写入照常**（**副本被提升之后**；提升之前只有那个 master 的槽位短暂不可写，见 §6.2） |

> 📌 **两台为什么做不到**：3 个 master 分到 2 台机器，必有一台承担 2 个
> ⇒ 那台挂掉只剩 1 个 master，**不过多数派** ⇒ 副本无权提升 ⇒
> 那些槽位永远无人接管。**这是算术，不是配置问题**（见 §8.3）。

⚠️ **`cluster-require-full-coverage` 决定的是「故障被发现之后」的那段窗口**：

⚠️ **`cluster-node-timeout 15000` 是「故障被发现」要花的时间，不是停写窗口的长度**
（master 挂掉 → 被标记 FAIL 需要 15 秒）。**在这 15 秒里集群还「看起来健康」**，
其它 master 照常接受写入 —— 仓库自己的 E2E 注释就是这么说的
（`scripts/e2e-cluster-config.sh:556-558`：*"the masters are only marked fail
after cluster-node-timeout (15s in the template), and until then the
cluster can still look healthy and accept writes"*）。
**停写窗口从「被发现」开始，到「副本被提升、槽位重新被接管」为止**（通常远小于 15 秒）：

| 配置 | 发现之前（~15s） | 发现之后 ~ 提升完成 | 提升完成后 |
|---|---|---|---|
| `no` | 死掉的 master 的槽位写不进去，**其余照常** | 只有那些槽位不可写 | 全量可写 |
| `yes` | 同上（`cluster_state` 可能还是 `ok`） | **全集群拒绝一切写入**（`CLUSTERDOWN`） | 全量可写 |

⇒ **本方案用 `no`** —— 它把「一台机器故障」从「**故障被发现后**全集群停写」降级成
「**只有那些槽位**短暂不可写」（§2.2 的模板里已经带上了）。

⚠️ **两台那套说法的同一张表（供对照，勿混用）**：

| 场景 | `no` | `yes` |
|---|---|---|
| 挂掉「master 少」的那台 | 槽位全覆盖 ⇒ 可写 | **故障被发现后到提升完成前全集群停写**（窗口 ≈ 提升耗时，不是 15 秒），之后可写 |
| 挂掉「master 多」的那台 | 存活 master 的槽位**仍可写**（死掉的那些不可用） | **全集群永久停写** |
```

- [ ] **Step 6: 改 §5.3.1 / §7.4 / §8.1 / §8.3 / §9**

| 位置 | 改动 |
|---|---|
| §5.3.1 中间件 | 判据里的实例数按 3 台 / 6 实例改 |
| §7.4 日常巡检 | 加一条「三台都在？每个 master 都有副本？」 |
| §8.1 端口表 | 改成「每台 6379 + 6380；总线 16379 + 16380」 |
| §8.3 易错点 | 「两台做不到对称容错」那条改成「两台 vs 三台」的对照，并指向 §2.5 |
| §9 一页速查 | 端口、实例数、容错结论同步 |

- [ ] **Step 7: 自检 —— 手册里不该再有「两台」**

Run:
```bash
grep -n '两台\|2 台' docs/HD-OPERATIONS.md
```
Expected: **只剩下 §3（ZK/Kafka 两节点）那一段的命中**。逐条核对剩下的命中确实都属于 ZK/Kafka；
若有任何一条在 Redis 段落里，说明漏改了。

- [ ] **Step 8: 自检 —— 文档交叉引用仍可解析**

Run:
```bash
python3 - <<'PY'
import re, pathlib
root = pathlib.Path(".")
def heads(p):
    out = set()
    for l in p.read_text(encoding="utf-8").splitlines():
        m = re.match(r"^#{1,6}\s+(.*)$", l)
        if not m: continue
        t = m.group(1).strip()
        mm = re.match(r"^(\d+(?:\.\d+)*)[ .、]?(.*)$", t)
        if mm:
            n = mm.group(1); out.add(n)
            parts = n.split(".")
            for i in range(1, len(parts)): out.add(".".join(parts[:i]))
    return out
docs = sorted((root/"docs").rglob("*.md")) + [root/"README.md"]
H = {p: heads(p) for p in docs}
union = set().union(*H.values())
bad = 0
for p in docs:
    for r in sorted(set(re.findall(r"§\s*(\d+(?:\.\d+)*)", p.read_text(encoding="utf-8")))):
        if r not in union:
            print(f"STALE {p.relative_to(root)} -> §{r}"); bad += 1
print("stale refs:", bad)
PY
```
Expected: `stale refs: 0`

- [ ] **Step 9: 提交**

```bash
git add docs/HD-OPERATIONS.md
git commit -m "docs(hd): move the redis plan from two hosts to three"
```

---

### Task 7: `scripts/e2e-cluster-config.sh` 的断言跟随新措辞

**这是本轮的隐藏依赖** —— E2E 断言的正是本轮要改的措辞，不改就会红。

**Files:**
- Modify: `scripts/e2e-cluster-config.sh`（A3 断言 + A6 追加一条）
- Test: `scripts/e2e-cluster-config.sh`（**需要 Docker**）

- [ ] **Step 1: 改 A3 的 protected 那台断言**

当前：

```bash
grep -q "host $protected: if it fails the cluster keeps serving" "$WORK/install.log" \
    || fail "cluster-config.sh did not name $protected as the survivable host"
```

改成：

```bash
# The main run's config does NOT set cluster_require_full_coverage, so the
# default (yes) applies: once the failure is detected the cluster refuses
# every write until the replicas are promoted. Saying "keeps serving" there
# would be the lie this whole change is about -- the A5 case below already
# measures that a host failure stops writes with coverage=yes.
grep -q "host $protected: if it fails the cluster refuses every write once the failure is detected" "$WORK/install.log" \
    || fail "cluster-config.sh did not name $protected as the host whose failure interrupts writes:
$(grep -i 'if it fails' "$WORK/install.log" || true)"
```

**fragile 那台的断言不动**（`survives=no` + `yes` ⇒ 措辞仍含 `the cluster STOPS serving`）。

- [ ] **Step 2: 在 A6（`coverage=no` 那次重建）里加一条断言**

在 A6 段落里，`reset_cluster "$WORK/rebuild-a6.log"` 成功之后、
`rendered=` 那段检查之前，插入：

```bash
# With coverage=no the verdict must be the degraded-but-serving one.
pick_fragile_and_protected
grep -q "host $protected: if it fails the cluster keeps serving (degraded)" "$WORK/rebuild-a6.log" \
    || fail "cluster-config.sh did not report the degraded verdict with coverage=no:
$(grep -i 'if it fails' "$WORK/rebuild-a6.log" || true)"
```

- [ ] **Step 3: 语法检查**

Run: `bash -n scripts/e2e-cluster-config.sh`
Expected: 无输出（退出码 0）。

- [ ] **Step 4: 跑 Docker E2E**

Run: `bash scripts/e2e-cluster-config.sh`
Expected: 退出码 0，输出 `E2E PASSED`。

> ⚠️ **本机 Docker Desktop 未启动时这一步跑不了** ⇒
> **不要伪造通过**。在提交信息 / 交接记录里如实写
> 「E2E 断言已同步，**未在 Docker 里跑过**（Docker 不可用）」，
> 并把「跑一次 Docker E2E」留成下一轮的待办。

- [ ] **Step 5: 提交**

```bash
git add scripts/e2e-cluster-config.sh
git commit -m "test(cluster): follow the coverage-aware failure verdict"
```

---

### Task 8: 端到端验证与收尾

- [ ] **Step 1: 跑全部本地测试**

```bash
bash tests/check_syntax.sh
bats tests/lib/cluster.bats tests/lib/topology.bats tests/cluster_config.bats
bash tests/validate_libs.sh
```
Expected:
- `check_syntax.sh` → `TOTAL=47 FAIL=0`
- bats → **全部通过**
- `validate_libs.sh` → `SUMMARY: PASS=54 FAIL=0`

- [ ] **Step 2: 跑三机干跑，肉眼核对拓扑**

```bash
bash cluster-config.sh --config cluster.conf.hd.example --dry-run
```
Expected（**逐字核对**）：

```
Config OK: 3 node(s), 6 instance(s), 1 replica(s) per master
  master  192.168.1.10:6379
  master  192.168.1.11:6379
  master  192.168.1.12:6379
  replica 192.168.1.10:6380 -> master 192.168.1.12:6379
  replica 192.168.1.11:6380 -> master 192.168.1.10:6379
  replica 192.168.1.12:6380 -> master 192.168.1.11:6379
  host 192.168.1.10: if it fails the cluster keeps serving (degraded): the slots that just lost their master are unavailable until a replica is promoted
  host 192.168.1.11: if it fails the cluster keeps serving (degraded): the slots that just lost their master are unavailable until a replica is promoted
  host 192.168.1.12: if it fails the cluster keeps serving (degraded): the slots that just lost their master are unavailable until a replica is promoted
```

⚠️ **主从映射必须与上面逐字一致** —— 贪心分配按「候选数相同取先选中者」打破平局，
**不是**「node1 的副本跟 node2」那种直觉顺序。**照抄输出，别按直觉推。**

- [ ] **Step 3: 跑「覆盖率=yes」的那一份，确认措辞变了**

```bash
sed 's/cluster_require_full_coverage = no/cluster_require_full_coverage = yes/' \
    cluster.conf.hd.example > /tmp/cov-yes.conf
bash cluster-config.sh --config /tmp/cov-yes.conf --dry-run
```
Expected: 三台都打印 `if it fails the cluster refuses every write once the failure is detected`，
且**不再出现** `keeps serving`。

- [ ] **Step 4: 确认工作区干净、推送**

```bash
git status --short
git push origin main
```
Expected: `git status --short` 无输出；push 成功。

- [ ] **Step 5: 写会话存档**

在 `docs/superpowers/sessions/` 下新建 `2026-11-05-hd-three-node-redis-cluster.md`，
按仓库既有存档的结构写，**必须包含**：

| # | 事 | 说明 |
|---|---|---|
| 1 | **实测证据** | 三机 `--dry-run` 的真实输出（主从映射逐字抄）、实例数矩阵、8.10.0 的版本核对、`cluster_role_of` 按 `host:port` 匹配的依据 | 
| 2 | **规格被修正的那一处** | spec §6 初稿把「死掉的副本」当成「死掉的 master」⇒ 三机的容错结论应是**全量可写**，不是「降级」 |
| 3 | **隐藏依赖** | `tests/cluster_config.bats` 那条 grep 文件文本的测试、`scripts/e2e-cluster-config.sh` 的 A3 断言、`tests/check_syntax.sh` 漏了 `cluster-config.sh` |
| 4 | **没做的事** | Docker E2E 未跑（Docker 不可用）、ZK/Kafka 未动、主线产品文档未动、没碰生产 Nacos、没建表、没写迁移脚本 |
| 5 | **下一轮** | ① 跑一次 Docker E2E ② 现场装 Redis 8.10.0 + 建 `redis` 用户 ③ 现场数实例数（确认真的只有 1 个 6379）④ 抽查生产 Nacos 的 `oms:` 真值 ⑤ 迁数据的停机窗口与 `DBSIZE` 基线 |

```bash
git add docs/superpowers/sessions/2026-11-05-hd-three-node-redis-cluster.md
git commit -m "docs(hd): archive the three-node redis cluster round"
git push origin main
```

---

## 附：本轮**不做**的事（再次记下来）

| # | 事 | 为什么 |
|---|---|---|
| 1 | 改 `install.sh` | Redis 现场已装好（8.10.0） |
| 2 | 改 `lib/topology.sh` 的**行为** / `lib/conf.sh` | 实测 N 台通用；`lib/topology.sh` 本轮**只改了注释**（`TOPO_SURVIVES` 的含义说明） |
| 3 | 改 `config/*.template` | 实测 54 条指令在 8.10.0 全部有效 |
| 4 | 改 ZK/Kafka（§3 整章） | 本轮只做 Redis |
| 5 | 改主线产品文档（`OPERATIONS.md` / `USAGE.md` / `README.md`） | 另一个交付形态 |
| 6 | 改生产 Nacos 的 `oms:` | 生产环境的动作 |
| 7 | 写数据迁移脚本 | 业务语义只有实施方知道 |
| 8 | 真机验证 | 真机要改生产环境 |

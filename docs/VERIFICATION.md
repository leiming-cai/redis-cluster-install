# Docker 验证报告 — redis-cluster-install

**验证时间**：2026-10-12
**验证环境**：Docker Desktop 29.8.1（Linux 容器，2 vCPU / 2 GB RAM）
**基础镜像**：`docker.m.daocloud.io/library/ubuntu:22.04`（Docker Hub 直连被阻断，改用镜像源）

| 镜像 | 组成 |
|------|------|
| `rc-control:local` | Ubuntu 22.04 + sshpass + openssh-client + redis-tools + bats |
| `rc-node:local` | Ubuntu 22.04 + openssh-server + systemd + build-essential（gcc 11.4） |

**结论**：发现并修复 **10 个缺陷**（含 2 个生产阻断级），最终 install.sh 全流程部署成功，
DoD 7 项中 6 项自动验证通过。

---

## 最终结果

| 验证项 | 修复前 | 修复后 |
|--------|--------|--------|
| `check_syntax.sh` | FAIL=12（全是误检） | **FAIL=0**（26 项） |
| `validate_libs.sh` | PASS=45 FAIL=2 | **PASS=50 FAIL=0** |
| `bats`（CI 调用方式） | 9 通过 / 16 文件加载失败 | **58/58 通过** |
| `bats`（绝对路径） | 9 通过 | **58/58 通过** |
| `install.sh` E2E | 步骤 3 失败（`Bad port ''`） | **退出码 0，14 步全通过** |

### install.sh 完整 E2E 日志（关键节点）

```
[OK]  SSH connectivity verified
[OK]  Toolchain verified on both nodes
[OK]  sudo access verified on both nodes
[OK]  Tarball copied
      already installed, skipping build          ← 预置二进制，跳过源码编译
[OK]  Build complete on both nodes
[OK]  Directories provisioned
[OK]  Auth file deployed
[OK]  Instance configs rendered                 ← 6 份 redis.conf
[OK]  systemd units rendered                    ← 6 份 unit
[OK]  All 6 instances responding to PING         ← D8 修复后
[OK]  All nodes agree about slots configuration.
[OK]  All 16384 slots covered.
[OK]  Cluster is healthy (attempt 1)
==========================================
 Redis Cluster READY
==========================================
```

> 交互输入全程「回车接受默认」SSH 用户与端口——这正是 D1 修复前必然失败的路径。

---

## 缺陷清单

### D1 · `read_default` 不返回默认值（生产阻断 · P0）

`lib/prompt.sh:48` 调用 `_read_from` 时漏传第三参数（默认值）：

```bash
if ! _read_from prompt_str reply; then   # ← 缺 "$default"
```

`_read_from` 的默认值逻辑在 `prompt.sh:34-36`，因此永远不触发；`$2` 仅用于拼接提示文本。

**E2E 实测**：直接回车接受默认 →

```
A_USER=[]   （期望 root）    A_PORT=[]   （期望 22）
→ Bad port ''  → ssh 退出码=255
→ [ERROR] cannot reach @node-a:    ← 步骤 3 中止
```

`install.sh` 与 `uninstall.sh` 的四项默认（SSH 用户/端口 × A/B）全部受影响。

**修复**：转发 `$default`；EOF 时也回落默认值。

**验证**：10/10 通过；E2E 中步骤 3 顺利通过。

---

### D8 · systemd `ReadWritePaths` 与实际路径不符（生产阻断 · P0）

**E2E 首个失败点**，`install.sh` 自身的诊断输出精确定位了问题：

```
==== last 30 journalctl lines for redis-6379.service ====
redis-server: *** FATAL CONFIG FILE ERROR ***
Reading the configuration file, at line 58
>>> 'logfile /opt/software/redis/log/redis-6379.log'
Can't open the log file: Read-only file system
```

systemd 单元的 `ReadWritePaths=` 当时只列了 `/var/lib/redis`、`/var/log/redis`、
`/var/run/redis` 三条，缺了 `redis.conf` 实际写入的 `%REDIS_PREFIX%` 路径
（下面展示的是修复后的现行形式）：

```
ReadWritePaths=-/var/lib/redis -/var/log/redis -/var/run/redis -%REDIS_PREFIX%/cluster -%REDIS_PREFIX%/log
```

而 `redis.conf` 把 `cluster-config-file` 与 `logfile` 放在
`/opt/software/redis/{cluster,log}` —— 在 `ProtectSystem=strict` 下这些目录只读，Redis 拒绝启动。

这正是静态分析阶段标记为「高风险待验证」的疑点，已被 E2E 证实。

**修复**：`ReadWritePaths` 补上 `%REDIS_PREFIX%/cluster` 与 `%REDIS_PREFIX%/log`，
并让 `redis.conf` / unit 的路径都从 `%REDIS_PREFIX%` 占位符渲染，与 `REDIS_PREFIX` 环境变量保持一致。

**验证**：修复后 `All 6 instances responding to PING`。

> **后补的一条（与 D8 不是同一个问题）**：现行形式里每一项前面的 `-` 是
> systemd 的「**该路径不存在就忽略**」标记。没有 `-` 的条目是硬性要求 ——
> 路径一旦缺失，单元直接以 `status=226/NAMESPACE` 启动失败，redis-server
> 根本没机会运行。`/var/log/redis` 虽然被列在单元里，但仓库里**没有任何代码
> 创建它**（`cluster-config.sh` 的 `create_dirs` 不建，`install.sh` 的源码编译
> 路径也不建），所以在没有装过发行版 redis 包的机器上，单元会在 redis-server
> 启动之前就死掉。Debian/Ubuntu 自己的 `redis-server.service` 五项也全带 `-`，
> 原因相同。
>
> 这与 D8 是**两个不同的问题**：D8 是「**该列的路径没列**」，
> 这条是「**列了，但根本没人创建**」。缺陷、触发条件与修法都不一样。
> 详见 `docs/HANDOFF.md` 的已知问题记录与提交 `32ac923`。

---

### D2 · `validate_libs.sh` / `cluster.bats` 夹具过时（测试 · P2）

`is_cluster_healthy` 还要求 `cluster_slots_fail` 与 `cluster_known_nodes`，但测试样本只有两行，
导致假阴性。生产逻辑本身正确。

用真实 `cluster info` 格式复验 6 种场景全部符合预期：

| 场景 | 期望 | 实测 |
|------|------|------|
| 健康集群（6 节点 / 16384 槽） | 0 | ✅ |
| 创建后短暂 `fail`（设计容忍） | 0 | ✅ |
| 槽位不全 | 1 | ✅ |
| 存在失败槽位 | 1 | ✅ |
| 节点数不足 | 1 | ✅ |
| 空输入（redis-cli 不可达） | 1 | ✅ |

**修复**：两处夹具均改为完整格式，并把断言扩充为上述 6 个场景。

---

### D3 · `tests/install.bats` load 路径错误（测试 · P1）

`load '../setup'` 在 `tests/` 下解析为 `./setup`，实测报 `bats: ../setup does not exist`。
同级 4 个文件写的都是 `load 'setup'`。

**修复**：改为 `load 'setup'`。

---

### D4 · `setup.bash` 的 `REPO_ROOT` 在 load 期为空（测试 · P1）

原实现把 `REPO_ROOT` 放在 `setup()` 里赋值，但测试文件在**顶层**调用 `load_lib`——
bats 分两个阶段，`load` 与顶层语句在 `setup()` 执行**之前**就跑了。导致 `load_lib` 拼出 `/lib/cluster`。

实测（复现 CI 的 `find | xargs bats` 调用）：

```
setup.bash: line 10: /lib/cluster: No such file or directory
setup.bash: line 10: .: /lib/systemd: is a directory
```

改成绝对路径后错误消失，证实与调用方式相关。

**修复**：改为在 **load 期**计算，且向上查找 `lib/common.sh` 标记文件定位仓库根
（测试文件位于 `tests/` 和 `tests/lib/` 两个深度，固定层数必然有一边错）。

**验证**：bats 由 9 通过 → 34 通过（7 个 lib 测试文件首次真正执行）。

---

### D5 · `load_lib` 未补 `.sh` 后缀（测试 · 首次发现）

`lib/` 里是 `cluster.sh`，测试调用 `load_lib cluster`，`load_lib` 直接拼 `$REPO_ROOT/lib/$1`。

意味着 **7 个 lib 测试文件从未真正运行过**——D4 修好后才暴露出来。

**修复**：`load_lib` 自动补 `.sh`。

---

### D6 · `uninstall.sh --help` 不含 `Usage:`（测试+UX · P2）

脚本用 `sed -n '2,8p'` 打印头部，实际输出不含 `Usage:`，测试断言必然失败；
且把 `set -euo pipefail` 与 `REPO_ROOT=...` 一并打印出来。

**修复**：补标准 `Usage:` 注释块，并把打印范围调整为 `2,9p` 精确匹配。

---

### D7 · `check_syntax.sh` 误检 `.bats`（工具 · P1）

`.bats` 的 `@test "x" {` 不是合法 bash，`bash -n` 全部报语法错误，
`TOTAL=26 FAIL=12` 的 FAIL 全是误检，掩盖真实结果。

**修复**：`.bats` 改为标注 SKIP 并提示用 bats 执行，`tests/setup.bash` 单独检查。

---

### D8b · `common.bats` 使用了 bats 1.2 不支持的 `$stderr`（测试 · P2）

Ubuntu 22.04 的 `apt install bats` 是 **1.2.1**，该版本 `run` 把 stderr 合并进 `$output`，
没有独立的 `$stderr` 变量。实测：

```
output=[out
err]
stderr=[<UNSET>]
```

库代码行为正确（`log_warn`/`log_error`/`die` 确实写 stderr），是测试用了过新的 API。

**修复**：改用显式重定向捕获 stderr，兼容新旧 bats 版本。

---

### D9 · `install_idempotency.bats` 断言恒真（测试 · P2）

```bash
type remote_file_exists >/dev/null 2>&1
[ "$?" -eq 0 ]        # type 成功必为 0 → 永真
```

且 `source "$(dirname "$BATS_TEST_FILENAME")/..."` 在 bats 中 `$(...)` 是命令替换而非插值，路径解析失败。

另外发现 `remote_file_exists`（`lib/common.sh:57`）内部调用 `ssh_run`，但 `common.sh` 并未 source
`lib/ssh.sh`，实际调用必然 `command not found`。

**修复**：改为 stub `ssh_run` 后真实调用，验证正反两种返回值。

---

### D10 · `status.sh` 健康判断逻辑颠倒 + 槽位解析错乱（生产 · P1）

两处问题，都在 E2E 中暴露：

**(a) 健康判断颠倒** —— 原写法：

```bash
if ! echo "$info" > /tmp/f && is_cluster_healthy < /tmp/f; then
```

`!` 优先级高于 `&&`，实际是 `(! echo...) && is_cluster_healthy`。分支语义与意图相反。

**(b) 槽位分布全是乱码** —— 原写法按「2 行一组」配对，但 `redis-cli cluster slots`
是**每行一个字段**：

```
0                      ← start
5460                   ← end
172.19.0.3             ← master ip
6384                   ← master port
b1a770e2...            ← master id
172.19.0.2 / 6379 / 46ffd383...   ← 副本三元组
10923 ...              ← 下一个范围
```

实测输出：

```
0  5460
172.19.0.3  6384              ← 槽位号与 IP 混在一起
b1a770e2...  172.19.0.2
```

**(c) SIGPIPE** —— 管道接 `head -20` 导致 `status.sh` 退出码 **141**。

**修复**：判断改为清晰的 `if ... ; then : ; else ... fi`；槽位解析改为按
「范围头 5 字段 + 每副本 3 字段」重建；移除 `head`。

**验证**：

```
== Slot Distribution ==
0      - 5460    master  172.19.0.3:6384
0      - 5460    replica 172.19.0.2:6379
10923  - 16383   master  172.19.0.2:6380
10923  - 16383   replica 172.19.0.3:6383
5461   - 10922   master  172.19.0.3:6382
5461   - 10922   replica 172.19.0.2:6381
```

与 `cluster nodes` 的槽位归属交叉验证完全一致；退出码 0。

---

### D11 · `add-node.sh` 未把 `REDIS_PREFIX` 传给远端（生产 · P2）

`add-node.sh:152` 远端脚本写 `REDIS_BIN=${REDIS_PREFIX:-/opt/software/redis}/bin`，
但 `$1`~`$5` 已被 `SUDO_PASS`/`NEW_HOST`/`NEW_PORT`/`EXIST_HOST`/`EXIST_PORT` 占用，
`REDIS_PREFIX` 从未作为参数传入 → 自定义前缀时远端必然找不到 `redis-cli`。

同文件建目录步骤也缺 `$REDIS_PREFIX/cluster` 与 `/log`，会触发与 D8 相同的只读错误。

**修复**：显式传参（第 6 位），并补齐前缀目录。

---

## DoD 验证（spec §10）

| # | DoD 条目 | 结果 | 证据 |
|---|----------|------|------|
| 1 | 6 个实例 PING → PONG | ✅ | 6/6 PONG |
| 2 | `--cluster check` 返回 OK | ✅ | `All nodes agree`、`All 16384 slots covered` |
| 3 | `cluster_state:ok` / `known_nodes:6` / `assigned:16384` | ✅ | 三项全部符合 |
| 4 | 跨机读写 | ✅ | A 写 B 读、B 写 A 读均正确；replica 返回 `MOVED` 说明路由正常 |
| 5 | kill master 后自动提升 | ✅ | 停 `redis-6379` 后约 20s，`node-b:6384` 提升为 master；重启后 6379 以 slave 回归，`cluster_state:ok` |
| 6 | `status.sh` 打印角色与槽位 | ✅ | 三段输出正常（修复 D10 后） |
| 7 | `uninstall.sh --force` 清干净 | ✅ | 进程 0、单元 0、配置/数据/二进制全删，数据已备份 |

### 故障自愈实测

```
--- 停止 node-a:6379 ---
[20s] node-b:6384  →  master        （原为 slave）
       node-a:6379 →  master,fail

--- 重启 node-a:6379 ---
       node-b:6384  →  master
       node-a:6379  →  slave         （正确回归为从节点）
cluster_state:ok  cluster_slots_assigned:16384  cluster_known_nodes:6
```

提升耗时约 20 秒，与 `cluster-node-timeout 15000` 一致，满足 DoD 的「30 秒内」。

### uninstall 实测

```
[INFO] tearing down 172.19.0.2...
torn down
[OK]   Local password file removed

node-a: redis 进程 0 / systemd 单元 0
        /etc/redis/cluster 已删除 / /var/lib/redis/cluster 已删除
        /opt/software/redis 已删除 / 备份 /tmp/redis-cluster-backup-1791797935.tar.gz
```

dry-run 模式（不给参数）确认不会误删，服务保持 active。

---

## 环境限制与说明

**源码编译步骤（步骤 6）未能完整执行**：本机仅 2 vCPU / 2 GB RAM，
`install.sh` 会在两台节点并行 `make -j$(nproc)`，而 Redis 8.8.0 的 jemalloc 默认带
`-g3 -flto=auto -ffat-lto-objects`，两台并行 LTO 编译导致宿主内存耗尽、
**Docker Desktop Linux 引擎崩溃并持续返回 HTTP 500**（两次，需手动重启）。

编译日志确认已正常推进至 jemalloc 符号生成阶段，**无编译错误**。

**绕过方式**：利用 `install.sh:267` 的幂等判断——二进制已存在即跳过编译。
预置 apt 版 `redis-server`/`redis-cli` 到 `$REDIS_PREFIX/bin/` 后，
步骤 6 打印 `already installed, skipping build`，流程继续走完步骤 7–14。

**影响范围**：步骤 6 的编译逻辑本身（GCC 探测、并行执行、PREFIX 传递、幂等跳过）
已在日志中确认正确执行；`build_remote` 的完整性依赖源码编译验证，本次未覆盖。

**另一处环境限制**：容器间无法解析 `CLUSTER MEET` 使用的主机名
（`ERR Invalid node address specified: node-a:6379`）。改用容器 IP 后集群创建成功。
真实环境用 IP 不受影响。

---

## 修复文件清单

| 文件 | 缺陷 |
|------|------|
| `lib/prompt.sh` | D1 |
| `config/redis-cluster.service.template` | D8（+ 后续 `32ac923`：五项加 `-` 前缀） |
| `config/redis.conf.template` | D8（`%REDIS_PREFIX%` 占位符） |
| `lib/config_gen.sh` | D8（支持 `%REDIS_PREFIX%`） |
| `lib/systemd.sh` | D8（支持 `%REDIS_PREFIX%`） |
| `install.sh` | 传入 `$REDIS_PREFIX` |
| `add-node.sh` | D11（传参 + 补目录） |
| `status.sh` | D10（判断逻辑 + 槽位解析 + SIGPIPE） |
| `uninstall.sh` | D6（Usage 注释块） |
| `tests/setup.bash` | D4 + D5 |
| `tests/install.bats` | D3 |
| `tests/install_idempotency.bats` | D9 |
| `tests/lib/common.bats` | D8b |
| `tests/lib/cluster.bats` | D2 |
| `tests/lib/prompt.bats` | D4 |
| `tests/validate_libs.sh` | D2 |
| `tests/check_syntax.sh` | D7 |

---

## 复现环境

```bash
docker network create rc-net

docker run -d --name rc-node-a --network rc-net --hostname node-a \
  --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw rc-node:local
docker run -d --name rc-node-b --network rc-net --hostname node-b \
  --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw rc-node:local

# 预置二进制以跳过源码编译（2GB 环境跑不动 LTO）
# ... cp redis-server redis-cli -> /opt/software/redis/bin/

docker run --rm --network rc-net \
  -v "$PWD:/repo" -v "$PWD/verify:/v" rc-test:local bash /v/run_install.sh
```

### D1 最小复现

```bash
docker run --rm -v "$PWD:/repo" rc-test:local bash -c '
  export PROMPT_NO_TTY=1
  . /repo/lib/prompt.sh
  echo "回车接受默认 SSH 端口:"
  echo "" | read_default "A SSH port" "22"
  echo "^ 期望 22"
'
```

### D10 最小复现

```bash
redis-cli -c -a "$PASS" cluster slots | head -8
# 每行一个字段，不是每行一个槽位区间
```

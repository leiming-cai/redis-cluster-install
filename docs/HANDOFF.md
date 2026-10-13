# cluster-config.sh 实施进度交接

**更新时间**：2026-10-13
**工作分支**：`feature/cluster-config-script`
**Worktree**：`C:\Users\蔡雷鸣\.local\share\opencode\worktree\3e438c\cluster-config-script`
**基线**：`main` = `7a2b0fc`（Docker E2E 修复 10 个缺陷后的提交）

---

## 一句话现状

计划的 **Task 1-10 已完成并提交**（`cluster-config.sh` 665 行，spec 第 4 节的 9 步流程全部实现）。
剩余 **Task 11-14**：Docker E2E、跑 E2E 修问题、文档、最终检查。
主脚本末尾已无 `die "not implemented yet"` 占位。
主脚本目前到「解析配置 + CLI + dry-run + 凭证收集（env 优先 + 交互回退）」，末尾留了一行占位：

```
(占位已删除 —— Task 7-10 实现了 preflight / 建目录 / 下发 / 启动 / 建集群)
```

---

## 文档位置

| 文档 | 路径 |
|---|---|
| 规格 | `docs/superpowers/specs/2026-10-13-redis-cluster-config-script-design.md` |
| 实施计划（14 个 Task） | `docs/superpowers/plans/2026-10-13-redis-cluster-config-script.md` |

规格与计划均已按「脚本建目录、流程 9 步」的决策同步过（提交 `a68d7dd`、`75442ed`）。

---

## 已完成的 Task

| Task | 内容 | 关键提交 |
|---|---|---|
| 1 | `cluster.conf.example` + `.gitignore` | `88c7c46` |
| 2 | `lib/conf.sh` 解析器 + 6 个测试 | `eb47fe4` |
| 3 | 追加 10 个错误处理/安全性测试 | `30c9902` |
| 4 | 渲染契约测试（守 D8 回归） | `3ccf63d` |
| 5 | `cluster-config.sh` 骨架：CLI + 配置加载 + dry-run | `417903b` |
| 6 | 凭证收集（env 优先 + 交互回退）+ `--print-credentials` | `a2f524d` |
| 7 | preflight（二进制 + redis 用户）+ 建运行时目录 | `0dc133c` |
| 8 | 下发 `auth.conf` + `redis.conf` + systemd unit | `9eafa0e` |
| 9 | 启动 + PING 验证 + 失败诊断 | `052aaa4` |
| 10 | `redis-cli --cluster create` + 健康检查 | `8a71347` |

---

## 提交清单（22 个，按时间倒序）

```
8a71347 feat(cluster-config): create cluster and verify health
052aaa4 feat(cluster-config): start instances and verify with PING plus diagnostics
9eafa0e feat(cluster-config): deploy auth.conf, redis.conf and systemd units
0dc133c feat(cluster-config): preflight binaries/user, then create runtime dirs
a2f524d feat(cluster-config): env-first credential resolution with interactive fallback
d27e6a2 fix(config_gen): escape sed metacharacters in every interpolated field
417903b feat(cluster-config): add CLI, config loading and dry-run
3ccf63d test(config): add render contract tests guarding REDIS_PREFIX propagation
75442ed docs(plan): align Task 7-9 with the 9-step spec
a68d7dd docs(spec): script creates runtime directories; renumber steps to 9
413e7ea fix(conf): reject configs whose values would fail silently
eacbfe7 fix(conf): reject node groups that collide on env var prefix
2631c3c fix(conf): reject misspelled section names and dedupe unknown keys
0459b38 chore(gitattributes): drop the out-of-scope cluster.conf* LF rule
bcdc6ee docs(example): correct the 3-master note in cluster.conf.example
fec99a8 fix(conf): drop the config-file replicas key and reject empty port lists
db6c5de fix(gitattributes): force LF for *.bash
30c9902 test(conf): cover parse errors, unknown keys and injection safety
eb47fe4 feat(conf): add INI-style cluster.conf parser
88c7c46 chore: add cluster.conf.example and ignore cluster.conf
```

---

## 剩余 Task

| Task | 内容 | 依赖真实 SSH？ |
|---|---|---|
| 11 | Docker E2E 脚本（**尚未开始**） | — |
| 12 | 跑 E2E 并修复发现的问题 | — |
| 13 | README / USAGE 文档 | — |
| 14 | 最终集成检查 | — |

Task 7-10 的代码已完成，但**全部只做过静态验证，一次真实 SSH 都没跑过**。
Task 11/12 的 E2E 是唯一能验证它们的手段。

---

## 当前测试基线

改动前先跑一遍这个基线，改完对比：

| 命令 | 预期结果 |
|---|---|
| `bats tests/lib/*.bats` | **105 通过 / 0 失败** |
| `bats tests/cluster_config.bats` | **16 通过 / 0 失败** |
| `bats tests/*.bats` | （与 lib 合计 **143 通过 / 0 失败**） |
| `find tests -name '*.bats' -print0 \| xargs -0 bats` | **143 通过 / 0 失败**（CI 调用方式） |
| `bash tests/check_syntax.sh` | `TOTAL=30 FAIL=0` |
| `bash tests/validate_libs.sh` | `PASS=50 FAIL=0` |

---

## 环境约束（换机器/换会话必读）

### bash 必须走 Docker

宿主机 `bash.exe` 是 WSL shim，会报 `Bash/Service/0x8007274c`。
**所有 bash 执行必须在容器内**：

```powershell
$wt="C:\Users\蔡Rei\.local\share\opencode\worktree\3e438c\cluster-config-script"
$tmp="C:/Users/蔡Rei/AppData/Local/Temp/opencode"
docker run --rm -v "${wt}:/repo" -w /repo rc-control:bats bash -c "bats tests/cluster_config.bats"
```

### 镜像

| 镜像 | 状态 | 内容 |
|---|---|---|
| `rc-control:bats` | **已构建，可直接用** | Ubuntu 22.04 + bats 1.2.1 + sshpass + redis-tools |
| `rc-control:local` | 已构建 | 同上但**不含 bats** |
| `rc-node:local` | ⚠️ **已丢失，需重建** | Ubuntu 22.04 + sshd + systemd + build-essential（Task 11 需要） |

> `rc-node:local` 在 2026-10-13 接手时已不在本机，只剩 `rc-control:*`。
> Task 11 开工前必须重建（走 `docker.m.daocloud.io` 镜像源）。

> `rc-control:bats` 是 subagent 在临时目录里用 `FROM rc-control:local` + `apt-get install bats` 建的，
> **Dockerfile 不在仓库里**。镜像若丢失，需重建：
> ```bash
> printf 'FROM rc-control:local\nRUN apt-get update -qq && apt-get install -y -qq bats && rm -rf /var/lib/apt/lists/*\nWORKDIR /repo\n' > Dockerfile.bats
> docker build -f Dockerfile.bats -t rc-control:bats .
> ```

### Docker Hub 被阻断

拉镜像要走镜像源（已验证可达）：`docker.m.daocloud.io`。
计划 Task 11 的 Dockerfile 里已经写了 `FROM docker.m.daocloud.io/library/ubuntu:22.04`。

### 宿主机资源有限

2 vCPU / 2 GB。**跑不动 Redis 源码编译**（LTO + `-g3` 会拖垮 Docker 引擎导致 HTTP 500）。
E2E 必须预置二进制跳过编译 —— 这正是 `cluster-config.sh` 的前提条件，不影响其验证目标。

### 写文件必须用编辑工具

PowerShell 的 `Out-File` / `Set-Content` / `echo >>` 会引入 BOM 或 CRLF，bash 立刻挂。

### 不要用内联 `bash -c '...'` 处理复杂脚本

PowerShell 会破坏嵌套引号和 `${...}` 展开。写成 `.sh` 文件挂载进容器执行：

```powershell
docker run --rm -v "${wt}:/repo" -v "${tmp}:/v" -w /repo rc-control:bats bash /v/yourscript.sh
```

### `die` 会终止整个 shell

`lib/common.sh` 的 `die` 调用 `exit`，**即使在 `if foo; then` 条件里也会杀掉整个脚本**。
`if` 只屏蔽 `set -e`，挡不住 `exit`。
探测失败分支时必须放进子 shell 或命令替换，否则脚本会在第一次 die 时静默中断，表现为「输出被截断」。

---

## 过程中踩过的坑（避免重蹈）

### 已修复但值得记住的

1. **`sed` 替换侧元字符**（`d27e6a2`）：值插进 `sed s|X|Y|` 的 `Y` 侧必须转义 `&`、`|`、`\`。
   `lib/systemd.sh` 早就转了，`lib/config_gen.sh` 漏了，导致
   `a&b → a%PASSWORD%b`、`a\b → ab`、`a|b → sed 直接报错`。
   **新增字段时记得两边同步。**

2. **未加引号的 `IFS=','` 数组展开会触发 glob**（`413e7ea`）：
   `ports = *` 被展开成当前目录所有文件名，解析结果依赖 CWD。
   正确写法：`IFS=',' read -r -a arr <<< "$var"`。

3. **bats 1.2.1 没有 `$stderr`**（Ubuntu 22.04 的 apt 版本）：
   `run` 把 stderr 合并进 `$output`。要区分流必须显式重定向到文件。

4. **`$status` 只在 `run` 之后有效**：测试体里直接调 `parse_conf` 后断言 `$status` 会报
   `[: : integer expression expected`。但**不能**改成 `run`，因为 `run` 用命令替换捕获输出，
   会把 `CONF_*` 全局变量一起丢掉。

5. **`.gitattributes` 漏 `*.bash`**（`db6c5de`）：`tests/setup.bash` 在 `autocrlf=true` 的
   Windows 上检出为 CRLF，**所有 bats 测试无法加载**（status 127）。

6. **`local v="$(cmd)"` 会吞掉退出码**（`a2f524d`）：实测确认
   `local v="$(false)"` 永远返回 0，而裸赋值 `v="$(false)"` 会把非零状态传出去，
   在 `set -e` 下**直接杀掉整个脚本**。计划里 Task 6 的
   `CRED_PASS[$i]="$(read_secret ...)"` 正是裸赋值 → 密码环境变量缺失且无 TTY 时
   会**静默 exit 1，一行错误都不打印**。已改成 `elif pass_var="$(...)"; then` 形式。
   同理，`if foo; then` 这种「被测试」上下文里 bash 会**关闭 errexit**，
   写探针脚本验证时别被这个骗了。

7. **bats 测试体在 `set -e` 下运行**：`out="$(cmd)"` 里 cmd 失败会**中止整个测试**，
   后面的 `rc=$?` 根本执行不到。要断言非零退出码必须写 `out="$(...)" || rc=$?`。

8. **`PROMPT_NO_TTY=1` 时 prompt 读 stdin**：bats 若继承了终端 stdin，
   `read` 会**永久阻塞**。测试里凡触发 prompt 的调用都必须 `</dev/null`。

9. **远端 heredoc 脚本 `bash -n` 查不出来**（Task 7-10）：bash 只把 heredoc
   当**文本**处理，`bash -n cluster-config.sh` 永远不会发现远端脚本里的语法错误。
   必须用 `sed` 把 `<<'DELIM'` 与 `DELIM` 之间的内容抽出来单独 `bash -n`。
   当前共 **9 段**远端脚本：PREFLIGHT / DIRS / AUTHREMOTE / DEPLOYREMOTE /
   PING / STARTREMOTE / DIAG / CLINFO / CREATE。

10. **远端脚本必须检查 `ssh_run` 退出码**（Task 7-10）：计划里几乎所有
    `ssh_run ... <<'REMOTE'` 都**没有检查返回码**，而远端是 `set -e`。
    结果是 `mkdir` / `cp` / `systemctl` 失败后照样打印「已部署」。
    统一改成 `rc=0; ssh_run ... <<'X' || rc=$?` 再 `[ "$rc" -eq 0 ] || die`。
    **别把 `|| die` 写在 `<<'X'` 后面用反斜杠续行** —— 那样 heredoc 体
    的起始行会变得难以判断（我就被自己的校验脚本坑了一次）。

11. **绝不把密码插进远端命令字符串**（Task 9-10）：`lib/conf.sh` 只校验
    `cluster_password` 非空，**不限制字符**。形如
    `ssh_run ... "redis-cli -a '$CONF_PASSWORD' -p $p PING"` 的写法，
    密码里只要有 `'` `;` `$()` 反引号就会被**远端 shell 执行**，
    而同一脚本在这台机器上是要跑 `sudo` 的。已实测确认旧的插值写法
    真的会执行注入命令。正确做法：**当位置参数传**，远端脚本里
    `"$REDIS_CLI" -a "$CLUSTER_PASS"` 引用。已改为 `ping_instance` /
    `cluster_info_from` 两个 helper。

### 一个已确认的既有 bug（未修，需要你拍板）

`lib/cluster.sh:19` 的 `is_cluster_healthy` 把 **`cluster_known_nodes >= 6` 写死了**，
但 `lib/conf.sh` 接受 **5 个实例**的布局（`masters = (5+1)/2 = 3 >= 3`）。

实测（`known_nodes=5` 时 `is_cluster_healthy` 返回假）：

| known_nodes | 结果 |
|---|---|
| 5（conf.sh 允许的最小布局） | **永远不健康** |
| 6（标准布局） | 健康 |
| 9 | 健康 |

后果：5 实例的集群会白等 5×3=15 秒，然后死于「health check failed」。
**未修**，因为 `is_cluster_healthy` 是共享库（`status.sh` 也在用）且有既有测试，
改语义需要单独决定：应该改成对比 `CONF_TOTAL_INSTANCES` 吗？

### 待处理（审查已报告，未修）

- `unset -f` 会删掉调用方同名函数（`lib/conf.sh` 的嵌套 `_conf_flush_node` 有此问题）
- 同组内重复键静默后者覆盖前者（`host` / `ports` 都会）
- UTF-8 BOM 的配置首行解析失败，报错难懂
- `set -u` 在 bash < 4.4 下访问空数组会报错（项目声明支持 Bash 4+）

---

## 与主分支的关系

- 主仓库 `D:\work\rediscluterproject` 在 `main` = `54438d8`
- `main` 上已有：Docker E2E 的 10 个缺陷修复（`7a2b0fc`）+ spec 同步（`54438d8`）
- worktree 分支领先 22 个提交，**尚未合并**
- 建议全部 Task 完成后一次性 rebase/merge，并在主仓库跑一次全套测试

---

## 下一步具体动作

1. 执行 **Task 11**：写 Docker E2E 脚本（`scripts/e2e-cluster-config.sh` + 两个 fixture Dockerfile）。
   **前置：`rc-node:local` 镜像已丢失，先重建（走 `docker.m.daocloud.io` 镜像源）。**
2. 执行 **Task 12**：跑 E2E，修发现的问题。**Task 7-10 的代码只有这一步能真正验证。**
3. Task 13-14：文档与最终检查。

### 给下一个执行者的提醒

计划文档里 Task 7-10 的代码是写好的，但**已确认计划本身有多处错误**，
下面这些都已改（详见上面的坑位清单）：

- Task 7 的 preflight 曾是**空操作**：`MISSING_*` 标记被捕获后从未检查，
  而远端脚本恒 `exit 0`，等于一台没装 Redis 的机器会被判为通过。
- `DIRCHECK` 名不副实：注释说验证 per-port 目录，实际一个都没验。
- Task 7-10 共 4 处未加引号的 `IFS=',' x=($raw)`（`lib/conf.sh` 明令禁止的旧 bug）。
- Task 7-10 共 5 处 `ssh_run` 没检查退出码。
- Task 9-10 共 3 处密码插值进远端命令字符串（可注入，已实测）。
- 计划给的测试 3 永远不可能通过（Task 6 已修）。

结论：**不要照抄计划**。以仓库代码为准，遇到可疑之处直接改并说明。

**Task 6 阶段已确认计划文档本身有错**，改法记在这里备查：

- 计划给的测试 3 断言 `[[ "$out" != *"10.9.9.9"* ]]`（env HOST 覆盖配置 host 后，
  配置里的 host 不该出现在输出里）。**这条永远不可能通过** —— 脚本第 2 步
  `log_info` 会对每个节点打印 `CONF_NODE_HOST`（配置值），实测确认。
  已改成断言解析后的凭证行 `a: root@1.2.3.4:22`。
- 计划没给测试加 `</dev/null`，在继承了终端 stdin 的环境下会**挂死**。
- 计划说「all 11 tests pass」，但 Task 6 前已有 12 个测试，实际是 16 个。

### 一个已知的 UX 问题（本轮未改，留给你判断）

`[2/9] Resolved plan` 打印的是**配置里的** host/user/port，
而 `--print-credentials` 打印的是**解析后的**值。用了 env 覆盖时两者会不一致：

```
[INFO]    a (NODE_A) 10.9.9.9:22 ports=[6379,6380,6381]   ← 配置值
[INFO]    a: ops@10.0.0.1:2201 (password: 3 chars)        ← 实际会连的地址
```

Task 7–10 真正下发时用的是后者。要消除歧义可以把凭证收集提到第 2 步之前，
但那会让 `--dry-run` 也开始弹提示（`--dry-run` 必须在收集前退出），
所以没动。

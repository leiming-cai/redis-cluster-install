# cluster-config.sh 实施进度交接

**更新时间**：2026-10-13
**工作分支**：`feature/cluster-config-script`
**Worktree**：`C:\Users\蔡雷鸣\.local\share\opencode\worktree\3e438c\cluster-config-script`
**基线**：`main` = `7a2b0fc`（Docker E2E 修复 10 个缺陷后的提交）

---

## 一句话现状

计划的 **Task 1–5 已完成并提交**，Task 6–10 未开始。
主脚本目前只到「解析配置 + CLI + dry-run」，末尾留了一行占位：

```
die "not implemented yet: credential collection and deployment (see spec section 4)"
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

---

## 提交清单（15 个，按时间倒序）

```
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
| 6 | 凭证收集（环境变量优先 + 交互回退），新增 `--print-credentials` | 否 |
| 7 | preflight（校验二进制 + redis 用户）+ **建运行时目录** | 是 |
| 8 | 下发 `auth.conf` + 6 份 `redis.conf` + 6 份 unit | 是 |
| 9 | 启动 + PING 验证 + 失败诊断 | 是 |
| 10 | `redis-cli --cluster create` + 健康检查 | 是 |
| 11 | Docker E2E 脚本（**尚未开始**） | — |
| 12 | 跑 E2E 并修复发现的问题 | — |
| 13 | README / USAGE 文档 | — |
| 14 | 最终集成检查 | — |

Task 6 的测试不依赖 SSH，Task 7–10 只能靠 Task 11/12 的 E2E 验证。

---

## 当前测试基线

改动前先跑一遍这个基线，改完对比：

| 命令 | 预期结果 |
|---|---|
| `bats tests/lib/*.bats` | **105 通过 / 0 失败** |
| `bats tests/*.bats` | （与 lib 合计 **139 通过 / 0 失败**） |
| `find tests -name '*.bats' -print0 \| xargs -0 bats` | **139 通过 / 0 失败**（CI 调用方式） |
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
| `rc-node:local` | 已构建（525MB） | Ubuntu 22.04 + sshd + systemd + build-essential |

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

### 待处理（审查已报告，未修）

- `unset -f` 会删掉调用方同名函数（`lib/conf.sh` 的嵌套 `_conf_flush_node` 有此问题）
- 同组内重复键静默后者覆盖前者（`host` / `ports` 都会）
- UTF-8 BOM 的配置首行解析失败，报错难懂
- `set -u` 在 bash < 4.4 下访问空数组会报错（项目声明支持 Bash 4+）

---

## 与主分支的关系

- 主仓库 `D:\work\rediscluterproject` 在 `main` = `54438d8`
- `main` 上已有：Docker E2E 的 10 个缺陷修复（`7a2b0fc`）+ spec 同步（`54438d8`）
- worktree 分支领先 15 个提交，**尚未合并**
- 建议全部 Task 完成后一次性 rebase/merge，并在主仓库跑一次全套测试

---

## 下一步具体动作

1. 执行 **Task 6**：替换 `cluster-config.sh` 末尾的 `die "not implemented yet..."`，实现 `collect_credentials` + `conf_env_get` + `--print-credentials` 标志。测试不依赖 SSH，可立即验证。
2. 执行 **Task 7–10**：preflight → 建目录 → 下发 → 启动 → 建集群。这几步的远端 heredoc 脚本**建议逐个抽出来 `bash -n` 检查**。
3. 执行 **Task 11**：写 Docker E2E 脚本（`scripts/e2e-cluster-config.sh` + 两个 fixture Dockerfile）。
4. 执行 **Task 12**：跑 E2E，修发现的问题。**这是唯一能验证 Task 7–10 的手段。**
5. Task 13–14：文档与最终检查。

### 给下一个执行者的提醒

计划文档里 Task 6–10 的代码是写好的，但**我已在计划自查阶段修过几处**
（顶层 `local`、preflight 的中间版本、行号范围）。以计划文档为准，
但遇到可疑之处**直接改并说明**，不要为了对上计划而将就。

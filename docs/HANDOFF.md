# cluster-config.sh 实施进度交接

**更新时间**：2026-10-19
**工作分支**：`feature/e2e-redis-8`（**未合并**）
**主仓库**：`D:\work\rediscluterproject`
**基线**：`main` = `18dd8ef`（spec/plan 提交，之后 main 未再动）

---

## 一句话现状

**第一轮计划的 14 个 Task 全部完成并已合并进 main**（`--no-ff`，合并点 `96737d2`）。
本轮又把 `cluster-config.sh` 的 E2E 从 Ubuntu 22.04 + apt Redis 6 迁到了官方
`redis:8` 镜像（Debian 13 trixie，当前 8.10.2），149 个单元测试通过，
E2E 在 Redis 8 上端到端全绿。

**迁移过程暴露了一个真实的生产缺陷**：`ReadWritePaths=` 把 `/var/log/redis`
写成了硬性要求，而仓库里没有任何代码创建这个目录 —— 单元直接以
`status=226/NAMESPACE` 启动失败。已由提交 `32ac923` 修复。

**下一步**：本轮工作**在 `feature/e2e-redis-8` 分支上，尚未合并**。
main 自 `18dd8ef`（spec/plan）之后未再改动。合并方式与上一轮相同：
`git merge --no-ff feature/e2e-redis-8`，合并前用 `git merge-tree` 预检。

---

## 文档位置

| 文档 | 路径 |
|---|---|
| 规格（cluster-config.sh） | `docs/superpowers/specs/2026-10-13-redis-cluster-config-script-design.md` |
| 实施计划（14 个 Task） | `docs/superpowers/plans/2026-10-13-redis-cluster-config-script.md` |
| 规格（E2E 迁 Redis 8） | `docs/superpowers/specs/2026-10-19-e2e-on-redis-8-design.md` |
| 实施计划（Redis 8 迁移） | `docs/superpowers/plans/2026-10-19-e2e-on-redis-8.md` |

第一轮的规格与计划均已按「脚本建目录、流程 9 步」的决策同步过
（提交 `a68d7dd`、`75442ed`）；Redis 8 迁移这一轮的 spec / plan 见上表。

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
| 11 | Docker 双节点 E2E + 两个 fixture Dockerfile | `f18302d` |
| 12 | 跑通 E2E 并修掉它发现的缺陷 | `2eb4aee`（含 chown 缺陷） |
| 13 | README + USAGE 文档 | `50e83bb` |
| 14 | 最终集成检查 + 清理误提交文件 | `95e47ab` |

### 第二轮：E2E 迁到 Redis 8（`feature/e2e-redis-8`，未合并）

| 步骤 | 内容 | 关键提交 |
|---|---|---|
| A | spec：把 E2E 挪到 `redis:8`、镜像源做成可覆盖的 build arg | `272a7fc`、`8d044df`、`7a3edc6` |
| B | plan：实施计划 | `18dd8ef` |
| C | 节点 fixture 底包换 `redis:8` | `7c357f9` |
| D | 控制端 fixture 底包换 `redis:8` | `f32de66` |
| E | `provision()` 改成用镜像自带的二进制，删掉运行期 `apt-get` | `8671bd5` |
| F | 脚本先断言节点确实是 Redis 8，不是就直接失败 | `0611710` |
| G | DoD5 改成真正观测**副本被提升** | `917fff1` |
| H | **生产修复**：`ReadWritePaths=` 五项全部加 `-` 前缀 | `32ac923` |
| I | 文档同步（USAGE / VERIFICATION / HANDOFF） | 本次提交 |

---

## 提交清单（按时间倒序）

### `feature/e2e-redis-8`（相对 `main` = `18dd8ef`，10 个提交，**未合并**）

```
32ac923 fix(cluster-config): make every ReadWritePaths entry optional
917fff1 fix(e2e): make the DoD5 promotion check actually observe a promotion
0611710 test(e2e): refuse to run unless the nodes are actually Redis 8
4fc12d8 docs: the 0770+setgid /etc/redis shape is not apt's doing
8671bd5 test(e2e): provision from the image instead of a runtime apt-get
b0579b5 test(e2e): explain the control fixture's choices in-file
0dc6974 docs: drop the procps claim; it is not in the redis:8 base
f32de66 test(e2e): run the control fixture on redis:8 too
4b24b14 docs: correct two claims that measurement disproved
7c357f9 test(e2e): run the node fixture on redis:8 instead of an apt redis 6
```

### 已合并进 main 的部分（上一轮，22 个）

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

## 本轮状态

上一轮 14 个 Task **全部完成并已合并**（`--no-ff`，合并点 `96737d2`），
Task 7-10 早已跑过真实 SSH（E2E 覆盖），不再是「只做过静态验证」的状态。

本轮（`feature/e2e-redis-8`）**没有遗留的实现任务**：spec 与 plan 的
DoD 全部达成，E2E 在 Redis 8 上端到端通过。

唯一已知遗留是下面「已知问题」里的 `add-node.sh:141` —— 它属于生产代码，
**本轮范围内刻意没有修**。

---

## 当前测试基线

改动前先跑一遍这个基线，改完对比：

| 命令 | 预期结果 |
|---|---|
| `bats tests/lib/*.bats tests/*.bats` | **149 通过 / 0 失败** |
| `find tests -name '*.bats' -print0 \| xargs -0 bats` | **149 通过 / 0 失败**（CI 调用方式） |
| `bash tests/check_syntax.sh` | `TOTAL=30 FAIL=0` |
| `bash tests/validate_libs.sh` | `PASS=50 FAIL=0` |
| `bash scripts/e2e-cluster-config.sh` | `E2E PASSED`，退出码 0（需 Docker，见下） |

> 149 是本轮 `32ac923` 补了渲染契约测试之后的数字（上一轮是 148）。

---

## 环境约束（换机器/换会话必读）

### bash 必须走 Docker

宿主机 `bash.exe` 是 WSL shim，会报 `Bash/Service/0x8007274c`。
**所有 bash 执行必须在容器内**：

```powershell
$wt="D:\work\rediscluterproject"
$tmp="C:/Users/蔡雷鸣/AppData/Local/Temp/opencode"
docker run --rm -v "${wt}:/repo" -w /repo rc-control:bats bash -c "bats tests/cluster_config.bats"
```

### 镜像

| 镜像 | 状态 | 内容 |
|---|---|---|
| `rc-control:bats` | **已构建，可直接用** | Ubuntu 22.04 + bats 1.2.1 + sshpass + redis-tools |
| `rc-control:local` | 已构建 | 同上但**不含 bats** |
| `rc-node:local` | ❌ 已丢失，**且并不需要** | — |

### E2E 用的镜像（都在本机）

| 镜像 | 用途 |
|---|---|
| `rc-e2e-node:local` | E2E 节点：**官方 `redis:8`（Debian 13 trixie，当前 8.10.2）** + sshd + systemd + sudo |
| `rc-e2e-control:local` | E2E 控制端：同样基于 **`redis:8`**，另加 sshpass + openssh-client |
| `rc-e2e-runner:local` | **仅本机需要**：带静态 docker CLI，用来在容器里驱动上面的镜像 |

> **底包换过了**：上一轮节点镜像是 `Ubuntu 22.04 + sshd + systemd + build-essential`，
> 里面装的是 apt 的 Redis 6 —— 也就是说**仓库宣称支持 Redis 8，E2E 却从没跑过 Redis 8**。
> 现在两个 fixture 都基于官方 `redis:8`，Redis 二进制随镜像而来，
> **不再有运行期 `apt-get`**（`8671bd5`），也**不再需要 build-essential**（不编译源码）。
>
> 控制端也换掉是有理由的：`cluster-config.sh` 会在本地 PATH 上找到 `redis-cli` 时
> 用它跑 `--cluster create`，apt 的 Redis 6 与节点的 Redis 8 存在版本错配，
> 之前一直没被测到。
>
> `rc-e2e-node:local` 与 `rc-e2e-control:local` **不需要手工构建** ——
> `scripts/e2e-cluster-config.sh` 每次运行都会自己 `docker build` 这两个镜像。

> **`rc-node:local` 其实不是 Task 11 的前置** —— Task 11 自带
> `Dockerfile.node.e2e`，直接从镜像源构建 `rc-e2e-node:local`，用不到那个丢失的镜像。
> 之前 HANDOFF 把「重建 rc-node:local」列为前置是判断错了。

### 在这台机器上跑 E2E 的方式

宿主机**没有可用 bash**（Git Bash 不存在，`bash.exe` 是坏的 WSL shim），
而 E2E 是 bash 脚本且要用 `docker` 编排容器。必须套一层：

```powershell
$wt="D:\work\rediscluterproject"
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock `
  -v "${wt}:/repo" -e E2E_HOST_REPO="${wt}" `
  rc-e2e-runner:local bash /repo/scripts/e2e-cluster-config.sh
```

`rc-e2e-runner` 的 Dockerfile 不在仓库里（`%TEMP%\opencode\Dockerfile.e2erunner`）。
镜像丢失时用阿里云静态 docker CLI 重建：

```dockerfile
FROM docker.m.daocloud.io/library/ubuntu:22.04
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
        ca-certificates curl bash coreutils grep gawk sed diffutils \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL -o /tmp/d.tgz https://mirrors.aliyun.com/docker-ce/linux/static/stable/x86_64/docker-24.0.9.tgz \
 && tar -xzf /tmp/d.tgz -C /tmp && install -m 0755 /tmp/docker/docker /usr/local/bin/docker \
 && rm -rf /tmp/docker /tmp/d.tgz
```

⚠️ **`docker.m.daocloud.io` 没有 `docker:cli` 镜像**（拉取报 502），所以只能自己构建。

⚠️ **注意镜像里有什么**：跑 bats 用 `rc-control:bats`，跑 git 用宿主 PowerShell。
**不要用 `rc-e2e-runner` 跑测试** —— 它既没有 bats 也没有 git，会报
「0 个测试 0 个失败」和「git: command not found」，看着像通过其实什么都没做。

> `rc-control:bats` 是 subagent 在临时目录里用 `FROM rc-control:local` + `apt-get install bats` 建的，
> **Dockerfile 不在仓库里**。镜像若丢失，需重建：
> ```bash
> printf 'FROM rc-control:local\nRUN apt-get update -qq && apt-get install -y -qq bats && rm -rf /var/lib/apt/lists/*\nWORKDIR /repo\n' > Dockerfile.bats
> docker build -f Dockerfile.bats -t rc-control:bats .
> ```

### Docker Hub 被阻断

拉镜像要走镜像源（已验证可达）：`docker.m.daocloud.io`。
两个 fixture 的 Dockerfile 里已经写了 `FROM ${REGISTRY}/redis:8`，
`REGISTRY` 是 build arg，默认 `docker.m.daocloud.io/library`。
换源用环境变量即可，不用改文件：

```bash
E2E_REGISTRY=docker.1ms.run/library bash scripts/e2e-cluster-config.sh
```

### 宿主机资源有限

2 vCPU / 2 GB。**跑不动 Redis 源码编译**（LTO + `-g3` 会拖垮 Docker 引擎导致 HTTP 500）。
E2E 不编译 Redis —— 二进制直接来自 `redis:8` 镜像，
这正是 `cluster-config.sh` 的前提条件，不影响其验证目标。

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

### 已修复（Task 12 用 E2E 发现的）

11. **父目录不 chown**（`2eb4aee`）：`create_dirs` 只 chown `/etc/redis/cluster`，
    不管它的**父目录** `/etc/redis`。当父目录是 `0770 redis:redis` 且带 setgid 时，
    redis 用户一旦被重建（容器重建、从备份恢复）拿到新 uid，父目录还挂在旧 uid 上，
    新 redis **无法穿越 0770 目录** —— 哪怕下面每个文件的归属都完全正确，
    依然报 `Fatal error, can't open config file ...: Permission denied`。

    > 更正：本条原先写「apt 装出来的是 `0770 redis:redis` 且带 setgid」，**这是错的**。
    > 实测 `redis-server 6.0.16-1ubuntu1.2`（Ubuntu 22.04）与 `7.0.15-1~deb12u10`
    > （Debian bookworm）都把 `/etc/redis` 装成 `0755 root:root`，且 postinst 完全
    > 不碰它。缺陷本身真实、修复也仍然必要（该形态见于其它打包方式与手工规划的机器），
    > 但来源不是 apt。
    这是最难查的一类：看起来一切正常，就是打不开。
    **只有真实跑一遍才会暴露，149 个单元测试全都测不到**（只在 uid 变化时触发）。
    `/var/lib/redis`、`/var/run/redis` 同理，已一并修。

12. **`is_cluster_healthy` 写死 `known_nodes >= 6`**（`1df5075`，已修）：
    但 `lib/conf.sh` 接受 5 实例布局（`ceil(5/2)=3`），那种集群报 `known_nodes:5`，
    健康检查**永远过不了**。已改成可选入参、默认仍是 6（`status.sh` 行为不变），
    `cluster-config.sh` 传 `CONF_TOTAL_INSTANCES`。

### 已修复（Redis 8 迁移这一轮用 E2E 发现的）

13. **`ReadWritePaths=` 把路径写成了硬性要求**（`32ac923`）：这是**真实的
    生产缺陷**，不是测试问题。

    **症状**：单元启动即失败，`status=226/NAMESPACE`，redis-server 根本没跑起来。
    systemd 的 `ReadWritePaths=` 里，**不带 `-` 前缀的条目是硬性要求** ——
    路径一旦不存在，systemd 直接拒绝启动该单元。

    **根因**：`config/redis-cluster.service.template` 把 `/var/log/redis` 列了进去，
    而**仓库里没有任何代码创建这个目录**：
    `cluster-config.sh` 的 `create_dirs` 不建，`install.sh` 的源码编译路径也不建
    （只有 `scripts/smoke-test.sh` 建，而它不是部署路径）。
    在**没装过发行版 redis 包**的机器上，这个目录从来就不存在 ——
    之前的 E2E 用的 Ubuntu 22.04 底包正好自带了 apt 装的 redis 6，
    顺手把 `/var/log/redis` 一起装了出来，**把这个 bug 掩盖住了**。

    **修复**：五个条目全部加 `-` 前缀（systemd 的「该路径不存在就忽略」标记）。
    Debian/Ubuntu 自己的 `redis-server.service` 五项也全带 `-`，原因相同。

    **怎么发现的**：**第一次把 E2E 跑在 Redis 8 上**的时候。
    底包从 `ubuntu:22.04 + apt Redis 6` 换成官方 `redis:8`（镜像里根本没有
    `/var/log/redis`），这个缺陷才第一次现形。
    **单元测试一个都测不到** —— 它们只比较渲染出来的文本，
    而渲染出来的文本当时是对的（缺的是目录，不是配置）。

    > 这是「换了底包才暴露旧缺陷」的又一例：**绿色的测试不代表配置是对的**。
    > 和下面 DoD5 那条「旧判定一直是绿的，但它从没观测过提升」是同一类错误。

14. **DoD5 的提升判定一直在误报通过**（`917fff1`）：旧判定轮询
    `$1==victim && $3 ~ /master`，但受害者在被杀**之前就已经是 master**，
    死掉之后那一行只是多了一个 `fail` 标志，`$3` 里仍然含 `master` ——
    条件在 `systemctl stop` 返回的瞬间就成立了，**从来没观测过副本被提升**。
    现在先按 `$4==victim_id`（第 4 个字段是 master id）定位**副本**，
    再等**副本自己**的 flags 里不再含 `slave`/`replica`。

    同样的教训：**一个从不失败的断言等于没有断言**。

### E2E harness 自身踩过的坑（Task 11-12）

15. **`docker run` 不加 `-i` 会丢弃 stdin**：`ssh_root ... bash -s <<EOF` 的
    heredoc 根本到不了 ssh，远端收到空 stdin、exit 0、什么都没做。
    叠加 `>/dev/null` 就是**完全静默的失败**，三步之后才以一个
    指向错误方向的 preflight 报错现形。

16. **`docker build -f` 与 `docker run -v` 的路径由不同方解析**：
    build 的 `-f` 和 context 由 **CLI** 读（要容器侧路径），
    `-v` 的源由 **daemon** 解析（要宿主侧路径）。混用会报
    `unable to prepare context: path ... not found`。

17. **`redis-cli -c` 不给 `-h/-p` 会连 `127.0.0.1:6379`**：node B 上根本没有这个实例
    → Connection refused。上面那条 `SET` 同样失败却被 `>/dev/null` 藏了，
    错误报在 `GET` 上、指向错误的命令。

18. **`cluster nodes` 的主机名逗号在 `@bus-port` 之后**：
    格式是 `<id> <ip:port@bus-port[,hostname]> <flags>`，
    所以 `grep ",$IP:port@"` **永远匹配不到**。

### 这一轮反复出现的一类错误

**写下了一个自己从没执行过的假设。** 上一轮至少 5 次：
诊断探针漏写 `-v` 就宣布「路径可用」；`setpriv` 不存在却把「命令找不到」
读成「文件不可读」；上面 16/18 两条；以及给反向 preflight 用例**没有断言前置条件**
（`userdel` 因进程占用而失败、stderr 又被丢弃，于是用例以完全错误的方式「通过」）。

**Redis 8 迁移这一轮又犯了两次**：DoD5 的提升判定（上面 14 条）从来没观测过提升，
却是绿的；`ReadWritePaths` 缺目录（上面 13 条）从来没在真实部署里跑过，
单元测试也只比文本，全绿。

这类错误 149 个单元测试一个都抓不到。**判断标准是：这条代码路径被真正执行过吗？**

### 待处理（审查已报告，未修）

- `unset -f` 会删掉调用方同名函数（`lib/conf.sh` 的嵌套 `_conf_flush_node` 有此问题）
- 同组内重复键静默后者覆盖前者（`host` / `ports` 都会）
- UTF-8 BOM 的配置首行解析失败，报错难懂
- `set -u` 在 bash < 4.4 下访问空数组会报错（项目声明支持 Bash 4+）

### 已知问题（本轮发现，**未修**）

**`add-node.sh:141` 的 `chown` 会引用一个没人创建的目录。**

`add-node.sh` 的远端脚本在 `set -e` 下运行，第 139-140 行只 `mkdir -p` 了
`/var/lib/redis/cluster/${PORT}`、`/var/run/redis/cluster/${PORT}`、
`$REDIS_PREFIX/cluster/${PORT}` 和 `$REDIS_PREFIX/log` ——
**从来不创建 `/var/log/redis`**。但第 141 行是：

```bash
_sudo chown -R redis:redis /var/lib/redis /var/log/redis /var/run/redis "$REDIS_PREFIX/cluster" "$REDIS_PREFIX/log"
```

`chown` 遇到不存在的路径会**以非零退出**，在 `set -e` 下**整个脚本就此中止** ——
节点加不进去，而且报错信息指向 `chown`，完全看不出真正的原因是「目录没建」。

触发条件：**目标机器上没有 `/var/log/redis`**。
装过发行版 redis 包的机器有（apt 建的），手工规划的机器没有。

这跟 `32ac923` 修掉的那个 `ReadWritePaths` 缺陷是**同一类问题**
（列了/用了一个根本没人创建的路径），只是发生在 `add-node.sh` 而不是
systemd 单元里。

**本轮刻意没有修** —— `add-node.sh` 属于生产代码，不在
「E2E 迁移到 Redis 8」这个变更的范围里。要修的话，最小改动是
在第 139-140 行的 `mkdir -p` 里补上 `/var/log/redis`
（或者给 `chown` 加 `|| true` / 改成只 chown 已存在的路径）。

> 注意：`add-node.sh` **不在 `cluster-config.sh` 的 E2E 覆盖范围内** ——
> E2E 跑的是 `cluster-config.sh` 的 9 步流程，`add-node.sh` 是独立脚本。
> 所以这个缺陷**至今没有任何自动化测试覆盖**。

---

## 与主分支的关系

- 主仓库 `D:\work\rediscluterproject`，当前检出 `feature/e2e-redis-8`
- **上一轮**（14 个 Task）已合并进 main：`git merge --no-ff feature/cluster-config-script`（`54438d8` → `96737d2`）
  - 合并前用 `git merge-tree` 预检过，exit 0、无冲突标记；实际合并也确实干净
  - 合并后在主仓库重跑：`bats 148/0`、`check_syntax 30/0`、`validate_libs 50/0`、E2E 全绿
- **本轮**（E2E 迁 Redis 8）**在 `feature/e2e-redis-8` 分支上，尚未合并**：
  - 相对 `main` = `18dd8ef` 领先 10 个提交
  - `main` 自 `18dd8ef`（spec/plan 提交）之后**未再动过**
  - 合并方式同上一轮：`git merge --no-ff feature/e2e-redis-8`
  - 合并前同样用 `git merge-tree` 预检
- 旧的 worktree `C:\Users\蔡雷鸣\.local\share\opencode\worktree\3e438c\cluster-config-script`
  （分支 `feature/cluster-config-script`）**仍保留在原处**，内容与 main 一致，可随时清理

### 合并时处理的一件事（上一轮）

主仓库当时有一个未提交改动（`docs/superpowers/plans/...`，96 增 50 删）。
先确认它的 blob hash（`7e1d95b`）与分支上已提交的版本**逐字节相同**，
即属于重复劳动，丢弃后 `git merge` 才肯运行（git 会拒绝覆盖脏文件）。
**没有丢失任何东西。**

---

## 下一步具体动作

**本轮（Redis 8 迁移）已收尾，没有遗留的实现任务。** 剩下的动作：

1. **合并 `feature/e2e-redis-8` 进 main**（本轮工作还在线上，未合并）：
   ```powershell
   cd D:\work\rediscluterproject
   git merge --no-ff feature/e2e-redis-8
   ```
   合并前先 `git merge-tree` 预检。合并后在 main 上重跑
   `bats`（149/0）、`check_syntax`（30/0）、`validate_libs`（50/0）与 E2E。
2. **决定是否修 `add-node.sh:141`**（见上面的「已知问题」）。
   它是生产代码，本轮刻意未动。修的话最小改动是在 `mkdir -p` 里补
   `/var/log/redis`。
3. 删除旧 worktree 与 `feature/cluster-config-script` 分支
   （内容已全部在 main 上，两者均未被本轮改动）：
   ```powershell
   cd D:\work\rediscluterproject
   git worktree remove "C:\Users\蔡雷鸣\.local\share\opencode\worktree\3e438c\cluster-config-script"
   git worktree prune
   git branch -d feature/cluster-config-script
   ```
   ⚠️ **顺序有讲究**：分支正被该 worktree 检出，必须先删 worktree 再删分支，
   否则 `git branch -d` 会失败。
4. 计划文档（`docs/superpowers/plans/...`）里的代码片段与仓库现状已有出入
   （上一轮修了计划中的多处错误）。若要让它成为可信参考，需要按仓库代码回改。
5. spec §8 的 DoD 清单里，`tests/lib/preflight.bats` 计划要求存在，
   实际从未创建 —— preflight 走真实 SSH，按设计只由 E2E 覆盖，没有单元测试。

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

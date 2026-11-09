# 会话存档（2026-11-09）：把 Docker E2E 固定到「本地 Docker」，不再用 WSL 里的容器

> **这份文件是给「下一个会话」看的。**
>
> - 上一份存档：`docs/superpowers/sessions/2026-11-05-hd-three-node-redis-cluster.md`
>   （华盾三机 Redis 集群轮）
> - 本轮的产出：`scripts/e2e-local-docker.sh`（**新建**）·
>   `tests/e2e_local_docker.bats`（**新建**，7 条）·
>   `tests/check_syntax.sh`（+1 个文件）·
>   `docs/HANDOFF.md` / `docs/OPERATIONS.md` / `docs/USAGE.md` / `README.md`（更正执行环境说明）

---

## 一、一句话现状

**本轮把「Docker 一律用本地 Docker Desktop，不许用 WSL 里的 Docker」这条约束落成了代码 + 文档 + 测试。**

起因是上一轮存档里写着「**必须用 WSL 的 bash 跑**」—— 那条在 2026-11-05 是对的
（当时 Windows 侧**没有** Docker Desktop），但现在**前提变了**，照着做就会把容器建到
另一套 daemon 里。

| | 上一轮存档说的（2026-11-05） | 本轮实测（2026-11-09） |
|---|---|---|
| Windows 侧 Docker | **没有**（`docker version` 失败） | **有**：Docker Desktop **4.98.0** / Engine **29.9.2**，context `desktop-linux` |
| WSL 侧 Docker | 有（Engine **29.5.3**） | **仍有**（同一套还在） |
| 该用哪套 | WSL 那套 | **本地 Docker Desktop**（用户明确要求） |
| E2E 怎么跑 | `bash scripts/e2e-cluster-config.sh`（在 WSL 里） | **`bash scripts/e2e-local-docker.sh`** |

> 📌 **两套引擎是并存的**，实测确认：
> `docker info`（本地）→ `Docker Desktop x86_64 mem=4107382784`；
> `wsl -e docker info` → Engine **29.5.3**。
> **版本号不同 = 两个不同的 daemon**，各有各的容器清单。

---

## 二、🔴 本轮修掉的那个问题：MSYS 路径转换在两处要求相反

### 2.1 现象

在 Windows 上用 Git Bash 直接跑 `bash scripts/e2e-cluster-config.sh`，**失败**：

```
ERROR: failed to build: unable to prepare context: path "/d/work/rediscluterproject" not found
FAIL: node image build failed (registry: docker.m.daocloud.io/library)
```

### 2.2 根因（实测，不是推断）

**两个不同的进程解析两种路径，而它们在 Windows 上要的路径语法是相反的**：

| 路径 | 谁解析 | 要求 | 实测 |
|---|---|---|---|
| `docker build <上下文>` | **CLI**（Windows 原生程序） | MSYS 转换**开** | 转换开 ⇒ `/d/work/...` → `D:\work\...` ⇒ ✅ 构建成功 |
| `docker run -v <源>:<目标>` | **daemon** | MSYS 转换**关** | 转换开 ⇒ `:目标` 被改写成 `D:/Program Files/Git/repo` ⇒ ❌ **挂载静默变空**（`ls: cannot access 'D:/Program Files/Git/repo'`） |

**两个设置互斥**：为救 `-v` 而设 `MSYS_NO_PATHCONV=1`，`docker build` 立刻报
`path "/d/work/rediscluterproject" not found`。

> 📌 **这就是仓库里 `REPO_ROOT` / `E2E_HOST_REPO` 两个变量存在的原因** ——
> 它们的分工正是「**给 CLI 看的路径**」与「**给 daemon 看的路径**」。
> `scripts/e2e-cluster-config.sh` 的注释里写得很清楚：
> "`docker build` 读 Dockerfile **和打包上下文都用 CLI**，
> 所以这两个必须是**跑脚本那台机器**能看见的路径；
> `docker run -v` 不同 —— **由 DAEMON 解析**，所以那个需要 `HOST_REPO`。"
>
> ⇒ **解法不是与 MSYS 缠斗，而是把脚本放进一个带 docker CLI 的容器里跑** ——
> 容器内是 Linux 路径语义，冲突消失：
> - `REPO_ROOT`（`/repo`）→ 给 **CLI**（`docker build` 的上下文）
> - `E2E_HOST_REPO`（`D:/work/rediscluterproject`）→ 给 **daemon**（`docker run -v` 的源）

### 2.3 修法

**新增 `scripts/e2e-local-docker.sh`**：它把上面的组合包起来，并且**先校验引擎身份再动手**。

| 设计点 | 为什么 |
|---|---|
| `docker info --format '{{.OperatingSystem}}'` 先查引擎 | 问的是**引擎**（不是客户端）—— 容器最终建在谁那里 |
| 不是 `Docker Desktop` ⇒ **硬失败**、**不建任何容器** | 「另一个 daemon」的错误一旦发生，容器就散在看不见的地方了。**必须在动手前拦住** |
| 引擎不认识的**严重级别**：警告会被 200 行日志刷过去 | 存档 §三 记过这个教训（措辞的严重级别是结论的一部分） |
| 顺带检查 runner 镜像**有没有 docker CLI** | 否则 E2E 会在容器里报 `docker not found` —— 离真正的原因十万八千里 |
| `E2E_LOCAL_DOCKER_ENGINE` 可覆盖 | 不把某一个品牌字符串写死成唯一答案 |

---

## 三、验证（全部实测）

### 3.1 Docker E2E —— **在本地 Docker Desktop 上跑通**

```bash
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  -v "D:/work/rediscluterproject:/repo" -e E2E_HOST_REPO="D:/work/rediscluterproject" \
  -w /repo rc-e2e-runner:local bash scripts/e2e-cluster-config.sh
```

**结果：`=== E2E PASSED ===`，退出码 0。**

| 断言 | 实测输出 |
|---|---|
| Redis 版本 | 两节点均 `v=8.10.3` |
| DoD1 | 6 实例全部 `PONG` |
| DoD2/3 | `cluster_state:ok` / `cluster_slots_assigned:16384` / `cluster_known_nodes:6` |
| DoD4 | `A->B OK` / `B->A OK` |
| **A0** | `OK masters: 172.23.0.2:6379 172.23.0.2:6380 172.23.0.3:6382` + `OK replicas match the plan` |
| A1 / A2 | 每个 master 1 个副本；副本与 master 异机 |
| **A3** | 脆弱主机打印 `STOPS serving`、受保护主机打印 `refuses every write once the failure is detected` |
| DoD7 | `idempotency OK`（`Cluster already healthy — skipping create`） |
| preflight 负例 | `MISSING_USER: redis`（uid 999 → 995，父目录悬空的情形是活的） |
| **DoD5** | `promotion OK` / `cluster_state:ok` |
| **A5** | `OK: the cluster refuses writes (CLUSTERDOWN The cluster is down)` |
| **A4** | `OK: the cluster kept serving` |
| **A6** | `OK: 39 writable / 21 refused of 60 keys` + `cluster_state: cluster_state:ok` |

> 📌 **A6 的 `keeps serving (degraded)` 措辞在本地引擎上也真的打印出来了**（`no` 覆盖率的受保护那台），
> 不是空跑。

### 3.2 无残留

| 检查 | 结果 |
|---|---|
| 本地 Docker 的 E2E 容器/网络 | **0 个**（`e2e-node-*`、`rc-cfg-net` 都已清） |
| **WSL 侧引擎的容器** | **0 个** —— 本轮**一个容器都没建在 WSL 里** |

### 3.3 测试

| 检查 | 结果 |
|---|---|
| `tests/e2e_local_docker.bats` | **7 通过 / 0 失败** |
| **变异检验** | **6 个变异全部让对应的用例变红**（详见下） |
| 全量 bats（CI 等价，递归） | **224 通过 / 0 失败**（基线 216 → +8） |
| `tests/check_syntax.sh` | **`TOTAL=49  FAIL=0`**（47 → 49：新脚本 + 新 bats 文件） |

### 3.4 ⭐ 变异检验（每一条断言都是承重的）

| 变异 | 变红的用例 |
|---|---|
| 去掉 docker socket 挂载 | `mounts the docker socket` |
| `E2E_HOST_REPO` 传 Linux 路径 | `passes the daemon-visible repo path` |
| 仓库挂载用 daemon 解析不了的路径 | `passes the daemon-visible repo path` |
| 容器里跑错脚本 | `runs the E2E script itself inside the runner` |
| 去掉引擎校验（接受任何引擎） | `refuses to run against a non-local engine` |
| 去掉 runner 镜像的 docker CLI 预检 | `runner image has no docker CLI` |

> 📌 **这 6 个变异不是一次过的**。第一版变异脚本**自己**有 bug：
> ① 用 `sed` 做替换，表达式里的 `)`/反斜杠被 sed 吃掉 ⇒ 「mutation target not found」；
> ② 匹配 `not ok` 用**整行锚定正则** + **部分测试名** ⇒ **永远匹配不上**，
> 于是 6 个变异全被误判成「断言是空转的」。
> **实际测下来：变异确实生效、测试确实变红** —— 是**检验工具**错了，不是断言错了。
> ⇒ 与本项目反复出现的那条教训同源：**「结论对」不等于「过程对」**。
> 最后改用 Python 按**精确字符串**替换 + **子串**匹配 `not ok` 行。

---

## 四、本轮改了什么

| 文件 | 改动 |
|---|---|
| **`scripts/e2e-local-docker.sh`**（**新建**） | 引擎校验 + 路径分工 + runner 预检，然后跑 E2E |
| **`tests/e2e_local_docker.bats`**（**新建**，7 条） | 用 **docker stub 记录 argv**，断言「**实际传了什么**」而不是「源码里有没有这几个字」 |
| `tests/check_syntax.sh` | 把新脚本纳入语法检查（TOTAL 47 → 49） |
| `docs/HANDOFF.md` | 「环境约束」章节**新增**一节「🔴 Docker 一律用本地 Docker Desktop」；更正「跑 E2E 的方式」 |
| `docs/OPERATIONS.md` | §6.2 脚本清单加新脚本 + 一段「为什么不能直接跑」 |
| `docs/USAGE.md` | §5.7.7 与 §12 改用新入口 + 说明 |
| `README.md` | 脚本清单 + 用法 + 「已知限制」里的 WSL 那条 |
| `docs/superpowers/sessions/2026-11-05-...md` | §二·五**加更正横幅**（那句「必须用 WSL 的 bash 跑」已失效） |
| `docs/superpowers/plans/2026-11-05-...md` | 同上 |

---

## 五、⚠️ 这一轮**没有**做的事（明确记下来）

| # | 事 | 为什么 |
|---|---|---|
| 1 | **没有改 `scripts/e2e-cluster-config.sh`** | 它**本来就是对的** —— `REPO_ROOT`/`E2E_HOST_REPO` 的分工早就写好了。本轮只是**把调用方式包起来** |
| 2 | **没有改 `scripts/e2e-cpsweb-nodes.sh` / `e2e-kafka-cluster.sh`** | 它们有同样的路径问题，但本轮**没实测过**它们在本地引擎上的行为 ⇒ 按本项目规矩，**没跑过的不写成规则**。下一轮若要用，同样套 `e2e-local-docker.sh` 的模式 |
| 3 | **没有删掉 WSL 里的 Docker Engine** | 它可能是别的项目在用。**本项目只是不用它** |
| 4 | **没有把 `rc-e2e-runner` 的 Dockerfile 进仓** | 它**本来就不在仓库里**（HANDOFF 记着在 `%TEMP%\opencode\`）。本轮**没重建镜像**，不需要动它 |
| 5 | **没有改 CI** | CI 在 Linux runner 上，`e2e-cluster-config.sh` 直接跑即可 |

---

## 六、给下一轮的一句提醒

> 📌 **「两套 Docker 并存」这件事本身值得记住。**
>
> 本机同时有：
> - **本地 Docker Desktop**（Engine 29.9.2）—— context `desktop-linux`，npipe
> - **WSL2 里的独立 Engine**（29.5.3）—— unix socket
>
> 它们**看起来都能用**（`docker` 命令在两边都通），但**容器清单是分开的**。
> 选错了不会报错，只会在**你看不见的地方**多出一堆容器。
>
> ⇒ **`scripts/e2e-local-docker.sh` 里的引擎校验不是多余的仪式，是这个陷阱的唯一防线。**
> 下一个会话如果要在本机起容器，**先确认用的是哪一套**。

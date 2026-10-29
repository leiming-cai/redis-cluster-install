# cluster-config.sh 实施进度交接

**更新时间**：2026-10-29
**工作分支**：无 —— 第七~十六轮都在 `main` 上，**全部已推送**
**主仓库**：`D:\work\rediscluterproject`
**基线**：`main` = `origin/main`（`git status -sb` 无 ahead/behind）；第十三轮已推送
（`521f244..aadcbb9`）；**第十四轮又推了 `80ad557`**（修 `check-bash-compat.sh`
的假红 + 4 条回归测试）、**`9b4f040`**（CI 覆盖面缺口）、
**`fdd3193`**（真集群测试 + jedis 版本上限）、**`6e86496`**、
**`09e080a`**（会话存档）；**第十六轮推了 `9be5aec`**（CI 语法覆盖面 15→28）、
**`c873d04`/`da93756`**（合并两套 RedisUtil 的设计与计划）、
**`ba5b0f6`**（计划进度）、**`389547b`**（**第十六轮的代码 + patch + 文档**）。
当前 bats **203 通过 / 0 失败**，E2E `E2E PASSED`（退出码 0），
`oms` **66 通过 / 0 失败 / 0 跳过**（含 3 条新增的真集群用例），
`idgenerator` **6 通过 / 0 失败**（第十五轮 3 条 + 第十六轮 3 条），
`rtdata-module` **14 通过 / 0 失败**

> **⭐ 2026-10-29 会话复核（第十六轮：合并两套 `RedisUtil`）**
>
> 这一轮把**两套** `RedisUtil` 合成一套，并把 `common/idgenerator → realserver/oms`
> 这条**反方向的依赖彻底去掉**。
>
> **先纠正交接文档里的一处说法**：它写的是「合并**三套** `RedisUtil`
> （oms / idgenerator / modelserver 各一份）」。**实际只有两套** ——
> modelserver 没有第三份，它经 idgenerator 传递依赖在用 idgenerator 那份。
> 而 idgenerator 那 179 行的类里，**真正的内容只有两段**：
> 一把 `SET NX EX` 锁 + 一个按模式删除；其余是 4 个一行包装、2 个注入 setter、
> **3 个零调用方的死方法**。它是个「装着两段实质代码的薄壳」。
>
> | 项 | 结果 |
> |---|---|
> | oms 的 `RedisUtil` | **加** `deleteNamespace`（通用能力归位），**+3 条真集群用例** → **66 / 0** |
> | idgenerator 的 `RedisUtil` | **整个删掉**（179 行）；锁搬进 `IdUtil` 变成私有方法 → **6 / 0** |
> | 反向依赖 | idgenerator 的依赖树里**再也看不到 `realserver-oms`**；`model-service` 改成**直接**声明 |
> | backend / napstarweb reactor | **44 个模块** / **13 个模块**，全 SUCCESS |
> | 变异检验 | 6 条：前五条**各自**只让**恰好一条**用例变红；最后一条（只扫第一个 master）让**两条**同时变红 |
> | patch | `docs/superpowers/patches/2026-10-29-unify-redis-util.patch`（10 个文件，81,478 B）<br>反向校验 exit 0；往返校验 `checked=9 mismatches=0` |
>
> **⚠️ 有一个「发布契约」变化必须写进发布说明**：4 个模块
> （`idgenerator`/`userservice`/`model-interface`/`menuservice`）的
> **对外传递闭包变小了** —— 能到 `realserver-oms` 的模块从 **20 个变成 16 个**，
> 而 `lettuce-core` 也随之从这 4 个模块里消失。仓库内无影响，
> **仓库外的消费者会察觉**。详见「第十六轮」。
>
> **⚠️ 另一个必须写进发布说明的破坏性变更**：
> `com.sac.platform.common.utils.redis.RedisUtil` 这个**类没了**
> （移到 oms 的 `RedisUtil`）。外部若引用它，要改成
> `com.sac.platform.realserver.oms.utils.RedisUtil`。
>
> **本轮留了两个「锁的归属权」隐患没修**（是既有缺陷、设计明确要求保持现状）：
> ① `tryLock` 的 catch 会删掉一把**自己从没拿到**的锁；
> ② 锁的 TTL（5 秒）比临界区（含一次 DB 往返）短，且锁值是常量 `"1"`
> → 无法校验归属。正确修法是「唯一 token + Lua compare-and-delete」。

> **⭐ 2026-10-29 会话复核（第十五轮：修 `IdUtil` 的 Redis 锁缺陷）**
>
> 这一轮**没有碰 `cluster-config.sh`**，而是修了一个**读代码读出来的生产缺陷**：
> `IdUtil.getNextSeqFromRedis` 拿到 Redis 锁之后**直接 return，从不释放**。
>
> **后果**：锁只能等 TTL（5 秒）过期 → 这 5 秒内每次取号都要**白等锁过期**
> （实测第二次调用被拖住约 5 秒）；一旦等待超过 `tryLock` 自己的超时（10 秒），
> 序列号就彻底取不到 → `getNextId` 里 `Long.toBinaryString(null)` →
> **裸的 NullPointerException**（既不说是哪张表，也不说是因为锁）。
>
> **同一段代码里还有两个锁缺陷**：`tryLock` 的 catch 释放的是
> `locked#locked#xxx`（前缀被拼了两次）；`IdUtil` 的 catch **无条件**释放锁 ——
> 哪怕异常发生在拿到锁之前，那把锁其实是**别人的**。
>
> | 项 | 结果 |
> |---|---|
> | 修复前的 3 条新用例 | **全部变红**（含 NPE 的现场复现） |
> | 修复后 | **3 通过 / 0 失败 / 0 跳过**，**连续 5 轮稳定** |
> | 变异检验 | 3 个变异**各自**让对应的一条用例变红（每处修复都是承重的） |
> | `oms` / `rtdata-module` | **63 / 0 / 0 跳过**、**14 / 0**（未受影响） |
> | backend reactor | **44 个模块全 SUCCESS**（⚠️ 交接文档原来写「29 个」，实际是 44） |
> | patch | `docs/superpowers/patches/2026-10-29-idutil-redis-lock-fix.patch`（4 个文件）<br>反向校验 exit 0；往返校验 `checked=4 mismatches=0` |
>
> **本轮还发现三件交接文档里与实际不符的事**（都已更正，见下文）：
> ① 「**三套** `RedisUtil`」→ 实际只有 **2 套**（modelserver 没有第三套，
> 它经 idgenerator 传递依赖复用 idgenerator 那套）；
> ② CI 的 `bash -n` 覆盖面「6 → **45** 个文件」→ 实际是 **15 → 28**
> （45 里有 17 条是 `.bats` 的 SKIP 占位，不是真正的语法检查）；
> ③ backend reactor 是 **44** 个模块，不是 29 个。
>
> **用户已定的两个决定**：
> - **生产必须留在 JDK 8** → 交接待办第 7 项（jedis 要不要继续升）
>   以「**不升级，固定 3.10.0**」结案。
> - **直接在 `main` 上改，走 SSH 推送**（与前 14 轮一致）。

> **⭐ 2026-10-29 会话复核（第十四轮：验证 + 修环境 + 修一个测试脚本 + 加真集群测试）**
>
> 本次会话把上面每一条基线**重跑了一遍**，结论：**全部与文档相符**。
> 期间发现**一个新缺陷**（`check-bash-compat.sh` 的假红 + 误报，
> **已修 + 已加 4 条回归测试**），**新增了 4 条真集群集成测试**
> （生产写路径此前只有 Mockito 用例、**零**真集群覆盖），
> 并把环境恢复到了文档描述的状态。
>
> | 检查 | 结果 |
> |---|---|
> | `git status -sb` / `git status --porcelain` | `main...origin/main`，工作区**干净**，`rev-list --left-right --count` = `0 0` |
> | bats（非特权 uid 1000） | **203 通过 / 0 失败**（199 + 本次新增的 4 条） |
> | `tests/check_syntax.sh` | `TOTAL=45 FAIL=0`（43 + 新增的 2 个文件） |
> | `tests/validate_libs.sh` | `PASS=54 FAIL=0`（退出码 0） |
> | `scripts/check-bash-compat.sh`（bash 4.3） | `BASH_COMPAT: PASS`（203/203） |
> | `scripts/e2e-cluster-config.sh` | `E2E PASSED`，退出码 **0**，**A0–A6 七条断言全部出现且全绿** |
> | `oms` 单测 | **63 通过 / 0 失败 / 0 跳过**（基线 59 → 第十四轮新增 4 条**真集群**测试；把集群拉起来后 L3 契约测试也是 `2/2，Skipped: 0`） |
> | `rtdata-module` 单测 | **14 通过 / 0 失败** |
> | `oms` 依赖树 | **零 `com.sac.platform` 依赖** |
> | `idgenerator` 依赖树 | **不含 `realserver-entity`** |
> | 五份 patch 反向校验 | **全部 exit 0**（磁盘上仍是 patch 的后像，源码没漂移） |
> | `RedisUtil` 的 `@Deprecated` 数量 | **27**（与第十三轮记录一致） |
> | `RedisClusterHashPipeline` 的公开入口 | 只有 `putAllHashes`，**没有 `getAllHashes`** → 读侧 pipeline **确实还没做** |
>
> **本次会话对仓库的改动（6 个文件）**：
>
> | 文件 | 改动 |
> |---|---|
> | `scripts/check-bash-compat.sh` | 修「假红」：不再吞掉 apk 的错误；失败时区分「包没装上」与「测试真的失败」 |
> | `tests/bash_compat.bats`（**新**） | 4 条回归用例，用 docker stub 真跑内层脚本 |
> | `tests/helpers/docker_stub.sh`（**新**） | docker stub：把内层 `sh -c` 真跑起来，配一个按需失败的假 `apk` |
> | `docs/superpowers/patches/2026-10-29-jedis-ceiling-platform-backend.patch`（**新**） | 第十四轮 Java 侧改动留痕 |
> | `docs/superpowers/patches/2026-10-29-jedis-ceiling-application-backend.patch`（**新**） | 同上（napstarweb 那个根） |
> | `docs/superpowers/patches/README.md` | 补第十四轮的 patch 说明 |
> | `docs/HANDOFF.md` | 本文件 |
>
> **Java 侧（不在本仓库，patch 留痕）**：
> `backend/pom.xml` 与 `application/backend/pom.xml` 的 `jedis.version`
> 从 `8.1.0-beta2` 恢复成 **`3.10.0`**（并就地写下实测出的上限依据）；
> 新增 `oms` 的 `RedisClusterHashPipelineLiveTest`（4 条真集群测试）。
>
> **本轮还发现了一个「下一轮待办」（未做，只记录）**：
> **CI 的 `bash -n` 覆盖面有缺口** —— `tests/check_syntax.sh` 已经管了 45 个文件，
> **但 CI 从来没跑它**，而是在 workflow 里手抄了一份更短的列表（6 个文件），
> 两份必然漂移。已实测出 14 个脚本**没有任何 CI 语法检查**。
> 修法只要一行（见「会话存档」第四节第 8 条）。
> ⚠️ 改 workflow 要走 **SSH** 推送（PAT 没有 `workflow` scope）。
>
> **⚠️⚠️ 先看这个：会话期间工作树被外部编辑器改过**
> `backend/pom.xml`（09:59:47）与 `application/backend/pom.xml`（10:03:22）的
> `jedis.version` 被改成 **`8.1.0-beta2`** —— **不是本轮改的**
> （VS Code + redhat.java 插件当时在跑）。这个改动**让整个工程编译失败**，
> 且 jedis 8 与 SDR 2.7.18 **不兼容**（详见「第十四轮」）。
> 本轮已恢复成 `3.10.0`。**下次动手前先看这两个文件的 mtime**。
>
> **环境复原过程（下次会话注意）**：Docker Desktop 当时是**停的**，
> 容器全在 `Exited` 状态。`docker start` 之后集群是 **`cluster_state:fail`**
> （6 个节点全 `disconnected`）—— 因为 announce 地址是**运行期**改动，容器一重启就丢了。
> 重跑 `%TEMP%\opencode\set-announce.sh` 后恢复 `state=ok` / 6/6 connected；
> 再重跑 `start-publish.sh` 重建转发器，宿主机 `127.0.0.1:16379-16384` 全部可达。
>
> ⚠️ **有两个同名相似的脚本，别用错**：
> `%TEMP%\opencode\set-announce.sh`（**正确**：bus-port 保持 0）
> vs `%TEMP%\opencode\restore-cluster.sh`（**错误**：它把 bus-port 也改成转发端口，
> 那正是「坑 9」说的会让节点链路断掉的改法）。
>
> **下一轮动手前先读这一段**。

**第十四轮（2026-10-29）**：**在 Docker Redis 集群上实测 Java 侧的读写**，
并**实测出「JDK 8 下 jedis 能升到哪个版本」的硬上限**。
详见下文「第十四轮」。


**第十三轮（2026-10-28）**：**统一三个工程的 Redis 连接基础设施**
（`realserver` / `modelserver` / `napstarweb`）。两步：① 修配置契约
（`oms:` 块补全、bean 改名、删三个墓碑）；② 给 `realserver-oms` **瘦身**
（解开对 `realserver-entity` 的依赖、删两个死代码类、27 个集群不安全方法加
`@Deprecated`）。**最重要的收获：我原先那 20 条"跨槽会抛 CROSSSLOT"的注释是错的** ——
SDR 2.7.18 大多**不抛**，而是**静默降级**成非原子的客户端实现。
详见下文「第十三轮」。
**第十二轮（2026-10-28）**：把「两台机器 + Redis 已装好」这个实际需求落进
`cluster-config.sh` —— 第 9 步从「单条 `--cluster create --cluster-replicas 1`」
改成**两阶段装配**（先建主、再逐个显式挂副本），新增 `lib/topology.sh`（纯函数
算主从映射）、`cluster_require_full_coverage` 配置键，以及 Docker E2E 的
**A0–A6** 七条断言。**关键结论：redis-cli 的自动分配会让整机故障致命；两台机器
做不到对称容错。** 详见下文「第十二轮」。
**第七轮（2026-10-27）**：在 CPS 节点镜像上部署集群 + 跑 `RTListener.onMessage`
写入测试，并固化成 `scripts/e2e-cpsweb-nodes.sh`。
**已提交**（`e2d01b4`），详见下文「第七轮」。
**第八轮（2026-10-27）**：ZooKeeper + Kafka 两节点集群，固化成
`scripts/e2e-kafka-cluster.sh`，详见下文「第八轮」。
**第九轮（2026-10-27）**：端到端写入性能测量（均值 ~1.33 万/秒）+ 写入路径诊断，
并设计出集群 pipeline（当时未实现），详见下文「第九轮」。
**第十轮（2026-10-27）**：**实现了集群按节点 pipeline**，并把测量固化成
`scripts/bench-consumer-write.sh`。同机交替 A/B 共 12 轮：**配对中位数 2.8×**
（区间 1.7–4.1×；全样本中位数 2.64×），写失败 0、数据精确守恒。
**倍数没有稳健达到计划里的 3×**，原因与重测建议见「第十轮」。
**Java 源码不在本仓库**，改动以 patch 形式落在
`docs/superpowers/patches/2026-10-27-cluster-pipeline.patch`，详见下文「第十轮」。
**第十一轮（2026-10-28）**：**两个消费者的对照测试**（功能全对，吞吐反而降到
0.32×，原因是这台机器 CPU/内存饱和）+ **配置搬进 `application.yaml` 验证生效**
（命令行可以完全不传配置），并修掉脚本里三个会「让正确的运行变红」的缺陷。
详见下文「第十一轮」。

**下一步**（第十五轮结束后，详见「会话存档（2026-10-29）」）：
① **填生产真值** —— 三个 `application.yml` 的 `oms.clusters` 现在是**占位符
`127.0.0.1:6379`**、`password` 是空串，必须换真值并同步 Nacos；
② 设 `cluster_require_full_coverage=no`（2 机部署必须，否则任一 master 挂 = 全集群停写）；
③ **读侧 pipeline**（`findByOtype` 集群下仍是 N 次串行 `HGETALL`）；
④ ~~合并**两套** `RedisUtil`~~ —— **✅ 已做（第十六轮）**（不是三套 ——
modelserver 没有第三套）；反向依赖 `common/idgenerator → realserver/oms` 已消除；
⑤ **CI 的 `bash -n` 换成 `bash tests/check_syntax.sh`**（真实覆盖面 15 → 28 个文件）；
⑥ （旧的）**别再在这台机器上加并发**（已换出 1.77 GB）；换干净集群重测倍率；
验证生产值 `max-poll-records=100000`（测试里生效的是 Boot 默认 **500**）。

> **✅ 已结案**：jedis 升不升 —— 用户确认**生产必须留在 JDK 8** →
> jedis **固定 `3.10.0`，不升级**（第十四轮已实测出这个上限）。
> **✅ 已修（第十五轮）**：`IdUtil` 的 Redis 锁「成功路径从不释放」。
> **✅ 已修（第十六轮）**：两套 `RedisUtil` 合成一套；`tryLock` 的忙等自旋加了 sleep。

---

## 一句话现状

**第一轮计划的 14 个 Task 全部完成并已合并进 main**（`--no-ff`，合并点 `96737d2`）。
第二轮又把 `cluster-config.sh` 的 E2E 从 Ubuntu 22.04 + apt Redis 6 迁到了官方
`redis:8` 镜像（Debian 13 trixie，当前 8.10.2），149 个单元测试通过，
E2E 在 Redis 8 上端到端全绿，**已 fast-forward 合并进 main**（`18dd8ef` → `d073da5`），
分支 `feature/e2e-redis-8` 已删除。

**迁移过程暴露了一个真实的生产缺陷**：`ReadWritePaths=` 把 `/var/log/redis`
写成了硬性要求，而仓库里没有任何代码创建这个目录 —— 单元直接以
`status=226/NAMESPACE` 启动失败。已由提交 `32ac923` 修复。

**第三轮修掉了 E2E 自己的三条断言**：它们是裸 `| grep`，脚本又没有 `set -e`，
所以断言失败时脚本照样跑到 `=== E2E PASSED ===` 并退出 0。
**实测复现过**：把匹配串换成永远不可能成立的值，E2E 依然报 PASSED、退出码 0。
提交 `3b6d23a`，详见「已知问题二」。

**第四轮修掉了 `add-node.sh` 的目录准备**：它 chown 了一个谁都不创建的
`/var/log/redis`，`chown` 非零退出、`set -e` 之下整个远端脚本当场中止 ——
**`systemctl` 一次都没跑到，实例根本没被启动**。现在它的 chown 列表与
`cluster-config.sh` 的 `create_dirs` 完全一致，并且**第一次有了自动化覆盖**：
把远端脚本抽出来在沙箱里真跑一遍。

**第五轮推翻了第二轮自己的一个错误结论**：`/etc/redis` **确实是** apt 装的
`2770 redis:redis`（第二轮读错了包）。所以 `2eb4aee` 的归因本来就是对的，
而且「父目录 chown」对**任何装了发行版 redis 包的主机**都是必须的。

**第六轮修掉了 4 条审查遗留项，并且发现 CI 一直是红的**（两个独立原因，
都只在 CI 的环境中才看得见）：一条测试用了 bats 1.4 才有的变量（以 root 跑绿、
以非特权用户跑红），以及 `gen_password` 把无限流灌进 `head` —— CI 的 coreutils
会报 `tr: write error: Broken pipe` 混进输出，本地那份静默地死。
**`9b0a6f6` 上 Actions 第一次变成 success。**

**第七轮把 `cluster-config.sh` 第一次放到真正的目标镜像（`cpsweb-env:1.0`）上跑，
并用真实消费者写入取证；已提交（`e2d01b4`）。**

**第八轮把 ZooKeeper/Kafka 做成两节点集群（`3a2856d`，已推送）；
第九轮测出端到端写入上限约 1.33 万/秒，并把写入路径诊断到「每点一次同步往返」。**

**第十轮把这根因修掉了**：新增 `RedisClusterHashPipeline`，集群写入从「每 key 一次
`HMSET` 往返」变成「每主节点一次 pipeline 往返」。同机交替 A/B（12 轮）配对中位数
**2.8×**（1.7–4.1×），守恒精确、失败 0；但**倍数未稳健达到 3×**，
需要在干净集群上重测（见「第十轮」末）。

**下一步**：第十轮改动待推送。**在一台干净的集群上重测倍率**（当前环境键数涨到 480 万、
AOF/RDB 反复触发，噪声盖过了差值）；再要提速就做消费/解析侧。
（**这是第十轮当时的待办，已被第十二~十四轮覆盖**；当前待办见「会话存档」第四节。）

**第十二轮（2026-10-28）把「两台机器 + Redis 已装好」这个实际需求落进了脚本**：
第 9 步从单条 `--cluster create --cluster-replicas 1` 改成**两阶段装配**
（先 `--cluster-replicas 0` 建主，再逐个 `--cluster add-node --cluster-slave` 挂副本），
新增 `lib/topology.sh`（纯函数算主从映射）与 `cluster_require_full_coverage` 配置键。
**实测证明 `redis-cli` 的自动分配会让整机故障致命**（3 个 master 全挤到一台），
并且**两台机器在数学上做不到对称容错** —— 要两头都活至少需要 3 台机器。
bats 163 → **199**，E2E 新增 A0–A6 七条断言并全绿。

**第十三轮（2026-10-28）统一了三个工程的 Redis 连接基础设施**：
`oms:` 配置块补全、bean 改名、删三个墓碑、`realserver-oms` 解耦
（零 `com.sac.platform` 依赖）、27 个集群不安全方法加 `@Deprecated`。
**本轮最重要的收获是纠正了自己的 20 条错注释** —— SDR 2.7.18 在跨槽时
大多**不抛 CROSSSLOT**，而是**静默降级**成非原子的实现。
bats 199 → **203**，`oms` 单测 50 → **59**。

**第十四轮（2026-10-29）把 Java 侧的读写第一次放到真集群上验证**，
并**实测出「JDK 8 下 jedis 的上限 = 3.10.0」**：
生产写路径 `RedisClusterHashPipeline.putAllHashes` 此前只有 28 条 **Mockito** 用例、
**零**真集群覆盖 —— 新增的 4 条真集群测试把它验了（`oms` 59 → **63**，0 跳过）。
**实测结论：jedis 4.0.0 及以上与 spring-data-redis 2.7.18 不兼容**
（`NoClassDefFoundError: redis/clients/jedis/GeoUnit`），
要升必须连带升 SDR 到 4.x，而那需要**编译目标升到 JDK 17**。
会话期间两个根 pom 被**外部编辑器**改成 jedis 8.1.0-beta2 并**导致整个工程编译失败**，
已恢复成 `3.10.0`。

**第十二轮（2026-10-28）把「两台机器 + Redis 已装好」这个实际需求落进了脚本**：
第 9 步从单条 `--cluster create --cluster-replicas 1` 改成**两阶段装配**
（先 `--cluster-replicas 0` 建主，再逐个 `--cluster add-node --cluster-slave` 挂副本），
新增 `lib/topology.sh`（纯函数算主从映射）与 `cluster_require_full_coverage` 配置键。
**实测证明 `redis-cli` 的自动分配会让整机故障致命**（3 个 master 全挤到一台），
并且**两台机器在数学上做不到对称容错** —— 要两头都活至少需要 3 台机器。
bats 163 → **199**，E2E 新增 A0–A6 七条断言并全绿。

---

## 第十轮（2026-10-27）：集群写入改成按节点 pipeline

**改的是应用侧，不是集群脚本。** 第九轮测出端到端写入 1.33 万/秒，根因是集群模式下
每个数据点一次同步 `HMSET` 往返。本轮把「每 key 一次往返」换成「每主节点一次往返」。

### 改动（Java 侧）

**Java 源码不在本仓库**（`D:\javawork\1.2\...` 不是 git 仓库），基线目录是：

```
D:\javawork\1.2\cpscloud1.0\code\platform\backend\realserver\
```

**5 个文件（2 改 + 3 新）**，行数是改完后文件里的行数：

| # | 绝对路径（相对上面基线） | 状态 | 行数 | patch |
|---|---|---|---|---|
| 1 | `common\oms\src\main\java\com\sac\platform\realserver\oms\config\RedisUtilConfig.java` | 改 | 342 | +7 |
| 2 | `common\oms\src\main\java\com\sac\platform\realserver\oms\utils\RedisClusterHashPipeline.java` | **新增** | 566 | +566 |
| 3 | `common\oms\src\test\java\com\sac\platform\realserver\oms\utils\RedisClusterHashPipelineTest.java` | **新增** | 648 | +648 |
| 4 | `plugins\rtdata-module\src\main\java\com\sac\platform\realserver\service\impl\RedisRealDataServiceImpl.java` | 改 | 189 | +27/-7 |
| 5 | `plugins\rtdata-module\src\test\java\com\sac\platform\realserver\service\impl\RedisRealDataServiceImplTest.java` | **新增** | 106 | +106 |

`git apply --stat` 合计：**5 files changed, 1345 insertions(+), 9 deletions(-)**。

**改动落在哪几处**（行号 = 改完后文件里的行号）：

- **① `RedisUtilConfig.java`（2 处）**
  - **L15** `import ...oms.utils.RedisClusterHashPipeline;`
  - **L336–341** 新增 `@Bean("redisClusterHashPipeline")`，参数是
    `RedisTemplate<String, Object>` + `RedisConnectionFactory`
- **④ `RedisRealDataServiceImpl.java`（4 处）**
  - **L4–9** 类头 `@Description` 改写（集群不再是「按 key 自动分片」）
  - **L30** import
  - **L44 / L47–52** 新字段 `private final RedisClusterHashPipeline clusterPipeline;`，
    构造器加第三个参数并赋值
  - **L124–135** `batchWirteOmsByRedisCluster()` —— **唯一的行为改动**：
    先 `grouped.isEmpty()` 短路返回 true，再只遍历求 `fieldCount`（不再写），
    然后一次 `clusterPipeline.putAllHashes(grouped)`，
    替换掉原来 for 循环里的 `redisTemplate.opsForHash().putAll(...)`
  - 单机/哨兵路径（`wirteOmsPip` **L63**、`wirteOmsPipByJedis` **L113**）**一行没动**；
    计数语义也没变（整批成功后一次性累加）
- **② `RedisClusterHashPipeline.java`（新）**：唯一对外入口 `putAllHashes(...)` **L150**，
  内部是 `CLUSTER SLOTS` 快照 → 按 slot 属主分组 → 每节点一条 pipeline → 检查返回值 → 逐 key 兜底
- **③ / ⑤ 测试（新）**：27 条 + 4 条用例

**留痕与一致性核对**：
`docs/superpowers/patches/2026-10-27-cluster-pipeline.patch`（5 个文件，66,582 B，
UTF-8/LF，`git apply --check` 通过；应用到基线上后 5 个文件与新源码 **SHA-256 完全一致**）。

> **2026-10-27 复核（比 SHA 更直接的一种查法）**：在 `realserver\` 下跑
> `git -c core.autocrlf=false apply --reverse --check <patch>` → **退出码 0**，
> 即磁盘上这 5 个文件**仍等于 patch 的后像**，跑完 A/B 之后没人再改过它们。
> 这个反向检查比逐个比 SHA-256 便宜，**以后核对「源码有没有漂移」直接用它**。

### 设计要点（都是实测过的，不是推理）

1. **Spring Data Redis 2.7.18 的集群 pipeline 不可用** —— `JedisClusterConnection.openPipeline()`
   字节码直接抛 `UnsupportedOperationException`。因此直接用原生 Jedis。
2. **`CLUSTER SLOTS` 的 host 是 `byte[]`**（Jedis 3.10），不是 String；解析时必须 UTF-8 解码。
3. **pipeline 里的 MOVED/ASK 是「返回值」不是异常**：`syncAndReturnAll()` 把
   `JedisDataException` 装进返回列表。所以必须按下标逐条检查，`sync()` 不会抛。
4. **ASK 不需要刷新拓扑**（迁移中的临时状态）；只有**非 ASK** 的 `JedisDataException`
   （MOVED/READONLY/WRONGTYPE/NOPERM…）或条数不匹配才刷新，且强制刷新最多每秒一次。
5. 槽位快照 30s TTL；刷新失败 **5s 退避**；重定向触发的强制刷新 **最多每秒一次**；
   刷新失败永远不抛给写入方（逐节点尝试，全失败则保留旧快照 → 逐 key 兜底）。
6. 被拒的 key **逐个** 走 `opsForHash().putAll`（JedisCluster 自己处理 MOVED/ASKING），
   成功的 key 不重写；传输层失败整批抛出，由上游 `writeWithRetry` 整批重试（HSET 幂等）。
7. 日志按「每节点每批一行」聚合，避免故障时每 key 一行把日志打爆（500×16 行/轮）。
8. 计数器仍在整批成功后**一次性**累加，与旧实现一致：旧的 `for (…) putAll` 也是循环结束后
   才 `add`，失败时同样不计数。本轮没有改变计数语义，只是把「逐 key 累加字段数」改成
   「先求字段总数再写」。
9. **节点直接不可达（连接被拒）也要能自愈**：本类不共享 `JedisCluster` 的槽位缓存，
   所以 `runPipeline` 捕获 `JedisConnectionException` → 刷新拓扑 → 该节点整组改走逐 key 写入
   （`JedisCluster` 自己会 `renewSlotCache` 并重试），不把整批抛给调用方。
   这是最终审查抓出来的回归：不做这一步，一个主节点硬死会让**每一批**失败，最长等到
   30s 快照 TTL 才恢复。
10. `Pipeline.hset(byte[], Map)` 发出的是多 field `HSET`（旧路径是 `HMSET`），
    要求 Redis ≥ 4.0；目标镜像是 Redis 8.10。

### 测试

`mvn -o -pl realserver/plugins/rtdata-module -am clean test ...` → **64 条全绿**
（oms 50：管线 28 + 配置 8 + 扫描 13 + 旧工具 1；rtdata 14：服务 4 + 既有 10）。
关键用例：MOVED 只重写被拒的 key、条数不匹配整节点兜底、ASK 不刷新、强制刷新每秒最多一次、
pipeline 构建期异常要先把缓冲刷掉再归还连接（否则脏连接会污染下一条命令）、
非集群连接一次性判定并永久降级、8 线程首次并发只借一次连接、瞬时失败不置「永久不可用」。
每条新用例都验证过「去掉对应实现就会红」。

### 实测（同一台机器，交替 A/B，CONC=1，每轮 20 万条）

**全部 12 轮**（点/秒，括号是活跃秒）：

| # | 侧 | 速率 | # | 侧 | 速率 |
|---|---|---|---|---|---|
| 1 | 旧 | 6,879 (29s) | 2 | 新 | 28,214 (7s) |
| 3 | 旧 | 10,500 (19s) | 4 | 新 | 40,000 (5s) |
| 5 | 旧 | 6,666 (30s) | 6 | 新 | 14,285 (14s) |
| 7 | 旧 | 6,451 (31s) | 8 | 新 | 18,181 (11s) |
| 11 | 旧 | 8,291 (24s) | 9 | 新 | 40,000 (5s，profile 那次) |
| — | — | — | 10 | 新 | 7,407 (27s) |
| — | — | — | 12 | 新 | 14,285 (14s) |

**同窗口相邻配对**（旧 → 新）：

| 对 | 旧 | 新 | 倍数 |
|---|---|---|---|
| 1 | 6,879 | 28,214 | **4.10×** |
| 2 | 10,500 | 40,000 | **3.81×** |
| 3 | 6,666 | 14,285 | 2.14× |
| 4 | 6,451 | 18,181 | 2.82× |
| 5 | 8,291 | 14,285 | 1.72× |

**配对中位数 2.82×，均值 2.92×**；全样本中位数：旧 6,879 → 新 18,181 = **2.64×**。

> **口径必须写清楚，否则就是自欺**：最早只跑了 4 对，主推 3.42×；补跑后掉到 2.6–2.9×。
> **所以本轮能负责的说法是「约 1.7–4.1×，配对中位数 2.8×」，不是 3.4×，也不是 3–10×。**
> 每一轮都没有失败、没有丢点（见下），提升是真实的；但**倍数没有达到计划里 3× 的稳健门槛**。
> 原因见下面两条。

每一轮（12/12）都满足：`written = 200000`、`write_failures = 0`、`lag = 0`、
`delta_per_record = 1.00`、三个主节点各写 ~66.6k、8 个抽样值逐字匹配。
另外手工复核了两个 obid（含一个脚本不抽样的下标），值与
`"<v>.20,<timestamp>,1"` 完全一致。

> **为什么倍数越跑越低**：本机 Redis 开着 AOF+RDB，每轮 20 万写入都会触发后台保存
> （实测一次 25 秒）；同时集群键数从 74 万涨到**每主 ~160 万**（合计 ~480 万，
> 每轮都写全新 obid）。两侧都在变慢（旧 6.4–10.5k，新 7.4–40k），
> 差值被环境噪声主导。**要给出可信倍率，需要一台干净的集群重测**（见「下一步」）。

> 相对第九轮的 13,233，新高值 18,181 只有 1.37×（中位数口径 1.37×）——
> 绝对值跨天比较同样不可靠，原因同上。

### 瓶颈现在在哪（第十轮 profile）

排空窗口采了 20 次 `jstack`（28–53s）：

| 指标 | 第九轮 | 第十轮 |
|---|---|---|
| 卡在 `socketRead0` | **59 / 192** 个写线程样本 | **0 / 20 次采样** |
| `BLOCKED` | 0 | 4（都是 Spring Boot 启动期加载 jar/类，不是写入） |
| `Unsafe.park`（空闲） | 128 | 279 |

> 采样窗口大部分落在启动/空闲（排空本身只剩 5 秒），所以这只能算**指向性**证据；
> 直接证据是**活跃秒从 19–31 秒降到 5–14 秒**，同样的 20 万条。

**结论：写入端不再是瓶颈。** 下一步若还要提速，目标应该是消费/解析侧
（`RTListener` 对同一批数据 split 三次），而不是继续加写入线程或消费者。

### 复现

```powershell
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock `
  -v "D:/work/rediscluterproject:/repo" `
  -e NEW_JAR=D:/path/to/rtdata-consumer-1.0.14.jar -e CONC=1 `
  rc-e2e-runner:local bash /repo/scripts/bench-consumer-write.sh
```

脚本自带 5 类断言（守恒、失败 0、lag 0、每个主节点都收到写、8 个抽样值逐字匹配），
失败时 `FAIL:` 退出；`MIN_MEAN=<n>` 可把「均值不低于 n」也变成硬门槛。
第九轮时还只在 `%TEMP%` 里的探针，这一轮进了仓库。

### 留痕与回滚

- Java 改动：`docs/superpowers/patches/2026-10-27-cluster-pipeline.patch`
  （在 `realserver/` 目录下 `git apply` 即可；已用 `--check` + 实际应用 + SHA-256 三重验证）。
  > 复现 SHA-256 对比时要先设 `core.autocrlf=false`，否则 Windows 上会检出成 CRLF、
  > 哈希对不上（文本内容其实相同）。
- 构建产物**没有覆盖** `D:\java\apache-maven\mvnRepo` 里的 `1.0.14`
  （仍是 140,507,290 字节、2026-10-23 14:00）；测试用的是 `target/` 下的新包
  （140,518,671 字节）。
- 回滚：把 `rc-cpsweb-app` 的 `/app/app.jar` 指回 mvnRepo 里那份原包即可，**不需要改配置或数据**。

### 环境现状（本轮结束时）

```
rc-cpsweb-app    运行的是新 jar，group lag=0，concurrency=1
Redis            3 主 × 2 从，cluster_state:ok，每主 ~1,6xx,xxx keys（合计 ~480 万）
Kafka/ZooKeeper  两节点集群，未改动
Docker VM        2 vCPU / 3.8 GB；node-a 872MB / node-b 910MB / app 368MB
```

> 键数比第九轮涨了 6 倍，是这轮每轮 20 万新 obid 累积出来的。
> 要恢复干净基线，要么删掉 benchmark 数据，要么让脚本复用固定 obid 段（会牺牲抽样检测能力）。

---

## 第十六轮（2026-10-29）：合并两套 `RedisUtil`，去掉反方向的依赖

**这一轮改的是 Java 侧**（`common/idgenerator` / `realserver/common/oms` /
`modelserver/services`），仓库里的 `cluster-config.sh` 一行没动。

### 一、先纠正一处说法：不是三套，是**两套**

第十三轮的 spec 写的是「合并三套 `RedisUtil`（`oms` / `idgenerator` / `modelserver` 各一份）」。
实测：**只有两套**。

| 位置 | 行数 | public 方法 | bean 名 |
|---|---|---|---|
| `oms` `…/realserver/oms/utils/RedisUtil.java` | 1699 | **120 个声明 / 102 个不同的方法名** | `realRedisUtil`（`@Bean`） |
| `idgenerator` `…/common/utils/redis/RedisUtil.java` | 179 | **13** | `redisUtil`（`@Component`） |
| `modelserver` | — | — | **没有第三份** —— 它经 idgenerator 传递依赖在用 idgenerator 那份 |

那 13 个 public 方法的构成：**2 段实质内容**（`SET NX EX` 锁、按模式删除）、
**3 个零调用方的死方法**（`setHash`/`getHashList`/`getPushList`）、
4 个一行包装（`getValue`/`setValue`/`delete`/`scan`）、
2 个注入 setter（`setRedisTemplate`/`setRedisClusterHelper`）、
1 个匿名 `SessionCallback` 里的 public 方法（`execute`，`getHashList` 内部用的）。
**它是个装着两段实质代码的薄壳。**

### 二、改了什么（**10 个文件**：8 个 Java + 2 个 pom）

| # | 文件 | 改动 |
|---|---|---|
| 1 | `oms/…/oms/utils/RedisUtil.java` | **加** `deleteNamespace(String pattern)`（通用能力归位） |
| 2 | `oms/…/oms/src/test/…/RedisUtilDeleteNamespaceLiveTest.java` | **新增**（3 条真集群用例） |
| 3 | `oms/…/oms/src/test/…/RedisClusterTestSupport.java` | **新增**（共享的拓扑支撑类） |
| 4 | `oms/…/oms/src/test/…/RedisClusterHashPipelineLiveTest.java` | 两个拓扑 helper 挪到共享类；**顺手把测试清理里的 `KEYS` 换成 `SCAN`** |
| 5 | `idgenerator/…/common/utils/redis/RedisUtil.java` | **整个删掉**（179 行） |
| 6 | `idgenerator/…/common/utils/IdUtil.java` | 锁搬进来（私有）；改用 `RedisTemplate`；模板**惰性取、不缓存** |
| 7 | `idgenerator/…/common/utils/IdUtilRedisLockLiveTest.java` | 3 条 → **6 条** |
| 8 | `idgenerator/pom.xml` | **删掉** `realserver-oms` 依赖 |
| 9 | `model-service/…/NapstarOaTransformerServiceImpl.java` | import 换成 oms 的 `RedisUtil`（**只有 import 一行**） |
| 10 | `model-service/pom.xml` | **显式加上** `realserver-oms` |

### 三、四个关键决定

**① oms 的 `RedisUtil` 只加 `deleteNamespace`，不加带超时的 `setIfAbsent`。**
锁留在 `IdUtil`、`IdUtil` 直接用 `RedisTemplate` → oms 那边没人需要那个 4 参重载
→ **不加**（YAGNI）。

**② `IdUtil` 的模板「惰性解析、不缓存」。**
现在 `IdUtil` 的静态初始化只需要 `CommonDataMapper`/`DataSource`/`IdWorker`，
**不需要 Redis**。改成静态初始化就解析 `RedisTemplate` 的话，**没有 Redis 的应用
在加载 `IdUtil` 时**就会炸（napstarweb 就只用 `SystemIDUtil`，根本不用 `IdUtil`）。
**而且不能缓存** —— 第十四轮实测过 `ApplicationContextRunner.run(cb)` 在回调返回后
**销毁上下文**，缓存下来的模板会指向已失效的 `JedisConnectionFactory`。
→ 每次使用时从当前上下文取，代价只是一次 bean 查找。

**③ Redis 里的值格式一个字节都不变。**
原来存的是 **Long**（JSON `100`）。若改用 oms 的 `RedisUtil.set(String, String)`
会存成字符串 `"100"` → **已有计数器的格式就变了**。所以 `IdUtil` 直接用
`opsForValue().set(key, id)`（`Object` 重载）✓
（实测：健康状态下 Redis 里就是 3 个 ASCII 数字 `100`，首字节 49=`'1'`）。

**④ `deleteNamespace` 统一用流式 `forEachKey`。**
原来 idgenerator 那份是「集群流式 / 单机批量」两套分支；统一走
`RedisScanUtils.forEachKey`（内部按连接类型自适应）。javadoc 里写清了
**非原子性**、**代价**（每个 key 一次 DEL 往返 + **同时至少占两个池化连接**）
和**模式语义**（glob `MATCH`，不是正则）。

### 四、⭐ 变异检验（6 条：前五条各自只让**恰好一条**用例变红，最后一条让**两条**）

| 变异 | 变红的用例 |
|---|---|
| 去掉 `finally` 里的释放 | `releasesTheRedisLockSoTheNextAcquisitionSucceeds` |
| `delete(lockKey)` → `unLock(lockKey)`（双前缀） | `tryLockReleasesOnlyTheLockItTookWhenTheAcquireCallFails` |
| 去掉重试的 `sleep` | `doesNotSpinOnSetIfAbsentWhileWaitingForTheLock` |
| `if (locked)` → `if (true)`（释放没拿到的锁） | `doesNotReleaseALockItNeverAcquired` |
| `set(key, id)` → `set(key, String.valueOf(id))` | `storesTheSequenceAsANumberNotAsAString` |
| 只扫第一个 master 的槽位 | 两条真集群用例同时变红 |

后两条是**代码审查发现「没有被钉住」之后补的**：那两条恰好是设计里**明确决定过**
的东西（值格式不变、只在真拿到锁时释放），却没有用例守着 → 改坏了测试还是绿的。

### 五、⭐ 一个「注释说错历史」的坑（本项目第三次犯）

我写的注释「原来的写法是在成功路径上直接 `return` —— 没有人释放这把锁」
**在第十五轮是对的**（那时确实要修），但 Task 2 把代码搬过来之后，这句话就
**贴在已经做对了的代码旁边** → 读 diff 的人会以为这次改的就是那个缺陷。
**同一个文件里有三份这样的注释，三份都要改 —— 漏一份就还在骗人。**
已改成只描述**当前的约定**，历史明确标注为「更早一轮修掉的」。

### 六、⚠️ 发布契约变化（**必须写进发布说明**）

**① 类没了**：`com.sac.platform.common.utils.redis.RedisUtil` → 改成
`com.sac.platform.realserver.oms.utils.RedisUtil`。外部若引用它，**编译不过**。

**② 4 个模块的对外传递闭包变小了**：`idgenerator`、`userservice`、
`model-interface`、`menuservice`。
独立复算（静态 POM 图 + 与 Maven 真实的 `dependency:tree` 交叉验证）：
能到 `realserver-oms` 的模块从 **20 个变成 16 个**，少的正好是这 4 个，
且**经由 idgenerator 的边从 4 条变成 0 条**。仓库内**无影响**
（这 4 个模块自己的源码里一个 oms 引用都没有）。
**`lettuce-core` 也随之从这 4 个模块里消失**
（它们以前经 idgenerator→oms 继承到 lettuce；idgenerator 的 starter 排除了 lettuce）。
→ 外部消费者若依赖 `model-interface` 并在**编译时**引用 oms 的类，或指望
classpath 上有 lettuce，**会察觉**。

### 七、⭐ 留了两个「锁的归属权」隐患没修（既有缺陷，设计明确要求保持）

| # | 隐患 | 后果 |
|---|---|---|
| 1 | `tryLock` 的 catch 会**删掉一把自己从没拿到的锁**（`setIfAbsent` 抛异常时我们并不持有它） | 可能放走另一个持有者 → 临界区里两个线程 → **重复 id** |
| 2 | 锁的 TTL 是 **5 秒**，而临界区里**含一次 DB 往返**；锁值是常量 `"1"`，**无法校验归属** | DB 慢于 5 秒时锁在我们还持有它的时候过期 → 我们的 `finally` 删掉**新持有者**的锁 → **重复 id** |

**正确修法**（两者一起）：每次获取一个**唯一 token**，释放时用
**Lua compare-and-delete**（只删自己那把）+ TTL 大于 DB 超时。
本轮**没有**做，因为设计明确要求保持现有语义、且新用例钉住了它 —— 要改就一起改。

### 八、这一轮的其他发现

- **oms 的 `RedisUtil`（1699 行 / 102 个方法）此前一个单测都没有** ——
  `deleteNamespace` 是它**第一个**被测的方法。
- **测试清理里原来用 `template.keys(...)`** —— 那正是 `RedisUtil.delete(Collection)`
  的 javadoc 里**点名警告**的集群级阻塞操作。已改成 `RedisScanUtils.scan(...)`，
  **并把同样的改动应用到了既有的 live test**（只改清理，不动任何断言）。
- **`idgenerator` 的 `jedis` 依赖必须留着**：它的 starter **排除了 lettuce**，
  而 oms 又被删了 → 这个显式的 `jedis` 是 `userservice`/`menuservice`/`model-interface`
  **唯一**能拿到的 redis 客户端。已在 pom 里写下原因，防止将来被「清理无用依赖」误删。
- **`model-service` 现在闭包里同时有 `jedis` 和 `lettuce-core`** ——
  但这不是本轮造成的（oms 本来就能到达，它一直带 lettuce）。

### 九、留痕与验证

| 东西 | 位置 |
|---|---|
| patch | `docs/superpowers/patches/2026-10-29-unify-redis-util.patch`（10 个文件，81,478 B） |
| 设计文档 | `docs/superpowers/specs/2026-10-29-unify-redis-util-design.md` |
| 实施计划 | `docs/superpowers/plans/2026-10-29-unify-redis-util.md` |

**验证**：`oms` **66 / 0 / 0 跳过**、`idgenerator` **6 / 0 / 0 跳过**、
`rtdata-module` **14 / 0**、backend reactor **44 个模块**全 SUCCESS、
napstarweb reactor **13 个模块**全 SUCCESS；
`idgenerator` 的依赖树里**没有 `realserver-oms`**、`model-service` 的是**直接**依赖；
patch 反向校验 **exit 0**、往返校验 **`checked=9 mismatches=0`**。
安装后的 433 个 jar **0 个**被 ECJ 污染。

---

## 第十五轮（2026-10-29）：修 `IdUtil` 的 Redis 锁缺陷（成功路径从不释放锁）

**这一轮不动 `cluster-config.sh`，也不动 Redis 集群。** 它修的是**读代码读出来的
生产缺陷**，位置在 `common/idgenerator`（Java 树，不在本仓库）。

### 一、结论先行

`IdUtil.getNextSeqFromRedis` 用一把 Redis 锁（`SET NX EX`）把
「读计数器 → 加一 → 写回」包起来，然后**直接 `return`，从不释放锁**。

```java
boolean locked = RedisUtil.tryLock(key, "1", 5);
if (locked) {
    ...
    redisUtil.setValue(key, id);
    return id;          // <-- 没有 unLock
}
```

**后果**（分两层，第二层才致命）：

| 层 | 现象 | 实测 |
|---|---|---|
| 1 | 锁只能等 TTL（5 秒）过期 → **这 5 秒内每次取号都要白等锁过期** | 第二次调用被拖住约 **5 秒** |
| 2 | 等待超过 `tryLock` 自己的超时（**10 秒**）→ 序列号彻底取不到 → `getNextId` 里 `Long.toBinaryString(null)` → **裸的 NullPointerException** | 锁被别人占着时**稳定复现** |

> **⚠️ 一开始我把第 1 层当成了第 2 层**，写下的第一条断言因此**是绿的**。
> 真正的原因是：**锁的 TTL（5 s）比 `tryLock` 的超时（10 s）短**，
> 所以第二次调用会**等到锁过期然后成功** —— 只有等到「等不到」那条路径
> 才会拿到 null。
> **教训与本文件里其它教训同源**：「读代码得出的结论」必须**跑一遍**才算数。

活调用方 **7 个类、8 处**（`base_dataversion` / `ENUM_DICT` / 业务表）：
`ModelEnumDictController`、`CommitListController`、`CommitDataRunner`、
`CommitListServiceImpl`、`SyncModelServiceImpl`、`BaseEntityDataServiceImpl`、
`SyncModelEntityDataServiceImpl`。

### 二、同一段代码里的另外两个锁缺陷

| # | 缺陷 | 后果 |
|---|---|---|
| D2 | `tryLock` 的 catch 里 `unLock(lockKey)`，而 `unLock` 内部**又拼一次** `"locked#"` | 删的是 `locked#locked#xxx`，**不是**它持有的那把锁 |
| D3 | `IdUtil` 的 catch 里**无条件** `unLock(key)` | 异常发生在拿到锁**之前**时，那把锁是**别人的** —— 删掉它会**放走另一个持有者** |

### 三、改了什么（3 处）

| # | 文件 | 改动 |
|---|---|---|
| F1 | `IdUtil.getNextSeqFromRedis` | 锁在 `finally` 里释放，且**只在真的拿到锁时**释放（`locked` 标志）；catch 里不再无条件 `unLock` |
| F2 | `RedisUtil.tryLock` | catch 里改成 `delete(lockKey)`（不再二次加前缀），并吞掉释放本身的异常 —— `tryLock` 的契约是「返回布尔值」 |
| F3 | `IdUtil.getNextId` | 序列号取不到时抛**带表名**的 `IllegalStateException`，不再是一个裸 NPE |

**F3 刻意不做的事**：**不回退到雪花算法**。
`obj_type` 已经编进了 id 的高位，造一个不对的 id 会被 `extractOType`
读成**别的类型** —— 那是**静默的数据错误**，比明确失败糟糕得多。

### 四、测试（`idgenerator` 此前**没有 `src/test`**）

新增 `common/idgenerator/src/test/java/com/sac/platform/common/utils/IdUtilRedisLockLiveTest.java`
（3 条），沿用第十四轮 `oms` 的真集群模式（`ApplicationContextRunner` → 真的
`JedisConnectionFactory` → 真的集群）。

| 用例 | 锁住什么 |
|---|---|
| `releasesTheRedisLockSoTheNextAcquisitionSucceeds` | 取号之后**锁必须已经不存在**；第二次取号必须成功且序列号更大 |
| `aHeldLockProducesADiagnosableErrorInsteadOfANullPointerException` | 锁被别人占着时，必须抛**带表名**的错误，而不是裸 NPE |
| `tryLockReleasesOnlyTheLockItTookWhenTheAcquireCallFails` | `tryLock` 抛异常时删的必须是**它自己那把锁** |

**两个必须记下来的实现约束**：

1. **装到本地仓库的 `realserver-oms` jar 是 proguard 处理过的** ——
   `RedisPropertiesConfig` / `RedisUtilConfig` **已经被改名**（本轮写作时它们在
   jar 里叫 `a` / `b`），从 idgenerator 的测试类路径上**根本引用不到**。
   所以这条用例**自己**照着生产代码搭 `JedisConnectionFactory` + `RedisTemplate`
   （序列化器必须一致，否则值读回来会变形，测的就不是生产行为了）。
2. **`idgenerator` 的 pom 因此加了 `spring-boot-starter-test`（test scope）** ——
   与 `oms` 模块一致。`spring-boot-test` 单独用**不够**：
   `ApplicationContextRunner` 返回的 `AssertableApplicationContext` 继承自
   `AssertProvider`，没有 AssertJ **编译都过不了**。

### 五、⭐ 变异检验（每一处修复都是承重的）

| 变异 | 变红的用例 |
|---|---|
| 去掉 `finally` 里的释放 | `releasesTheRedisLockSoTheNextAcquisitionSucceeds` |
| `unLock(lockKey)` 换回 `delete(lockKey)` 之前 | `tryLockReleasesOnlyTheLockItTookWhenTheAcquireCallFails` |
| 去掉序列号为 null 的判断 | `aHeldLockProducesADiagnosableErrorInsteadOfANullPointerException` |

**修复前的 3 条用例全部变红**（含 NPE 的现场复现：
`instead it threw a NullPointerException`）；
**修复后 3/3 绿，连续 5 轮稳定**。

> 过程中我自己的测试出过一次**不稳定**：两条真集群用例**共用一把锁**，
> 而清理是尽力而为的（清理失败只记日志）—— 一次清理失败就会让另一条
> 用例白等锁过期。已改成**两条用例各用各的表**，
> 并且「锁被别人占着」那条用例**自己**收掉它放进去的锁。

### 六、⭐ 本轮顺手更正的三处「交接文档与实际不符」

| # | 文档写的 | 实际 | 怎么查出来的 |
|---|---|---|---|
| 1 | 合并「**三套** `RedisUtil`」（oms / idgenerator / modelserver 各一份） | 只有 **2 套**；**modelserver 没有第三套**，它经 idgenerator 传递依赖复用 idgenerator 那套 | 全树扫 `RedisUtil*.java` |
| 2 | CI 的 `bash -n` 覆盖面「**6 → 45** 个文件」 | 实际 **15 → 28**；`check_syntax.sh` 的 `TOTAL=45` 里有 **17 条是 `.bats` 的 SKIP 占位** | 数 CI 那条手抄列表（6 具名 + `lib/*.sh` 展开 9 个）与 `check_syntax.sh` 的 `OK:` 行数 |
| 3 | backend reactor「**29 个**模块」 | 实际 **44 个** | 数 reactor summary 的 `SUCCESS [` 行 |

> 第 2 条尤其要小心：照文档写会以为「CI 现在检查 45 个文件」，
> 实际上 CI 检查 15 个、而 `check_syntax.sh` 检查 28 个 ——
> **换成 `bash tests/check_syntax.sh` 之后的真实覆盖面是 28，不是 45**。

### 七、留痕与验证

| 东西 | 位置 |
|---|---|
| 新增真集群测试（3 条） | `realserver/common/idgenerator/src/test/java/com/sac/platform/common/utils/IdUtilRedisLockLiveTest.java` |
| pom 的测试依赖 | `common/idgenerator/pom.xml`（`spring-boot-starter-test`，test scope） |
| patch | `docs/superpowers/patches/2026-10-29-idutil-redis-lock-fix.patch`（4 个文件，23,551 B） |

**验证**：`idgenerator` **3 通过 / 0 失败 / 0 跳过**（连续 5 轮稳定）、
`oms` **63 / 0 / 0 跳过**、`rtdata-module` **14 / 0**、
backend reactor **44 个模块全 SUCCESS**、napstarweb reactor 全 SUCCESS。
patch 反向校验 **exit 0**；**往返校验**（从纯净基线重建 → 与现网逐文件 SHA-256 比对）
**`checked=4 mismatches=0`**。

### 八、这一轮**刻意没做**的（记录待办）

| # | 待办 | 为什么没做 |
|---|---|---|
| 1 | `tryLock` **忙等自旋没有 sleep**（锁被占用时以无限速的 `SET NX` 空转，最长 10 秒） | 修好 F1 之后争用变得罕见，实际影响大幅下降；用户选的是「只修 NPE」。**仍是个真问题** |
| 2 | **合并两套 `RedisUtil`** | 跨模块公共 API 重构，用户没选 |
| 3 | **读侧 pipeline** | 同上 |
| 4 | `idgenerator` 那套 `RedisUtil` 的 3 个**死方法**（`setHash` / `getHashList` / `getPushList`，零调用方） | 删它们属于「合并」那件事；**但 `getHashList` 的集群分支就是 N 次串行 `multiGet`** —— 形态与读侧 pipeline 的待办一模一样 |

> **第 4 条值得单独记一笔**：`getHashList` 的**单机分支与集群分支返回形状不同**
> ——集群分支 `addAll` 压平成一维；单机分支
> `executePipelined(SessionCallback)` 返回的是「每次 `multiGet` 一个元素」的
> **二维列表**（这一点是从 spring-data-redis 2.7.18 的源码
> `RedisTemplate.executePipelined(SessionCallback, …)` L271-301 确认的：
> 回调必须返回 `null`，结果由 `closePipeline()` 给出）。
> 好在它**零调用方**，删掉即可。

---

## 第十四轮（2026-10-29）：在 Docker Redis 集群上实测 Java 读写 + jedis 版本的硬上限

**这一轮回答两个问题：**
① Java 侧（生产写路径 + 读路径）在**真的 Docker Redis 集群**上读写是否正确？
② **JDK 8 之下，jedis 最多能升到哪个版本？**

### 一、⭐ 结论先行：JDK 8 下 jedis 的上限是 **3.10.0**

这是**逐版本在真集群上跑出来的**，不是查文档推断的：

| jedis | SDR 2.7.18 + JDK 8 的实测结果 |
|---|---|
| **3.6.1 / 3.8.0 / 3.10.0** | ✅ **SDR write+read OK**（读回 `42.0,1712345678000,1`） |
| 4.0.0 | ❌ `NoClassDefFoundError: redis/clients/jedis/GeoUnit`（另需 gson） |
| 4.4.3 / 5.2.0 / 6.0.0 / 7.2.1 | ❌ `NoClassDefFoundError: redis/clients/jedis/GeoUnit` |
| 8.1.0-beta2 | ❌ 同上，另需 `redis.clients.authentication` |

**根因（两条，都是实测的）**：

1. **jedis 4 起把 `GeoUnit` 从 `redis.clients.jedis` 挪到了 `redis.clients.jedis.args`**，
   而 **spring-data-redis 2.7.18 引用的是老包名** —— 一用 SDR 就 `NoClassDefFoundError`。
2. **SDR 2.7.18 的 `JedisClusterNodeResourceProvider` 调用
   `JedisPool.getResource():Lredis/clients/jedis/Jedis;`**，
   而 jedis 4+ 的 `getClusterNodes()` 返回的是 `Map<String, ConnectionPool>`，
   元素类型从 `JedisPool` 变成了 `ConnectionPool`。

**要越过这条线，就得把 spring-data-redis 一起升**：

| SDR | 声明的 jedis | 最低 JDK | 与 jedis 8 实测 |
|---|---|---|---|
| 2.7.18（本工程现在） | 3.8.0 | **8** | ❌ GeoUnit 缺失 |
| 3.2.4 / 3.5.10 | 5.0.2 / 6.0.0 | **17** | ✅ write+read OK |
| 4.0.4 | 7.0.0 | **17** | ✅ write+read OK |

**但 SDR 3.x/4.x 是 Java 17 字节码**，JDK 8 的 javac 直接拒绝：

```
bad class file .../JedisConnectionFactory.class
class file has wrong version 61.0, should be 52.0
```

（JDK 21 + `--release 8` 可以编译通过，但**产物变成 Java 17 字节码**，
而且 `oms` 的 proguard 配的是 `${JAVA_HOME}/jre/lib/rt.jar` ——
**那个路径只有 JDK 8 有**，JDK 9+ 只有 `jmods`。）

> **所以在 JDK 8 这个前提下，jedis 8 不是一个「改个版本号」的事**，
> 它的真实代价是：升 SDR 到 4.x + 编译目标升到 JDK 17 + 重做 proguard +
> 改 `RedisClusterHashPipeline`（`JedisPool` → `ConnectionPool`）+
> 改 `RedisScanUtils`（`ScanParams`/`ScanResult` 换包），
> 而且这些改动会沿 `oms` → 三个应用**向上扩散**。
>
> **本轮已把 pom 恢复到可编译状态**：`jedis.version` 从 `8.1.0-beta2` 改成
> **`3.10.0`**（3.x 里 API 与 3.6.1 完全一致，**不需要改任何生产代码**），
> 并在 pom 里就地写下这条上限及依据。

### 二、⭐ 生产写路径第一次在**真集群**上被验证

**此前的覆盖情况**：`RedisClusterHashPipelineTest` 的 **28 条用例全是 Mockito** ——
拓扑快照、pipeline 回复、被拒 key 的兜底**全都是构造出来的**。
这个类的真正难点全在与真 Redis 的交互上，**一条都没被真集群检验过**。

本轮新增 `RedisClusterHashPipelineLiveTest`（`oms` 模块，**4 条**），
用 `ApplicationContextRunner` 装配**真实的** `oms:` 契约 → 真的 `JedisConnectionFactory`
→ 真的 `JedisCluster` → 真的 Docker 集群：

| 用例 | 锁住什么 |
|---|---|
| `writesEveryKeyOfTheBatchAndReadsItBackUnchanged` | 批量写 300 个 key，**逐个读回，字字相等**（同时覆盖 slot 分组、属主正确、**值序列化与读路径一致**） |
| `spreadsTheBatchAcrossSeveralMastersWithoutAnyMovedRedirect` | **服务端收到的 MOVED 次数必须为 0**，且 key 确实落在多个 master 上 |
| `readPathReturnsEntriesInTheSameOrderAsTheKeys` | 读路径返回顺序**必须与传入 key 顺序一致**（`OmsReadDaoImpl.findByOtype` 是**按下标**对齐的，顺序错了会静默返回错位数据） |
| `overwritingTheSameKeyKeepsTheLastValue` | 重复写同一个 key 得到最后写的值 |

**实测结果：`63 通过 / 0 失败 / 0 跳过`**（基线 59 + 新增 4）。

### 三、⭐ 这一轮最有价值的收获：**我自己的断言也空转过**

新写的「MOVED 次数必须为 0」那条断言，**第一次写完是绿的** ——
而分组逻辑明明被我改坏了。**这是一条空转断言**，和本仓库历史上那些
「从没失败过的断言」是同一类错误。三次修正才让它真的会红：

| # | 空转的原因 | 症状 |
|---|---|---|
| 1 | `seed.info("errorstat")` —— **Redis 8 没有名为 `errorstat` 的段**，返回**空** | 计数恒为 0，断言永远成立 |
| 2 | 按 `,` 切 `errorstat_MOVED:count=201` —— 但这个格式**中间没有逗号** | 同上，恒为 0 |
| 3 | 借连接时**忘了 AUTH** | 同上，恒为 0 |

**改对之后**，变异检验立刻生效：

| 变异 | 结果 |
|---|---|
| 把 hash value 的序列化器换成 `StringRedisSerializer` | **3 条变红**（读回时 JSON 解析失败） |
| 把分组逻辑改成「所有 key 挤到第一个 master」 | **1 条变红**：`the batch was redirected 201 times` |

> **教训**：这次空转的是**我自己刚写的断言**，而且**它一开始是绿的**，
> 所以「测试全过」给不了任何信心 ——
> **只有「把实现改坏，测试变红」才能证明断言有效**。
> 上一轮刚在 `check-bash-compat.sh` 上犯过一次同样的错（见「当前测试基线」），
> **一周内两次**，说明这已是本项目的系统性问题，值得在写断言时默认怀疑它。

### 四、顺带修掉的一个真实缺陷：`ApplicationContextRunner` 的上下文会被销毁

`ApplicationContextRunner.run(callback)` 在**回调返回后销毁上下文**，
连带 `JedisConnectionFactory` 失效（`JedisConnectionFactory was destroyed`）。
把断言写在回调**外面**会拿到已销毁的工厂。
**所有断言必须写在回调内部。**

### 五、本轮的留痕

| 东西 | 位置 |
|---|---|
| 新增真集群测试（4 条） | `realserver/common/oms/src/test/java/com/sac/platform/realserver/oms/utils/RedisClusterHashPipelineLiveTest.java` |
| pom 的 jedis 版本与上限说明 | `backend/pom.xml` 与 `application/backend/pom.xml`（`<jedis.version>` 就地注释） |
| 逐版本兼容性实测 | 见本节「结论先行」的表；探针脚本在 `%TEMP%\opencode\probe\SdrJedisProbe.java` |
| patch | `docs/superpowers/patches/2026-10-29-jedis-ceiling-platform-backend.patch`（2 个文件）<br>`docs/superpowers/patches/2026-10-29-jedis-ceiling-application-backend.patch`（1 个文件） |

**验证**：`oms` 63/0、`rtdata-module` 14/0、
**backend reactor 29 个模块 `mvn -o clean install` 全 SUCCESS**（含 proguard）、
**napstarweb reactor 12 个模块全 SUCCESS**。
patch 的反向校验两个根都 **exit 0**；
**往返校验**（反向 → 正向）**0 mismatch**。

### 六、这一轮的坑

| # | 坑 | 后果 / 正确做法 |
|---|---|---|
| 1 | **有人（不是我）在会话期间把 `backend/pom.xml` 的 jedis 改成了 8.1.0-beta2**（09:59:47，VS Code + Java 插件当时在跑） | 整个工程**编译失败**。本轮已恢复成 `3.10.0`。**如果下次又看到这个值，先看本节** |
| 2 | `RedisClusterHashPipeline` 的 `getClusterNodes()` 在 jedis 4+ 返回 `Map<String, ConnectionPool>` | 3.x 下不用改；一旦升 4+ 就必须改（L356、L188、L381） |
| 3 | `jedis` 8 还需要额外的 `redis.clients.authentication:redis-authx-core` | 只加 jedis 版本会 `NoClassDefFoundError: redis/clients/authentication/core/Token` |
| 4 | `JedisPool` 在 jedis 8 里**仍然存在**（`extends Pool<Jedis>`），但 `getClusterNodes()` 给的不再是它 | 「类还在」不等于「API 没变」——**必须看返回类型** |
| 5 | 本机 `mvn` 直连不了外网拉插件元数据 | `dependency:build-classpath` 会报 `NoPluginFoundForPrefixException`；用 `mvn -o` + 本地仓库 |

---

## 第十三轮（2026-10-28）：统一三个工程的 Redis 连接基础设施

**这一轮回答的问题是：三个独立部署的工程，怎么共用同一份 Redis 连接配置与连接代码？**

涉及工程：`realserver`、`modelserver`、`napstarweb`（三个独立进程）。

### 一、结论先行

**统一早就"事实上"发生了，只是没人设计过它。**

依赖链实测（`realserver-oms` 已被 `idgenerator` / `realserver-service` 传递依赖，
三个工程的 `@ComponentScan` 都会扫到 `com.sac.platform.realserver.oms.config`）：

```
realserver-oms (RedisUtilConfig / RedisConfigProperties / RedisClusterHelper / …)
   ↑ 被 modelserver（经 idgenerator）与 napstarweb（经 realserver-service）共用
```

**所以不需要"全局注入 JedisCluster"。** 反编译 `spring-data-redis-2.7.18` +
`jedis-3.10.0` 确认：`JedisConnectionFactory` 在 `afterPropertiesSet` 里
`createCluster()` 并持有那**一个** `JedisCluster`，`getNativeConnection()` 返回的就是它。
**自己再造一个 = 第二个实例 = 连接池翻倍（200→400）+ slot 缓存分裂**，
而且 `RedisClusterHashPipeline` 恰恰是靠"不共享 slot 缓存"精心设计的。

真正的问题是**四层**：

| # | 缺陷 | 等级 |
|---|---|---|
| A | 三个应用的 `oms:` 配置块**全是注释** → `redisMode` 取默认 `standalone` → 启动失败。全靠 Nacos 兜底 | P0 |
| B | `RedisPropertiesConfig` **bean 名冲突** —— 三个工程各留了一个**被注释的墓碑**，都是同一次失败尝试 | P0 |
| C | `realserver-oms` 依赖 `realserver-entity`（实时数据域业务实体）→ `common/idgenerator` 这个公共库被迫拖进业务实体层 | P1 |
| D | 共享模块里有 2100+ 行死代码，其中 13 组方法在集群下不安全 | P2 |

### 二、⭐ 本轮最重要的收获：**我写错了 20 条注释**

Task 1 给 13 组集群不安全方法加 `@Deprecated` 时，我写的是"跨槽会抛 CROSSSLOT 错误"。
**代码质量审查逐条核对了 spring-data-redis 2.7.18 的源码，结论是：这 20 条大多是错的。**

| 命令 | 跨槽时的**真实**行为 |
|---|---|
| `keys()` | `executeCommandOnAllNodes` + 取并集 → 返回**整个集群的 keyspace**（不是只返回一个节点！） |
| `del` / `mGet` / `mSet` / `mSetNX` | 按 slot 拆分 → **不抛** CROSSSLOT |
| `rename` | 降级成 `DUMP → RESTORE(dst,0,REPLACE) → DEL` → **不抛**，但**非原子**且**丢 TTL** |
| `renameNX` | 同上，但 `RESTORE(dst,0)` **不带 REPLACE**，且先 `EXISTS` 判断 |
| `rPopLPush` | 降级成 `RPOP + LPUSH` → **不抛**，非原子，崩溃丢元素 |
| `sMove` | 降级成 `EXISTS → SREM → SISMEMBER → SADD` **四步** → **不抛**；`SISMEMBER` 为真时跳过 `SADD` → **元素静默丢失** |
| `SINTER`/`SUNION`/`SDIFF` | 逐 key `SMEMBERS` 后**在 JVM 里算** → **不抛**，非原子，整集合进堆 |
| `ZUNIONSTORE`/`ZINTERSTORE` | **真的失败**，但抛的是 `InvalidDataAccessApiUsageException`（"can only be executed when all keys map to the same slot"），**不是** CROSSSLOT |
| `MOVE` | 抛 `UnsupportedOperationException("Cluster mode does not allow moving keys.")` |

**真正的风险不是"会抛异常"，而是"静默地、不原子地做错事"。**
一个照着原注释排查的人会去找一个永远不会出现的异常，
而真正会咬人的（rename 丢 TTL、sMove 丢元素、`KEYS` 拉爆内存）反而看不见。

> **教训（与本文件里其它教训同源）：关于第三方库行为的断言，必须去看它的源码/字节码，
> 不能靠"常识"推断。** 这次是我自己写的注释错了，被审查抓出来。
> 同类错误在这个项目里已经出现过多次（DoD5 提升判定、`ReadWritePaths` 缺目录、
> 裸 `| grep` 断言、空转断言）——**"写下了一个自己从没执行过的假设"**。

### 三、改了什么（10 改 + 5 删 + 2 未改）

**第一步 · 配置契约**
| 改动 | 文件 |
|---|---|
| `oms:` 块补全（三个应用**完全相同**，`redisMode: cluster` **显式写出**） | 三个 `application.yml` |
| bean 名 `redisConfigProperties` → `omsRedisConfigProperties` | `realserver-oms/…/config/RedisPropertiesConfig.java` |
| 删三个"在消费方自己加一份配置类"的失败墓碑 | `napstarweb` / `modelserver` / `rtdata-module` 各一个 |

**第二步 · `realserver-oms` 瘦身**
| 改动 | 说明 |
|---|---|
| 删 `opsHashSetPipeByHashData(List<HashData>)` | `OmsWriteDaoImpl` 改调已有的 `opsHashSetPipe(Map)`，分组逻辑挪到业务侧 |
| `oms/pom.xml` 去掉 `realserver-entity` | **oms 现在零 `com.sac.platform` 依赖** |
| `oms/pom.xml` 显式加 `jackson-databind` | 之前是**通过 `realserver-entity` 传递**进来的，解耦后暴露出来 |
| 删 `JedisUtils.java`（~700 行）、`JedisPoolUtils.java`（~50 行） | 死代码；后者静态读**不存在的** `jedis.properties` → 一调用就 NPE |
| 删 `batchWirteJedisStandalone` | 单机裸 Jedis pipeline 分支；`batchWirteJedis` 改为集群/单机统一走 `wirteOmsPip` |
| **27** 个方法加 `@Deprecated` + 准确 javadoc | 26 个原计划 + 1 个 `lBRightPopAndLeftPush`（审查时发现它同样有风险） |

### 四、⭐ 让宿主机上的 Java 能用真集群

之前只做到"端口可达"（socat 转发 `16379-16384` → `127.0.0.1`），
但 **Jedis 仍然连不上**：`Cluster retry deadline exceeded.`

**根因**：Jedis 连上种子节点后，会按 `CLUSTER SLOTS` 返回的**真实地址**去路由命令，
而集群广播的是 `172.21.0.2:6379` —— Windows 宿主机**没有**到 `172.21.0.0/16` 的路由。

**解法**：让集群广播宿主机可达的地址（**运行期**改动，只针对这套一次性 E2E 集群）：
```
CONFIG SET cluster-announce-ip   127.0.0.1
CONFIG SET cluster-announce-port  16379 / 16380 / …
```
> ⚠️ **`cluster-announce-bus-port` 不能改** —— 它是节点**之间**通信用的，
> 改了会让集群内部链路断掉（节点全部 `disconnected`）。改回 `0` 即恢复。

### 五、验证结果

| 检查 | 结果 |
|---|---|
| `realserver` / `modelserver` / `napstarweb` 全量 `clean install` | 三个都 **EXIT=0** |
| `realserver-oms` 单测 | **59/59 绿**（基线 50 → 新增 9） |
| `rtdata-module` 单测 | **14/14 绿** |
| `oms` 依赖树 | 只剩自己，**零 `com.sac.platform` 依赖** |
| `idgenerator` 依赖树 | **不含 `realserver-entity`** |
| 三个应用启动 | **三个都打印** `*** Using Redis Cluster with nodes: … (connectTimeout=2000ms, readTimeout=5000ms, maxWait=3000ms)` |
| **真集群 L3 契约测试** | `Tests run: 2, Failures: 0, Errors: 0, **Skipped: 0**`（真写真读了集群） |
| patch 反向校验 | 两个根都 **exit 0** |
| patch 正向重建 | 从纯净基线重建 → 与现网**逐文件 hash 比对** → **0 mismatch** |

**三个应用启动时都只在 Nacos 上失败**（`node1:18848` 不可达），与 Redis 无关；
Redis 的 bean 在那之前就已装配好并打印了配置行。

### 五之二、⭐ 终审又找出 5 个问题（全部已修）

写完 9 个 Task 之后又做了一遍**整体终审**（不是逐 Task 的检查），
找出 5 个问题。**其中两个是我自己在前面几轮埋的错误。**

| # | 问题 | 状态 |
|---|---|---|
| 1 | **我在 Task 7 写的注释又引入了一个新的错误说法** —— "集群下 `keys()` 只返回它落到的那**一个**节点的结果"。**这也是错的**（SDR 会 `executeCommandOnAllNodes` + 取并集，返回**整个集群的 keyspace**）。**我错了一次还把它抄进了第二处。** | 已改 |
| 2 | **`oms.redisMode` 大小写敏感** —— 写成 `CLUSTER` 时三个分支**一个都不激活**，**一个 `RedisConnectionFactory` bean 都不创建**，报错停在 "No qualifying bean"，完全指不到真正原因 | 三个 `@ConditionalOnExpression` 改为 `.trim().toLowerCase()`，与 `parseMode` 一致；新增 `RedisModeCaseSensitivityTest` |
| 3 | L3 契约测试**只断言 `props`**，没断言属性真的落进了 `JedisPoolConfig` —— 把 `setMaxTotal` 写死，测试照样绿 | 加断言 `JedisPoolConfig` + `JedisClientConfiguration`；**变异后确实变红** |
| 4 | L3 契约测试**可能偶发变红**（守卫只护住了探针那次 GET） | 整段读写都进守卫 |
| 5 | 补丁生成用 `Out-File -Encoding ascii` 会把**中文全变成 `?`**，patch 直接 corrupt | 改用 `git diff --output=` |

> **问题 1 的教训最值钱**：我在 Task 1 已经把 `RedisUtil` 的 27 条 javadoc 改对了
> （明确写"返回整个集群的 keyspace，不是只返回某一个节点"），
> **结果 Task 7 修另一处注释时又写反了**。
> **修正一处错误，反而在另一处引入同类错误。**
> 所以终审必须**逐条对源码**，不能凭印象。

> **问题 2 是给运维的坑**：Nacos 上有人把 `redisMode` 写成大写，
> 应用会报"找不到 RedisConnectionFactory"，而不是"模式字符串不对"。
> **这就是"配置契约"必须包含"取值格式"的原因。**

### 六、留痕

| 东西 | 位置 |
|---|---|
| 设计文档 | `docs/superpowers/specs/2026-10-28-unified-redis-connection-design.md` |
| 实施计划 | `docs/superpowers/plans/2026-10-28-unified-redis-connection.md` |
| 执行记录（含每一步的证据与踩坑） | `docs/superpowers/plans/2026-10-28-unified-redis-connection-progress.md` |
| **代码 patch** | `docs/superpowers/patches/2026-10-28-unified-redis-connection-platform-backend.patch`（18 个文件）<br>`docs/superpowers/patches/2026-10-28-unified-redis-connection-napstarweb.patch`（2 个文件）<br>`docs/superpowers/patches/2026-10-28-unified-redis-connection.patch`（合并 20 个，仅用于合成仓库） |

> **Java 源码不在本仓库**（`backend` 与 `napstarweb` **都不是 git 仓库**），
> 所以改动只能以 patch 留痕。校验方式：
> ```powershell
> cd D:\javawork\1.2\cpscloud1.0\code\platform\backend
> git apply --reverse --check "<patch>"    # 退出码 0 = 磁盘上仍是 patch 的后像
> ```
> **注意**：源文件行尾是**混的**（`pom.xml` 是 LF，`.java` 是 CRLF），
> patch 用 `core.autocrlf=false` 生成。**不要重新规范化这些文件**，否则 patch 会失效。

### 七、下一轮该做什么

1. **填生产真值**：三个 `application.yml` 里的 `oms.clusters` 现在是**占位符**
   `127.0.0.1:6379`，必须换成生产地址，并同步 Nacos 上的同名配置。
   （`password` 也是空串，靠 Nacos 提供。）
2. **设 `cluster_require_full_coverage=no`**（第十二轮的键）—— 默认 `yes` 时
   **任一 master 挂掉 = 全集群停写**；2 机部署必须设 `no`。
3. **读侧 pipeline**（`RedisClusterHashPipeline.getAllHashes`）——
   `findByOtype` / `findByOtypeIds` 在集群下是 **N 次串行 `HGETALL`**，
   写侧第十轮已按节点 pipeline 化，**读侧还没有**。这是同一根因的另一半。
4. **合并三套 `RedisUtil`**：`oms` / `idgenerator` / `modelserver` 各一份。

### 八、给下一个执行者的三个坑

1. **`mvn spring-boot:run` 会 fork 新 JVM，不传递 Maven 的 `-D` 系统属性**。
   `-Doms.clusters[0]=…` **无效**；要写
   `"-Dspring-boot.run.jvmArguments=-Doms.clusters[0]=… -Doms.password=…"`。
2. **`oms` 的 pom 配了 proguard，它要 JDK 8 的 `rt.jar`**，JDK 9+ 没有 →
   `Can't read .../jre/lib/rt.jar`。构建前确认 `JAVA_HOME` 是
   `D:\java\java-se-8u42-ri`（本机有两个 JDK，subagent 的 shell 拿到的是 JDK 21）。
3. **PowerShell 里 `-D` 参数必须加引号**：`"-Dproguard.skip=true"`。
   不加会被拆成 `.skip=true`，maven 报 `Unknown lifecycle phase`。
   另外 **绝不要用 `Set-Content` 改 Java/YAML**（会加 BOM + CRLF，直接编译失败），
   **也绝不要用它改本仓库的 md**（会加 BOM 并把 LF 换成 CRLF）。

---

**这一轮回答的问题是：两台机器、Redis 已装好，怎么配成集群？**

### 一、结论先行

`cluster-config.sh` 原来第 9 步是一条
`redis-cli --cluster create <全部实例> --cluster-replicas 1`。
**实测证明这条路在 2 台机器上是错的**：

| 6 实例 / 2 台机器，create 的节点顺序 | redis-cli 的分法 | 杀掉一台机器 |
|---|---|---|
| `A,A,A,B,B,B`（配置文件分组顺序） | **3 个 master 全在 A** | `CLUSTERDOWN` |
| `A,B,A,B,A,B`（交错） | A:2 主，B:1 主 | `CLUSTERDOWN`（存活 master 只有 1，达不到多数派） |
| `A,B,B,A,B,A` | A:1 主，B:2 主 | **集群仍可用，写入 OK** |

原因是**副本提升需要过半 master 存活授权**（`cluster_size/2 + 1`）。
3 个 master 分到 2 台机器，必有一台承担 2 个；那台挂掉就只剩 1 个 master，
副本**无权**提升 → 槽位无人接管 → 集群停写。

所以：**主从映射必须显式算出来，且副本必须挂在另一台机器的 master 上。**

### 二、改动（7 个提交）

| 提交 | 内容 |
|---|---|
| `8f6baa2` | 新增 `lib/topology.sh`：纯函数，按节点组 round-robin 选主、按「异机候选最少者优先」配副本，自检 4 条不变式，并判定每台机器故障时集群是否还活 |
| `7e78fc7` | 补 5 条单测（锁住「protected 半条规则」「最稀缺优先」「只跨一机必须拒绝」「通配符 host 不得被 shell 展开」）+ 修掉 `for item in $groups` 的路径名展开隐患（`lib/conf.sh` 里有过同款坑） |
| `7710993` | `cluster.conf` 新增 `cluster_require_full_coverage`（默认 `yes`，非法值报错） |
| `241e7cb` | 该键渲染进 `redis.conf`（`%REQUIRE_FULL_COVERAGE%`） |
| `9c4d6a0` | `lib/cluster.sh` 增加 `build_add_replica_command` / `build_eval_argv` / `cluster_nodes_index` / `cluster_role_of` / `cluster_replica_master_of` / `cluster_exists`；`build_create_command` 的 replicas 可传参 |
| `28298b0` | 第 9 步改成两阶段装配；`--dry-run` 现在也会打印拓扑；幂等（已正确的跳过、角色不符报错） |
| `46eb005` | Docker E2E 增加 **A0–A6** 七条断言 |
| `f063299` | 5 个探针脚本入仓（`tests/probes/`），spec §3 的每条事实可复现 |

### 三、两阶段装配

```
9a  选主 + 配副本    lib/topology.sh（纯函数）
9b  建主            redis-cli --cluster create <3 个 master> --cluster-replicas 0
9c  加副本          redis-cli --cluster add-node <副本> <master> --cluster-slave   （逐个）
```

`--cluster-replicas 0` 是关键：先不分配副本，把 master 完全由我们决定，再逐个
指定副本挂到哪个 master 上。

**拓扑推导（2 台 × 3 实例）**：

```
master  A:6379   replica: B:6383
master  B:6382   replica: A:6381
master  A:6380   replica: B:6384
脆弱主机：A（2 个 master）—— A 挂掉集群不可用
受保护主机：B（1 个 master）—— B 挂掉集群仍可用（降级）
```

布局由**配置文件里节点组的顺序 + 组内端口顺序**确定性推导。想让另一台受保护，
把 `[node.a]` / `[node.b]` 对调即可。

### 四、Docker E2E 的七条新断言（A0–A6）

| 断言 | 内容 | 为什么必须有 |
|---|---|---|
| A0 | 实际主从映射 == 脚本计划的那份 | A1/A2 只验「性质」，验不了「是不是按计划装的」：旧的单条 create 产生「主全在 A、从全在 B」，**A1 和 A2 都会绿** |
| A1 | 每个 master 至少 1 个副本 | |
| A2 | 每个副本与其 master **不同机** | 同机副本 = 同机故障双杀，等于没有副本 |
| A3 | 脚本打印的脆弱主机 == E2E **独立算**出的那台 | 用同一份代码自证等于没验 |
| A4 | 杀掉受保护的那台 → 集群仍可用 | 真提升，真写入 |
| A5 | 杀掉脆弱的那台 → 集群停写 | **把已知限制钉死**：将来若布局逻辑变了，这条会红，提示重新评估 |
| A6 | `coverage=no` 时无覆盖槽位存在、其余仍可写 | 见下面的「空转」教训 |

**E2E 现在会装配 3 次集群**（初始 + A4 重建 + A6 重建），耗时明显变长。

### 五、这一轮抓到的两个「空转断言」（都是实测出来的）

1. **A6 第一版是空转的**：它只杀了 master 6379，但 6379 的副本 6383 被提升
   → 槽位仍被覆盖 → 60 个 key 全可写。**即使 `coverage=yes` 也会绿。**
   现在改成**连同副本一起杀**（6379 + 6383），并加断言：必须**同时**有
   「可写 > 0」和「被拒 > 0」—— 后者是反空转守卫，证明真的构造出了未被覆盖的槽位。
   实测结果：39 可写 / 21 被拒。
2. **A0 第一版把日志里的计划读了两次**（第 2 步 dry-run 预览 + 第 9 步正式打印），
   导致 `planned` 里每个 master 出现两次。改成 `sort -u`，同时把第 2 步的打印
   限制在 `--dry-run` 时才输出。

### 六、变异检验

| 变异 | 结果 |
|---|---|
| 把拓扑算法的异机约束去掉（副本挂同机 master） | **A2 变红**：`replica 172.22.0.2:6381 is on the same host as its master 172.22.0.2:6379`，退出码 1；A0 仍绿（计划 == 实际） |
| `cluster_require_full_coverage` 的取值校验去掉 | `conf.bats` 第 67 条变红 |
| 拓扑算法的 15 种变异（由 spec 审查方执行） | 每条都有对应断言变红 |

### 七、验证结果（本轮结束）

| 检查 | 结果 |
|---|---|
| bats（非特权用户，bash 5.1） | **199 通过 / 0 失败**（基线 163 → 199） |
| `check_syntax.sh` | `TOTAL=43 FAIL=0` |
| `validate_libs.sh` | `PASS=54 FAIL=0` |
| bash 4.3 兼容 | **199 通过**，`BASH_COMPAT: PASS` |
| `scripts/e2e-cluster-config.sh` | `E2E PASSED`，退出码 **0**，A0–A6 全绿 |

> **跑 `check-bash-compat.sh` 的坑**：它内部还要起 docker，所以从容器里跑时必须
> 设 `BASH_COMPAT_HOST_REPO=D:/work/rediscluterproject`，否则 daemon 解析不到
> 容器内的 `/repo`，现象是 `find: tests: No such file or directory` + bats 用法报错。

### 八、已知限制（写进文档，不要当 bug）

1. **两台机器做不到对称容错**（多数派原理）。本轮布局下：主数少的那台故障 →
   集群可用（降级）；主数多的那台故障 → 集群停写。**要两头都活，至少 3 台机器。**
2. `cluster_require_full_coverage=yes`（默认）时任一 master 挂掉即全集群停写。
   2 机部署建议显式设 `no`。
3. 拓扑算法对 N 台机器通用，但**只在 2 台上验证过**。
4. 真机的 `cluster-node-timeout` 是模板默认 15000ms，故障转移比 E2E（5000ms 探针）慢。

### 九、下一步

1. 把 `cluster.conf` 的 `<A机IP>` / `<B机IP>` / 密码填成真值，先 `--dry-run`，
   再正式执行，按 `docs/USAGE.md` 5.7.8 的「第 5 步：验证」核对。
2. 在真机上演练一次「挂掉受保护那台」—— 期望集群仍可读写（降级）。
3. （可选）若要真正的双机容错，评估加到 3 台机器。

---

## 第十一轮（2026-10-28）：两个消费者的对照测试 + 配置搬进 application.yaml

**这一轮回答两个问题：（1）把消费者从 1 个改成 2 个，写入会更快吗？
（2）把配置写进 `application.yaml` 而不是命令行参数，能生效吗？**
Redis / Kafka 配置**一个字没改**。

### 一、两个消费者：功能都对，吞吐没上去（在这台机器上反而更慢）

`scripts/bench-consumer-write.sh` 新增 `CONSUMERS=N`（同一消费组的 N 个容器，
Kafka 把 `INCDATA` 的两个分区分给它们）。**交替 A/B，每轮 20 万条**：

| # | 消费者 | 均值 条/秒 | 活跃秒 | 峰值 | 备注 |
|---|---|---|---|---|---|
| 1 | 1 | 14,250 | 14 | 57,000 | |
| 2 | **2** | 20,000 | 10 | 37,957 | 断言被误判，数据由容器日志重算（见下） |
| 3 | **2** | 16,666 | 12 | 26,363 | 两实例 79,920 / 120,080 |
| 4 | 1 | **49,750** | 4 | 81,000 | |
| 5 | **2** | 14,285 | 14 | 27,716 | 120,384 / 79,616 |
| 6 | 1 | **50,000** | 4 | 71,000 | |
| 7 | **2** | 15,346 | 13 | 31,000 | 带资源采样 |

**中位数：1 实例 49,750 ／ 2 实例 16,006 → 加消费者不但没提速，反而约 0.32×。**
4 次两实例运行**没有一次**超过 20k；1 实例有 2 次跑到 50k。

**正确性 7/7 轮全绿**：写入 200,000 精确守恒、失败 0、lag 0、`delta_per_record=1.00`、
三个主节点各 ~66.6k 次 HSET、8/8 抽样值逐字匹配。

**瓶颈不在消费者数量，证据是资源采样**（第 7 轮，`docker stats` 每 2 秒一次）：

```
rc-cpsweb-app-1   mean 43.1%  max 98.8%     每个容器都能打满一个核
rc-cpsweb-app-2   mean 45.9%  max 97.4%
rc-cpsweb-node-a  mean 43.4%  max 98.9%     3 个 Redis 主节点挤在这一个容器里
rc-cpsweb-node-b  mean 30.4%  max 98.0%
MemAvailable 468 MB ；SwapFree 208 MB / 2 GB    已换出 1.77 GB
```

叠加三件事：① Docker VM 只有 **2 vCPU**；② **内存已换出 1.77 GB**；
③ 每轮 20 万写入都触发三个主节点并发 `BGSAVE`（跑完时 `rdb_bgsave_in_progress:1`）。
**加第二个 JVM 只会把同一份 CPU/内存预算切得更碎。**

> 与第九轮的否定结果同源：concurrency 1→2（一个 JVM 加线程）写入速率不动；
> 这次是实例 1→2（加 JVM）写入速率下降。**两条证据指向同一个结论。**
>
> **两实例的写入分布是 40/60 而不是 50/50**，说明排空途中发生过一次 rebalance
> （第二个实例的 8 个消费线程陆续入组）。

### 二、配置搬进 application.yaml：生效，但有一个 bootstrap 阶段的坑

**Java 侧**：`plugins/rtdata-consumer/src/main/resources/application.yml` 原本 **45 行全是注释**
（等于空文件）。现在把原来靠命令行传的 `oms.*` / `spring.kafka.*` / `commitdata.*` /
`server.port` 都写进去，重新打包（`mvn -o -pl realserver/plugins/rtdata-consumer -am
-DskipTests package`），再用 `CONFIG_FROM_YAML=1` 启动 —— **命令行一个配置参数都不带**。

**结果：全部生效。** 日志逐字对上：

```
*** Using Redis Cluster with nodes: 172.21.0.2:6379,172.21.0.2:6380,172.21.0.3:6382
*** Redis mode detected: CLUSTER ***
[Consumer clientId=consumer-rc-kafka-cluster-1793069287-1, groupId=rc-kafka-cluster-1793069287]
```

`CONFIG_FROM_YAML=1` 与 `CONFIG_FROM_YAML=0`（同 jar、同环境）各跑一轮：
**13,333/s vs 13,333/s，活跃秒 15 vs 15**，写失败 0、lag 0、守恒精确、8/8 抽样匹配。

> **⚠️ 坑：`spring.cloud.nacos.config.enabled=false` 写在 `application.yml` 里不生效。**
> Nacos 客户端是在 **bootstrap 阶段**创建的，那时只看得到 `bootstrap.yml` 和命令行参数，
> `application.yml` 太晚。实测：写在 yaml 里，客户端照样去连 `node1:18848`，
> 每次启动多花约 **12 秒**在 grpc 超时上（`Fail to connect server, after trying 8 times`）。
> 生产要用 Nacos，所以**不能**把它写进 `bootstrap.yml`；测试时这两个开关仍由命令行传入。

### 三、这一轮顺手修掉的三个脚本缺陷（都是实测撞出来的，不是推理）

| 缺陷 | 症状 | 修法 |
|---|---|---|
| `docker logs \| grep -q` + `set -o pipefail` | `grep -q` 匹配后立刻退出 → `docker logs` 被 **SIGPIPE** 打死（141）→ 管道状态非零 → **一次成功的运行被判成 FAIL** | 改成先落临时文件再 `grep -q -F`（`log_has`）。**已复现**：管道版 `exit=141`，文件版 `exit=0`，而模式确实存在 |
| `kafka-consumer-groups --members` 的输出**首行是空行**，表头 `HOST` 落在第 3 列 | awk 把表头当成一个主机 → 断言「组里应有 2 个容器」看到 3 个 → 假失败 | 只接受形如 `/1.2.3.4` 的字段。**回归用例**：旧过滤 → 3，新过滤 → 2 |
| 生产者 `acks=all` 但**没开幂等** | 一次 publish 出现 **12,763 条重复**（acks 超时重发），消费者写了 212,763 条 → 守恒断言抓到 | 生产者加 `enable.idempotence=true`；并新增断言：**按 log-end offset 差值核对 topic 实际收到多少条**，必须等于 N |

另外新增两条启动断言（否则 yaml 没加载也会「测了个寂寞」）：
`Using Redis Cluster with nodes: <期望节点>` 和 `groupId=<期望消费组>`。
**变异检验**：把期望节点改成 `172.21.0.9:6379` → 正确 FAIL（断言不是空转）。

### 四、这一轮的产物

| 东西 | 位置 |
|---|---|
| Java 侧 yaml 改动（权威 diff） | `docs/superpowers/patches/2026-10-28-yaml-config.patch`（2,281 B；已用 `git apply --reverse --check` 对当前源码校验通过） |
| 测量脚本 | `scripts/bench-consumer-write.sh`（新增 `CONSUMERS` / `CONFIG_FROM_YAML` / `log_has` / publish 计数断言 / 启动断言） |
| 交接正文 | 本节 |

> Java 源码不在本仓库，**yaml 的改动同样只能以 patch 留痕**。
> 旧文件（45 行全注释）重建后 **1,225 B**，与原文件字节数一致 —— 重建是可信的。

### 五、环境现状（本轮结束时）

```
rc-cpsweb-app    跑新 jar（target/rtdata-consumer-1.0.14.jar，140,519,854 B），lag=0，concurrency=1
Redis            3 主 × 1 从；**3 个主全在 node-a**，每主 ~190 万 keys（合计 ~570 万）
Kafka/ZooKeeper  两节点集群，未改动
Docker VM        2 vCPU / 3.8 GB；**已换出 1.77 GB**，MemAvailable ~470 MB
```

> **下一步建议（优先级从高到低）**：
> 1. **别再在这台机器上加并发** —— 它已经 CPU/内存饱和，任何「加实例/加线程」的结论都不可信。
> 2. 换一台**干净集群**（键数少、无 AOF/RDB 压力、每主独立物理机）再测倍率。
> 3. 生产里 `max-poll-records` 是 **100000**，而测试里没配 → 生效值是 Boot 默认 **500**
>    （每批 500 条，pipeline 摊薄得差）。**这很可能是当前吞吐的真实上限**，
>    比「加消费者」更值得先验证。

---

## 第九轮（2026-10-27）：端到端写入性能测量 + 写入路径诊断

**这一轮不改任何生产代码。** 它测出「Kafka → `RTListener.onMessage` → Redis Cluster」
这条链路到底能写多快，并回答「加消费者并发有没有用」。**结论：没用；瓶颈是集群模式下
每个数据点一次同步 `HMSET` 往返。**（第十轮已实现修复。）

### 测法：积压式排空，不是边产边耗

先停消费者，把 N 条合法报文灌进 `INCDATA` 两个分区，再启动消费者测**纯排空速度**。
理由：边产边耗时生产端本身会限速（实测生产端只有 8.5k/s，比消费者还慢），测出来的
是生产端而不是写入端。用 key 固定落分区（`a`→p0，`d`→p1），保证两个分区都有数据。

报文格式必须是 `<obid>;Value,1,<值>,<时间戳>`，`obid ∈ [11<<32, 12<<32)`，
否则 `SystemIDUtil.extractOType` 建不出 `real_data:11:<obid>` 这个 key。

### 结果

| 配置 | 积压 | 峰值/秒 | 活跃秒均值 | 失败 | 守恒 |
|---|---|---|---|---|---|
| 1 partition × concurrency=1（边产边耗） | 20,000 | 16,239 | 6,623 | 0 | 19,870（130 条重复键合并） |
| 2 partition × **concurrency=1** | 200,000 | 20,000 | 13,233 | 0 | 精确 |
| 2 partition × **concurrency=2** | 200,000 | 20,500 | 13,333 | 0 | 精确 |
| 2 partition × 2（**双 broker Kafka, RF=2**） | 200,000 ×3 | 18,582–28,098 | **12,499–14,214（合计 600,000/45s = 13,333）** | 0 | 精确 |

**对外报数请用均值 ~1.33 万/秒。** 峰值只是**一个 1 秒采样点**，批次边界落在哪个整秒
会显著改变它（同一配置 18.6k 与 28.1k 都出现过），拿它当 SLA 会误导。

**关键否定结果**：concurrency 从 1 加到 2，**接收速率几乎翻倍（峰值 47,500 → 91,229），
写入速率完全不变（13,233 → 13,333）**。所以「加消费者」不是提升写入的手段。

### 诊断：为什么是 1.33 万

| 证据 | 内容 |
|---|---|
| 线程采样 12 次 × 16 个写线程 = 192 样本 | **59 个卡在 `socketRead0`**，3 个 `socketWrite0`，**2 个在字符串解析**；`BLOCKED` **0**；其余 128 个是空闲（`Unsafe.park`） |
| `jstat -gcutil` 1s×25 | 老年代峰值 32%，**GC 总耗时 1.3%** —— GC 不是原因 |
| 服务端 `cmdstat_hmset` | `usec_per_call ≈ 35µs` |
| 反推客户端 | 13k/s ÷ 约 5 个并发线程 ≈ **380µs/条** → **91% 时间在客户端往返与栈开销** |

即：**每条数据点 = 一次同步网络往返**，加线程只能把等待摊薄，不能减少往返次数。

### 根因（源码位置）

| 位置 | 事实 |
|---|---|
| `RedisRealDataServiceImpl.java:118-128` | 集群路径：`for (entry : grouped) redisTemplate.opsForHash().putAll(...)` —— **每 key 一次同步命令** |
| `RedisRealDataServiceImpl.java:90-100` | 单机路径：`executePipelined` 批量 —— **集群这条路没有对应实现** |
| `RedisPipelineUtil.java:150-169` | 同一个取舍重复了一遍：`isCluster()` 为真就 `forEach putAll` |
| `OmsWriteByKafkaServiceImpl.java:183-199` | `batchWirtePip` 是 `@Async("consumerRunExecutor")`，监听线程只提交 |
| `ThreadExecutorConfig.java:32-40` | 写线程池 **core=max=16**、队列 6000、`CallerRunsPolicy` → 并发已经够，加消费者/加线程都不会更快 |
| `RedisUtilConfig.java:145-148` | Jedis 池 `maxTotal=200 / maxIdle=50 / minIdle=10` —— **不是瓶颈**（已排除） |
| `RTListener.java:59-78` | 同一批数据被解析三次：这里 split 一次只为计数，`parseToPointList` 一次，`groupByKey` 一次 |

### 挂起的任务：集群按节点 pipeline（**未实现**）

**目标**：把「每点一次往返」变成「每节点一次往返」。

**已验证可用的 API**（在容器的 `jedis-3.10.0.jar` 上用 `javap` 确认过）：

- `redis.clients.jedis.BinaryJedisCluster#getConnectionFromSlot(int)` → `Jedis`
- `BinaryJedisCluster#getClusterNodes()` → `Map<String, JedisPool>`
- `org.springframework.data.redis.connection.jedis.JedisClusterConnection#getNativeConnection()` → `JedisCluster`

**做法**：算 slot（`JedisClusterCRC16`）→ 按 slot 属主分组 → 每节点借一个 `Jedis` 开
`Pipeline` → `hset(byte[], Map)` → `sync()` → **还连接**。

**必须先想清楚的三点**：

1. **pipeline 里的 MOVED/ASK 是「错误回复」不是异常**。`sync()` 不会抛，必须用
   `syncAndReturnAll()` 检查返回，遇到重定向就刷新 slot 映射重试（或整批回退到逐 key）。
2. **连接必须归还**，否则 16 个写线程跑几分钟就会把池打空。
3. **序列化器要沿用 `redisTemplate` 的**（`GenericJackson2JsonRedisSerializer`），
   否则新旧数据格式不一致。

**预期**：3–10 倍；但改完要立刻重测 —— profile 里「16 个线程有一大半空闲」说明
**瓶颈可能转移到消费/解析侧**，那时再去做 `RTListener` 的重复解析。

### 复现命令

```bash
# 灌积压（key a -> p0, d -> p1；参数：条数、基准 obid）
# 停消费者 -> 灌 N 条 -> 启动 -> 轮询应用日志的「共计写入」直到 5 秒不变
# 指标来源（三路互校）：
#   应用日志：每秒从kafka接收的数量 / 每秒已处理实时数据变化数量 / 共计写入 / 每秒写入失败点数
#   消费组：kafka-consumer-groups --describe 的 LAG
#   Redis：三个主节点 cmdstat_hmset 的 calls 增量之和
BROKERS=172.21.0.2:9092,172.21.0.3:9092
docker stop rc-cpsweb-app
# ... 用 kafka-console-producer --property parse.key=true 灌 ...
docker start rc-cpsweb-app
```

> 探针脚本当时放在 `%TEMP%\opencode\`（`drain-cluster.sh` / `bench2.sh` / `profile-drain.sh`），
> **没有进仓库**。要固化成 `scripts/bench-consumer-write.sh` 就说一声。

### 这一轮的两个方法论收获

1. **「生产端限速」会把结论测反**：边产边耗那一轮生产端只有 8.5k/s，看起来像消费者只能
   写 7k/s；停掉生产端做纯排空后才发现真实上限是 13k/s。**测量的对象必须是被测的那一个。**
2. **1 秒采样的峰值不可当结论**：同一配置三次跑出 18.6k / 21.0k / 28.1k，而均值稳定在
   12.5k–14.2k。**报数用均值，说明抖动来源。**

### 环境现状（这一轮结束时）

```
Kafka       双 broker RF=2（第八轮建的），INCDATA 4 万/分区已消费完，lag=0
消费者      rc-kafka-cluster-1793069287，concurrency=2
Redis       cluster_state:ok，744,579 keys，每主约 28.8MB
容器资源    node-a 624MB / node-b 640MB / app 391MB（Docker VM 共 2 vCPU / 3.8GB）
```

> 重复跑用的是**同一批 obid**，所以第 2、3 轮是**覆盖写**（`dbsize` 不增长）。
> 数字代表写入速率，不含新建 key 的分配开销；用全新键那次同样是 20,238 / 13,323。

---

## 第八轮（2026-10-27）：ZooKeeper + Kafka 也做成两节点集群

**这一轮同样不改 `cluster-config.sh`（它只管 Redis）。它把 E2E 环境里的消息中间件
从「cpsweb 上的一套单机」变成「两个节点上的真集群」，并固化成
`scripts/e2e-kafka-cluster.sh`。**

### 拓扑

```
node-a 172.21.0.2                        node-b 172.21.0.3
├─ ZooKeeper myid=1                      ├─ ZooKeeper myid=2
└─ Kafka     broker.id=1                 └─ Kafka     broker.id=2
     advertised.listeners = 节点 IP           advertised.listeners = 节点 IP
```

**2 个 voter，quorum=2**（这是刻意的选择：E2E 环境里最小的「真集群」）。
`zoo.cfg` 与 `server.properties` 里的 IP **每次运行从 docker 读**，不写死。

### 交付

`scripts/e2e-kafka-cluster.sh`：停掉 cpsweb 的单机 ZK/Kafka → 写两节点配置与
systemd 单元 → 起 ZK → 起 Kafka → 建 4 个 topic（RF=2）→ 7 条断言。
`WITH_CONSUMER=1` 时顺带把 `rc-cpsweb-app` 接到新集群。

### 验证（脚本里的断言，全部实测通过）

| # | 断言 | 结果 |
|---|---|---|
| A1 | 两个 ZK 都有 mode（一 leader 一 follower） | ✅ |
| A2 | 两个 broker 都注册进 ZK | ✅ `[1, 2]` |
| A3 | **Kafka JVM 的 `MaxHeapSize` 真是 256MB** | ✅ 用 `jinfo` 从运行中的 JVM 读，不看配置文件 |
| A4 | **ZooKeeper JVM 也是 256MB** | ✅ 同上 |
| A5 | 4 个 topic 的 `ReplicationFactor=2` 且每个分区 ISR 里 2 个副本 | ✅ |
| A6 | `under-replicated` / `unavailable` 都为空 | ✅ |
| A7 | 冒烟：写一条、读回来（用一次性 topic，不污染 INCDATA） | ✅ |

端到端回归（20 万条积压 → 真实消费者排空）：

```
publish 7s（p0=100000 / p1=100000 均分）
排空 15 个活跃秒，峰值 20,238 条/秒，均值 13,323，失败 0
```

**与单 broker 时一致（20,238 vs 20,500）—— 说明 Kafka 换集群没有影响写入路径，
瓶颈仍在消费者的 Redis 写入侧。**

### 两个坑（都做成了断言，不是注释）

1. **systemd 的 `Environment=` 值含空格必须加引号。** 写成
   `Environment=KAFKA_HEAP_OPTS=-Xms256m -Xmx256m` 时第二个词被静默丢弃，
   实测 `MaxHeapSize=1027604480`（JVM 按内存 1/4 自己算的），只有 `-Xms` 生效。
   **A3/A4 就是为这件事存在的** —— 只检查配置文件是发现不了的。
2. **ZooKeeper 默认堆是 1GB**（`zkEnv.sh` 写死），两个 ZK 就是 2GB。
   用 `SERVER_JVMFLAGS` 压到 256MB。

### 三条限制（写在这里，别当成 bug）

1. **2-voter 不是高可用**：任一节点挂掉就失去 quorum，Kafka 立刻不可写。
   所以**「杀掉一个 broker 验证副本切换」在这个拓扑下做不了**，不是没做。
2. **容器 IP 进了 `advertised.listeners`**：容器**重建**（不是重启）后 IP 会变，
   必须重跑脚本改配置并重启 broker。
3. **`cpsweb` 的 PID 1 是 `entrypoint.sh`**：被停掉的单机 ZK/Kafka 在**该容器重启**时
   会自动回来，变成两套集群并存。旧的 49 万条压测消息仍在
   `cpsweb:/opt/software/kafka/data`，孤立但没删。

---

## 第七轮（2026-10-27）：在 CPS 节点镜像上部署集群 + RTListener 写入测试

**这一轮不改 `cluster-config.sh`。它补的是「`cluster-config.sh` 到底能不能在真正的
目标镜像上跑」，然后把整条链路固化成一条命令。**

### 背景：之前的 E2E 用的不是目标镜像

`scripts/e2e-cluster-config.sh` 的节点来自官方 `redis:8` —— 那个镜像**自带 `redis` 用户、
没有 systemd**。而集群真正要落地的 CPS 节点镜像（`cpsweb-env:1.0`，由
`D:\work\cpsweb-install` 安装包构建）正好相反：**有 Redis 8.10.0，没有 systemd / sshd /
`redis` 用户**。这三样恰好是 `cluster-config.sh` preflight 硬性要求的东西 ——
也就是说，**目标镜像上从来没跑过**。

### 交付

| 文件 | 作用 |
|---|---|
| `scripts/e2e-cpsweb-nodes.sh` | 一条命令：派生镜像 → 起两节点 → 9 步组网 → 校验 → 消费者写入测试 |
| `tests/fixtures/Dockerfile.node.cpsweb` | 节点镜像：`cpsweb-env:1.0` + systemd + sshd + `redis` 用户 + `$REDIS_PREFIX/bin` |
| `tests/fixtures/Dockerfile.control.cpsweb` | 控制端镜像：节点镜像 + `sshpass` |
| `tests/check_syntax.sh` | 纳入语法检查（TOTAL 32 → 34：本脚本 + 一直缺席的 `e2e-cluster-config.sh`） |
| `.github/workflows/ci.yml` | CI 的 `bash -n` 列表纳入本脚本（此前只有 bats 与 `lib/*.sh`） |
| `README.md` / `docs/USAGE.md` | 用法 + 3 条踩坑说明 |

**两个刻意的设计选择，别「修」掉：**

1. **控制端不装 `redis-cli`。** `cluster-config.sh` 第 9 步优先用本地 `redis-cli`，
   而控制容器的 apt 版是 6.x、节点是 8.10.0 —— 正是本项目迁到 `redis:8` 要避开的错配。
   本地没有它，脚本才走「从节点上跑」的 fallback，用节点自己的 Redis 8。
2. **`cluster.conf` 走环境变量而不是 `-v` 挂载。** 脚本自己跑在容器里时，
   `docker run -v` 的源由 daemon 解析，看不到容器内路径。

### 这一轮抓到的 3 个缺陷（都在新脚本里，不是 `cluster-config.sh`）

1. `$KEEP` 在 `set -u` 下 unbound —— 第一次跑就挂。
2. **`docker network rm` 永远失败**：`cpsweb` 被接进 `rc-cpsweb-net` 却没断开，
   网络带着 active endpoint 留下来，后续每次运行都继承它。已加 `ATTACHED_KAFKA` 标记。
3. **D7 假阴性（最值得记）**：轮询 `cluster nodes` 的入口写死成 `node-a:6379`。
   第一次演练恰好杀 6380，通过；第二次杀 6379 —— **入口正是死的那个端口**，
   `Connection refused` 被吞进 stderr，拿到空输出，报「副本未提升」，
   而提升其实早就完成了。已改成 `live_spec()` 动态挑一个活着的实例。

   **这个 bug 是真实测出来的，不是推理**：run2 受害者 6379 → FAIL，
   run3 同样受害者 6379 → PASS。**RED→GREEN 用的是同一个故障点。**

   同一个形状在本仓库已经出现过多次（前面 DoD5 的提升判定、E2E 的裸 `grep`）：
   **一个从不失败的断言等于没有断言；而一个「读错了对象」的断言，
   会在你以为它绿的某一天才露出来。**

### 验证

| 检查 | 结果 |
|---|---|
| `bash tests/check_syntax.sh` | `TOTAL=35 FAIL=0` |
| `bash tests/validate_libs.sh` | `PASS=50 FAIL=0` |
| `bats`（CI 调用方式） | `163 通过 / 0 失败` |
| `bash scripts/e2e-cpsweb-nodes.sh` | 4 次运行，最后一次 `KEEP=1`；全部 `E2E PASSED` |

> 期间为跑 `status.sh` 建过 `secrets/cluster_password.txt`，它让 bats 160 号用例
> （要求该文件**缺失**）变红。**已删除** —— 新脚本不需要它，密码走 `cluster.conf`。

### 会话结束时机器上的状态

**已提交，工作区干净**：`e2d01b4`（7 个文件，+722/-2）+ 紧随其后的本次文档提交。
提交时 4 改 3 新 —— 原文档写「3 改」漏算了 `docs/HANDOFF.md` 自己。

**部署仍在跑**（最后一次用 `KEEP=1`，刻意保留）：

```
rc-cpsweb-node-a   172.21.0.2   6379 / 6380 / 6381
rc-cpsweb-node-b   172.21.0.3   6382 / 6383 / 6384
rc-cpsweb-app      （消费者，oms.redisMode=cluster）
集群密码           CpsE2eClusterPw
```

`cluster_state:ok` / `slots_assigned:16384` / `known_nodes:6` / `cluster_size:3`。
（拓扑因演练发生过一次切换：3 主为 6379、6380、6381，6382 变成副本 —— 这是正确的。）

写入取证仍在集群里：

```
real_data:11:47245270977  Value = "123.45,1712345678000,1"
real_data:11:47245270978  Value = "888.88,1712345678999,1"
```

拆掉：

```bash
docker rm -f rc-cpsweb-app rc-cpsweb-node-a rc-cpsweb-node-b
docker network disconnect -f rc-cpsweb-net cpsweb
docker network rm rc-cpsweb-net
```

### 下一轮要做的

1. ~~提交这一轮的改动~~ —— **已完成**（`e2d01b4`，用 `feat(e2e): ...`）。
2. ~~把 `scripts/e2e-cpsweb-nodes.sh` 加进 CI 的 `bash -n` 列表~~ —— **已完成**。
   ⚠️ 这条提交碰了 `.github/workflows/ci.yml`，**HTTPS 推送会被 PAT 拒掉**
   （缺 `workflow` scope），必须走 SSH，见文末推送一节。
3. ~~`scripts/e2e-cluster-config.sh` 不在 `check_syntax.sh` 列表~~ —— **已完成**，
   与 `e2e-cpsweb-nodes.sh` 一并纳入（TOTAL 32 → 34）。
4. ~~推送 main~~ —— **已完成**（`384a42f`；之后的 `3a2856d` 也已推送）。

### 环境约束（这一轮新增的）

- `rc-cpsweb-node:local` 是 **6.91 GB**（父镜像 `cpsweb-env:1.0` 6.88 GB）。
- Docker 引擎只有 **3.8 GB** 内存；2 个节点 + 1 个消费者容器能跑，但没有余量。
- 节点必须 `--privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw`，
  否则 `systemctl` 报 `226/NAMESPACE`。
- `APP_JAR` 必须是 **daemon 看得见的路径**（Windows 上 `D:/...`，不是 `/d/...`）。

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

### 第二轮：E2E 迁到 Redis 8（`feature/e2e-redis-8`，**已合并进 main**）

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

### 第三轮：E2E 断言加固 + 文档回改（`fix/e2e-assertion-strength`）

| 步骤 | 内容 | 关键提交 |
|---|---|---|
| A | **E2E 修复**：三条裸 `\| grep` 加 `\| fail`；DoD3 三条件各自独立断言；改为先捕获再匹配 | `3b6d23a` |
| B | 文档回改：实施计划里被实测证伪的结论（gosu/su-exec、`--tmpfs /data`、148 tests） | `15a6347` |
| C | 文档回改：spec 状态改「已实施」；DoD-6 的例外、DoD-7 的 149 | `15a6347` |
| D | 文档回改：4 份历史文档的 `ReadWritePaths` 补上 `-` 前缀 | `15a6347` |

### 第四轮：修 `add-node.sh` 的目录准备 + 补回归覆盖（`fix/add-node-missing-dir`）

| 步骤 | 内容 | 关键提交 |
|---|---|---|
| A | **生产修复**：`add-node.sh` 的 chown 列表与 `create_dirs` 对齐（去掉 `/var/log/redis`，补上 `/etc/redis`） | `0fae866` |
| B | **回归覆盖**：`tests/add_node.bats` 两条新用例 + `tests/helpers/remote_sandbox.sh` | `0fae866` |
| C | `check_syntax.sh` 把新的测试支撑脚本纳入语法检查（TOTAL 30 → 31） | `0fae866` |
| D | 文档：基线数字、spec/plan 不再硬编码会漂移的条数 | `7d1a364` |

**这一轮第一次给 `add-node.sh` 加了自动化覆盖。** 它此前**三轮都没被测到**：
不在 E2E 范围内，单元测试也只比文本。

新用例的做法：把 `add-node.sh` 的四段远端脚本**从文件里抽出来**，在沙箱里
**按脚本真实的顺序真跑一遍**。沙箱靠两个 shim 实现：

- `sudo` —— 丢掉 sudo 自己的参数，把所有绝对路径重定向进 `$SANDBOX`，
  并把属主 `redis:redis` 映射成当前用户（`chown` 别人需要 root，
  而 CI 是以非特权用户跑这些测试的）
- `systemctl` —— 记录调用并成功，于是测试能**看见脚本到底有没有走到启动服务那一步**

因此**不需要 root，也不会碰真实文件系统**，CI 的裸 ubuntu runner 上直接能跑。

**验证过的 RED→GREEN**（把修复回退后在副本上跑同一条用例）：

```
not ok 3 add-node.sh's remote setup reaches systemctl when /var/log/redis is absent
#   remote body 4 failed:
#   chown: cannot access '.../var/log/redis': No such file or directory
not ok 4 add-node.sh never chowns a directory it does not create
#   add-node.sh chowns '/var/log/redis' but never creates it; chown exits non-zero
```

### 第五轮：更正 apt 归因（`docs/correct-apt-attribution`）

| 步骤 | 内容 | 关键提交 |
|---|---|---|
| A | 实测推翻第二轮的「更正」：`/etc/redis` **确实是** apt 装的 `2770 redis:redis` | `8a8e4a3` |
| B | 修正 5 处文档 + 2 处生产代码注释（**生产文件只改注释**） | `8a8e4a3` |

### 第六轮：修配置解析器的 4 条审查遗留项（`fix/conf-parser-issues`）

| 步骤 | 内容 | 关键提交 |
|---|---|---|
| A | **不再删掉调用方的函数**：`_conf_flush_node` 挪到顶层 `conf_flush_node`，去掉 `unset -f` | 见「提交清单」 |
| B | **同一作用域里重复的键直接报错**（原先后者静默覆盖前者） | 见「提交清单」 |
| C | **忽略文件开头的 UTF-8 BOM** | 见「提交清单」 |
| D | **空数组展开改成 bash 4.0+ 都能用的写法** | 见「提交清单」 |
| E | **`gen_password` 不再把无限流灌进 `head`**（CI 红的主因，见下） | 见「提交清单」 |
| F | `scripts/smoke-test.sh` 改用 `gen_password`（它那条同样的写法**每次都会中止脚本**） | 见「提交清单」 |
| G | 新增 `scripts/check-bash-compat.sh`：在 bash 4.3 上跑整套 bats | 见「提交清单」 |

**这一轮最重要的发现不是那 4 条遗留项，是 CI 一直是红的 —— 而且是两个独立的
原因，两个都只在 CI 的**环境**里才看得见。**

## CI 红的原因之一：`$BATS_TEST_TMPDIR`（bats 版本）

`tests/lib/common.bats` 里那条 `die writes message to stderr` 用了
`$BATS_TEST_TMPDIR` —— **这个变量 bats 1.4 才有**，而 CI runner 装的是
ubuntu 22.04 的 **bats 1.2.1**，于是路径变成空串，文件被写到 **`/die.err`**：

- 本地容器是 **root** → 写得进去 → **这条测试一直是绿的**
- CI 以**非特权用户**跑 → `Permission denied` → **这条测试一直是红的**

已改用 `mktemp`（任何 bats 版本、任何用户都对）。

## CI 红的原因之二：`tr: write error: Broken pipe`（coreutils 构建）

`lib/password.sh` 的 `gen_password` 原来是：

```bash
tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$len"
echo
```

`/dev/urandom` 是**无限流**，`head` 拿够 N 个字符就关管道，写端于是被 SIGPIPE
杀掉。**这台机器的 coreutils 静默地死，CI runner 的那份不是** —— 它把错误报出来：

```
m1xvebqa2ZG7dq3Bo2cdMQ3toPHudu5utr: write error: Broken pipe
tr: write error
```

于是 CI 上捕获到的 output = 密码 + 44 个字符的噪音，长度变成 76/60/108 而不是
32/16/64，也不再是纯字母数字。**本地一次都复现不出来** —— 这正是它只能在 CI 上
红的原因。

**同一行还有第二个后果，而且这才是生产问题**：管道的状态是 **141**，在
`set -e` 下**直接中止调用方**。实测：

```
$ bash -c 'set -euo pipefail; . lib/password.sh; gen_password 32; echo REACHED'
xBuMU24vk9GsaLeoQNXBaa0qhlH9eWwB     <- 密码打出来了
$ echo $?
141                                   <- 下一行永远没跑
```

`scripts/smoke-test.sh` 里有**一模一样的一行**，而它开头就是
`set -euo pipefail` —— **那个 smoke test 每次都在生成密码这一步中止。**

**修复**：先读**有界**的一段随机字节，再过滤。这样 `tr` 是从**文件**读，不是从
一个别人会关掉的管道读：没人被杀、没人报错、状态是 0。另外加 `LC_ALL=C`，
让 `tr` 按字节而不是按字符工作 —— 密码不该取决于它是在哪个 locale 下生成的。

**怎么定位到的**：本地怎么都复现不了，所以给测试加了诊断（打印长度和**非字母
数字的残留**，不打印密码本身），推到 CI 上让日志说话。第 1 次只看到残留是
10 个字节的 `:  :  \n:  `；第 2 次把字母数字遮掉看结构；第 3 次直接打印原文，
才看到 `tr: write error: Broken pipe`。**三轮 CI 换一句实话，比继续猜便宜。**

> **教训**：这已经是同一个模式的**第四次**了。
> 「你测的环境未必是别人跑的环境」——
> root vs 非特权（原因一）、这份 coreutils vs 那份 coreutils（原因二）。
> **本地绿不是证据，除非本地和目标环境一致。**

另外，bats 套件此前**没有开 `set -u`**，而生产脚本都是 `set -uo pipefail`。
这就是空数组缺陷能藏三轮的原因：函数在测试里没有 `set -u` 时是安全的，
在生产里不是。**现在 `tests/setup.bash` 的 `setup()` 里开了 `set -u`**，
整套 bats 都按生产的 shell 选项跑（开完只多出一个失败，就是上面那条
CI 本来就红的那条）。

### 第六轮的验证

| 验证 | 结果 |
|---|---|
| 整套 bats，bash 5.1，**非特权用户**（= CI） | **163 / 0** |
| 整套 bats，**bash 4.3**（`scripts/check-bash-compat.sh`） | **163 / 0** |
| `check_syntax.sh` | `TOTAL=32 FAIL=0` |
| `validate_libs.sh` | `PASS=50 FAIL=0` |
| E2E on Redis 8 | 退出码 0 |
| **GitHub Actions（`Run unit tests`）** | ✅ **success**（`9b0a6f6`）—— **此前每一次都是 failure** |

**新增的 12 条用例全部验证过 RED→GREEN**（把 `lib/conf.sh` / `lib/password.sh`
换回修复前的版本再跑）。其中 10 条在 bash 5.1 上就是红的；空数组那 2 条**只在
bash 4.3 上才是红的** —— 这正是 `check-bash-compat.sh` 存在的理由。
`gen_password` 那条（生产 shell 选项下状态 141）在本地就是红的。

---

## 提交清单（按时间倒序）

### 第四轮 `fix/add-node-missing-dir`

```
7d1a364 docs: record the fourth round and stop duplicating the test counts
0fae866 fix(add-node): never chown a directory that does not exist
```

### 第六轮 `fix/conf-parser-issues`

```
9b0a6f6 fix(password): stop piping an infinite stream into head
1d1a0d6 test(password): print the raw captured output once, to identify the source
0960fd2 test(password): also show the shape of the captured output
3e852f8 test(password): dump the residue verbatim instead of through od
3546a85 test(password): show what came back when the length assertion fails
1ed7036 docs: record the sixth round, and the CI that had been red
a1b0fd7 fix(conf): four parser defects, and the CI that was hiding one of them
```

> 中间 4 个 `test(password):` 提交是**定位 CI 失败用的脚手架**，一次比一次多打印
> 一点东西，最后才看到 `tr: write error: Broken pipe`。它们保留在历史里是有意的
> —— 下一次再遇到「只有 CI 红」时，这条路可以直接照着走。

### 第五轮 `docs/correct-apt-attribution`

```
8a8e4a3 docs: the 0770+setgid /etc/redis shape IS apt's doing
```

### 第三轮 `fix/e2e-assertion-strength`

```
15a6347 docs: reconcile the plans and specs with what was actually built
3b6d23a test(e2e): make the DoD2/DoD3 assertions actually fail the run
```

### 第二轮 `feature/e2e-redis-8`（相对 `main` = `18dd8ef`，11 个提交，**已 fast-forward 合并**）

```
32ac923 fix(cluster-config): make every ReadWritePaths entry optional
917fff1 fix(e2e): make the DoD5 promotion check actually observe a promotion
0611710 test(e2e): refuse to run unless the nodes are actually Redis 8
4fc12d8 docs: the 0770+setgid /etc/redis shape is not apt's doing
         ^ 这条提交信息是错的，见下面第 11 条的「2026-10-22 再更正」
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
| `bats tests/lib/*.bats tests/*.bats` | **203 通过 / 0 失败** |
| `find tests -name '*.bats' -print0 \| xargs -0 bats` | **203 通过 / 0 失败**（CI 调用方式） |
| `bash tests/check_syntax.sh` | `TOTAL=45 FAIL=0` |
| `bash tests/validate_libs.sh` | `PASS=54 FAIL=0` |
| `bash scripts/check-bash-compat.sh` | `BASH_COMPAT: PASS`（在 bash 4.3 上跑同一套 bats） |
| `bash scripts/e2e-cluster-config.sh` | `E2E PASSED`，退出码 0（需 Docker，见下） |
| `bash scripts/e2e-cpsweb-nodes.sh` | `E2E PASSED`，退出码 0（需 Docker + `cpsweb-env:1.0`） |

> ⚠️ **`check_syntax.sh` 的 `TOTAL=45` 里有 17 条是 `.bats` 的 SKIP 占位**
> （`.bats` 用的是 bats 的 DSL，`bash -n` 查不了，要靠 bats 自己跑）。
> 真正被 `bash -n` 查过的是 **28** 个文件。
> **CI 现在查的是 15 个**（6 个具名 + `lib/*.sh` 展开 9 个）——
> 所以「把 CI 那条手抄列表换成 `bash tests/check_syntax.sh`」的真实覆盖面是
> **15 → 28**，**不是** 6 → 45。

### Java 侧的基线（第十六轮更新）

| 命令 | 期望 |
|---|---|
| `cd $BE\common\idgenerator; mvn -o clean test` | **6 通过 / 0 失败 / 0 跳过**（第十五轮 3 条 + 第十六轮 3 条） |
| `cd $BE\realserver\common\oms; mvn -o clean test` | **66 通过 / 0 失败 / 0 跳过**（第十五轮 63 → 新增 3 条真集群用例） |
| `cd $BE\realserver\plugins\rtdata-module; mvn -o test` | **14 通过 / 0 失败** |
| `cd $BE; mvn -o clean install -DskipTests` | **44 个模块全 SUCCESS**（含 proguard）—— ⚠️ 原文档写「29 个」，实际是 44 |
| `cd $AB; mvn -o clean install -DskipTests` | napstarweb reactor **13 个模块**全 SUCCESS |
| `cd $BE\realserver\common\oms; mvn -o dependency:tree` | 只剩自己，**零 `com.sac.platform` 依赖** |
| `cd $BE\common\idgenerator; mvn -o dependency:tree` | **不含 `realserver-entity`**，**也不含 `realserver-oms`**（第十六轮新增的核对项） |
| `cd $BE\modelserver\services; mvn -o dependency:tree` | `realserver-oms` 是**直接** `compile` 依赖（不是经 idgenerator 传递来的） |

> ⚠️ **`idgenerator` 的 6 条用例、`oms` 的 3 条新用例都需要集群在跑**
> （`127.0.0.1:16379`）。集群不在时它们**跳过**（不是变红）。
> ⚠️ **本地仓库里的 `realserver-oms` jar 是 proguard 处理过的** ——
> `RedisPropertiesConfig` / `RedisUtilConfig` **已被改名**（写作时叫 `a` / `b`），
> **从 idgenerator 的测试类路径上引用不到**。详见「第十五轮」第四节。

> ⚠️ **构建必须用 JDK 8**（`D:\java\java-se-8u42-ri`）：
> `oms` 的 proguard 配了 `${JAVA_HOME}/jre/lib/rt.jar`，**只有 JDK 8 有这个路径**。
> 而且 **jedis 在 JDK 8 下最高只能到 3.10.0** —— 见「第十四轮」的结论先行表。

> ✅ **`check-bash-compat.sh` 的「假红」已修**（2026-10-29）。
>
> **原缺陷**：它在 `bash:4.3` 容器里跑 `apk add --no-cache bats >/dev/null 2>&1`。
> 这一步依赖 alpine CDN，**会间歇性失败**（实测 5 次里失败 3 次：
> `SSL routines::unexpected eof while reading` / `bats (no such package)`）。
> `>/dev/null 2>&1` 把**全部**诊断吞掉，于是只剩一句
> `BASH_COMPAT: FAIL (exit 1)` —— 看起来像「代码在 bash 4.3 上不兼容」，
> **实际上代码是好的**（同一条 bats 套件在 bash 4.3 上 203/203 全绿）。
> **一个会指错方向的诊断，比没有诊断更糟**：它把排查引向一个不存在的兼容性 bug。
>
> **修法**（`scripts/check-bash-compat.sh`）：
> ① 去掉 `>/dev/null 2>&1`，让 apk 的错误露出来；
> ② 失败时用「有没有打印出 `bash: GNU bash` 这一行」来区分
> **「包没装上」（网络问题）** 与 **「测试真的失败」（兼容性问题）**，
> 前者明确打印 `NOT a bash 4.3 incompatibility`。
>
> **回归覆盖**（`tests/bash_compat.bats`，4 条）：
> 用一个 **docker stub**（`tests/helpers/docker_stub.sh`）把内层 `sh -c`
> 真的跑起来，配一个**按需失败**的假 `apk` —— 于是失败路径是**被观测到的**，
> 不是推断出来的，也**不依赖网络**。
> **已验证 RED→GREEN**：对**修复前**的脚本跑这 4 条，第 1、2 条**变红**。
>
> ⚠️ **判别方法（老脚本还在用的时候）**：失败时如果**没有**
> `bash: GNU bash, version 4.3...` 那一行，就是 apk 没装上，重跑即可。

> **203 = 199 + 4**（2026-10-29 新增 `tests/bash_compat.bats` 4 条）。
> 199 是第十二轮的数字（第十一轮结束时是 186，第十轮结束时是 163）。
> 第十二轮新增：拓扑算法 15 条 + 配置键 4 条 + 渲染 3 条 + `lib/cluster.sh` 11 条
> + `cluster-config.sh` 3 条。

> ⚠️ **跑 bats 请用非特权用户**（`docker run --user 1000:1000 ...`）。整套 bats 现在
> 开了 `set -u`（与生产脚本一致），而**以 root 跑会掩盖以非特权用户跑才会暴露的问题**
> —— 第六轮就有一条测试因为「以 root 跑」而在本地绿、在 CI 红。CI runner 就是
> 非特权用户。**验证环境必须和目标环境一致。**

> **E2E 的退出码 0 现在是可信的**（第三轮 `3b6d23a` 之前不是）：
> 当时 DoD2/DoD3 的断言是裸 `| grep`，失败也不会让脚本非零退出。
> 现在三条断言都由 `|| fail` 守着，并且**验证过它们真的会失败** ——
> 见「已知问题二」的 M1/M2/M3 三张实测结果。

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

> **跑 bats 要加 `--user 1000:1000`**（非特权）：
> ```powershell
> docker run --rm --user 1000:1000 -v "${wt}:/repo" -w /repo rc-control:bats bash -c "find tests -name '*.bats' -print0 | xargs -0 bats"
> ```
> 以 root 跑会掩盖以非特权用户跑才暴露的问题（第六轮吃过这个亏）。

> **`check-bash-compat.sh` 要设 `BASH_COMPAT_HOST_REPO`**（第十二轮新踩）：
> 它内部还要再起一次 docker，所以从容器里跑时，容器内的 `/repo` daemon 解析不了，
> 现象是 `find: tests: No such file or directory` + bats 打印用法（退出 123）。
> ```powershell
> docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "${wt}:/repo" -w /repo `
>   -e BASH_COMPAT_HOST_REPO="D:/work/rediscluterproject" rc-e2e-runner:local bash -c "bash scripts/check-bash-compat.sh"
> ```
> `scripts/e2e-cluster-config.sh` 同理，要设 `E2E_HOST_REPO`（脚本里已有这个变量）。

> **不要用内联 `bash -c '...'` 处理复杂脚本**（第十二轮又踩了一次）：
> PowerShell 会把 `$(...)`、反引号、多行 heredoc 搅坏，报的错还指向错误的行。
> 写成 `.sh` 文件挂载进容器执行（同「写文件必须用编辑工具」那条）。

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

    > **2026-10-22 再更正：第二轮那条「更正」本身是错的。**
    > 实测（`redis-tools` 的 postinst，不是 `redis-server` 的）：
    > ```
    > Setup_dir /var/log/redis 2750 adm
    > Setup_dir /etc/redis 2770 ${USER}
    > ```
    > Ubuntu 22.04 的 `redis-tools 5:6.0.16-1ubuntu1.2` 与 Debian 12 的
    > `redis-tools 5:7.0.15-1~deb12u10` **都**把 `/etc/redis` 装成
    > **2770 redis:redis**（0770 + setgid），`/var/log/redis` 装成 2750 redis:adm。
    >
    > 第二轮为什么会搞反：当时读的是 `redis-server` 包的 postinst（里面没有
    > `Setup_dir`）和 data.tar 里的条目（`drwxr-xr-x root/root`），
    > **没看到真正改权限的是 `redis-tools` 的 postinst**。
    > 于是「tarball 里是 0755 root:root」被读成了「装出来是 0755 root:root」。
    >
    > **结论反过来：`2eb4aee` 最初的归因是对的**，而且这个形态**不是冷门角落**
    > —— **凡是装了发行版 redis 包的主机上都是这个形态**。父目录 chown 不是
    > 有备无患，是**必须**的。
    缺陷本身真实、修复也仍然必要（该形态见于其它打包方式与手工规划的机器），
    这是最难查的一类：看起来一切正常，就是打不开。
    **只有真实跑一遍才会暴露，单元测试全都测不到**（只在 uid 变化时触发）。
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
    （2026-10-22 实测确认：发行版的 `redis-tools` postinst 里有
    `Setup_dir /var/log/redis 2750 adm`，Ubuntu 22.04 与 Debian 12 都一样。）

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

**第三轮又犯了一次**：E2E 自己的三条断言是裸 `| grep`，脚本又没有 `set -e`，
所以断言失败也照样 PASSED、退出 0（见「已知问题二」）。

**第四轮同样**：下面那条 `add-node.sh` 的缺陷，**三轮里一次都没被测到**，
因为它不在 E2E 覆盖范围内，而单元测试只比文本 —— 直到第四轮把它抽出来
**在沙箱里真跑了一遍**，才第一次看到「脚本在 chown 那一行就死了、
`systemctl` 一次都没跑到」。

**第四轮还抓出了第二轮自己写下的一个错误结论**，而且是**同一个套路的第三次**：

第二轮「更正」说「apt 装出来的是 `0755 root:root`，这个形态不是 apt 干的」。
第四轮实测（**装出来看**，不是读包）：

```
$ stat -c '%n %a %U:%G' /etc/redis /var/log/redis
/etc/redis 2770 redis:redis
/var/log/redis 2750 redis:adm
```

**第二轮的探测坏在哪儿**：它读的是 `redis-server` 包的 postinst（里面没有
`Setup_dir`）和 data.tar 里的条目（`drwxr-xr-x root/root`），
**没看到真正改权限的是 `redis-tools` 的 postinst**。于是
「tarball 里是 0755 root:root」被读成了「装出来是 0755 root:root」。

**同一个错误形状已经出现三次**：
（a）诊断探针漏写 `-v` 就宣布「路径可用」；
（b）`setpriv` 不存在却把「命令找不到」读成「文件不可读」；
（c）**这次** ——「包里是 0755」被读成了「装出来是 0755」。

**规律不是「探测要小心」，而是「探测的对象可能不是出问题的那一个」。**
（b）看错了文件，（c）看错了包。**下结论之前先确认自己看的是不是同一份东西。**

这类错误 151 个单元测试一个都抓不到。**判断标准是：这条代码路径被真正执行过吗？**

### 待处理（审查已报告，第六轮全部修完）

- ~~`unset -f` 会删掉调用方同名函数~~ —— **已修**（第六轮）。嵌套的
  `_conf_flush_node` 挪到顶层 `conf_flush_node`，`parse_conf` 不再定义、
  也不再 `unset -f` 任何东西。
- ~~同组内重复键静默后者覆盖前者~~ —— **已修**（第六轮）。同一作用域里
  重复的键现在直接报错，并指出第一次出现的位置。
- ~~UTF-8 BOM 的配置首行解析失败，报错难懂~~ —— **已修**（第六轮）。BOM 被忽略。
- ~~`set -u` 在 bash < 4.4 下访问空数组会报错~~ —— **已修**（第六轮）。
  展开改成 `"${arr[@]+"${arr[@]}"}"` 这种 bash 4.0+ 都能用的写法，
  并且新增 `scripts/check-bash-compat.sh` 在 bash 4.3 上跑整套 bats。

### 已知问题（第二轮发现，**第四轮已修**）：`add-node.sh` 的 `chown` 引用了没人创建的目录

**原症状**：`add-node.sh` 的远端脚本在 `set -e` 下运行，第 139-140 行只 `mkdir -p` 了
`/var/lib/redis/cluster/${PORT}`、`/var/run/redis/cluster/${PORT}`、
`$REDIS_PREFIX/cluster/${PORT}` 和 `$REDIS_PREFIX/log` ——
**从来不创建 `/var/log/redis`**。但第 141 行是：

```bash
_sudo chown -R redis:redis /var/lib/redis /var/log/redis /var/run/redis "$REDIS_PREFIX/cluster" "$REDIS_PREFIX/log"
```

`chown` 遇到不存在的路径会**以非零退出**，在 `set -e` 下**整个脚本就此中止** ——
节点加不进去。

**实测（第四轮，不是推理）**：把 `add-node.sh` 的远端脚本体抽出来在沙箱里跑，
`/var/log/redis` 不存在时：

```
BODY EXIT=1
```

而且 **`systemctl daemon-reload` 一次都没出现** —— 脚本在 chown 那一行就死了，
**实例根本没被启动**。

还有一个更阴的地方：`_sudo` 的密码分支是
`echo "$SUDO_PASS" | sudo -S -p '' "$@" 2>/dev/null`，
**stderr 被丢掉了**。所以在需要密码的机器上，操作员看到的是「脚本莫名中止」，
**连 chown 这个词都看不到**。

**根因不是「忘了建目录」，而是「两个脚本对同一件事的做法不一致」。**
`cluster-config.sh` 的 `create_dirs` 是这件事的参考实现，它 chown 的是：

```bash
_sudo chown -R redis:redis /etc/redis /var/lib/redis /var/run/redis \
    "$REDIS_PREFIX/cluster" "$REDIS_PREFIX/log"
```

**五个路径全部是它自己 `mkdir` 出来的**，所以它不可能撞上缺失路径。
`add-node.sh` 多了第六个 `/var/log/redis`（没人建），
**同时又少了 `/etc/redis`**（`2eb4aee` 修过父目录 chown，`add-node.sh` 没跟上）。

**修复**（第四轮）：`add-node.sh` 的 chown 列表改成与 `create_dirs` **完全一致** ——
去掉 `/var/log/redis`，补上 `/etc/redis`。

> 顺带说明「为什么不干脆把 `/var/log/redis` 建出来」：
> 没有任何部署路径创建它（`cluster-config.sh` 的 `create_dirs`、`install.sh` 的
> 源码安装路径都不建，只有 `scripts/smoke-test.sh` 建，而它不是部署路径），
> redis 的 `logfile` 指向 `$REDIS_PREFIX/log`，这个目录**根本没人写**。
> 单元模板自己的注释已经写明了这一点，`ReadWritePaths` 的那一项也早就加了
> `-` 前缀（路径不存在就忽略）。**建一个没人写的目录，只是把症状藏起来。**

---

### 已知问题二（收尾时新发现，**已修**，提交 `3b6d23a`）：E2E 自己的断言不会让运行失败

`scripts/e2e-cluster-config.sh` 里有**三处**断言是**裸 `| grep`，没有 `|| fail`**
（交接文档原先写「两处」，**漏了第 233-234 行**那一处）：

```bash
232: ssh_root "$A_IP" "... --cluster check $A_IP:6379" | grep -E "All 16384 slots covered"
233: ssh_root "$A_IP" "... -h $A_IP -p 6379 cluster info" \
234:     | grep -E "cluster_state:ok|cluster_slots_assigned:16384|cluster_known_nodes:6"
346: ssh_root "$A_IP" "... -h $A_IP -p 6380 cluster info" | grep "cluster_state:ok"
```

脚本用的是 `set -uo pipefail`，**没有 `set -e`**。所以这些 grep 不到时，
脚本会继续往下走，**最后照样退出 0**。

**而且 DoD3 那处还有第二重问题。** 第 234 行的 `|` 是正则的**择一**而不是管道，
所以只要三个条件里**任意一个**成立就通过 —— `cluster_state` 是 `fail`
但槽位仍然覆盖着的集群，也会被算作 DoD3 通过。

**实测证据（不是推理）**：把 DoD2 的匹配串换成永远不可能出现的
`ZZZ_NO_MATCH_ZZZ`（只改一行），跑真实 E2E ——

```
=== DoD2/3: cluster check + info ===
Warning: Using a password with '-a' ...
Warning: Using a password with '-a' ...
cluster_state:ok
...
=== E2E PASSED ===
E2E_EXIT_CODE=0
```

DoD2/3 那一段里**根本没有 "All 16384 slots covered" 这一行**（grep 什么都没匹配到），
而脚本一路跑到底，报告 PASSED，**退出码 0**。

**修复**（`3b6d23a`，只动 E2E 驱动，不动被测方）：

- 三处全部改成 `|| fail`
- 输出先捕获、再匹配，**不直接管道给 grep**。这样守卫依赖的是
  「报告里说了什么」，而不是 `redis-cli` 的退出码 —— 在 `pipefail` 下，
  管道式守卫会在 `redis-cli` 返回非零时也失败，那是**另一个断言**
- DoD3 的三个条件**各自独立断言**，不再用择一

**验证**（真实 E2E 跑，每个探针都先确认自己只改了一行）：

| 跑次 | 变异 | 要求的结果 | 实测 |
|---|---|---|---|
| 修复前 | DoD2 匹配串不可能成立 | （记录缺陷） | **PASSED，退出 0** ← 缺陷 |
| M1 | DoD2 匹配串不可能成立 | 必须失败 | **失败**（`FAIL: cluster check did not report...`） |
| M2 | DoD3 从一个没有实例的端口取报告 | 必须失败 | **失败**（`FAIL: cluster_state is not ok`） |
| M3 | 收尾检查从一个没有实例的端口取报告 | 必须失败 | **失败**（`FAIL: cluster_state is not ok after...`） |
| 干净 | 无 | 必须通过 | **PASSED，退出 0** |

> 教训同 DoD5：**一个从不失败的断言等于没有断言**。这次它长在**测试自己**身上。
> 而且光加 `|| fail` 还不够 —— DoD3 那个择一的 grep 即使加了守卫，
> 仍然会因为「三个条件里任意一个成立」而放行。
> **断言的强度和断言的强制性是两件事。**

---

## 与主分支的关系

- 主仓库 `D:\work\rediscluterproject`，当前检出 `main`，工作区干净
- **第一轮**（14 个 Task）已合并进 main：`git merge --no-ff feature/cluster-config-script`（`54438d8` → `96737d2`）
  - 合并前用 `git merge-tree` 预检过，exit 0、无冲突标记；实际合并也确实干净
  - 合并后在主仓库重跑：`bats 148/0`、`check_syntax 30/0`、`validate_libs 50/0`、E2E 全绿
- **第二轮**（E2E 迁 Redis 8）**已合并进 main**：`git merge --ff-only feature/e2e-redis-8`（`18dd8ef` → `d073da5`）
  - 相对 `main` = `18dd8ef` 领先 11 个提交，因 main 未动过，故为**纯 fast-forward，无需预检**
  - 分支 `feature/e2e-redis-8` 已 `git branch -d` 删除
  - 合并后在主仓库重跑：`bats 149/0`、`check_syntax 30/0`、`validate_libs 50/0`、E2E 退出码 0
- **第三轮**（E2E 断言加固 + 文档回改）**已合并进 main**：`git merge --ff-only fix/e2e-assertion-strength`（`cf26fca` → `16a1765`）
  - 分支已 `git branch -d` 删除
  - 验证：`bats 149/0`、`check_syntax 30/0`、`validate_libs 50/0`，E2E 干净跑退出码 0，
    三个变异探针全部按预期失败（见「已知问题二」）
- **第四轮**（修 `add-node.sh` + 补回归覆盖）**已合并进 main**：`git merge --ff-only fix/add-node-missing-dir`（`16a1765` → `7d1a364`）
  - 分支已 `git branch -d` 删除
  - 验证：`bats 151/0`、`check_syntax 31/0`、`validate_libs 50/0`、E2E 退出码 0；
    新增的两条用例**在修复前确认会失败**（见「第四轮」一节）
- **第五轮**（更正 apt 归因）**已合并进 main**：`git merge --ff-only docs/correct-apt-attribution`（`7d1a364` → `8a8e4a3`）
  - 生产文件**只改注释**（已用 `git diff` 逐行核过）
- **第六轮**（解析器 4 条遗留项 + 修好 CI）直接提交在 main 上，已推送：`2160c75`
- **第七轮**（CPS 节点镜像 E2E）直接提交在 main 上，**已推送**：`e2d01b4` + `384a42f`
  - 验证：`check_syntax 34/0`、`validate_libs 50/0`、`bats 163/0`（bash 5.1，非特权 uid 1000）
  - `scripts/e2e-cpsweb-nodes.sh` 在本轮完整跑过 4 次，最后一次 `KEEP=1`
- **第八轮**（ZooKeeper + Kafka 两节点集群）直接提交在 main 上，**已推送**：`3a2856d`
  - 验证：`check_syntax 35/0`、`validate_libs 50/0`、bats 163/0；脚本 A1–A7 全绿
- **第九轮**（端到端写入性能测量 + 写入路径诊断）直接提交在 main 上，**已推送**：`c8560a8`
  - 测量结论：端到端写入上限 ~1.33 万/秒，根因是集群模式下每数据点一次同步 `HMSET` 往返
- **第十轮**（集群写入按节点 pipeline）直接提交在 main 上，**已推送**：`c8560a8`..`02db42a`
  - 同机交替 A/B 12 轮：配对中位数 **2.8×**（1.7–4.1×），守恒精确、失败 0
  - Java 源码不在本仓库，patch 见 `docs/superpowers/patches/2026-10-27-cluster-pipeline.patch`
- **第十一轮**（两个消费者的对照测试 + 配置搬进 application.yaml）直接提交在 main 上，**已推送**：`43d781d..90c801e`
  - 验证：`bats 186/0`；`scripts/bench-consumer-write.sh` 新增 `CONSUMERS` / `CONFIG_FROM_YAML`
- **第十二轮**（两台机器 6 实例的显式主从装配）直接提交在 main 上，**已推送**：`525d07a..856d1b8`
  - 验证：`bats 199/0`、`check_syntax 43/0`、`validate_libs 54/0`、bash 4.3 `PASS`、
    `scripts/e2e-cluster-config.sh` `E2E PASSED` 退出码 0（A0–A6 全绿）
  - 变异检验：去掉异机约束 → A2 变红（实测退出码 1）
- **✅ `origin/main` 与 `main` 同步**（`git status -sb` 无 ahead/behind）。第十二轮推于
  `525d07a..856d1b8`；各轮推送都走的 SSH（HTTPS 被 PAT scope 挡住，见下）。
  > 前三轮之所以推不了，是 GitHub 从这台机器不可达
  > （`Recv failure: Connection was reset` / `Failed to connect to github.com:443`），
  > **不是**配置问题。网络恢复后一次推成功。

  > ### ⚠️ 推送方式：走 SSH，不是 HTTPS
  >
  > HTTPS 那条路**推不上去**，原因不是网络：
  > ```
  > ! [remote rejected] main -> main (refusing to allow a Personal Access Token
  >   to create or update workflow `.github/workflows/ci.yml` without `workflow` scope)
  > ```
  > Git Credential Manager 里存的那个 PAT **没有 `workflow` 权限**。
  > 本次推送范围里只有一个提交碰了 `.github/`：
  > `bf55228`（新增 `.github/workflows/ci.yml`）。
  >
  > **实际用的办法**（`~/.ssh/id_rsa` 已经在 GitHub 上注册过，
  > `ssh -T git@github.com` 能通）：
  > ```powershell
  > $env:GIT_SSH="C:\Windows\System32\OpenSSH\ssh.exe"
  > git -c remote.origin.pushurl=git@github.com:leiming-cai/redis-cluster-install.git push origin main
  > ```
  > 两个要点：
  > 1. **`-c remote.origin.pushurl=...`** 是**一次性**覆盖，用户的 remote 配置
  >    没动（`git remote -v` 仍然是 HTTPS）。注意这个 git 版本**不支持**
  >    命令行上的 `--push-url` 选项。
  > 2. **必须指定 `GIT_SSH` 指向原生 Windows OpenSSH。**
  >    git 自带的是 MSYS 版 ssh，它把中文用户名 `蔡雷鸣` 转义成
  >    `/c/Users/\262\314\300\327\303\371/...`，于是
  >    `known_hosts` 和 `id_rsa` 都**找不到**，报「Host key verification failed」。
  >    原生 `C:\Windows\System32\OpenSSH\ssh.exe` 没有这个问题。
  >    **这是这台机器上第三次被非 ASCII 用户名绊倒**
  >    （前两次：PowerShell 读 UTF-8 脚本、docker 的 `-v` 路径）。
  >
  > **长期修法**（三选一，都还没做）：
  > 给 PAT 加 `workflow` scope；或把 `origin` 换成 SSH 并设好 `core.sshCommand`；
  > 或把 `~/.ssh` 复制到一个纯 ASCII 路径下。
  > **否则下次再改 workflow 文件，推送会再被拒一次。**
- 旧的 worktree 与 `feature/cluster-config-script` 分支**已清理**：
  `git worktree remove` 删掉了全部内容并注销了登记（`git worktree list` 只剩主仓库），
  分支已 `git branch -d` 删除（它相对 main 的独有提交数为 0）。
  目录本身还剩一个**空壳** —— `opencode.exe` 进程把它当工作目录占着，
  Windows 拒绝删除被占用的目录。**那个目录归 harness 管**，
  等占用它的会话退出后（或重启）删掉即可，git 状态已经是干净的。

### 合并时处理的一件事（上一轮）

主仓库当时有一个未提交改动（`docs/superpowers/plans/...`，96 增 50 删）。
先确认它的 blob hash（`7e1d95b`）与分支上已提交的版本**逐字节相同**，
即属于重复劳动，丢弃后 `git merge` 才肯运行（git 会拒绝覆盖脏文件）。
**没有丢失任何东西。**

---

## 会话存档（2026-10-29）：第十六轮结束时的完整状态

**这一节是给「下一个会话」看的** —— 打开仓库先读这一节，能立刻知道现在是什么状态、
东西在哪、哪些坑踩过了。

> ⚠️ **本节已更新到第十六轮**（下面第十五轮、第十四轮的内容仍然有效，
> 但「验证基线」和「下一次该做什么」两节以第十六轮的为准）。

### 一、代码在哪、改了什么

| 位置 | 说明 |
|---|---|
| `D:\javawork\1.2\cpscloud1.0\code\platform\backend` | `realserver` + `modelserver` 的 Java 源码（**不是 git 仓库**） |
| `D:\javawork\1.2\cpscloud1.0\code\application\backend` | `napstarweb` 的 Java 源码（**不是 git 仓库**） |
| `D:\work\rediscluterproject` | **本仓库**（唯一的 git 仓库）—— 放 spec / plan / patch / 文档 |

**第十六轮改了 10 个文件（8 个 Java + 2 个 pom）**：

```
改  common/idgenerator/…/utils/IdUtil.java                    (锁搬进来 + 惰性取模板 + 值格式不变)
删  common/idgenerator/…/utils/redis/RedisUtil.java           (179 行的薄壳)
改  common/idgenerator/pom.xml                                (删掉 realserver-oms)
改  common/idgenerator/src/test/…/IdUtilRedisLockLiveTest.java (3 → 6 条)
改  realserver/common/oms/…/oms/utils/RedisUtil.java          (加 deleteNamespace)
改  realserver/common/oms/src/test/…/RedisClusterHashPipelineLiveTest.java (helper 挪走 + KEYS 换 SCAN)
新增 realserver/common/oms/src/test/…/RedisClusterTestSupport.java
新增 realserver/common/oms/src/test/…/RedisUtilDeleteNamespaceLiveTest.java
改  modelserver/services/…/NapstarOaTransformerServiceImpl.java (import 换 oms 的 RedisUtil)
改  modelserver/services/pom.xml                              (显式加 realserver-oms)
```

**第十五轮改了 2 个源文件 + 1 个 pom + 新增 1 个测试**：

```
改  common/idgenerator/…/utils/IdUtil.java            (锁在 finally 里释放 + 序列号取不到时抛可诊断的错误)
改  common/idgenerator/…/utils/redis/RedisUtil.java   (tryLock 的 catch 释放正确的键，且不抛)
改  common/idgenerator/pom.xml                          (加 spring-boot-starter-test，test scope)
新增 common/idgenerator/src/test/…/utils/IdUtilRedisLockLiveTest.java   (3 条真集群测试)
```

**第十四轮改了 2 个 pom + 新增 1 个测试**：

```
改  backend/pom.xml                              (jedis 8.1.0-beta2 -> 3.10.0 + 就地写上限依据)
改  application/backend/pom.xml                   (同上)
新增 realserver/common/oms/src/test/…/utils/RedisClusterHashPipelineLiveTest.java  (4 条)
```

> ⚠️ **那两个 pom 的 jedis 8.1.0-beta2 不是本轮改的** —— 是会话期间
> （09:59:47 / 10:03:22）**外部编辑器**（VS Code + Java 插件）改的，
> 改动让**整个工程编译失败**。本轮已恢复成 `3.10.0`。
> **如果下次又看到 `8.1.0-beta2`，先读「第十四轮」那一节**。

**第十三轮改了 11 个 + 删了 5 个 + 新增 4 个测试**：

```
改  realserver/common/oms/…/oms/utils/RedisUtil.java              (27 个方法加 @Deprecated)
改  realserver/common/oms/…/oms/utils/RedisPipelineUtil.java       (删 opsHashSetPipeByHashData)
改  realserver/common/oms/…/oms/config/RedisPropertiesConfig.java  (bean 改名)
改  realserver/common/oms/…/oms/config/RedisUtilConfig.java        (模式大小写不敏感)
改  realserver/common/oms/pom.xml                                   (解耦 + 显式 jackson-databind)
改  realserver/dao/…/impl/OmsWriteDaoImpl.java                     (分组逻辑挪到业务侧)
改  realserver/plugins/rtdata-module/…/OmsWriteByKafkaServiceImpl.java
改  realserver/controller/src/main/resources/application.yml         (oms: 块补全)
改  modelserver/controller/src/main/resources/application.yml        (oms: 块补全)
改  modelserver/services/…/CacheServiceImpl.java                     (修正错误注释)
改  napstarweb/web-controller/src/main/resources/application.yml      (oms: 块补全)

删  realserver/common/oms/…/oms/utils/JedisUtils.java               (~700 行死代码)
删  realserver/common/oms/…/oms/utils/JedisPoolUtils.java           (~50 行死代码)
删  realserver/plugins/rtdata-module/…/config/RedisPropertiesConfig.java   (墓碑)
删  modelserver/controller/…/config/RedisPropertiesConfig.java             (墓碑)
删  napstarweb/web-controller/…/config/RedisPropertiesConfig.java           (墓碑)

新增 realserver/common/oms/src/test/…/config/RedisClusterOmsContractTest.java
新增 realserver/common/oms/src/test/…/config/RedisModeCaseSensitivityTest.java
新增 realserver/common/oms/src/test/…/config/RedisPropertiesConfigBeanNameTest.java
新增 realserver/common/oms/src/test/…/utils/RedisPipelineUtilNoEntityDependencyTest.java
```

**留痕**：七份 patch 在 `docs/superpowers/patches/`（Java 树不是 git 仓库，只能这样留痕）：

| 文件 | 大小 | 校验结果 |
|---|---|---|
| `2026-10-29-unify-redis-util.patch` | 81,478 B | 反向校验 exit 0；往返校验 `checked=9 mismatches=0`（10 个文件：7 改 / 1 删 / 2 增） |
| `2026-10-29-idutil-redis-lock-fix.patch` | 23,551 B | 反向校验 exit 0；往返校验 `checked=4 mismatches=0` |
| `2026-10-29-jedis-ceiling-platform-backend.patch` | 22,571 B | 反向校验 exit 0；往返校验 `checked=2 mismatches=0` |
| `2026-10-29-jedis-ceiling-application-backend.patch` | 596 B | 反向校验 exit 0；往返校验 `checked=1 mismatches=0` |
| `2026-10-28-unified-redis-connection-platform-backend.patch` | 107,604 B | 反向校验 exit 0；正向重建 `checked=19 mismatches=0` |
| `2026-10-28-unified-redis-connection-napstarweb.patch` | 3,138 B | 反向校验 exit 0；正向重建 `checked=2 mismatches=0` |
| `2026-10-28-unified-redis-connection.patch`（合并，仅供合成仓库） | 110,742 B | 20 个 `diff --git`（4 新增 / 5 删除） |

### 二、验证基线（下一次会话先跑这个，别改代码先跑一遍）

| 命令 | 期望 |
|---|---|
| `docker run --rm --user 1000:1000 -v "D:/work/rediscluterproject:/repo" -w /repo rc-control:bats bash -c "find tests -name '*.bats' -print0 \| xargs -0 bats"` | **203 通过 / 0 失败** |
| `bash tests/check_syntax.sh` | `TOTAL=45 FAIL=0`（其中 28 个是真做的 `bash -n`，17 个是 `.bats` 的 SKIP 占位） |
| `bash tests/validate_libs.sh` | `PASS=54 FAIL=0` |
| `cd $BE\common\idgenerator; mvn -o clean test` | **6 通过 / 0 失败 / 0 跳过**（第十五轮 3 条 + 第十六轮 3 条） |
| `cd $BE\realserver\common\oms; mvn -o clean test` | **66 通过 / 0 失败 / 0 跳过**（第十五轮 63 → 第十六轮 +3） |
| `cd $BE\realserver\plugins\rtdata-module; mvn -o test` | **14 通过 / 0 失败** |
| `cd $BE; mvn -o clean install -DskipTests` | **44 个模块全 SUCCESS**（含 proguard）—— ⚠️ 原文档写「29 个」，实际 44 |
| `cd $AB; mvn -o clean install -DskipTests` | napstarweb reactor **13 个模块**全 SUCCESS |
| `cd $BE\realserver\common\oms; mvn -o dependency:tree` | 只剩自己，**零 `com.sac.platform` 依赖** |
| `cd $BE\common\idgenerator; mvn -o dependency:tree` | **不含 `realserver-entity`**，**也不含 `realserver-oms`**（第十六轮） |

> ⚠️ **`oms` 的真集群测试需要集群在跑**（`127.0.0.1:16379`）。
> 集群不在时它们**跳过**（不是变红）—— 已实测
> `-Dtest.clusters=127.0.0.1:19999` → `Skipped: 8`，`BUILD SUCCESS`。
> **`idgenerator` 的 6 条同理**（集群不在时 `Skipped: 4` —— 另外两条用替身，不需要集群，照常跑）。
>
> ⚠️ **构建必须用 JDK 8**（`D:\java\java-se-8u42-ri`）：
> `oms` 的 proguard 配了 `${JAVA_HOME}/jre/lib/rt.jar`，**只有 JDK 8 有这个路径**。
>
> ⚠️ **本地仓库里的 `realserver-oms` jar 是 proguard 处理过的** ——
> `RedisPropertiesConfig` / `RedisUtilConfig` **已被改名**（写作时叫 `a` / `b`），
> 从 idgenerator 的测试类路径上**引用不到**。详见「第十五轮」第四节。
>
> ⚠️ **VSCode 的 ECJ 语言服务器会污染 `target/classes`**（第十六轮踩到，
> 详见「踩过的坑」第 21 条）：它异步写进编译输出，产出带
> `Error: Unresolved compilation problem` 的 class 文件，
> **会让明明正确的源码「测出 4 个错误」**。**安装后的 jar 是干净的**
> （433 个全部扫过，0 个污染）。改完源码**等 8 秒**再构建，
> 并确认 class 文件里没有那个标记再采信结果。

### 三、环境现状（2026-10-29 实测）

```
rc-redis-publish    Up 3 hours       socat 转发器，把集群暴露到宿主机 127.0.0.1:16379-16384
rc-cpsweb-app       Up 2 hours       上一轮留下的 consumer（跑的是 10/28 的新 jar）
rc-cpsweb-node-a    Up 3 hours       Redis 集群 node-a（3 个 master）
rc-cpsweb-node-b    Up 3 hours       Redis 集群 node-b（3 个 replica）
```

**集群健康**：`cluster_state:ok` / `cluster_slots_assigned:16384` /
`cluster_known_nodes:6` / `cluster_size:3`，密码 `CpsE2eClusterPw`。

> ⚠️ **⚠️ 第十六轮实测出的两个新情况，下一轮要知道**：
>
> **① 三个 master 现在是空的**（`dbsize=0`）。原来有 **820 万**个
> `real_data:11:*` 压测残留，是第十六轮的变异检验（把 `deleteNamespace` 的
> pattern 改成 `"*"`）**误删**的 —— 那个变异在满 keyspace 上跑不动
> （实测删除速度约 2000/s，Spring 的 DEBUG 日志还会**每个 key 打一行**，
> 45 分钟产出 828 MB 日志）。残留数据是压测产物、不是业务数据，可再生。
>
> **② 三个 replica 的复制链路是断的**（`master_link_status:down`），
> 而且它们**还留着 820 万个陈旧 key**（master 已清空，replica 没跟上，
> 因为 `FLUSHALL` 在 replica 上会被拒：`READONLY You can't write against a read only replica`）。
>
> **根因不是本轮**：master 的 `cluster-announce-ip` 被改成了 `127.0.0.1`
> （运行期改动，为了让宿主机上的 Java 能连上）→ master 眼里的 replica 地址
> 变成 `127.0.0.1:1638x`，而那个地址在**容器内部**什么都没有 → 链路必然断。
> → **这套集群的副本提升能力在 announce 改成回环地址之后就是不可用的**。
> 真要演练「master 挂了 → 副本提升」，得用 `scripts/e2e-cluster-config.sh`
> 那套**独立的** E2E 集群（它的 A4/A5/A6 断言与本集群无关）。
>
> **对本仓库的测试无影响**：所有真集群用例只读写 master。

**⚠️ 集群的 announce 地址被改过（运行期改动，只针对这套一次性 E2E 集群）**：

```
127.0.0.1:16379@16379  master   ← 已改
127.0.0.1:16380@16380  master   ← 已改
127.0.0.1:16381@16381  master   ← 已改
172.21.0.3:6382@16382   slave    ← 仍是旧地址
127.0.0.1:16384@16384  slave    ← 已改
172.21.0.3:6383@16383   slave    ← 仍是旧地址
```

3 个 master 的地址是 `127.0.0.1:1637x`，**所以宿主机上的 Java 能连上**；
两个 replica 仍是 `172.21.0.3:638x`（宿主机不可达），但**客户端只路由到 master，
所以不影响 L3 测试**（实测 `RedisClusterOmsContractTest` 仍然 `2/2 绿、Skipped: 0`）。

**重建转发器**（如果 `rc-redis-publish` 没了）：
```powershell
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock `
  -v "C:/Users/蔡雷鸣/AppData/Local/Temp/opencode:/v" -w /v `
  rc-e2e-runner:local bash /v/start-publish.sh
```
说明见 `%TEMP%\opencode\REDIS-CLUSTER-ACCESS.md`。

### 四、下一次会话该做什么（按优先级）

1. **填生产真值（唯一的"欠账"）** —— 三个 `application.yml` 里的
   `oms.clusters` 现在是**占位符 `127.0.0.1:6379`**，`password` 是空串。
   必须换成生产地址，并同步 Nacos 上的同名配置。
   ⚠️ **实测过的两种下场**（不是交接文档原来写的「会被静默连上」）：
   ① 6379 上**什么都没有** → 应用**正常启动、不报错**，故障推迟到**第一次读写**
   （`JedisNoReachableClusterException: No reachable node in cluster`）；
   ② 6379 上是**单节点 Redis** → **启动直接失败**
   （`JedisDataException: ERR This instance has cluster support disabled`）。
   真正会「静默连上」的是第三种：6379 上是一个 **Redis Cluster**。
   → 见「下一步具体动作」里建议的 fail-fast 方案。
2. **`cluster_require_full_coverage=no`**（第十二轮的键）—— 默认 `yes` 时
   **任一 master 挂掉 = 全集群停写**；2 机部署必须设 `no`。
3. **读侧 pipeline** —— `RedisClusterHashPipeline.getAllHashes`。
   `findByOtype` / `findByOtypeIds` 在集群下是 **N 次串行 `HGETALL`**；
   写侧第十轮已按节点 pipeline 化，**读侧还没做**，是同一根因的另一半。
   > 第十四轮已经在真集群上锁住了读路径的**顺序正确性**
   > （`readPathReturnsEntriesInTheSameOrderAsTheKeys`），
   > 所以做读侧 pipeline 时**别把这条断言改坏**。
4. ~~**合并两套 `RedisUtil`**~~ —— **✅ 已做（第十六轮）**：
   idgenerator 那份薄壳**已删**，通用能力归到 oms，锁归到 `IdUtil`；
   `common/idgenerator → realserver/oms` 的**反向依赖已消除**。
   ⚠️ **随之而来的发布说明**（必须写）：① 类 `com.sac.platform.common.utils.redis.RedisUtil`
   **没了** → 改成 `com.sac.platform.realserver.oms.utils.RedisUtil`；
   ② 4 个模块（`idgenerator`/`userservice`/`model-interface`/`menuservice`）的
   **对外传递闭包变小**（能到 oms 的模块 20 → 16），且 `lettuce-core` 也随之消失。
5. **（新，第十六轮）锁的归属权隐患** —— 两个**既有**缺陷，本轮刻意没修
   （设计明确要求保持现状、新用例也钉住了它）：
   ① `tryLock` 的 catch 会删掉一把**自己从没拿到**的锁；
   ② 锁的 TTL（5 秒）比临界区（含一次 DB 往返）短，且锁值是常量 `"1"`
   → **无法校验归属**。两者都会导致「临界区里两个线程 → 重复 id」。
   **正确修法**：每次获取**唯一 token** + 释放时用 **Lua compare-and-delete**
   + TTL 大于 DB 超时。**要改就得连同 `tryLockReleasesOnlyTheLockItTook…` 那条用例一起改。**
6. **（可选）`sche-viewer-server`** —— 第四个部署物，有同样的 P0 缺陷
   （`oms:` 块全注释）+ 第四份墓碑。但**它的模块在 aggregator 里是注释掉的**
   （不参与构建），且用 jedis 3.6.1（更老）。本轮**没动它**。
7. **（可选）`realserver-oms` 的命名与位置** —— 现在叫 `oms`、放在 `realserver/` 下，
   但装的是 Redis 基础设施。本轮**刻意没动**（spec §5.2）：
   改 artifactId 要同步 `backend/pom.xml` 的 `dependencyManagement` + 三个工程的 pom
   + Artifactory 上架，是仪式性成本。
8. ~~**（第十四轮）决定 jedis 要不要继续升**~~ —— **已结案（第十五轮）**：
   用户确认**生产必须留在 JDK 8** → jedis **固定 `3.10.0`，不升级**。
   （理由与实测数据见「第十四轮」的结论先行表。）
9. ~~**（第十四轮）把 CI 的 `bash -n` 换成 `bash tests/check_syntax.sh`**~~ ——
   **✅ 已做（第十五轮）**：`.github/workflows/ci.yml` 里那条手抄的
   `for f in ...` 换成了 `bash tests/check_syntax.sh`，并**新增**一步
   `bash tests/validate_libs.sh`。**真实覆盖面 15 → 28 个文件**
   （⚠️ **不是** 6 → 45：`check_syntax.sh` 的 `TOTAL=45` 里有 17 条是
   `.bats` 的 SKIP 占位）。⚠️ 改 workflow **必须走 SSH 推送**。
   **变异检验**：改坏 `scripts/e2e-cluster-config.sh`（旧 CI 列表**根本没查**的
   14 个脚本之一）→ `check_syntax.sh` 报 `FAIL:` 且退出码 1；
   改坏 `validate_libs.sh` 里的一条断言 → `PASS=53 FAIL=1` 且退出码 1。
   → **新步骤真的会红，不是空转**。
10. ~~**（第十五轮）`tryLock` 的忙等自旋没有 sleep**~~ —— **✅ 已做（第十六轮）**：
    锁搬进 `IdUtil` 时一起修了（重试之间 sleep 10 ms），并有用例钉住
    （300 ms 窗口里 `setIfAbsent` 至多 60 次）。
11. **（新，第十六轮）`check-bash-compat.sh` 接进 CI** —— 还没做。
    它内部要起 docker，CI 的 `container:` 作业得自己验一下。
12. **（新，第十六轮）`common/utils/redis/RedisLock` 是个孤儿注解** ——
    两个树里**零引用**（它以前也是死的，只是现在那个包里只剩它和 `RedisConfig`）。
    可以删或挪走。

### 五、这一轮踩过的坑（**别再踩**）

| # | 坑 | 后果 / 正确做法 |
|---|---|---|
| 1 | **`mvn spring-boot:run` 会 fork 新 JVM，不传递 Maven 的 `-D` 系统属性** | `-Doms.clusters[0]=…` **无效**；要写 `"-Dspring-boot.run.jvmArguments=-Doms.clusters[0]=… -Doms.password=…"` |
| 2 | **`oms` 的 pom 配了 proguard，它要 JDK 8 的 `rt.jar`** | JDK 9+ 没有这个文件 → `Can't read .../rt.jar`。本机有**两个 JDK**：`D:\java\java-se-8u42-ri`（8）与 `D:\java\jdk-21.0.2`（21）。**构建前确认 `JAVA_HOME`** |
| 3 | **PowerShell 里 `-D` 参数必须加引号** | `"-Dproguard.skip=true"`；不加会被拆成 `.skip=true`，maven 报 `Unknown lifecycle phase` |
| 4 | **绝不要用 `Set-Content` 改 Java / YAML / 本仓库的 md** | 会加 BOM + 把 LF 换成 CRLF → Java 编译失败、YAML 解析失败。**一律用编辑工具** |
| 5 | **`Out-File -Encoding ascii` 会把 patch 里的中文全变成 `?`** | patch 直接 `corrupt`。用 `git diff --output=<file>`（原始字节） |
| 6 | **改 `oms` 之后必须 `mvn install` 重装它** | 下游模块从 `D:\java\apache-maven\mvnRepo` 取 jar，**不是**从源码树。旧 jar 会让下游编译旧代码 |
| 7 | **生成 patch 时必须 `core.autocrlf=false` / `core.eol=lf`** | 源文件行尾是**混的**（`pom.xml` 是 LF，`.java` 是 CRLF）。默认 `autocrlf=true` 会规范化行尾，patch 的"改动前"侧与磁盘对不上 → **应用失败** |
| 8 | **生成 patch 时必须显式 `Remove-Item` 已删的文件** | 只复制存在的文件 → `git add -A` 认为没变 → **5 个删除全部静默丢失** |
| 9 | **`cluster-announce-bus-port` 不能改** | 它是节点**之间**通信用的，改了会让集群内部链路断掉（节点全 `disconnected`）。要改就用**转发端口本身** |
| 10 | **集群的 announce 地址要 6 个节点全改** | 只改 master 的话，`CLUSTER SLOTS` 会混着 `127.0.0.1:1637x` 与 `172.21.0.x`，客户端按后者去连就超时 |
| 11 | **容器重启后 announce 配置会丢** | `CONFIG SET cluster-announce-*` 是**运行期**改动，容器一重启就回到 `172.21.0.x`，集群变 `cluster_state:fail`（6 个节点全 `disconnected`）。重启后必须重跑 `%TEMP%\opencode\set-announce.sh`（**注意是 `set-announce.sh`，不是 `restore-cluster.sh`** —— 后者会把 bus-port 也改掉，正是坑 9 说的那种改法） |
| 12 | **（第十四轮）`ApplicationContextRunner.run(cb)` 会在回调返回后销毁上下文** | 连带 `JedisConnectionFactory` 失效（`JedisConnectionFactory was destroyed`）。**所有断言必须写在回调内部** |
| 13 | **（第十四轮）`seed.info("errorstat")` 返回空** | Redis 8 **没有**名为 `errorstat` 的段，那个调用返回**空字符串** → 计数恒为 0 → **断言变成空转**。Errorstats 段只在完整 `INFO` / `INFO all` 的输出里 |
| 14 | **（第十四轮）`errorstat_MOVED:count=201` 中间没有逗号** | 按 `,` 切会切出一个元素，再按 `:` 切得到的是 `count=201` 而不是 `count` → 比较永远不成立 → **计数恒为 0** |
| 15 | **（第十四轮）借连接忘了 AUTH** | 集群开了 `requirepass`，`INFO` 回 NOAUTH，异常被吞掉 → **计数恒为 0** |
| 16 | **（第十四轮）`JedisPool` 在 jedis 8 里仍然存在，但这不代表 API 没变** | jedis 8 的 `JedisPool extends Pool<Jedis>`，可 `getClusterNodes()` 给的是 `ConnectionPool`。**必须看返回类型，不能只看类还在不在** |
| 17 | **（第十四轮）外部编辑器会改你的工作树** | 会话期间 `backend/pom.xml` 与 `application/backend/pom.xml` 被改成 jedis 8.1.0-beta2（09:59:47 / 10:03:22，VS Code + Java 插件在跑），**整个工程编译失败**。**动手前先看文件 mtime**，发现异常改动先查清楚是谁改的 |
| 18 | **（第十五轮）本地仓库里的 `realserver-oms` jar 是 proguard 处理过的** | `RedisPropertiesConfig` / `RedisUtilConfig` **已被改名**（写作时叫 `a` / `b`）→ 从 idgenerator 的测试类路径上**根本引用不到**，编译直接失败。**跨模块写测试时，先 `jar tf` 看一眼 jar 里到底有什么** |
| 19 | **（第十五轮）PowerShell 5.1 把无 BOM 的 UTF-8 `.ps1` 当 ANSI 读** | 脚本里**字面写死**含中文的路径（本机用户名 `蔡雷鸣`）会被读坏 → `New-Item` 报**误导性的**「访问被拒绝」。**脚本里用 `$env:TEMP`，不要写字面路径** —— 这是本机第三次被非 ASCII 用户名绊倒 |
| 20 | **（第十五轮）`if (false) {…}` 是编译错误** | javac 报「unreachable statement」。做变异检验时用一个**运行期**为假的条件（如 `System.currentTimeMillis() < 0`），不要用常量 |
| 21 | **（第十六轮）VSCode 的 ECJ 语言服务器会污染 `target/classes`** | 它**异步**写进编译输出，产出带 `Error: Unresolved compilation problem` 的 class 文件（它的自动构建 classpath 缺 `common/util`）→ **明明正确的源码会「测出 4 个错误」**。**安装后的 jar 是干净的**（433 个全扫过，0 污染）。改完源码**等 8 秒**再构建，并确认 class 文件里没有那个标记再采信结果 |
| 22 | **（第十六轮）Redis 不打印计数为 0 的 errorstat** | `errorstat_MOVED:` 那行**只在真的发生过 MOVED 时才出现**（实测：本机健康的 16380 一个 `errorstat_*` 行都没有）。所以「数有几个 master 报了 MOVED」**不能**当作「测到了几个 master」→ 会让「从没发生过 MOVED」的集群**误报红**。要判「测没测到」用「INFO 成功读到的 master 数」（而 `# Errorstats` **段头**即使计数全为 0 也会打印） |
| 23 | **（第十六轮）行尾要「跟邻居一致」，不是「一律 CRLF」** | `oms/src/test/.../oms/utils/` 这个包**本来就是 LF**。按「一律 CRLF」去转，会让 `RedisClusterHashPipelineLiveTest` 的 diff 变成 **448 行行尾噪音**而不是 ~104 行。**先看邻居** |
| 24 | **（第十六轮）注释里的「历史」会过期** | 我在第十五轮写的「原来的写法是在成功路径上直接 return —— 没有人释放这把锁」**当时是对的**，但代码搬过来之后，它就贴在**已经做对了**的代码旁边 → 读 diff 的人以为这次改的就是那个缺陷。**同一个文件里有三份这样的注释，三份都要改** |
| 25 | **（第十六轮）「变异检验」本身也会造成破坏** | 把 `deleteNamespace` 的 pattern 改成 `"*"` 在**满 keyspace**（820 万 key）上跑不动：删除速度约 2000/s，Spring 的 DEBUG 日志**每个 key 一行** → 45 分钟产出 **828 MB** 日志，最后被超时杀掉。**做「删更多」这类变异前，先看 keyspace 有多大** |

---

## 下一步具体动作

**第七~十六轮都已提交并推送**（`git status -sb` 无 ahead/behind；`origin/main` 与 `main` 同步）。
第十三轮已推送：`521f244..aadcbb9`；第十四轮：`80ad557` / `9b4f040` / `fdd3193` / `6e86496`；
第十五轮：`54aa2e7`（修 `IdUtil` 的锁）+ `9be5aec`（CI 语法覆盖面）+ `c873d04`/`da93756`/`ba5b0f6`；
第十六轮：合并两套 `RedisUtil` 的 patch + 文档。

> **⭐ 当前状态、代码位置、环境、待办、踩过的坑，全部在上面的
> 「会话存档（2026-10-29）」一节里 —— 下一次会话先读那一节。**
> 下面的内容是**历史记录**，保留供对照。

### 下一次会话从这里开始（第十六轮结束时）

```powershell
cd D:\work\rediscluterproject
git status -sb            # main...origin/main，工作区干净
git log --oneline -5
```

环境（2026-10-29 实测，与上面的「会话存档」一致）：

```
rc-redis-publish    socat 转发器，把集群暴露到宿主机 127.0.0.1:16379-16384
rc-cpsweb-node-a/b Redis 集群，cluster_state:ok / 16384 slots / 6 nodes / size 3
                    ⚠️ 3 个 master 的 announce 地址被改成了 127.0.0.1:1637x（运行期改动）
                    ⚠️ 容器一重启这个改动就丢，集群会变 cluster_state:fail
                    ⚠️ 3 个 replica 的复制链路是断的（announce 改成回环地址的必然结果）
                    ⚠️ master 现在是空的；replica 还留着 820 万陈旧 key
rc-cpsweb-app       上一轮留下的 consumer，未改动
```

验证基线（**改代码前先跑一遍**）：

| 命令 | 期望 |
|---|---|
| `docker run --rm --user 1000:1000 -v "D:/work/rediscluterproject:/repo" -w /repo rc-control:bats bash -c "find tests -name '*.bats' -print0 \| xargs -0 bats"` | **203 / 0** |
| `bash tests/check_syntax.sh` | `TOTAL=45 FAIL=0` |
| `bash tests/validate_libs.sh` | `PASS=54 FAIL=0` |
| `cd $BE\common\idgenerator; mvn -o clean test` | **6 / 0 / 0 跳过** |
| `cd $BE\realserver\common\oms; mvn -o clean test` | **66 / 0 / 0 跳过** |
| `cd $BE\realserver\plugins\rtdata-module; mvn -o test` | **14 / 0** |

> ⚠️ **构建必须用 JDK 8**（`D:\java\java-se-8u42-ri`）——
> `oms` 的 proguard 要 `${JAVA_HOME}/jre/lib/rt.jar`，只有 JDK 8 有这个路径。
>
> ⚠️ **本地仓库里的 `realserver-oms` jar 是 proguard 处理过的** ——
> `RedisPropertiesConfig` / `RedisUtilConfig` 已被改名，
> 从 idgenerator 的测试类路径上引用不到（见「第十五轮」第四节）。
>
> ⚠️ **改完源码等 8 秒再构建** —— VSCode 的 ECJ 会污染 `target/classes`（坑 21）。

### 下一次会话从这里开始（第十五轮结束时）

```powershell
cd D:\work\rediscluterproject
git status -sb            # main...origin/main，工作区干净
git log --oneline -5
```

环境（2026-10-29 实测，与上面的「会话存档」一致）：

```
rc-redis-publish    socat 转发器，把集群暴露到宿主机 127.0.0.1:16379-16384
rc-cpsweb-node-a/b Redis 集群，cluster_state:ok / 16384 slots / 6 nodes / size 3
                    ⚠️ 3 个 master 的 announce 地址被改成了 127.0.0.1:1637x（运行期改动）
                    ⚠️ 容器一重启这个改动就丢，集群会变 cluster_state:fail
rc-cpsweb-app       上一轮留下的 consumer，未改动
```

验证基线（**改代码前先跑一遍**）：

| 命令 | 期望 |
|---|---|
| `docker run --rm --user 1000:1000 -v "D:/work/rediscluterproject:/repo" -w /repo rc-control:bats bash -c "find tests -name '*.bats' -print0 \| xargs -0 bats"` | **203 / 0** |
| `bash tests/check_syntax.sh` | `TOTAL=45 FAIL=0` |
| `bash tests/validate_libs.sh` | `PASS=54 FAIL=0` |
| `cd $BE\common\idgenerator; mvn -o clean test` | **3 / 0 / 0 跳过** |
| `cd $BE\realserver\common\oms; mvn -o clean test` | **63 / 0 / 0 跳过** |
| `cd $BE\realserver\plugins\rtdata-module; mvn -o test` | **14 / 0** |

> ⚠️ **构建必须用 JDK 8**（`D:\java\java-se-8u42-ri`）——
> `oms` 的 proguard 要 `${JAVA_HOME}/jre/lib/rt.jar`，只有 JDK 8 有这个路径。
>
> ⚠️ **本地仓库里的 `realserver-oms` jar 是 proguard 处理过的** ——
> `RedisPropertiesConfig` / `RedisUtilConfig` 已被改名，
> 从 idgenerator 的测试类路径上引用不到（见「第十五轮」第四节）。

### 下一次会话从这里开始（第十四轮结束时，历史记录）

```powershell
cd D:\work\rediscluterproject
git status -sb            # main...origin/main，工作区干净
git log --oneline -5      # 6e86496 / fdd3193 / 9b4f040 / 80ad557 / 0c74f24
```

环境（2026-10-29 实测，与上面的「会话存档」一致）：

```
rc-redis-publish    socat 转发器，把集群暴露到宿主机 127.0.0.1:16379-16384
rc-cpsweb-node-a/b Redis 集群，cluster_state:ok / 16384 slots / 6 nodes / size 3
                    ⚠️ 3 个 master 的 announce 地址被改成了 127.0.0.1:1637x（运行期改动）
                    ⚠️ 容器一重启这个改动就丢，集群会变 cluster_state:fail
rc-cpsweb-app       上一轮留下的 consumer，未改动
```

验证基线（**改代码前先跑一遍**）：

| 命令 | 期望 |
|---|---|
| `docker run --rm --user 1000:1000 -v "D:/work/rediscluterproject:/repo" -w /repo rc-control:bats bash -c "find tests -name '*.bats' -print0 \| xargs -0 bats"` | **203 / 0** |
| `bash tests/check_syntax.sh` | `TOTAL=45 FAIL=0` |
| `bash tests/validate_libs.sh` | `PASS=54 FAIL=0` |
| `cd $BE\realserver\common\oms; mvn -o clean test` | **63 / 0 / 0 跳过** |
| `cd $BE\realserver\plugins\rtdata-module; mvn -o test` | **14 / 0** |

> ⚠️ **构建必须用 JDK 8**（`D:\java\java-se-8u42-ri`）——
> `oms` 的 proguard 要 `${JAVA_HOME}/jre/lib/rt.jar`，只有 JDK 8 有这个路径。

### 下一次会话从这里开始（第十三轮结束时，历史记录）

```powershell
cd D:\work\rediscluterproject
git status -sb            # main...origin/main，工作区干净
git log --oneline -3      # aadcbb9 / 1252437 / bac3398
```

环境（2026-10-29 实测，与上面的「会话存档」一致）：

```
rc-redis-publish    socat 转发器，把集群暴露到宿主机 127.0.0.1:16379-16384
rc-cpsweb-node-a/b Redis 6 节点集群，cluster_state:ok / 16384 slots / 6 nodes / size 3
                    ⚠️ 3 个 master 的 announce 地址被改成了 127.0.0.1:1637x（运行期改动）
rc-cpsweb-app       上一轮留下的 consumer，未改动
```

验证基线（**改代码前先跑一遍**）：

| 命令 | 期望 |
|---|---|
| `docker run --rm --user 1000:1000 -v "D:/work/rediscluterproject:/repo" -w /repo rc-control:bats bash -c "find tests -name '*.bats' -print0 \| xargs -0 bats"` | **199 / 0** |
| `cd $BE\realserver\common\oms; mvn -o clean test` | **59 / 0** |
| `cd $BE\realserver\plugins\rtdata-module; mvn -o test` | **14 / 0** |

### 下一次会话从这里开始（第十二轮结束时，历史记录）

```powershell
cd D:\work\rediscluterproject
git status -sb            # main...origin/main，工作区干净
git log --oneline -3      # 856d1b8 / f063299 / 46eb005
```

环境（本轮结束时仍在跑，没有拆）：

```
rc-cpsweb-app      跑的是新 jar（target/rtdata-consumer-1.0.14.jar，140,519,854 B）
                   配置来自 jar 内 application.yml（CONFIG_FROM_YAML=1 那轮留下的状态）
rc-cpsweb-node-a/b Redis 6 节点集群，cluster_state:ok
                   ⚠️ **3 个主全在 node-a**，每主 ~190 万 keys（合计 ~570 万）
Kafka/ZooKeeper    两节点集群，未改动
Docker VM          2 vCPU / 3.8 GB；MemAvailable ~945 MB，⚠️ **SwapFree 只剩 35 MB**
```

> 本轮的 E2E 容器（`e2e-node-a/b`）已由脚本自己的 trap 清理干净 ✓。
> 上面这些 `rc-cpsweb-*` 是第十一轮留下的，跟本轮无关。

### 本轮（第十四轮）的待办，按优先级

1. **（要人做决定）jedis 要不要继续升到 8？** 现在是 `3.10.0`（**JDK 8 下的上限**）。
   - 已实测：jedis **3.6.1 / 3.8.0 / 3.10.0** + SDR 2.7.18 + JDK 8 → ✅ 全绿；
     jedis **4.0.0 及以上** → ❌ `NoClassDefFoundError: redis/clients/jedis/GeoUnit`。
   - 升到 4+ 的代价：**SDR 必须一起升到 4.x**（实测 SDR 4.0.4 + jedis 8.1.0-beta2
     在真集群上 **write+read 都 OK**，路径是通的），
     而 SDR 4.x 是 **Java 17 字节码** → 编译目标要升 JDK 17 +
     **重做 proguard**（现在配的 `${JAVA_HOME}/jre/lib/rt.jar` 只有 JDK 8 有）+
     改生产写路径（`JedisPool` → `ConnectionPool`）+
     改 `RedisScanUtils`（`ScanParams`/`ScanResult` 换包），
     且会沿 `oms` → 三个应用**向上扩散**。
   - **前提（代码里看不出来，需要人确认）**：生产服务器是不是必须留在 JDK 8？
2. **（要人做决定）CI 的 `bash -n` 覆盖面** —— 把 workflow 里那条手抄的
   `for f in ...` 换成 `bash tests/check_syntax.sh`，覆盖面 6 → 45 个文件。
   ⚠️ 改 `.github/workflows/ci.yml` **必须走 SSH 推送**（PAT 没有 `workflow` scope）。
3. **读侧 pipeline**（第十三轮的待办，仍然有效）——
   `RedisClusterHashPipeline.getAllHashes`。写侧第十轮已按节点 pipeline 化，
   **读侧还没做**，是同一根因的另一半。
   第十四轮已在真集群上锁住了读路径的**顺序正确性**，
   做的时候**别把那条断言改坏**。
4. **填生产真值**（唯一的"欠账"）—— 三个 `application.yml` 的 `oms.clusters`
   还是占位符 `127.0.0.1:6379`、`password` 空串；同步 Nacos。
5. **`cluster_require_full_coverage=no`** —— 2 机部署必须，否则任一 master 挂 = 全集群停写。

### 本轮（第十二轮）的待办，按优先级

1. **填真机信息并上真机**（唯一还欠的事）：
   把 `cluster.conf` 里的 `<A机IP>` / `<B机IP>` / 密码换成真值 → 先
   `bash cluster-config.sh --dry-run` 看拓扑 → `bash cluster-config.sh` → 按
   `docs/USAGE.md` 5.7.8 的「第 5 步：验证」核对 `cluster_state:ok` +
   `cluster_known_nodes:6`。
2. **演练一次整机故障**：杀掉「master 数少」的那台 → 期望集群**仍可读写**（降级）；
   杀掉「master 数多」的那台 → 期望停写（这是**已知限制**，不是 bug）。
   真机的 `cluster-node-timeout` 是 15000ms，比 E2E 慢，给足等待时间。
3. **如果需要真正的双机容错**：加到 **3 台机器**。两台机器在数学上做不到对称容错
   （副本提升要过半 master 存活），见「第十二轮」第八节。

### 第十一轮遗留的待办（仍然有效，与本轮无冲突）

1. **验证 `max-poll-records`**：生产 Nacos `share_base` 里是 **100000**，而测试没配
   → 生效值是 Spring Boot 默认 **500**（每批 500 条，pipeline 摊薄得差）。
   做法：在 app 的 `application.yml` 里加 `spring.kafka.consumer.max-poll-records:
   100000` → 重新打包 → 用 `CONFIG_FROM_YAML=1` 跑 3 轮，与记录的 13,333/s 对比。
   **这很可能比「加消费者」更能解释当前吞吐上限。**
2. **在干净集群上重测倍率**（收紧「1.7–4.1×，中位数 2.8×」）：当前环境键数已到
   ~570 万 + 每轮触发 BGSAVE + VM 的 swap 只剩 35 MB，差值不可信。
3. **可选**：把 `scripts/check-bash-compat.sh` 接进 CI（旧待办，仍未做）。
   ⚠️ 它内部还要起 docker，CI 的 `container:` 作业要自己验一下。

> **给下一个执行者的一条硬约束**：这台机器现在 **CPU/内存饱和**（swap 2 GB 几乎
> 用尽）。「加消费者」「加线程」类的实验在这里**得不出可信结论** ——
> 第十一轮的实测是：2 个消费者比 1 个**慢 3 倍**（中位数 16,006 vs 49,750），
> 而同一配置单消费者的波动范围本身就是 14,250–50,000（**3.5 倍**）。
> **先看 `docker stats` 和 `/proc/meminfo` 的 SwapFree，再决定要不要跑性能实验。**

### 第十一轮的产物（下次接手直接看这里）

| 东西 | 位置 |
|---|---|
| yaml 改动的权威 diff | `docs/superpowers/patches/2026-10-28-yaml-config.patch` |
| 测量脚本（`CONSUMERS` / `CONFIG_FROM_YAML` / `log_has` / publish 计数断言） | `scripts/bench-consumer-write.sh` |
| 交接正文 | 本文件「第十一轮」 |
| 改后的 application.yml（可直接抄） | `realserver/plugins/rtdata-consumer/src/main/resources/application.yml`（**不在本仓库**，以 patch 为准） |
| 新 jar | `realserver/plugins/rtdata-consumer/target/rtdata-consumer-1.0.14.jar`（140,519,854 B，2026-10-28 08:21） |

> ⚠️ **新 jar 里的 `application.yml` 写的是 E2E 集群的临时地址（172.21.0.x）**，
> **不能带进生产**。生产配置来自 Nacos（`share_base` + `ext_base`），
> 详见「第十一轮」第二节。

**第九轮的旧动作（保留备查）：**

- ~~把积压式排空的探针固化成 `scripts/bench-consumer-write.sh`~~ —— **已完成**（第十轮，
  并且补了 5 类断言，见「第十轮」）。

### 第十轮的产物（下次接手直接看这里）

| 东西 | 位置 |
|---|---|
| 设计 | `docs/superpowers/specs/2026-10-27-cluster-pipeline-design.md` |
| 计划（含执行后的补注） | `docs/superpowers/plans/2026-10-27-cluster-pipeline.md` |
| 代码补丁（权威 diff） | `docs/superpowers/patches/2026-10-27-cluster-pipeline.patch` |
| 测量脚本 | `scripts/bench-consumer-write.sh` |
| 交接正文 | 本文件「第十轮」 |
| 12 轮原始数字 | `%TEMP%\opencode\pipeline-result.txt` |
| 旧 jar 副本（A/B 用） | `%TEMP%\opencode\rtdata-consumer-1.0.14-old.jar` |
| 改动前的两个源文件备份 | `%TEMP%\opencode\pipeline-baseline\` |
| 单轮原始日志 | `%TEMP%\opencode\bench-run*.txt`、`task8-bench.txt` |

> `%TEMP%` 是临时的。**要长期保留的是 patch**——它能从基线重建全部改动：
> 在 `realserver/` 下 `git -c core.autocrlf=false apply <patch>`。
> 新版 jar 不在了就重新 `mvn -o -pl realserver/plugins/rtdata-consumer -am -DskipTests package`。

**跑一次测量的最短路径**（环境还在时）：

```powershell
# A. 配置走命令行（默认）
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock `
  -v "D:/work/rediscluterproject:/repo" `
  -e NEW_JAR=D:/javawork/1.2/cpscloud1.0/code/platform/backend/realserver/plugins/rtdata-consumer/target/rtdata-consumer-1.0.14.jar `
  -e CONC=1 -e MIN_MEAN=0 `
  rc-e2e-runner:local bash /repo/scripts/bench-consumer-write.sh

# B. 配置走 jar 内的 application.yaml（第十一轮新增，已验证等价）
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock `
  -v "D:/work/rediscluterproject:/repo" `
  -e NEW_JAR=D:/javawork/1.2/cpscloud1.0/code/platform/backend/realserver/plugins/rtdata-consumer/target/rtdata-consumer-1.0.14.jar `
  -e CONFIG_FROM_YAML=1 -e CONC=1 -e MIN_MEAN=0 `
  rc-e2e-runner:local bash /repo/scripts/bench-consumer-write.sh

# C. 两个消费者实例（第十一轮新增）
... -e CONSUMERS=2 -e CONC=1 -e MIN_MEAN=0 ...
```

> `CONFIG_FROM_YAML=1` 时命令行**只**保留两个 Nacos 开关
> （`spring.cloud.nacos.config/discovery.enabled=false`）——
> 它们**必须**留在命令行，因为 Nacos 客户端在 bootstrap 阶段创建，
> `application.yml` 里写不生效（见「第十一轮」第二节）。

**已完成的旧动作（保留备查）：**

2. ~~决定是否修 `add-node.sh:141`~~ —— **已完成**（第四轮）。
   根因不是「忘了建目录」，而是它的 chown 列表与 `cluster-config.sh` 的
   `create_dirs` 不一致：多了一个没人创建的 `/var/log/redis`，
   又少了一个 `2eb4aee` 修过的 `/etc/redis`。现已完全对齐，并补了回归验证。
3. ~~修 E2E 里两处裸 `| grep` 断言~~ —— **已完成**（`3b6d23a`）。
   实际是**三处**，且 DoD3 那处还有「择一即通过」的第二重问题，见「已知问题二」。
4. ~~删除旧 worktree 与 `feature/cluster-config-script` 分支~~ —— **已完成**。
   git 登记已注销、文件已删净、分支已删除；只剩一个被 `opencode.exe`
   占用的**空目录**，等占用它的会话退出后删掉即可（见「与主分支的关系」）。
5. ~~计划文档里的代码片段与仓库现状有出入~~ —— **已完成**（第三轮）。
   两份实施计划与两份 spec 的 `ReadWritePaths` 都补了 `-` 前缀；
   2026-10-19 的计划里被实测证伪的结论（gosu/su-exec、`--tmpfs /data`、
   148 tests）也已在原处标注证伪过程。
6. spec §8 的 DoD 清单里，`tests/lib/preflight.bats` 计划要求存在，
   实际从未创建 —— preflight 走真实 SSH，按设计只由 E2E 覆盖，没有单元测试。
   这是**有意的设计决定**，不是遗漏。
7. ~~审查已报的 4 条解析器遗留项~~ —— **已完成**（第六轮）：
   `unset -f` 删掉调用方同名函数、同组内重复键静默覆盖、UTF-8 BOM 首行解析失败、
   `set -u` 在 bash < 4.4 下访问空数组报错。四条全部修掉，并各配了回归用例。
8. **CI 一直是红的** —— **已修**（第六轮，`9b0a6f6` 上 Actions 变成 success）。
   **两个独立原因**，都只在 CI 的环境中才看得见：
   (a) 一条测试用了 bats 1.4 才有的 `$BATS_TEST_TMPDIR`，在 CI 的 bats 1.2.1 上
   路径变成 `/die.err` —— **以 root 跑绿、以非特权用户跑红**；
   (b) `gen_password` 把无限流灌进 `head`，CI runner 的 coreutils 会报
   `tr: write error: Broken pipe` 到 stderr，噪音混进捕获的输出 —— 本地那份
   coreutils 静默地死，所以**本地一次都复现不出来**。
   详见上面「第六轮」。
   > **顺手发现的一个系统性缺口**：bats 套件此前**没有开 `set -u`**，
   > 而生产脚本都是 `set -uo pipefail` —— 这就是空数组缺陷能藏三轮的原因。
   > 现在 `tests/setup.bash` 的 `setup()` 里开了 `set -u`。
9. **把 `scripts/check-bash-compat.sh` 接进 CI**（还没做）——
   它是**唯一能看见 bash 4.0-4.3 那类 bug 的地方**（CI 跑的是 bash 5.1）。
   CI 的 `container:` 作业需要容器里有 node 才能跑 `actions/checkout`，
   这条路要自己验一下，不是加一行就完事。
   > ⚠️ **接进去之前先修掉它的「假红」** —— 已经修了（2026-10-29，
   > 见「当前测试基线」一节）：它依赖 alpine CDN 下载 bats，而那个 CDN
   > **间歇性失败**，失败时旧版只打印一句 `BASH_COMPAT: FAIL (exit 1)`，
   > 看起来像「代码在 bash 4.3 上不兼容」。**接进 CI 之前不修，
   > CI 会随机变红，而且红的原因会被指错方向。**

10. **⭐ CI 的 `bash -n` 覆盖面有缺口**（2026-10-29 实测，本轮新发现）：
    `.github/workflows/ci.yml` 里那条 `bash -n` 列表是**手工维护**的，
    只列了 6 个文件 + `lib/*.sh`。实测哪些脚本**根本没有任何 CI 检查**：

    | 脚本 | CI 的 `bash -n` | bats 里有 `bash -n`？ |
    |---|---|---|
    | `cluster-config.sh` | ❌ | ✅（`tests/cluster_config.bats`） |
    | `scripts/e2e-cluster-config.sh` | ❌ | ❌ |
    | `scripts/e2e-kafka-cluster.sh` | ❌ | ❌ |
    | `scripts/bench-consumer-write.sh` | ❌ | ❌ |
    | `scripts/check-bash-compat.sh` | ❌ | ❌ |
    | `tests/check_syntax.sh` 本身 | ❌ | ❌ |
    | `tests/validate_libs.sh` | ❌ | ❌ |
    | `tests/helpers/*.sh`、`tests/probes/*.sh` | ❌ | ❌ |

    **根因**：`tests/check_syntax.sh` **已经**把这一切都管了
    （`TOTAL=45 FAIL=0`，覆盖上面每一个文件），**但 CI 从来没跑它** ——
    CI 是在 workflow 里**手抄**了一份更短的列表，两份必然漂移。

    **修法（很便宜）**：把 CI 那条手抄的 `for f in ...` 换成
    ```yaml
      - name: Bash syntax check
        run: bash tests/check_syntax.sh
    ```
    一行改动，覆盖面从 6 个文件变成 45 个，而且**不再会漂移**
    （新增脚本只要被 `check_syntax.sh` 收进去就自动被 CI 检查）。
    `tests/validate_libs.sh` 同理（`PASS=54 FAIL=0`，纯 bash，不需要 docker）。

    ⚠️ **改 `.github/workflows/ci.yml` 必须走 SSH 推送**（HTTPS 的 PAT
    没有 `workflow` scope），命令见文末「推送方式」一节。

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

> **适用范围**：上面这些是**第一轮**计划
> （`docs/superpowers/plans/2026-10-13-redis-cluster-config-script.md`）的 Task 7-10。
> 第二轮的计划（`2026-10-19-e2e-on-redis-8.md`）已在第三轮回改过，
> 代码块与仓库现状一致、可直接照抄，被证伪的结论也都标注了证伪过程。

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

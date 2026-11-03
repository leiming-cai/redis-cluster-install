# 会话存档（2026-11-03）：华盾 napstar2.0 —— 用 Redis 集群跑一轮全量回归

> **这份文件是给「下一个会话」看的。**
> 打开它 == 拿到本会话的**全部产出**：环境体检、集群全链路回归的**逐条数字**、
> 一个**执行顺序**的坑（批次 1 与 1b 不能串）、一个**脚本不在仓库里**的缺口。
>
> - 上一份存档：`docs/superpowers/sessions/2026-11-03-hd-monitor-runtime-coverage.md`
>   （树名更正 + `monitor` 运行时覆盖轮）
> - **本会话的树图**：`docs/superpowers/sessions/2026-11-03-tree-map.md`
> - 缺陷清单：`docker/hd-napstar/DEFECTS.md`（本轮**没有新缺陷**，只有一次复核）

---

## 一、一句话现状

**上一轮把 `monitor` 的集群分支补上了运行时覆盖，但那一轮结束时集群是「已停」的状态** ——
也就是说「集群模式下应用真的能读写」这件事，在**收尾那一刻并没有处于可执行状态**。

本轮**把集群起起来，把整条链路重跑一遍**：

> **8 项判据全绿，与上一轮基线**逐条一致**；**
> **集群模式下应用自己写的 key 进得去、载荷读得回来；**
> **单机与集群的 `real_graph:realscope` 各 12 个 field、名字逐个相等。**

**本轮一行生产代码都没改**，产出的是**一份带数字的回归存档** + **两个执行层面的发现**。

---

## 二、开工前的环境体检

> 存档里的规矩：**上一轮的数字是「上一轮跑出来的」，不是「现在还是不是真的」**。
> ⇒ 每一轮开工前先把环境和脚本对齐情况查一遍。

| 判据 | 本轮实测 | 上一轮基线 | 一致 |
|---|---|---|---|
| Nacos readiness | `18849` → **200** · `18848` → **200** | 200 | ✅ |
| JWT `/tmp/hd-token.txt` | `exp=1793774238` · `now=1793690346` ⇒ **剩 83,892 秒（≈23.3 小时）** | 未过期 | ✅ |
| Kafka | **2 个 broker**（`/brokers/ids` = `[755, 756]`）· 7 个 topic（含 `COMMITDATAINCRE`） | 同 | ✅ |
| ZooKeeper | `Mode: follower` | 同 | ✅ |
| 夹具 `info.model_objecttype` | **3 行** | 3 | ✅ |
| 容器内存 | hd-node1 `available` **741 MB**（总 3917 / used 3008 / swap 已用 1898） | — | 偏紧 |

**脚本对齐**（`/opt/hd/*.sh` vs 仓库 `scripts/*.sh`）：

| 脚本 | md5 | 状态 |
|---|---|---|
| `hd-redis-cluster.sh` | `d6e7ac39d2a49025a3ab8a817706157b` | ✅ 一致 |
| `hd-cluster-verify.sh` | `bf5f530e58094eea62ef947495952cbb` | ✅ 一致 |
| `hd-cluster-app-test.sh` | `5085a64fd4c63cc2e8cbcb3b7dbcd329` | ✅ 一致 |
| `hd-monitor-runtime-verify.sh` | `835ba471ea8f778ff4b42f2748331079` | ✅ 一致 |
| `hd-monitor-runtime-lib.sh` | `2ed7bb84d33f5f6197e535e24def6900` | ✅ 一致 |
| `seed-hd-model-metadata.sh` | `3e093cae50a0a84c0d9dceffb971d8e8` | ✅ 一致 |
| `start-hd-apps.sh` | `251eec34d4b7196b5636657e931ad5b4` | ✅ 一致 |
| `mint-hd-token.sh` | `cc8a75aacf37d2163ecb716aae3f9df1` | ✅ 一致 |
| **`verify-hd-napstar.sh`** | 容器 `/opt/hd/verify.sh` = `8bcd70e2636bf195d407b3c61368c1cf` | ✅ 一致 |

> 📌 **部署约定**：`scripts/verify-hd-napstar.sh` 部署成容器里的 **`/opt/hd/verify.sh`**
> （不是同名）。容器里那个同名的 `verify-hd-napstar.sh` 是**上一轮之前的旧版**
> （缺 A0 指纹段、缺 B2 前置条件判据）⇒ **别照着它跑**。

---

## 三、执行顺序（这一轮的产出之一）

> **上一轮就记过三条顺序约束**，本轮实测**照着做就一次通过**，顺序错了会怎样也再次确认。

```
[0] 环境体检
[1] 起集群          hd-redis-cluster.sh start
[2] 底层 L1-L6      hd-cluster-verify.sh            ← 集群在跑
[3] 应用层读写      hd-cluster-app-test.sh          ← 集群在跑；脚本自己起批 HD_REDIS_CLUSTER=1
[4] monitor 运行时  hd-monitor-runtime-verify.sh    ← 单机 + 集群两遍跑
[5] merge-wiring    test-hd-cluster-merge-wiring.sh ← **必须集群在跑**
[6] 停集群 + 恢复单机态   hd-redis-cluster.sh stop + start-hd-apps.sh
[7] base 回归矩阵   verify.sh                       ← 集群必须已停
[8] 其余三个脚本自测
```

| # | 约束 | 不遵守的后果 | 依据 |
|---|---|---|---|
| 1 | **[7] 必须在 [6] 之后** | 集群在跑时 base 矩阵会把集群计数并进来 ⇒ SUMMARY **不可比**；且 [3][4] 用 `HD_REDIS_CLUSTER=1` 重启应用并**截断日志** ⇒ A2/A2b（找 `Using Redis Standalone at` 那行）会 FAIL。**实测顺序错了 → `PASS=78 FAIL=8`** | 上一轮存档 §八.1 |
| 2 | **[5] 必须在集群在跑时** | 集群没跑时它**静默跳过**（退出码 0 但 `PASS=0`）⇒ 「退出码 0」**不等于**「测到了」 | 上一轮存档 §八.2 |
| 3 | **[8] 的 portal 自测必须在 `rc-e2e-runner` 里** | 它要读 `/out/portal-snapshot-cluster.txt`（`/out` 是宿主 `.hd-work` 的挂载点，`hd-node1` 里**没有**）⇒ 在 `hd-node1` 里跑会**退出码 2** | 上一轮存档 §八.3 |

---

## 四、逐条结果

### 4.1 起集群

```
bash /opt/hd/hd-redis-cluster.sh start
```

| 项 | 实测 |
|---|---|
| 节点 | **3 master**（`16379` / `16380` / `16381`），容器内地址 `172.22.0.2` |
| 槽位 | `0-5460` / `5461-10922` / `10923-16383` ⇒ **16384 全覆盖** |
| `cluster_state` | `ok`（create 后第 3 次探测才收敛，前两次是 `fail` —— **脚本等 10 次是对的**） |
| `cluster_known_nodes` / `cluster_size` | `3` / `3` |
| bus 端口 | `+10000`（`26379`/`26380`/`26381`） |

### 4.2 底层集群验证 L1–L6

```
bash /opt/hd/hd-cluster-verify.sh      →  SUMMARY: PASS=39 FAIL=0
```

| 层 | 关键实测 |
|---|---|
| L3 跨槽读写 | 3 个 key 落在 **3 个不同的 master** 上，`-c` 模式全部读回 |
| L4 MOVED | 非本节点 key 返回 `MOVED 14400 172.22.0.2:16381`，`-c` 能跟随重定向读回 |
| L5 分片倾斜 | 30 个 key → `+12 / +10 / +8`，**总量 = 30**，最大分片 12/30（≤70%） |
| L6 pipeline | 跨槽 `--pipe` 返回 **MOVED × 2**、`errors=2`、回复数 = 命令数；**同一条 pipeline 里本节点槽的 2 条命令成功** |
| 清理 | 三个 master 残留 **0** 个测试 key |

> 📌 **L6 复现了 JVM 层限制的前提**：命令行能证明「跨槽 pipeline 必失败」，
> 但 `JedisClusterConnection.openPipeline()` 抛 `UnsupportedOperationException`
> **属于客户端库行为，命令行复现不了** ⇒ 那个由应用层的 C3 / B3 覆盖（均 = 0）。

### 4.3 应用层集群读写

```
bash /opt/hd/hd-cluster-app-test.sh     →  SUMMARY: PASS=36 FAIL=0 SKIP=0
```

| 判据 | 实测 |
|---|---|
| **A2（web-controller）** | ✅ **真 PASS**（上一轮已是真 PASS；本轮 `SKIP=0` ⇒ **没有任何一条判据被跳过**） |
| **B2（model-controller）** | 应用写的 `model:*` key 在集群里（16379 三个 / 16380 一个 / 16381 三个）；读回 `model:objecttypes:names:DPSPoint` → `900002` |
| **B3** | model-controller **无** `java.lang.UnsupportedOperationException`（限定 `= 0` + SDR 原文 `= 0`） |
| **C2（rtdata-consumer）** | 发一条 INCDATA Kafka 消息 ⇒ `real_data:31249:134213433032705` 在集群里；**读回 field `9001` = `"3.14,2026-11-01 00:00:00,2"`** |
| **C3** | rtdata-consumer **无** `java.lang.UnsupportedOperationException` |
| **D 分片** | 30 个 key → `7 / 10 / 13`，总量 30，最大分片 13/30（≤70%） |
| **E 清理** | 三个 master 的 DBSIZE 增量 **0**（**已扣除** `model:*` / `real_graph:*`）⇒ **上一轮修的 namespace 口径生效**；本脚本登记的 `model:enumdicts:folder:user_sex` 已删，`model:*` 里**别的** key 保留 |

> ⭐ **C2 读回的那个值是本轮最硬的证据**：
> `"3.14,2026-11-01 00:00:00,2"` —— 是**应用自己**的载荷格式，
> 不是脚本自己用 `redis-cli` 写的探针值。⇒ **写路径在集群模式下真的跑通了。**

### 4.4 monitor 运行时覆盖（单机 vs 集群）

```
bash /opt/hd/hd-monitor-runtime-verify.sh  →  SUMMARY: PASS=10 FAIL=0
```

| 判据 | 实测 |
|---|---|
| S0 / S3 | 单机模式应用启动成功 · 日志里**有** Standalone 行、**没有** Cluster 行（模式唯一） |
| S1 / S2 | 单机 `real_graph:realscope` **12 个 field**，全部来自种子编号（`900001_900101` … `900003_900112`） |
| C0 / C5 | 集群模式应用启动成功 · 日志里**有** Cluster 行、**没有** Standalone 行（模式唯一） |
| C1 | 集群 `real_graph:realscope` **12 个 field** |
| **C2** | **集群模式的 field 名与单机模式逐个相等（12 个）** |
| C3 | kafkabus 那 3 个类型的 `OTypeException` = **0**（总数仍有 23，来自 SVG 解析路径的其它类型） |
| C4 | 集群模式下**无** `UnsupportedOperationException` |

> ⭐ **C2 是「等价性」的判据，不是「存在性」**：
> 只跑集群模式无法排除「其实走的是单机分支」（`isCluster()` 判断错了）。
> ⇒ 必须**两边都跑**、**field 名逐个相等**。

### 4.5 集群合并 wiring 自测

```
bash /opt/hd/test-hd-cluster-merge-wiring.sh  →  TEST SUMMARY: PASS=8 FAIL=0
```

**4 个反例全部守住**（helper 缺失 / helper 为空 / helper 语法错 / helper 里没有那个函数）：
矩阵**必须**非 0 退出**且不打印 `FAIL=0` 的 SUMMARY** ⇒ 集群的失败**不会悄悄丢掉**。

> 📌 这一条**必须在集群在跑时**才有意义（否则整段静默跳过、`PASS=0`）。

### 4.6 停集群 + 恢复单机态 + base 回归矩阵

```
bash /opt/hd/hd-redis-cluster.sh stop     →  3 节点全停 · 数据目录 /opt/hd/redis-cluster 已删
bash /opt/hd/start-hd-apps.sh 1           →  批次 1（web-controller / realalarmconsumer / rtdata-consumer）
bash /opt/hd/t6-start-mc.sh               →  model-controller 单独起（**不停别的应用**）
bash /opt/hd/verify.sh                    →  SUMMARY: PASS=47 FAIL=0 SKIP=4
```

| 段 | 结果 |
|---|---|
| M 中间件 | 6379 / 6389 PONG · 6379 standalone · 无密码被拒 · ZK ensemble · Kafka 2 brokers · 5 个 topic · Nacos ready · PG info 30 表 · napstar 库存在 · 4 个业务角色 · pg_hba 放行容器 IP |
| **A0 启动来源（必答项）** | 三个 jar 的 md5 + mtime 全部打印；三个 app 的生效模式**逐字**打印 |
| A 段 | 4 个 app 全部 `Started ... in ... seconds` · 无致命错误 · **`Using Redis Standalone at node1:6379`（timeout=5000ms）** · 模式 = STANDALONE · PG 错误 0 |
| B 段 | B1（SKIP：hds schema 无表）· B2（SKIP：第三方 schema 无表；**SQL 层真判据照跑** PASS=5）· B6 / B7（mapper MD5 与基线一致）· B8（方言测试 OK=6 FAIL=0，含「改前写法确实失败」的反向验证）· B9（HD info 30 表） |
| **C 段** | **SKIP**「集群没在跑」——**预期行为**，集群是本轮第 [1]–[5] 步测的，这里已经停了 |

> ⚠️ **C 段被跳过是本轮设计内的**：base 矩阵的 C 段是「把集群的计数并进 SUMMARY」，
> 而集群部分**已经在第 2/3/4/5 步单独测过了** ⇒ 停掉集群再跑矩阵，才保证 SUMMARY 与基线可比。

### 4.7 其余三个脚本自测

| 脚本 | 跑在哪 | 结果 |
|---|---|---|
| `test-hd-cluster-summary.sh` | hd-node1 | **`PASS=19 FAIL=0`**（含「被直接执行时必须非 0 退出并说明它是个库」） |
| `test-hd-monitor-runtime-verify.sh` | hd-node1 | **`PASS=16 FAIL=0`**（16 条边界，含「必须 FAIL」的反例） |
| `test-hd-portal-baseline.sh` | **`rc-e2e-runner`**（要 `/out` 挂载） | **`PASS=40 FAIL=0`**（含「噪声里的数不许被当真值」） |

---

## 五、⚠️ 本轮踩到的一个执行顺序的坑（**不是新缺陷，是老坑复发**）

### 现象

**`start-hd-apps.sh 1b` 会把批次 1 的应用停掉。**

它的 `stop_apps()` 是按 jar 名**全停**：

```bash
APP_JARS="web-controller|realalarmconsumer|…|model-controller|…"
pkill -f "[-]jar .*(${APP_JARS}).*\.jar"
```

⇒ 所以「先 `1` 再 `1b`」的结果是**只剩 model-controller**，
batch 1 的三个应用**全被 `1b` 停了**。

### 正确做法（`.hd-work/t6-start-mc.sh` 里的既有做法）

批次 1 用 `start-hd-apps.sh 1` 起，model-controller **手工起**（**不带任何 `--oms.*` 覆盖**
= 基线的启动方式），两者**同时在跑** —— 这才是基线 `PASS=47` 的应用集合。

> 📌 这条**在 `docker/hd-napstar/DEFECTS.md` 的 D8 节里已经记过**
> （「批次 `1` 和 `1b` **不能**用这个脚本串起来跑」），
> 但它在**缺陷清单里**，不在**脚本的用法说明**里 ⇒ 容易再踩一次。

### ⚠️ 一个**缺口**：`t6-start-mc.sh` **不在仓库里**

它只存在于 `.hd-work/`（上一轮的临时脚本，`.hd-work/` 被 `.gitignore` 忽略）
⇒ 本轮是**手动 `docker cp` 进容器**跑的。

> ⇒ **下一轮如果还要跑 base 矩阵，要么再 cp 一次，要么把它收进 `scripts/`。**
> 我倾向后者：它是「跑 base 矩阵」这件事的**必要前置步骤**，
> 而 base 矩阵是每一轮都要跑的回归。

---

## 六、最终环境状态

| 项 | 状态 |
|---|---|
| Redis | **集群已停**（`hd-redis-cluster.sh stop`）· 只剩 **6379 / 6389 两个独立单机**（`redis_mode:standalone`） |
| 6379 / 6389 DBSIZE | **11** / **0**（与本轮开跑前一致） |
| 集群数据目录 | `/opt/hd/redis-cluster` **已删除** |
| 应用 | **4 个跑在 Standalone**（web-controller / realalarmconsumer / rtdata-consumer / model-controller），生效模式 `node1:6379`（timeout=5000ms） |
| Nacos | **200** |
| Kafka / ZK | 2 broker（755 / 756）· ZK follower |
| 夹具 | `info.model_objecttype` **3 行** |
| 容器内存 | hd-node1 available **741 MB** |
| 仓库 | **工作区干净**，HEAD 未变（本轮只写了 `.hd-work/` 里的进度文件，该目录被 gitignore） |

---

## 七、本轮的提交

```
（本轮只有文档提交，见下方 §九）
```

---

## 八、这一轮**没有**做的事（明确记下来）

| # | 事 | 为什么没做 |
|---|---|---|
| 1 | **`monitor` 另外 5 处集群分支的运行时覆盖** | 仍是 **D11**：C/D/E/F 四处需要 **SVG 文件**（容器里一个 `*-ScheFile.svg` 都没有）或 websocket 订阅；`RTListener` 那处缺一条 Kafka `COMMITDATAINCRE` 消息。**不假装覆盖了** |
| 2 | **任何生产代码 / 脚本改动** | 本轮是**回归轮**，不改代码 ⇒ 数字可与上一轮直接对比 |
| 3 | **`sac` / `cmt` / `hds`** | **第三方系统的表，本项目只有读权限** ⇒ 不建表（🚫 明确不做） |
| 4 | **把 `t6-start-mc.sh` 收进仓库** | 本轮没动脚本（见 §五 的「缺口」）⇒ **下一轮决定** |
| 5 | **`transformNapstarModel` 真跑起来** | 它是**读** sac/cmt、**写** info 的转换作业 ⇒ 要**第三方实例/历史数据**才有意义 ⇒ 属于「第三方数据接进来」的问题，**与本项目无关** |

---

## 九、下一轮照做

| # | 事 | 严重度 | 说明 |
|---|---|---|---|
| **1** | **`monitor` 的另外 5 处**补运行时覆盖 | 🟡 | 已记在 **D11**。C/D/E/F 需要 SVG 文件或 websocket 订阅；`RTListener` 需要一条 `COMMITDATAINCRE` 消息 |
| **2** | **把 `t6-start-mc.sh` 收进 `scripts/`** | 🟡 | 本轮踩到（§五）。它是跑 base 矩阵的**必要前置**，而 base 矩阵每轮都要跑 |
| **3** | **门户线自己的 `3dmanager` 迁移跑不通** | 🟡 | 迁移脚本是 **MySQL 方言**，门户库 `cpspg` 是 **PostgreSQL** ⇒ 门户线的独立问题（与华盾无关） |
| **4** | **门户线要切集群** | 🟡 | 门户树**一个集群标记都没有** ⇒ 得从基线把整套补丁搬过去（跟华盾当时一样） |
| **5** | **`sche-viewer-server` 的 15 处裸 `executePipelined`** | 🟡 | 当前 standalone、不参与构建 ⇒ 暂时安全；**将来切集群前必须一并处理** |
| **6** | **`application/backend-gd/` 是同一批代码的副本目录** | 🟡 | 不参与发版，但留着不改以后会再咬人 |
| **7** | **交付方确认交付流程** | 🔴 | 「先编 platform 再 `mvn install`」吗？若是 ⇒ 必须先完成树 A 与基线的**整体**对齐；在此之前**禁止 install 树 A 的 platform**、**禁止把区间切到 `[3.0.0,4.0.0)`**（见 D9） |
| **8** | **`sac`/`cmt`/`hds` 的建表脚本找第三方要** | 🔴 | 本项目**只读**，不建表。`sac` 在 MySQL 布局下的源大概率是平台的 `SystemTable.sql`（**但那个文件在安装包里是孤儿 —— 没有任何脚本执行它**）；`cmt`/`hds` **在安装包里完全没有** |
| **9** | **⚙️-C / ⚙️-D 开工前必查** | ⚙️ | Nacos readiness 是不是 200（不是就重启）；token 是不是还有效（不是就重铸） |

> 🚫 **明确不做**：**在 napstar2.0 里建 `sac`/`cmt`/`hds` 的表** ——
> 那是第三方系统的表，本项目只有读权限。

---

## 十、给下一轮的一句提醒

> **「跑判据」不等于「判据还是那个判据」，也不等于「判据这次真的跑到了」。**
>
> 本轮有两条都属于后者：
> ① `test-hd-cluster-merge-wiring.sh` 在集群没跑时**退出码 0 但 `PASS=0`**；
> ② base 矩阵的 C 段在集群停了之后**整段 SKIP**（这也是本轮想要的，但它是「跳过」不是「通过」）。
>
> ⇒ **每条判据都要回答两个问题：这次它**执行**了吗？它**执行了**的话读的是**哪个**状态？**

---

*本轮全部数字来自 2026-11-03 的实测（`hd-cluster-verify.sh` L1–L6、`hd-cluster-app-test.sh`、
`hd-monitor-runtime-verify.sh`、base 矩阵 `verify.sh`、三个脚本自测），逐条与上一轮基线对照。*

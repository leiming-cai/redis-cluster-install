# 会话存档（2026-11-03）：华盾 napstar2.0 —— 树名更正 + 给 `monitor` 的集群分支补运行时覆盖

> **这份文件是给「下一个会话」看的。**
> 打开它 == 拿到本会话的**全部产出**：环境体检、**一个横跨全部文档的树名错误**、
> D10 的重新定性、`monitor` 的运行时覆盖、回归中查出的 3 个判据缺陷、2 个新环境缺口。
>
> - 上一份存档：`docs/superpowers/sessions/2026-11-02-hd-redis-cluster-fix.md`（§九 / §十 是本会话的前半段）
> - **本会话的树图**：`docs/superpowers/sessions/2026-11-03-tree-map.md`（**先看这个**，它是理解其它文档的钥匙）
> - 本轮计划：`docs/superpowers/plans/2026-11-03-hd-monitor-runtime-coverage.md`
> - 本轮设计：`docs/superpowers/specs/2026-11-03-hd-monitor-runtime-coverage-design.md`
> - 缺陷清单：`docker/hd-napstar/DEFECTS.md`（新增 **D11** + **⚙️-C** + **⚙️-D**）

---

## 一、一句话现状

**上一轮说「`monitor` 的 6 处集群分支已修」，但那 6 处**一次都没在集群模式下真正执行过** ——
验收只有静态证据（jar 里 `isCluster` 的 class 数 0 → 4），而「日志里没有 UOE」是**假绿**：
模型元数据表是空的，`matchOType` 先抛异常，**根本走不到那行 Redis 调用**。

本轮灌了 **27 行最小模型元数据**（数据源 = 应用自己的 Nacos `kafkabus.yaml`），
让 6 处里的 **1 处**（`SVGCacheServiceImpl` 的写路径）真正跑起来，
并用**正向判据**证明「集群分支与单机分支行为等价」：
**单机与集群模式下 `real_graph:realscope` 各 12 个 field，field 名逐个相等。**

**顺带查清了两个横跨全部文档的错误：**
① `D:\javawork\1.2\cpscloud1.0\code` 一直被叫作「门户树」，**它其实是基线**；
真正的门户树（集控-IV区门户）**此前从未被检查过**。
② `sac`/`cmt`/`hds` 是**第三方系统的表，本项目只有读权限** ⇒ D10 不是「本项目要补 DDL」。

**回归中又查出 3 个判据本身的缺陷**（都修掉了）——
它们上一轮之所以绿，只是因为**应用什么都没写**。

---

## 二、开工前的环境体检

> 这一步是必要的：上一轮的数字是「上一轮跑出来的」，不是「现在还是不是真的」。

| 判据 | 本轮实测 | 上一轮基线 | 一致 |
|---|---|---|---|
| 集群层测试 | `PASS=34 FAIL=0 SKIP=1` | 同 | ✅ |
| 底层集群验证 | `PASS=39 FAIL=0` | 同 | ✅ |
| base 回归矩阵 | `PASS=47 FAIL=0 SKIP=4` | 同 | ✅ |
| `test-hd-cluster-summary.sh` | `PASS=19 FAIL=0` | 同 | ✅ |
| `test-hd-cluster-merge-wiring.sh` | `PASS=8 FAIL=0` | 同 | ✅（**这次集群在跑**，测到了「合并」那一步） |
| `test-hd-portal-baseline.sh` | `PASS=40 FAIL=0` | 同 | ✅ |

其它实测结论：
- **⚙️-A（Kafka broker 起不来）未复发**：`/brokers/ids` = `[755, 756]`，两个 broker 都活着。
- **⚙️-B（token 过期）未复发**：`exp=1793681279`，`now=1793605295` → 剩余 75984 秒。
- **归档 patch 仍可用**：`git apply --check -p1` rc=0；apply 后 **12/12 与树 A 现文件 SHA256 全等**。
- **mvnRepo 零改动**：两个仓库（`%USERPROFILE%\.m2\repository` 与 `D:\java\apache-maven\mvnRepo`）
  12:00 之后被修改的文件数 **均为 0**。
- **门户未受影响**：新快照 vs 上一轮快照 **只差 uptime 一行**。

---

## 三、🔴 树名更正（横跨全部文档）

用户给出三棵树的权威对照后发现：

| 角色 | 路径 | 自有版本 | `platform.version` |
|---|---|---|---|
| **基线** | `D:\javawork\1.2\cpscloud1.0\code` | `1.0.14` | `[1.0.0,2.0.0)` |
| **门户**（集控-IV区门户） | `D:\work\info\web\extendsystem\集控-IV区门户\code` | `2.0.2` | `2.0.0`（**定点**） |
| **华盾**（napstar2.0 交付树） | `D:\work\info\web\extendsystem\华盾-napstar2.0\code` | `3.0.0` | `[1.0.0,2.0.0)` |

> **文档里叫「门户树 / portal/SVN 树」的那棵树（`cpscloud1.0`）其实是「基线」。**
> 真正的门户树**此前从未被检查过**。

**逐字节证据**：

| 证据 | 结果 |
|---|---|
| 旧 `model-controller-3.0.0.jar`（`c41735d8…`，D8 的元凶） | md5 **完全等于基线树**的 `platform/backend/modelserver/controller/target/model-controller-1.0.14.jar` |
| 那份 jar 内嵌的 `application.yml`（`541faf69…`） | md5 **完全等于基线树**同名文件 |
| `oms:` 块「生效 + 集群占位符」的树 | **只有基线**（门户树和华盾树的 `oms:` 都是**注释着**） |
| ⇒ **D8 的成因归属** | 从「门户树」更正为「**基线树**」（结论不变，归属变了） |

**门户树（第一次纳入对照）的实测能力**：

| 项 | 值 |
|---|---|
| 集群标记 | `isCluster` / `RedisClusterHelper` / `RedisClusterHashPipeline` / `writeWithRetry` **全 0** |
| `realserver/common/oms` 模块 | **没有**（`rtdata-module` 也没有） |
| 版本控制 | `application\.git` + 3 个 worktree（**三棵树里唯一有版本控制的**） |
| 独有模块 | `platform/backend/portal`、`processsinfomodel`、`application/backend/{3dmanager,smartoptsys}` |
| ⚠️ 附带发现 | 门户的 `3dmanager` flyway 迁移是 **MySQL 方言**（`AUTO_INCREMENT`×4 / `COMMENT`×44 / `ON UPDATE CURRENT_TIMESTAMP`×2），而门户库 `cpspg` 是 **PostgreSQL** ⇒ **门户线自己的迁移跑不起来**（与华盾无关的独立问题） |

**⇒ D9（版本区间挑版本）的机制对门户线不成立** —— 门户用定点 `2.0.0`，不挑版本。

完整对照见 `docs/superpowers/sessions/2026-11-03-tree-map.md`。

---

## 四、🟡 D10 重新定性：`sac`/`cmt`/`hds` 是**第三方只读表**

> 用户 2026-11-03 明确：`cmt`、`sac`、`hds` 是**第三方系统表**，该项目**有读取权限**。

**只读是实测确认的**（mapper XML 口径，华盾交付树）：

| schema | select | insert | update | delete |
|---|---|---|---|---|
| `sac` | 32 | **0** | **0** | **0** |
| `cmt` | 12 | **0** | **0** | **0** |
| `hds` | 1160 | **0** | **0** | **0** |
| **`info`（本项目自有）** | 0 | **4** | 0 | 0 |

（基线树同形；Java 代码里对这三个 schema 也**零** DDL/DML。）

**活库权限模型印证**：`sac`/`cmt`/`hds` 各自 **owner 是自己**，跨 schema **只授 USAGE**
⇒ **表级 SELECT 由建表的第三方单独授予**。

⇒ **原表述「三个 schema 缺 DDL → 要把 `SystemTable.sql` 转 PG → 补建表」方向错了**：
那些表**不由本项目建**。**真正的阻塞是「本环境没有第三方数据」**。
⇒ D10 从 🔴 降为 🟡：**不是代码缺陷，是环境/依赖缺口**。

---

## 五、`monitor` 的运行时覆盖（本轮的正事）

### 5.1 6 处按「可达性」分三档

| 档 | 位置 | 到达它需要什么 | 本轮 |
|---|---|---|---|
| **A** | `SVGCacheServiceImpl:85` | `matchOType(oname)` 成功 —— `oname` 就在 **Nacos 的 `kafkabus.yaml`** 里 | ✅ **做了** |
| B | `RTListener:142` | 一条 Kafka `COMMITDATAINCRE` 消息 | ⏸ 未做 |
| C/D/E/F | `CalculateService`×2、`SVGParseService`×2 | **SVG 文件**（容器里一个 `*-ScheFile.svg` 都没有）或 websocket 订阅 | ⏸ 未做 |

### 5.2 种子数据不用编 —— 照抄应用自己的配置

Nacos 的 `kafkabus.yaml`（`NAPSTARWEB_GROUP`，HTTP 200）就是应用声明的清单：

```yaml
- oname: MVPoint    aname: Value,Quality
- oname: DPSPoint   aname: State,Unacknowledged
- oname: Machine    aname: CPUStatus,MemStatus,CPUSystemEx,DiskSystem,DiskCPS,MemSystemEx,SyncStatus,SyncPhase
```

⇒ **3 个 objecttype + 12 个 attribute + 12 条关联 = 27 行**，
`source_code='HDTEST'`，编号用 **900001+** 显眼段（`obj_type` 会进 Redis field 名，不能撞业务编号）。
**属性名必须逐字相同** —— `loadRTConfigKafka()` 是拿 `aname` 跟 `oa.getAttrName()` 做 `equals` 比的。

### 5.3 判据必须是**正向**的，且**单机 + 集群都跑**

「日志里没有 UOE」正是上一轮的假绿。改成：
- **单机**跑一遍 → `real_graph:realscope` 应有 **12 个 field**
- **集群**跑一遍 → 应有**同样的 12 个 field**，field 名**逐个相等**
- ⇒ 这是排除「其实走的是单机分支」的唯一办法
- **写前先 `DEL` 那个 hash** ⇒ 找到 12 个 field 就一定是**本次写的**，不是上次的残留

### 5.4 新增的文件

| 文件 | 作用 |
|---|---|
| `scripts/seed-hd-model-metadata.sh` | 灌 / 清 27 行夹具；幂等；退出码 0/1/2 分别是「成功」「行数不对」「库不可达」 |
| `scripts/hd-monitor-runtime-verify.sh` | 单机 + 集群两遍跑，**10 条判据** |
| `scripts/hd-monitor-runtime-lib.sh` | 判据的**纯逻辑**（可 source，不碰网络/库） |
| `scripts/test-hd-monitor-runtime-verify.sh` | 判据的**边界自测（16 条）**，含「必须 FAIL」的反例 |

---

## 六、🔴 回归中查出并修掉的 3 个判据缺陷

> **三个都是「判据本身过时」** —— 上一轮它们是绿的，只因为**应用什么都没写**。

### 缺陷 1：种子脚本的清缓存是**空操作**

真实缓存 key 带 `model:` 前缀：

```
model:objecttypes:names:MVPoint     model:objecttypes:types:900001
model:attributetypes:names:Value    model:attributetypes:atypes:900101
```

而脚本清的是 `objecttypes*` ⇒ **匹配 0 个**（实测有 **8** 个）⇒ `--clean` 之后缓存还在，
指向已删的行 ⇒ 「夹具已清」是假象。
**修法**：模式改成 `model:*`；函数改名 `clear_model_cache`；注释记下实测到的 key 名。

### 缺陷 2：base 矩阵的 B2 **按报错文案**判 ⇒ 灌了元数据后变 FAIL

B2 原来只认 `属性名称非法或不存在` ⇒ SKIP。灌了元数据后 `matchAType("Value")` 成功，
请求走得更远，报错变成 `Map.get 返回 null` ⇒ 不匹配 ⇒ 落到 `"code":500` ⇒ **FAIL**。

而**真正**的原因是：曲线接口要先读**第三方实例数据**
（`getHisMVPoint` → `modelEntityDataService.read` → 查 `sac`/`hds`），
这两个 schema **一张表都没有** ⇒ 接口级判据**本来就不可能执行**。
（顺带查明：测试自己的 objectid `999999` **结构性**不可用 ——
`extractOType(entityId) = (entityId >>> 32) & 0xFFFFFFFF` ⇒ 它的 otype 是 **0**。）

**修法**：改成**判前置条件**（第三方 schema 有没有表），没有就 SKIP 并说清原因；
**SQL 层那条真判据照跑**。

### 缺陷 3：集群测试的 E 判据没算应用自己写的 key

E 段要求「key 数回到基线」，但灌了元数据后应用**真的会**写自己的 key：
6 个 `model:*` 缓存 + 1 个 `real_graph:realscope`（**正是 A2 判据要求它存在的**）
⇒ `FAIL E 清理后 key 数跟基线不符（增量 7）`。

而 E 段**自相矛盾**：前一条判据说「`model:*` 还在是对的」，后一条说「总数必须回基线」。

⇒ **这条判据在任何有模型元数据的环境里都必然失败**（真实部署也有元数据）
⇒ 它上一轮之所以绿，只是因为**应用什么都没写**。

**修法**：增量统计**扣除应用自己的 `model:*` / `real_graph:*` 命名空间**
（基线与终值用同一口径）；本脚本自己的 key 全在 `hd:test:apptest:*` 下，由前一条判据单独查。

---

## 七、⚙️-C / ⚙️-D（两个新的环境缺口）

### ⚙️-C：hd-node1 的 **Nacos 会在长时间运行后退出**

**现象**：**10:47:19 优雅退出**（JVM 的 shutdown 钩子跑了：
`WatchFileCenter shutdown` + `ThreadPoolManager Destruction of the end`）。
它从容器启动（11-02 01:37Z）活到那一刻，**约 33 小时**。

**影响**：Nacos 不在 ⇒ 所有应用起不来
（`NacosException: Client not connected, current status:STARTING`）
⇒ **所有判据都不可执行**（不是 FAIL，是「没法测」）。

**已排除的原因**（都实测过）：

| 假设 | 结论 |
|---|---|
| `stop_apps()` 的 pkill 误杀 | ❌ **排除** —— 用 Nacos 真实 cmdline 测模式不匹配；**实弹跑那条 pkill，Nacos 存活**（pid 前后不变） |
| 容器被重启 | ❌ `RestartCount=0`，`StartedAt` 没变 |
| 容器 OOM | ❌ `OOMKilled=false` |
| GC 抖动 | ❌ GC 日志无死前记录 |
| Redis 集群脚本 | ❌ 它的 pkill 只匹配 `redis-server \*:port` |

⇒ **死因未查明**（Nacos 的 `start.out` 被重启覆盖了，关键证据没了）。

**恢复办法**（实测 26 秒就绪）：

```bash
docker exec hd-node1 bash -c "cd /opt/software/nacos/bin && nohup sh startup.sh -m standalone >/tmp/nacos-restart.log 2>&1 &"
# 等 readiness 200
```

**下一轮开工前必查**：

```bash
curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18848/nacos/v1/console/health/readiness
```

> 📌 **顺带证明了 S0 判据有用**：Nacos 挂掉时，S0 报的是
> **FAIL（应用启动失败）**，而不是让脚本带着「0 个异常」继续跑出一个假绿。

### ⚙️-D：**base 矩阵读缓存里的 JWT，从不刷新**

本轮第一次跑 base 矩阵时，`/tmp/hd-token.txt` 的 JWT **在开跑前 4 秒刚好过期**
（铸于 11-02 12:48，24 小时 TTL）⇒ **2 条假 FAIL**（两端点都 500，消息是 `TokenExpiredException`）。

**矩阵自己不会重铸 token** ⇒ 每轮跑矩阵之前都得**手动**：

```bash
bash /opt/hd/mint-hd-token.sh
```

（= §七 #5 已记的 ⚙️-B，但**矩阵本身不带**这个动作 ⇒ 容易忘。）

---

## 八、执行顺序（三条，踩过）

| # | 顺序 | 为什么 |
|---|---|---|
| 1 | **跑 base 矩阵前必须恢复单机态**（集群停 + 应用按 standalone 起 + `model-controller` 单独起） | 集群在跑时 base 矩阵会把集群的计数并进来（C 段）⇒ SUMMARY **不可比**；而且集群测试会用 `HD_REDIS_CLUSTER=1` 重启应用并**截断日志** ⇒ base 矩阵的 A2/A2b（找 `Using Redis Standalone at` 那行）会 **FAIL**。实测：顺序错了会得到 `PASS=78 FAIL=8` |
| 2 | `test-hd-cluster-merge-wiring.sh` **要在集群在跑时**跑 | 集群没跑时它**静默跳过**（退出码 0 但 `PASS=0`）—— 「退出码 0」**不等于**「测到了」 |
| 3 | `test-hd-portal-baseline.sh` **要在 `rc-e2e-runner` 里**跑 | 它要读 `/out/portal-snapshot-cluster.txt`（`/out` 是宿主 `.hd-work` 的挂载点，`hd-node1` 里**没有**）⇒ 在 `hd-node1` 里跑会退出码 2 |

---

## 九、收尾状态

| 判据 | 结果 |
|---|---|
| 集群层测试 `hd-cluster-app-test.sh` | **`PASS=36 FAIL=0 SKIP=0`**（上一轮 `34/0/1`） |
| ↳ **A2 从 SKIP 变成真 PASS** | `PASS A2 应用写的 real_graph:realscope 在集群里` |
| 底层集群验证 `hd-cluster-verify.sh` | `PASS=39 FAIL=0` |
| base 回归矩阵 `verify.sh` | **`PASS=47 FAIL=0 SKIP=4`**（与基线同数） |
| `test-hd-cluster-summary.sh` | `PASS=19 FAIL=0` |
| `test-hd-cluster-merge-wiring.sh` | `PASS=8 FAIL=0` |
| `test-hd-portal-baseline.sh` | `PASS=40 FAIL=0` |
| `test-hd-monitor-runtime-verify.sh` | `PASS=16 FAIL=0` |

**单机与集群的 `real_graph:realscope` 各 12 个 field，field 名逐个相等。**
`kafkabus` 那 3 个类型的 `OTypeException` → **0**（总数仍 23，来自 SVG 解析路径的其它类型）。

**base 矩阵与 11-02 基线的唯一差异**（不是退化）：
- `A3 应用有 PG 连接（4 条）` → `（5 条）`
- `B1 PG 收到了应用的 SQL（1 条 execute）` → `（7 条 execute）`
  （这两条是 jar 重建带来的，在更新的 `/tmp/v4.txt` 基线里就是新值）
- B2 两条 SKIP 的**文案**变了（现在说清是「第三方 schema 无表」，而不是「模型表是空的」）

**环境交接状态**：集群**已停**（只剩 6379/6389）· 夹具**已灌**（3/12/12）·
4 个 app 跑在 **Standalone** · Nacos 200 · 仓库 12 个脚本的 md5 与容器**逐个一致**。

---

## 十、提交列表（本轮）

```
734b1b1 docs(hd): record the runtime coverage result, the three verdict defects and the token gap
891ea2a fix(hd): exclude the application's own key namespaces from the cluster cleanup verdict
8b3993a fix(hd): clear the real model cache keys and judge B2 by its precondition
824b3e3 docs(hd): correct the cross-reference in the new session section
ef237ac docs(hd): record the runtime coverage result and the remaining gap
ef225cf test(hd): close false-green hazards in monitor runtime lib
eae8832 test(hd): guard the monitor runtime verdict against false green
6cd8d24 fix(hd): make the monitor runtime mode assertions bidirectional
8706011 docs(hd): update the monitor runtime plan for the four added judgements
81ed8da fix(hd): guard the monitor runtime verdict against false-green PASSes
8903e00 docs(hd): correct the expected verdict count in the monitor runtime plan
53e45ca feat(hd): verify the monitor cluster branch by comparing standalone and cluster output
015a46a docs(hd): widen the seed script's exit code note
0c34147 fix(hd): surface seed failures via exit status and reuse psql via function
3b10c24 feat(hd): add the minimal model metadata seed for the monitor cluster branches
```

（`3b10c24` 之后的 13 个是本轮；`3b10c24` 是 Task 1 的首个提交。）

---

## 十一、下一轮照做

> **「跑判据」不等于「判据还是那个判据」。**
> 本轮 3 个缺陷里有 2 个是**判据本身过时**（按文案判、按总数判）——
> 它们在旧环境下是绿的，只是因为**应用什么都没跑**。
> ⇒ 每次加夹具 / 灌数据后，都要重新问一遍：
> **每条判据在「应用真的会干活」的世界里还成立吗？**

剩下的活：

| # | 事 | 严重度 | 说明 |
|---|---|---|---|
| **1** | **`monitor` 的另外 5 处**补运行时覆盖 | 🟡 | C/D/E/F 四处需要 **SVG 文件**（容器里一个都没有）或 **websocket 订阅**才能到达；`RTListener` 那处缺一条 Kafka `COMMITDATAINCRE` 消息。已记进 DEFECTS 的 **D11**，**不假装覆盖了** |
| **2** | **`transformNapstarModel` 要真跑起来** | 🟡 | 它是**读** sac/cmt、**写** info 的转换作业 ⇒ 要第三方实例/历史数据（`sac`/`hds` 的表）才有意义。⇒ 属于 §八 #10 那个「第三方数据接进来」的问题，**与本项目无关** |
| **3** | **门户线自己的 `3dmanager` 迁移跑不通** | 🟡 | 迁移脚本是 **MySQL 方言**，门户库 `cpspg` 是 **PostgreSQL** ⇒ 门户线的独立问题（与华盾无关），**本轮未碰** |
| **4** | **门户线要切集群** | 🟡 | 门户树**一个集群标记都没有** ⇒ 得从基线把整套补丁搬过去（跟华盾当时一样） |
| **5** | **`sche-viewer-server` 的 15 处裸 `executePipelined`** | 🟡 | 当前 standalone、不参与构建 ⇒ 暂时安全；**将来切集群前必须一并处理** |
| **6** | **`application/backend-gd/` 是同一批代码的副本目录** | 🟡 | 不参与发版，但留着不改以后会再咬人 |
| **7** | **基线的几个次要设计问题** | 🟢 | `FailSetCounter` 只写不读 · `add(data.size())` 的单位在集群/单机两条路上不一致 · `wirteOmsPip` 去 `@Async` 后写操作占用 `consumerRunExecutor` · `processItem` 异常时 `return 0` 会丢掉该 item 已累计的 fieldCount · `CacheServiceImpl` 单机分支的 try/catch 粒度比集群分支粗。**都是基线设计**，本轮「与基线对齐」时没改 |
| **8** | **交付方确认交付流程** | 🔴 | 「先编 platform 再 `mvn install`」吗？若是 ⇒ 必须先完成树 A 与基线的**整体**对齐；在此之前**禁止 install 树 A 的 platform**、**禁止把区间切到 `[3.0.0,4.0.0)`**（见 D9） |
| **9** | **`sac`/`cmt`/`hds` 的建表脚本找第三方要** | 🔴 | 本项目**只读**，不建表。`sac` 在 MySQL 布局下的源大概率是平台的 `SystemTable.sql`（**但那个文件在安装包里是孤儿 —— 没有任何脚本执行它**）；`cmt`/`hds` **在安装包里完全没有** ⇒ 得找第三方要 |
| **10** | **⚙️-C / ⚙️-D 开工前必查** | ⚙️ | Nacos readiness 是不是 200（不是就重启）；token 是不是还有效（不是就重铸） |

> 🚫 **明确不做**：**在 napstar2.0 里建 `sac`/`cmt`/`hds` 的表** ——
> 那是第三方系统的表，本项目只有读权限。

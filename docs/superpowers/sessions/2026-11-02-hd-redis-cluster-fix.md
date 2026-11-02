# 会话存档（2026-11-02）：华盾 napstar2.0 —— 交付树集群修复

> **这份文件是给「下一个会话」看的。**
> 打开它 == 拿到本会话的**全部产出**：环境、结论、实测证据、留痕、以及**上一轮存档被推翻的 7 处结论**
> （下表是影响面最大的 5 处，**完整清单见上一轮存档 §十**）。
>
> - 上一份存档：`docs/superpowers/sessions/2026-11-02-hd-redis-cluster-test.md`（**它的第十节是本轮的复核更正**）
> - 本轮设计：`docs/superpowers/specs/2026-11-02-hd-redis-cluster-fix-design.md`
> - 本轮计划：`docs/superpowers/plans/2026-11-02-hd-redis-cluster-fix.md`
> - 缺陷清单：`docker/hd-napstar/DEFECTS.md`（D6 / D7-a / D7-b / D8 已修；新增 **D9** + **⚙️-A / ⚙️-B**）

> ⚠️ **2026-11-02 树名更正（后补）**：本文里的「**门户树**」/「**portal/SVN 树**」
> 指的是 `D:\javawork\1.2\cpscloud1.0\code` —— **那是「基线」，不是门户**。
> 真正的门户树是 `D:\work\info\web\extendsystem\集控-IV区门户\code`，
> **此前从未被检查过**。树图见 `docs/superpowers/sessions/2026-11-02-tree-map.md`。
> **本文的结论本身不受影响** —— 改的只是那棵树的**名字**。
---

## 一、一句话现状

**上一轮实测出的两个真缺陷（D7-a / D7-b）和一个交付包事故（D8）本轮全部修掉了**，
实测数字：**集群层 `PASS=34 FAIL=0`**（上一轮 2 FAIL）、**回归矩阵 `PASS=47 FAIL=0 SKIP=4`**（与基线逐条一致）。

**但开工前重新核对依赖解析时，推翻了上一轮存档里的 7 处结论**
（下表是影响面最大的 5 处，**完整清单见上一轮存档 §十**）——
其中 3 处直接改变了工作范围，
1 处推翻了一个「结论对、推理错」的机制说明。

> 📌 **本轮结束时的独立复核**：一个 reviewer 重新核了**全部实测数字**
> （patch 12/12 字节还原、三个 jar 的 md5、依赖解析、`oms:` 注释状态、单测 5+7 条、
> `mvnRepo` 零改动、门户快照差异归因）—— **全部对得上**。
> 它查出的 6 条重要问题**全在文档层**（代码没问题），已全部抹平 → 见 §6.1·一。

| # | 上一轮的说法 | 本轮的实测 |
|---|---|---|
| 1 | 「jar 赢过 Nacos → `OPERATIONS.md` §4.5 不生效」 | **只对门户树编的 jar 成立**。交付树三个 app 的 `oms:` 是**注释着的** → **Nacos 赢** → §4.5 生效 |
| 2 | 「补丁只落在 platform 侧，application 侧没跟上」 | 根因是**版本区间**：`platform.version=[1.0.0,2.0.0)` 不含 3.0.0 → 交付物里的 platform **全部**是基线 `1.0.14`，而**基线才是打过补丁的** |
| 3 | 「5 个调用点」 | **4 个文件 6 处**（且平台侧那处由基线解决） |
| 4 | 「D7-b 要移植 `.join()`」 | **二进制已由 `rtdata-module-1.0.14` 解决**（`javap` 实测有 `writeWithRetry` + `join()`） |
| 5 | 「`mvn install` 会覆盖基线」 | **错的** —— 3.0.0 与 1.0.14 存在不同目录，各存各的。真正的机制是**区间挑版本** |

---

## 二、本轮改了什么

### 2.1 树 A（交付树）—— 12 个文件

> ⚠️ **树 A 没有任何版本控制**（无 `.git`、无 `.svn`）→ 改前先快照到
> `.hd-work/treeA-baseline/`，改后把**完整 diff** 归档进本仓库
> `docker/hd-napstar/patches/2026-11-02-treeA-cluster-fix.patch`（95847 字节 / 12 文件）。

| # | 文件 | 改了什么 |
|---|---|---|
| 1 | `napstarweb/monitor/.../services/SVGParseService.java` | **2 处**集群分支（多 key 写 → `execute(cb)`；多 key string 读 → `getAllValues`）+ 2 字段 + 2 import |
| 2 | `napstarweb/monitor/.../services/CalculateService.java` | **2 处**（多 key hash 读 → `getAllHashes`）×2 + 2 字段 + 2 import |
| 3 | `napstarweb/monitor/.../services/impl/SVGCacheServiceImpl.java` | **1 处**（单 key 写 → `execute(cb)`）+ 1 字段 + 1 import |
| 4 | `napstarweb/monitor/.../kafka/RTListener.java` | **1 处**（单 key 写 → `execute(cb)`）+ 1 字段 + 1 import |
| 5 | `realserver/plugins/rtdata-module/.../service/RedisRealDataService.java` | 整文件替换（接口 1 → 3 个方法） |
| 6 | `realserver/plugins/rtdata-module/.../service/impl/RedisRealDataServiceImpl.java` | 整文件替换（`isCluster` 分支 + `groupByKey` + `putAllHashes`，去 `@Async`） |
| 7 | `realserver/plugins/rtdata-module/.../service/impl/OmsWriteByKafkaServiceImpl.java` | 整文件替换（`writeWithRetry` + `.join()`） |
| 8 | `realserver/plugins/rtdata-module/.../config/FailSetCounter.java` | **新增**（30 行 `LongAdder`） |
| 9 | `modelserver/services/.../service/impl/CacheServiceImpl.java` | 整文件替换（5 个集群分支：写逐 key `set`、删用 `RedisScanUtils.forEachKey`） |
| 10 | `modelserver/controller/src/main/resources/bootstrap.yml` | D2 (a)：`shared-configs: []` + 只留 `napstarmappingconfig.yaml` |
| 11 | `realserver/plugins/rtdata-module/src/test/.../RedisRealDataServiceImplTest.java` | **新增**（5 条 Mockito 单测） |
| 12 | `realserver/plugins/rtdata-module/src/test/.../OmsWriteByKafkaServiceImplTest.java` | **新增**（7 条 Mockito 单测） |

**#5–#9 五个文件与基线树逐字节相同**（SHA256 核对）——
只有**两个测试文件**故意不同（见 §二·3）。

### 2.2 本仓库 —— 4 个文件 + 1 个 patch

| 文件 | 改了什么 |
|---|---|
| `scripts/start-hd-apps.sh` | ① 启动前打印 jar 的 **路径 + md5 + mtime**；② 更正 Redis 模式提示（交付树 jar 的 `oms:` 是注释的 → Nacos 赢） |
| `scripts/verify-hd-napstar.sh` | A 段加 **A0「启动来源（必答项）」**：三个 app 的 jar md5+mtime + 各日志里生效的 Redis 模式行 |
| `scripts/hd-cluster-app-test.sh` | C2 的 FAIL 文案已过期（「部署的 jar 里这条写路径没有集群分支」**现在不成立**）→ 改掉 |
| `docs/OPERATIONS.md` | §4.5 **回改**（上一轮把它改成了「不生效」，方向错了）；表格第 1 行与 Kafka 表第 11 行改指向 `icms-controller.yaml`（D2 (a) 删了 `share_base.yaml`/`ext_base.yaml`）；加「切集群前必读」的状态更新 |
| `docker/hd-napstar/DEFECTS.md` | D6 适用条件澄清；D7-a / D7-b / D8 标为已修；D2 标为已在交付树实施 + **同类缺口 `kafkabus.yaml`**；**新增 D9**；新增 `⚙️-A` / `⚙️-B` 环境缺口 |

### 2.3 移植过来的测试**不是**照抄 —— 补掉了基线的两处真实缺口

树 B 的 `rtdata-module` 测试有一处是**空测试**（变异测试证明：
把 `wirteOmsPipStandalone` 的**整个 hMSet 写入体**删掉，4 条用例**依然全绿**），
而且 `processItem`（树 A 原有行为的替代品）**零覆盖**。

⇒ 补了 3 类用例，并用**变异测试**逐条证明它们真的锁得住：

| 变异 | 结果 |
|---|---|
| 删掉 `wirteOmsPipStandalone` 的 hMSet 写入体 | `Tests run: 12, Failures: 1` ✅ |
| 删掉 `processItem` 的 `redisConnection.hSet(...)` | `Tests run: 12, Failures: 1` ✅ |
| 禁用 `processItem` 的 `&` 拆分（`split("&")` → `new String[]{item}`） | `Tests run: 12, Failures: 1` ✅（失败信息直接显示「第二个点的 obid 被粘进第一个点的 value 里」） |
| 禁用 `parseToPointList` 的 `&` 拆分 | `Tests run: 12, Failures: 1` ✅ |

**测试总数 12 条**（`RedisRealDataServiceImplTest` 5 + `OmsWriteByKafkaServiceImplTest` 7），全绿。

> 📌 顺带纠正一条历史认知：上一轮的 `PASS=32 FAIL=2` 里，那 2 条 FAIL 是 **C2 + C3**，
> **B2 当时是 PASS**（token 那时还没过期）。⇒ 上一轮的 **C3 FAIL 是真的**（UOE 确实抛过）。

---

## 三、实测数字

### 3.1 应用层集群测试

```
SUMMARY: PASS=34 FAIL=0 SKIP=1        （上一轮：PASS=32 FAIL=2 SKIP=1）
```

| 判据 | 上一轮 | 本轮 |
|---|---|---|
| **C2**（发一条 INCDATA Kafka 消息 ⇒ 应用自己写的 `real_data:31249:134213433032705` 进集群 + 读回载荷） | ❌ FAIL | ✅ **PASS** |
| **C3**（rtdata-consumer 无 UOE） | ❌ FAIL | ✅ **PASS**（这次算数 —— C2 证明写路径**真的跑过**） |
| **B2**（`@Cacheable` 写 `model:enumdicts:folder:user_sex` + 读回载荷） | ✅ PASS | ✅ **PASS**（本轮第一次跑时 FAIL，是 token 过期） |
| **A2** | ⏭️ SKIP | ⏭️ **SKIP**（模型元数据表空 → 数据缺口，非缺陷） |

### 3.2 base 回归矩阵

```
SUMMARY: PASS=47 FAIL=0 SKIP=4        （与上一轮基线逐条一致）
```

**与上一轮基线的唯一差异**是一个**诊断计数**（不是判据）：
`B1 PG 收到了应用的 SQL（2 条 execute）` → `（12 条 execute）`
—— 本轮 Kafka 是通的，应用真的在消费消息写库 ⇒ PG 日志更多。

**A0 段（必答项）实测**：

```
############ A0 — 启动来源（必答项）############
  web-controller  md5=22019472fec4c07c143ef6d9d1ae7685  mtime=2026-11-02 12:12:13 +0800
  rtdata-consumer  md5=c28d1adfcae93a42c87321724c693e14  mtime=2026-11-02 12:15:07 +0800
  model-controller  md5=0ce5a08a344306f22eb8226b10405f6c  mtime=2026-11-02 12:14:16 +0800
  Redis 生效模式：
    web-controller     *** Using Redis Standalone at node1:6379 (...)
    rtdata-consumer    *** Using Redis Standalone at node1:6379 (...)
    model-controller   *** Using Redis Standalone at node1:6379 (...)
```

⇒ **`Using Redis Standalone` 而不是 `Using Redis Cluster`** ⇒ **Nacos 赢** ⇒ item 5 的结论实测成立。

### 3.3 部署产物的内容核验

| jar | 旧 md5 | 新 md5 | 换掉后修好的 |
|---|---|---|---|
| `web-controller-3.0.0.jar` | `658af524…` | **`22019472…`** | `monitor-3.0.0.jar` 的 `isCluster` class **0 → 4** |
| `model-controller-3.0.0.jar` | `c41735d8…`（**门户树编的**） | **`0ce5a08a…`** | **D8**（`oms:` 不再是活的集群占位符）+ **D2 (a)**（bootstrap.yml 在交付树里） |
| `rtdata-consumer-3.0.0.jar` | `3174ad84…` | **`c28d1adc…`** | **D7-a 第 5 处 + D7-b**（jar 里装的是基线 `rtdata-module-1.0.14`，带 `writeWithRetry`/`.join()`/`isCluster`） |

**三个 jar 的 `oms:` 块全部是注释着的**（实测三个 jar 的 `application.yml` + `bootstrap.yml`）
⇒ **D8 未复发**。
**`mvnRepo` 全量扫描：2026-11-02 12:00 之后被修改的文件数 = 0** ⇒ 本轮**绝不 install** 守住了。

> 📌 **扫的是哪一个 `mvnRepo`？（下一轮别扫错地方得出假绿）**
>
> 本机有**两个** Maven 仓库，**两个都扫了，结果都是 0 改动**：
>
> | 仓库（绝对路径） | 是什么 | `com\sac\platform` 下的模块数 | 有 `rtdata-module` 吗 |
> |---|---|---|---|
> | `%USERPROFILE%\.m2\repository`<br>（本机：`C:\Users\蔡雷鸣\.m2\repository`） | Maven **默认**的本地仓库 | **6** 个<br>（`actuator` / `menuservice` / `model-service` / `realserver-oms` / `systemconfig-service` / `userservice`） | ❌ **没有** |
> | **`D:\java\apache-maven\mvnRepo`** | `settings.xml` 里配的**真正共享库**（本轮离线编译用的就是它） | **57** 个模块目录（其中 **40** 个带 `1.0.14` 的 jar） | ✅ **有**（`1.0.14` + `3.0.0` 都在） |
>
> ⚠️ **只扫 `%USERPROFILE%\.m2\repository` 会得出假绿** ——
> 那里面**根本没有 `rtdata-module`**，`mvn install` 也不会碰到它。
> **本轮的「0 改动」结论建立在两个仓库都扫过的基础上。**

### 3.4 门户未受影响 —— **6 处差异，全部同源**

⚠️ **本轮开工时 Docker Desktop 被重启过** → 门户容器跟着重启了
（`StartedAt` 从 `2026-10-31T10:49:25Z` 变成 `2026-11-02T00:22:31Z`，`RestartCount=0`）
⇒ 这**不是**本轮改动造成的。

| # | 位置 | 原因 |
|---|---|---|
| 1 | `container status` 的 uptime | 容器重启 → uptime 归零重算 |
| 2 | `1b` 的 `started` / `oom` | 新实例 |
| 3 | `nacos readiness` 从 `000` → `200` | 旧快照时门户的 **Nacos 根本没在跑**（那行 `oom=true` ⇒ 旧实例被 OOM 过）；重启后 entrypoint 把它拉起来了 |
| 4-6 | java 进程数 2→3 / 进程列表 / 监听端口 | 同 #3 的连带（Nacos 进程 + 它的 4 个端口新增） |

**真正说明「本轮没碰门户」的部分全部没变**：
cpspg info 表数 **36** → **36** · redis ping **PONG** → **PONG** ·
portal napstar info 表数 **30** → **30** · image id **同** · databases 列表 **同** · redis dbsize **0** → **0**。

⇒ **门户现在比旧快照更健康**（Nacos 起来了），不是退化。

### 3.5 脚本自测（**回归防线**，本轮改了 `start-hd-apps.sh` / `verify-hd-napstar.sh` → 必须重跑）

| 测试 | 结果 | 测什么 |
|---|---|---|
| `scripts/test-hd-cluster-summary.sh` | **`PASS=19 FAIL=0`** | 计数合并逻辑本身的边界 |
| `scripts/test-hd-cluster-merge-wiring.sh` | **`PASS=8 FAIL=0`** | **防假绿门禁**：helper 缺失/空/语法错/没有那个函数时，矩阵**必须非 0 退出**且**不打印 `FAIL=0` 的 SUMMARY** |
| `scripts/test-hd-portal-baseline.sh` | **`PASS=40 FAIL=0`** | 门户比对脚本的边界（含「噪声里的数不许被当真值」） |
| 树 A `rtdata-module` 单测 | **`Tests run: 12, Failures: 0`** | 见 §2.3 |

⚠️ **`test-hd-cluster-merge-wiring.sh` 第一次跑是 SKIP** —— 集群没在跑 ⇒ C 段整段跳过 ⇒
**测不到「合并」这一步**（退出码 0，但 `PASS=0`）。
⇒ **起集群重跑才是有效的**（`PASS=8`）。**「退出码 0」不等于「测到了」。**

---

## 四、发现的缺陷 / 缺口

### 4.1 🟡 D9（本轮新发现）**版本区间会挑版本** → 切区间就静默降级

树 A 的 `platform/backend` 是 3.0.0，但 `platform.version=[1.0.0,2.0.0)` **不含 3.0.0**
→ Maven **不做 reactor 替换** → 交付物里的 platform **全部**取自 mvnRepo 的基线 `1.0.14`。

**好消息**：基线 1.0.14 **是打过集群补丁的**（`realserver-oms` 14 个 class /
`model-service` 的 `CacheServiceImpl` / `rtdata-module` 的写路径）。

**坏消息**：这套能力**不是树 A 源码提供的**，而树 A 自己的源码是旧的。

| 触发方式 | 需要 `mvn install` 吗 | 后果 |
|---|---|---|
| 把区间切回 `[3.0.0,4.0.0)`（pom 里那几行**被注释掉的** `${napstarserver.version}` 就是这个开关） | **不需要** | 无补丁的树 A 源码进包 → 集群能力**静默消失** |
| 发布 `1.0.15` | 需要 | 区间**自动选中更高的 1.0.15** → 无补丁的树 A platform 顶掉 1.0.14 |

⇒ **本轮已做**：把影响集群能力的 4 个类与基线对齐 + 12 条单测兜底。
⇒ **仍需交付方确认**：交付流程是不是「先编 platform 再 `mvn install`」？
若是 ⇒ 必须先完成树 A 与基线的**整体**对齐 ⇒ **在此之前禁止 install 树 A 的 platform**。

⚠️ 另注：mvnRepo 里的 `1.0.14` 是 **11-01 00:13–00:15 的一次本地 install 快照**，
**不是正式发布产物** ⇒ 「1.0.14 带集群补丁」是**当前恰好成立**，不是**保证**。

### 4.2 ⚙️-A / ⚙️-B（环境缺口，**不是代码缺陷**，但会让判据**不可执行**）

| # | 现象 | 根因 | 恢复 |
|---|---|---|---|
| **A** | Kafka broker 起不来（node1+node2 都中招），`hd-entrypoint` 自己打 `Kafka : DOWN` | 容器被**非正常**停过 → 旧 broker 的 ZK session 没走正常 ephemeral 清理 → ZK 快照里 `/brokers/ids/<id>` 挂着旧 owner → 新 broker 撞车 → **启动即致命退出** | 删掉陈旧的 `/brokers/ids/<id>` 再起 broker |
| **B** | B2 返 HTTP 500，日志 `Shiro ... Authentication failed for token submission` | `/tmp/hd-token.txt` 里的 JWT **过期**（实测 `exp=1793583211`，当时 `now=1793594841`） | `bash /opt/hd/mint-hd-token.sh` 重铸 |

⚠️ **A 会让 C2 静默不可执行**（长得跟 PASS 一模一样 —— 写路径压根没跑，「没有 UOE」是必然不是证明）。
⚠️ **B 会让 B2 必然失败**（长得跟「应用写不进集群」一模一样）。
⇒ **下一轮开工前先确认这两件事。**

### 4.3 🟡 D2 的同类缺口（本轮未处理）

`napstarweb/web-controller` 的 `bootstrap.yml` 引用 **`kafkabus.yaml`**，
而它**也不在安装包导出包里**（导出包 `DEFAULT_GROUP/` 只有
`hisdataproducer-ext.yaml` / `jk.yaml` / `napstarmappingconfig.yaml`）。

**本轮为什么不处理**：① 导出包可能不全，要先确认真实 Nacos 里有没有它；
② 改它会动到 napstarweb 的配置加载链，超出「集群修复」的范围；
③ 实测 `web-controller` **启动正常、致命错误 0** ⇒ 当前不阻断启动。

### 4.4 🟡 `monitor` 的 6 处**运行时未覆盖**（本轮唯一的「不可执行」判据）

模型元数据表（`info.model_objecttype` / `model_attribute` / `model_objectattribute`）全 0 行
⇒ 图形解析路径跑不到 ⇒ `monitor` 的 6 处**在运行时到不了**。

**「启动无 UOE」不能当判据**（假绿）：A3/C3 查的是**应用日志**，
而 `openPipeline()` 的异常只在**代码真的走到那行**时才抛；没走到 ⇒ 日志里当然没有异常。

⇒ 本轮 `monitor` 的验收 = **静态判据**（jar 里 `isCluster` 的 class **0 → 4**）
+ **逐处审阅**（6/6 都在 `if (redisClusterHelper.isCluster())` 的 `else` 分支里）。
⇒ **「运行时未覆盖」已记进 DEFECTS 的 D7-a 节末。**

---

## 五、踩的坑

| # | 坑 | 对策 |
|---|---|---|
| 1 | **本机离线编译必须加 `-llr`** —— 共享 mvnRepo 里 plugin 依赖的 `_remote.repositories` **缺 `aliyun-central` 这个 key**（`settings.xml` 把 `central` 镜像成了 `aliyun-central`）→ 离线模式下被判「不可用」→ `plexus-utils:jar:2.0.4` 等解析失败 | `-llr`（legacy local repository）忽略 `_remote.repositories`；**不改全局配置、不改 pom**。已写进计划的 **C12** |
| 2 | **`git diff --no-index` + `Set-Content -Encoding utf8` 产出的 patch 不能用** —— 绝对路径（含中文八进制转义）+ UTF-8 BOM → `git apply` 拒绝 | 用**临时 git 仓库**（`core.autocrlf=false`）生成相对路径、无 BOM 的 patch；验证 `git apply --check -p1` + apply 后逐文件 SHA256 全等 |
| 3 | **PS 5.1 的 `Get-Content` 在 UTF-8 无 BOM 的中文文件上按 GBK 解码** → 行数少报（实测 206 vs 217）、中文乱码 | 核验行数用 `Select-String` / `git` / 字节流；读中文文件用 `read` 工具或 `-Encoding UTF8` |
| 4 | **用 PS 的 `Get-Content -Raw` + `WriteAllText` 改含中文的文档 → 编码被搞坏**（`华盾`→`鍗庣浘`） | 立刻 `git checkout --` 恢复；改中文文档一律用 `edit` 工具，不走 PowerShell 文本管道 |
| 5 | **`mvn compile` 会假绿** —— `Copy-Item` 保留 mtime → `Nothing to compile - all classes are up to date` | 编译一律带 `clean`（`clean package` / `clean compile` / `clean test`） |
| 6 | **宽松正则 `isCluster` 会多算** —— `RedisClusterHelper` 里含子串 `Red`**`isCluster`**`er` | 数分支调用点必须用精确正则 `redisClusterHelper\.isCluster\(\)`（否则得到 13/12/7/7） |
| 7 | **`hash.get("1".getBytes())` 必然返回 null** —— `byte[]` 无内容 equals | 逐项解码（测试里加了 `decodeHash` 助手） |
| 8 | **`new String(byte[])` 在中文 Windows 上按 GBK 解码** → UTF-8 字节变乱码 → 断言必挂 | 一律 `new String(bytes, StandardCharsets.UTF_8)` |
| 9 | **`stop_apps()` 会杀所有 HD app JVM** ⇒ 「batch 1」和「batch 1b」凑不到一起 | 回归矩阵里用与 `start_one()` 相同的命令行**单独**起 `model-controller` |
| 10 | **跑 base 矩阵前必须先停 Redis 集群** —— 集群在跑时 C 段会把 `hd-cluster-verify.sh` 的计数并进来 → SUMMARY 数字**与基线不可比** | 顺序固定：跑完集群测试 → `hd-redis-cluster.sh stop` → 再跑 base 矩阵 |
| 11 | **`verify.sh` 里的 `BATCH="${1:-1}"` 是死变量**（没人用） | 记进 DEFECTS，本轮不改 |
| 12 | **`read` 工具会重排 markdown 的 `**` 强调标记** —— 原文里跨空行配对的 `**` 被显示成「每行各自配对」→ 照着 `read` 的显示写 `oldString` 会匹配失败 | 改中文 markdown 时，`**` 密集的区域用 **PowerShell + .NET（`ReadAllText`/`WriteAllText` + UTF-8 无 BOM）+ 行锚点**做精确替换，改完用 `.Contains()` 逐条字节级校验 |
| 13 | **`test-hd-cluster-merge-wiring.sh` 集群没跑时会「静默跳过」** —— 退出码 0，但 `PASS=0`（C 段整段 SKIP ⇒ 测不到「合并」这一步） | **「退出码 0」不等于「测到了」** ⇒ 起集群重跑才是有效的（本轮 `PASS=8`） |

---

## 六、留痕

### 6.1 提交列表（本轮）

```
7b9383b docs(hd): record the script self-tests in the session log
0b49f3c docs(hd): mark the superseded precedence claims in the earlier session log
7b47b54 docs(hd): reconcile the defect list and the operations manual with the fix
bc9cc24 docs(hd): record the cluster fix session and correct the precedence conclusion
c544f0b fix(hd): make the jar each app was started from visible
2739e9b fix(hd): drop the two Nacos dataIds that the install package does not ship
6ff7c0c test(hd): cover the ampersand split in the standalone write path
ed7b06f test(hd): give the delivery tree's platform sources real coverage
0af6982 fix(hd): align the delivery tree's platform sources with the baseline
530b606 docs(hd): add -llr to the offline maven commands and fix the branch counter
794d97a fix(hd): add the cluster branch to the delivery tree's monitor call sites
e39e3da fix(hd): add the cluster branch to the delivery tree's monitor call sites
c1626db docs(hd): add the implementation plan for the delivery tree cluster fix
5ef91b5 docs(hd): correct the call site classification in the spec
cd1371a docs(hd): confirm the design and the D2 scope
8bca98e docs(hd): correct the D2 rationale -- version ranges pick, installs do not overwrite
9db2e4a docs(hd): design the delivery-tree cluster fix after re-checking dependency resolution
```

> 📌 **`794d97a` 与 `e39e3da` 的标题逐字相同** —— 这是 `git log` 的原样
> （`794d97a` 是 `e39e3da` 的**后续提交**：只补了三处写路径的注释，
> commit body 里写的是「Comments only, no logic changes」，
> 提交时**沿用了同一个标题**）。
> ⇒ 本列表的标题一律**照抄 `git log`**，不做「按内容改写」。

（本轮起点：`54346d4` docs(hd): correct the D8 timeline and record how the platform jars are resolved）
（本存档自身的提交：`bc9cc24` `7b47b54` `0b49f3c` `7b9383b`）

### 6.1·一 本轮做过的审查（**下一轮别重复**）

每个 Task 都过了「规格符合性 + 代码质量」两道审查，**最后还做了一次整体审查**。
整体审查独立复核了**全部实测数字**（patch 12/12 字节还原、三个 jar 的 md5、
依赖版本、`oms:` 注释状态、单测 5+7 条、`mvnRepo` 零改动、门户快照差异归因）——
**全部对得上**。

它查出的问题**全在文档层**（代码没问题），已全部抹平：

| # | 问题 | 状态 |
|---|---|---|
| I-1 | `OPERATIONS.md` §4.3 仍在写「Nacos 的 `oms:` 一律不生效」，且**把读者导向**已被推翻的结论 | ✅ 加了 banner + 5 处逐个标注 |
| I-2 | DEFECTS.md **D6 正文**与汇总表矛盾（同一份文件两个相反说法） | ✅ 正文按新结论重写 |
| I-3 | DEFECTS.md **D7-b 正文**标题仍写「交付树里依然存在，重新编译也修不掉」 | ✅ 加「改后」列 + 现状说明 |
| I-4 | DEFECTS.md **D8 正文**写「修法本轮不做」「下次重启会又起不来」 | ✅ 改「已实施」+ 标注残留对象已消除 |
| I-5 | DEFECTS.md **D2 正文**的「还没修」结论已过时 | ✅ 改为「已实施」 |
| **I-6** | **上一轮的 🔴「`sac`/`cmt`/`hds` 建表 DDL」在两轮之间静默消失** | ✅ DEFECTS 加 D10 + 存档下一轮入口加第 10 条 |
| M-1~M-8 | 8 条次要（行尾数字、模块数、`§4.3` 的交叉引用…） | ✅ 全修 |
| S-1~S-4 | 4 条建议 | ✅ 全做 |

> 📌 **教训（下一轮照做）**：
> **改了汇总表就要改正文** —— 只改一处会留下「同一份文件两个相反说法」。
> 同样，**上一轮存档正文的旧结论也要标「已作废」**，光在末尾加一节「更正」不够
> （读者可能只引用正文那一句）。

### 6.2 树 A 的完整 diff（归档）

`docker/hd-napstar/patches/2026-11-02-treeA-cluster-fix.patch` —— **95847 字节 / 12 个文件**。
相对路径、无 BOM、`git apply --check -p1` 通过、apply 后 12/12 与树 A 现文件 SHA256 全等。

⚠️ **应用前要设 `core.autocrlf=false`** —— 树 A 的这 **12 个**文件是**混合行尾**
（**7 CRLF + 5 LF**；其中 **9 个**是树 A 原有文件、**3 个**是本轮新增，
逐文件内部一致）。`autocrlf=true` 的环境会把 5 个 LF 文件翻成 CRLF
（内容语义相同，字节不同）。

### 6.3 脚本清单（本轮改动的）

| 东西 | 位置 | 作用 |
|---|---|---|
| 启动器 | `scripts/start-hd-apps.sh` | 加 jar 指纹打印 + 更正 Redis 模式提示 |
| 回归矩阵 | `scripts/verify-hd-napstar.sh` | 加 A0「启动来源（必答项）」段 |
| 集群应用测试 | `scripts/hd-cluster-app-test.sh` | C2 的 FAIL 文案改掉（已过期） |

容器内路径一律 `/opt/hd/<同名>.sh`（`verify-hd-napstar.sh` 部署成 `/opt/hd/verify.sh`）。

### 6.4 容器里的备份（回滚点）

| 位置 | 内容 |
|---|---|
| `/opt/napstar_app/backup-20261102/` | **本轮部署前**的三个旧 jar（`c41735d8…` / `3174ad84…` / `658af524…`） |
| `/opt/hd/jar-backup-d2/` | 上一轮留的**基线部署那份** `model-controller-3.0.0.jar`（113073623 字节，11-01 00:16） |

---

## 七、下一轮的入口

| # | 事 | 严重度 | 说明 |
|---|---|---|---|
| **1** | **`monitor` 的 6 处补运行时覆盖** | 🟡 | 本轮只做了静态核验。**要补模型元数据表的数据**（`info.model_objecttype` / `model_attribute` / `model_objectattribute`），或在有真实模型数据的环境上再跑一次集群模式。**「启动无 UOE」不能当判据**（假绿） |
| **2** | **交付方确认交付流程** | 🔴 | 「先编 platform 再 `mvn install`」吗？若是 ⇒ 必须先完成树 A 与基线的**整体**对齐；在此之前**禁止 install 树 A 的 platform**、**禁止把区间切到 `[3.0.0,4.0.0)`**（见 D9） |
| **3** | **`napstarweb` 的 `kafkabus.yaml`** | 🟡 | 先确认真实 Nacos 里有没有它；有 → 无事；没有 → 按 D2 (a) 同样方式处理（见 D2 节末） |
| **4** | **`hd-entrypoint.sh` 加一步清 `/brokers/ids/<id>`** | 🟡 | 否则**下一个容器重启周期还会再犯** ⚙️-A，而它会让 C2 **静默不可执行** |
| **5** | **每轮跑判据前重新铸 token** | ⚙️ | `bash /opt/hd/mint-hd-token.sh`（⚙️-B） |
| **6** | **`sche-viewer-server` 的 15 处裸 `executePipelined`** | 🟡 | 当前 standalone、不参与构建 → 暂时安全；**将来切集群前必须一并处理** |
| **7** | **`application/backend-gd/` 是同一批代码的副本目录** | 🟡 | 不参与发版，但留着不改以后会再咬人 |
| **8** | **基线的几个次要设计问题** | 🟢 | `FailSetCounter` 只写不读（没接出口）· `add(data.size())` 的单位在集群/单机两条路上不一致（点数 vs 记录数）· `wirteOmsPip` 去 `@Async` 后写操作占用 `consumerRunExecutor`（core=16 + CallerRunsPolicy → Redis 故障时可能反压到 Kafka 消费线程）· `processItem` 异常时 `return 0` 会丢掉该 item 已累计的 fieldCount · `CacheServiceImpl` 单机分支的 try/catch 粒度比集群分支粗。**这些都是基线设计，本轮「与基线对齐」时没改** |
| **9** | **平台基线树的其它业务逻辑差异** | 🟡 | 树 A 的 platform 源码与基线 1.0.14 在**业务逻辑**上也有差异（本轮只对齐了影响集群能力的 4 个类）⇒ 见 D9 |
| **10** | **`sac` / `cmt` / `hds` 的建表 DDL** | 🔴 | **上一轮遗留，本轮未处理**。挡住 `transformNapstarModel`。平台上 `SystemTable.sql` 是 **MySQL 方言**（不是 PG 方言）→ 要转换 |

> **🚫 明确不做**：`hisDataProducer` / `hisDataSend` 的 PG 驱动缺失（D1，用户已决定不修改这两个模块）。

> 📌 **第 6 / 7 / 8 条不在缺陷清单里** ——
> `docker/hd-napstar/DEFECTS.md` 的汇总表**没有对应的行**
> ⇒ **这三条是本轮新记的**（记在本存档里），不要在缺陷清单里找不到就以为它们不存在。
>
> 📌 **D6 = 已接受**（密码走命令行，与仓库现有惯例一致），
> **生产解法待定**。⚠️ 但补一条本轮复核后的结论：**交付树**编出来的 jar 里
> `oms:` 块是**注释着的** ⇒ **Nacos 赢** ⇒ **生产上不必把密码放命令行**，
> 在 Nacos 里配好三个 dataId 即可（详见 `docker/hd-napstar/DEFECTS.md` 的 D6 节）。

---

*本会话基于 2026-11-02 的实测（依赖树、jar 字节扫描、`javap` 反编译、变异测试、文件行号核对）。
所有"通过"都有原始输出支撑。*
*上一份存档：`docs/superpowers/sessions/2026-11-02-hd-redis-cluster-test.md`（第十节是本轮的复核更正）。*

---

## 八、2026-11-02 追加轮：环境体检 + **树名更正**

> 本节是**第三轮**（前两轮 = 集群测试轮 + 交付树集群修复轮）。
> 做的是：① 开工前环境体检（确认判据可执行） ② **发现并更正一个横跨全部文档的树名错误**。

### 8.1 环境体检：判据全部可执行，数字与上一轮**逐条一致**

| 判据 | 本轮实测 | 上一轮 | 一致 |
|---|---|---|---|
| 应用层集群测试 | `PASS=34 FAIL=0 SKIP=1` | 同 | ✅ |
| 底层集群验证 `hd-cluster-verify.sh` | `PASS=39 FAIL=0` | 同 | ✅ |
| base 回归矩阵 | `PASS=47 FAIL=0 SKIP=4` | 同 | ✅ |
| `test-hd-cluster-summary.sh` | `PASS=19 FAIL=0` | 同 | ✅ |
| `test-hd-cluster-merge-wiring.sh` | `PASS=8 FAIL=0` | 同 | ✅（**这次集群在跑**，测到了「合并」这一步） |
| `test-hd-portal-baseline.sh` | `PASS=40 FAIL=0` | 同 | ✅ |

- base 矩阵与上一轮基线**逐条 diff**：只有 4 处计时/计数抖动（启动秒数 ×4、PG 连接数 4→5、SQL execute 条数 1→7），
  **判据本身零差异**。
- **⚙️-A（Kafka broker 起不来）未复发**：`/brokers/ids` = `[755, 756]`，两个 broker 都活着。
- **⚙️-B（token 过期）未复发**：`exp=1793681279`，`now=1793605295` → **剩余 75984 秒**。
  （但按 §七 #5 的规矩，下一轮开工仍应重铸。）
- **归档 patch 仍然可用**：`git apply --check -p1` **rc=0**；apply 后 **12/12 与树 A 现文件 SHA256 全等**。
- **mvnRepo 零改动**：两个仓库（`%USERPROFILE%\.m2\repository` 与 `D:\java\apache-maven\mvnRepo`）
  12:00 之后被修改的文件数 **均为 0**。
- **门户未受影响**：新快照 vs 上一轮快照 **只差 uptime 一行**。

### 8.2 🔴 **发现一个横跨全部文档的树名错误**（已修）

用户给出三棵树的权威对照后发现：

> **文档里叫「门户树 / portal/SVN 树」的那棵树（`D:\javawork\1.2\cpscloud1.0\code`）
> 其实是「基线」。**
> 真正的门户树是 `D:\work\info\web\extendsystem\集控-IV区门户\code` ——
> **此前从未被检查过。**

**逐字节证据**：

| 证据 | 结果 |
|---|---|
| 旧 `model-controller-3.0.0.jar`（`c41735d8…`，D8 的元凶） | **md5 完全等于基线树**的 `platform/backend/modelserver/controller/target/model-controller-1.0.14.jar` |
| 那份 jar 内嵌的 `application.yml`（`541faf69…`） | **md5 完全等于基线树**同名文件 |
| `oms:` 块「生效 + 集群占位符」的树 | **只有基线**（门户树和华盾树的 `oms:` 都是**注释着**） |
| ⇒ **D8 的成因归属** | 从「门户树」更正为「**基线树**」（结论不变，归属变了） |

**门户树（集控-IV区门户）的实测能力**：

| 项 | 值 |
|---|---|
| 自有版本 / `platform.version` | `2.0.2` / **`2.0.0`（定点，不是区间）** |
| 集群标记 | `isCluster` / `RedisClusterHelper` / `RedisClusterHashPipeline` / `writeWithRetry` **全 0** |
| `realserver/common/oms` 模块 | **没有**（`rtdata-module` 也没有） |
| 版本控制 | `application\.git` + 3 个 worktree |
| 独有模块 | `platform/backend/portal`、`processsinfomodel`、`application/backend/{3dmanager,smartoptsys}` |

⇒ **D9 的机制（版本区间挑版本）对门户线不成立** —— 门户用定点 `2.0.0`。
⇒ **门户线要切集群的话，得从基线把整套补丁搬过去**（跟华盾当时一样）。

### 8.3 D10 的缺口被量化（结论不变，边界更清楚）

| 需求 | 源 | 方言 | 状态 |
|---|---|---|---|
| `info` 30 表 | `/pkg/database/postgresql_install/sqls/info/InitTable/*.sql` | PG | ✅ 已装 |
| `sac` | 平台包 `mysql_install/SystemTable.sql`（15 表，`engine=innodb`×15 / `smallint(5)`×14）—— `AttributeTypes`/`ObjectTypes`/`Choice`/`Wiring` **正好对得上** mapper 里的 `sac.attributetypes`/`sac.objecttypes`/`sac.choice`/`sac.wiring` | MySQL | ❌ **要转方言** |
| `cmt`（`commitlist`） | **安装包里没有建表脚本** | — | ❌ **源都要另找** |
| `hds`（`h_daymvpointstat_` 等，mapper 引用上百次） | **安装包里没有建表脚本**（`CreatehistoryTable.sql` 只建 `H_AlarmEvents`/`H_DataEdits`/`H_TempId`/`H_TimeStamp`） | — | ❌ **源都要另找** |

### 8.4 顺带发现（**门户线自己的问题，与华盾无关**）

门户的 `3dmanager` flyway 迁移是 **MySQL 方言**
（`AUTO_INCREMENT`×4 / `COMMENT`×44 / `TINYINT|DATETIME`×10 / `ON UPDATE CURRENT_TIMESTAMP`×2），
而门户库 `cpspg` 是 **PostgreSQL** ⇒ **那些迁移脚本在门户自己的库上跑不起来**。

### 8.5 本轮改了什么

| 文件 | 改了什么 |
|---|---|
| `docs/superpowers/sessions/2026-11-02-tree-map.md` | **新增** —— 三棵树权威对照表（路径 / 版本 / 补丁分布 / `oms:` 状态 / jar 归属 md5 / mvnRepo 版本矩阵 / DDL 出处） |
| `docker/hd-napstar/DEFECTS.md` | 树表改成**三棵**；标记表加门户列；**D8 成因改归基线树**；**D10 缺口量化**；顶部加树名更正 banner |
| `docs/OPERATIONS.md` | 10 处「门户树」→「**基线树**」（每处都指 `cpscloud1.0`）；3 处指门户容器本身的**没动** |
| 4 份历史存档 / plan / spec | **正文不改**（结论不受影响），各加一条**树名更正 banner** 指向树图 |

提交：`dd1b59e docs(hd): correct the tree names -- cpscloud1.0 is the baseline, not the portal`

### 8.6 本轮踩的坑

| # | 坑 | 对策 |
|---|---|---|
| 14 | **全局 `sed`/`perl` 替换会误伤刚写的 banner**（「真正的门户树」被当成旧词改掉） | 先打**保护标记**（`\x01PTREE\x01`）→ 全局替换 → 还原；改完逐行 `diff` 复核 |
| 15 | **PS 5.1 的 `Get-Content`/`-File` 对 UTF-8 无 BOM 的中文按 ANSI 解码** | ① 写 `.ps1` 时**只用 ASCII**（中文改用 `[System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes(...))` 读）② 文本替换**放进容器里用 perl 做**（字节级安全） |
| 16 | **`.ps1` 里出现中文路径 ⇒ `Test-Path` 恒为 false** | 实测踩到：`D:\work\info\...\华盾-napstar2.0\code` 被判「不存在」⇒ 误以为树没了。改用容器内 `find`（挂载后路径是纯 ASCII） |
| 17 | **`read` 工具会重排 markdown 的 `**` 强调标记** | 改中文 markdown 时**按行**做精确替换（`sed -i "<行号>s/.../.../"`），不要拿 `read` 的多行输出当 `oldString` |

> 📌 **下一轮照做**：**树名先对齐再引用** ——
> 本轮之前，`树 B`、`门户树`、`基线树` 三种叫法在文档里混用，
> 而它们指向的是**同一棵树**（`cpscloud1.0`）———
> 一旦有一份权威树图，这种歧义就不会再发生。

# 执行进度：统一 Redis 连接基础设施

> 计划：`docs/superpowers/plans/2026-10-28-unified-redis-connection.md`
> 开始：2026-10-28

## 环境

```powershell
$MVN  = "D:\java\apache-maven\apache-maven-3.8.6\bin\mvn.cmd"
$BE   = "D:\javawork\1.2\cpscloud1.0\code\platform\backend"
$BE2  = "D:\javawork\1.2\cpscloud1.0\code\application\backend\napstarweb"
$REPO = "D:\work\rediscluterproject"
$TMP  = "C:\Users\蔡雷鸣\AppData\Local\Temp\opencode"
```

**真集群（已打通）**：`127.0.0.1:16379-16384` → 6 实例，
密码 `CpsE2eClusterPw`，`cluster_state:ok` / 16384 slots / 6 nodes / size 3。
转发器容器 `rc-redis-publish`（临时，删了要用 `$TMP\start-publish.sh` 重建）。

**基线**：`realserver-oms` 50 条测试全绿；`realserver-dao` 无测试。

## 任务状态

| # | 任务 | 状态 |
|---|---|---|
| 0 | 备份原始文件（17 个 + manifest） | ✅ DONE |
| 1 | `RedisUtil` 13 组方法加 `@Deprecated` | ✅ DONE |
| 2 | `RedisPropertiesConfig` bean 改名 | ✅ DONE |
| 3 | 删三个墓碑文件 | ✅ DONE |
| 4 | 补全三个应用的 `oms:` 配置块 | ✅ DONE |
| 5 | 删 `opsHashSetPipeByHashData`，解开对 `realserver-entity` 的依赖 | ✅ DONE |
| 6 | 删 `JedisUtils` / `JedisPoolUtils` | ✅ DONE |
| 7 | 修正错误注释 | ✅ DONE |
| 8 | 生成 patch 并留痕 | ✅ DONE |
| 9 | 三个应用最终验证（含真集群 L3） | ✅ DONE |
| 10 | **终审发现的 5 个问题**（修复 + 回归） | ✅ DONE |

## 完成记录

### Task 0 — 备份原始文件 ✅

17 个文件已备份到 `%TEMP%\opencode\redis-unify-baseline\`，manifest 为 **3 列**
（`ROOT` / 相对路径 / 备份文件名）。独立复核：**17 个文件，0 个 hash 不一致**。

> **计划里的 `$BE2` 路径有 bug**（由 subagent 发现并修正）：
> `$BE2` 本身已经指向 `napstarweb` 目录，所以路径是 `$BE2\web-controller\...`，
> **不是** `$BE2\napstarweb\web-controller\...`（后者重复了一段，路径不存在）。
> 计划文档已修正（提交 `da5152e`）。
>
> **manifest 从 2 列改成 3 列**：2 列时无法区分来源
> （`web-controller\...` 来自 BE2、`realserver\...` 来自 BE），
> 前缀判断会混淆并产生假 hash 不匹配。加 ROOT 列后 0 误报。

### Task 1 — 集群不安全方法加 `@Deprecated` ✅

`realserver-oms/…/utils/RedisUtil.java`：**27** 个方法加 `@Deprecated` + `@deprecated`
javadoc（写明集群下的**真实**行为 + 正确替代 + 注明本代码库已无调用方）。
**0 个方法被删除，0 个方法体被改动**（与基线 diff 只有 javadoc 与注解的增行）。

- **证据**：`mvn -o test` → `Tests run: 50, Failures: 0, Errors: 0` + `BUILD SUCCESS`
- `@Deprecated` 计数 = **27**，「已无调用方」注记 = **27**，BOM 检查 = `47,42,42`（无 BOM）

> **计划里写的"28"是算术错误**（subagent 纠正）：文件里**没有** `sDifferenceAndStore`
> 这个方法 —— 两个 store 变体叫 `sDifference(String,String,String)` 与
> `sDifference(String,Collection,String)`。

> **⭐ 这三轮里最有价值的发现：我的 javadoc 有 20/26 说的是错的。**
>
> 我原来写"跨槽会抛 CROSSSLOT 错误"。**实际上 SDR 2.7.18 大多不抛**，
> 而是**静默降级**成非原子的客户端实现。逐条用字节码/源码核实后：
>
> | 命令 | 跨槽时的真实行为 |
> |---|---|
> | `keys()` | `executeCommandOnAllNodes` + 取并集 → 返回**整个集群的 keyspace**（不是只返回一个节点！）|
> | `del` / `mGet` / `mSet` | 按 slot 拆分 → **不抛** CROSSSLOT |
> | `rename` | 降级成 `DUMP → RESTORE(dst,0,REPLACE) → DEL` → **不抛**，但**非原子**且**丢 TTL** |
> | `renameNX` | 同上，但 `RESTORE(dst,0)` **不带 REPLACE**，且先 `EXISTS` 判断 |
> | `rPopLPush` | 降级成 `RPOP + LPUSH` → **不抛**，非原子，崩溃丢元素 |
> | `sMove` | 降级成 `EXISTS → SREM → SISMEMBER → SADD` **四步** → **不抛**；`SISMEMBER` 为真时跳过 `SADD` → **元素静默丢失** |
> | `SINTER`/`SUNION`/`SDIFF` | 逐 key `SMEMBERS` 后**在 JVM 里算** → **不抛**，非原子，整集合进堆 |
> | `ZUNIONSTORE`/`ZINTERSTORE` | **真的失败**，但抛的是 `InvalidDataAccessApiUsageException`（"can only be executed when all keys map to the same slot"），**不是** CROSSSLOT |
> | `MOVE` | 抛 `UnsupportedOperationException("Cluster mode does not allow moving keys.")` |
>
> **真正的风险不是"会抛异常"，而是"静默地、不原子地做错事"** ——
> 一个照着原 javadoc 排查的人会去找一个永远不会出现的异常，
> 而真正会咬人的（rename 丢 TTL、sMove 丢元素、KEYS 拉爆内存）反而看不见。
>
> 这是本轮最该记住的一条：**关于第三方库行为的断言，必须去看它的源码/字节码，
> 不能靠"常识"推断。**

> **顺带发现**：`lBRightPopAndLeftPush`（阻塞版 `lRightPopAndLeftPush`）也是双 key 命令、
> 同样有非原子降级风险，但原先没被弃用。实测**全仓库无调用方** → 一并弃用（26 → 27）。

### Task 2 — `RedisPropertiesConfig` bean 改名 ✅

bean 名 `redisConfigProperties` → **`omsRedisConfigProperties`**（显式 `@Bean("...")`）。
**方法名保持不变** —— Spring 按类型注入，bean 名只影响按名查找；
改方法名会波及所有注入点。`RedisUtilConfig.java` **一行没动**（实测确认：它的 6 处
`RedisConfigProperties redisConfigProperties` 都是方法参数，不是按名注入）。

新增回归守卫 `RedisPropertiesConfigBeanNameTest`（2 条）：
按新名取到 bean、按类型取到同一个实例、**旧名必须已不存在**。

- **证据**：`mvn -o test` → `Tests run: 52, Failures: 0, Errors: 0` + `BUILD SUCCESS`
- **变异检验（我亲自做的）**：把 `@Bean("omsRedisConfigProperties")` 改回裸 `@Bean` 后
  重跑 → **2 条全红**（`theOldBeanNameNoLongerResolves` 报 `expected: <false> but was: <true>`，
  另一条因新名不存在而 Error）→ 证明这条测试**不是空转**，改回去文件即恢复。

### Task 3 — 删三个墓碑文件 ✅

三个「在消费方自己加一份 `RedisPropertiesConfig`」的失败尝试墓碑已删除。
**全树现在只剩一个** `RedisPropertiesConfig.java`（`realserver-oms` 里的真身）。

- **证据**：三个文件 `Test-Path` 均为 `False`；全树 grep 只剩 1 个；
  `modelserver-controller EXIT=0`；`rtdata-module EXIT=0`；`napstarweb EXIT=0`；
  `realserver clean install EXIT=0`；`oms` 52/52 绿

> **两个环境坑（都不是本次改动引起的，但会绊住后续任务）**：
>
> 1. **本地仓库里的 `realserver-oms` jar 是旧的**。`rtdata-module` 通过
>    `realserver-service` **传递依赖** `oms`，maven 从
>    `D:\java\apache-maven\mvnRepo`（`settings.xml` 的 `localRepository`）取到
>    10/23 的旧 jar —— 那里面连 `RedisClusterHashPipeline` 都没有，
>    报"找不到符号"。**改了 `oms` 之后必须 `mvn install` 重装它**，
>    否则下游模块编译的是旧代码。
> 2. **proguard 需要 JDK 8**。`oms/pom.xml` 配了 `proguard-maven-plugin`，
>    它要 `${JAVA_HOME}/jre/lib/rt.jar`，**JDK 9+ 没有这个文件**。
>    用 JDK 21 构建会报 `Can't read .../jre/lib/rt.jar`。
>    **本机 `JAVA_HOME` 是 `D:\java\java-se-8u42-ri`（JDK 8），没问题**；
>    但如果哪个 shell 把它切到 JDK 21，`clean install` 就会失败。

### Task 4 — 补全三个应用的 `oms:` 配置块 ✅

三个应用的 `application.yml` 都有了**完全相同**的 `oms:` 块（SHA-256 一致：
`70c10ee4…`），`redisMode: cluster` **显式写出**（不靠默认值），
并含 `clusters` / `password` / `database` / 三个超时 / 三个连接池参数。

- **证据**：Python `yaml.safe_load` 解析三个文件 → 各自**只有一个顶层键 `oms`**，
  11 个键齐全；无 BOM；三个工程 `mvn test` 全 `EXIT=0`
- **⭐ R1 风险没有发生**：Nacos 并没有在 bootstrap 阶段用空值覆盖 `oms.*`。
  正常启动与 `-Dspring.cloud.nacos.config.enabled=false` 两种情况下，
  日志**都**打印
  `*** Using Redis Cluster with nodes: 127.0.0.1:6379 (connectTimeout=2000ms, readTimeout=5000ms, maxWait=3000ms)`
  —— 说明本地 `application.yml` 能独立撑起启动，Nacos 只是覆盖层。
  （顺带发现：Nacos 服务 `node1:18848` 在本机根本连不上，重试 23 次但不影响启动，
  这反而让"本地兜底有效"的结论更强了。）

> **⭐ 为此新增了一条 L3 真集群契约测试** `RedisClusterOmsContractTest`（2 条）：
> ① 断言 `oms.*` 绑定的值真的传到了 `JedisConnectionFactory`（含连接池参数）；
> ② 用这个工厂对**真实集群**写入 → 读回 → 删除。
> 集群不可达时用 `assumeTrue` **跳过**而不是变红（没有集群的构建环境不受影响）。
>
> 写这条测试时踩了两个坑：
> - `@ConfigurationProperties` 打在 `@Bean` 方法上时，绑定由
>   `ConfigurationPropertiesBindingPostProcessor` 完成，而 `ApplicationContextRunner`
>   **不自动注册**它 → properties 全是 null →
>   `RedisUtilConfig` 抛 `Redis mode mismatch: oms.redisMode='null'`。
>   解法：`.withInitializer(ctx -> ConfigurationPropertiesBindingPostProcessor.register(...))`。
> - `RedisClusterHelper` 是 `@Component` 不在 `AutoConfigurations` 里 →
>   `NoSuchBeanDefinitionException`。解法：显式 `@ComponentScan` 扫 utils 包。

> **⭐⭐ 让宿主机上的 Java 能用真集群 —— 这是本轮最费劲也最有价值的一段**
>
> 之前只做到"端口可达"（socat 转发 16379-16384 → 127.0.0.1），
> 但 **Jedis 仍然连不上**：
> ```
> JedisClusterOperationException: Cluster retry deadline exceeded.
> ```
> 根因：**Jedis 连上种子节点后，会按 `CLUSTER SLOTS` 返回的"真实地址"去路由命令**，
> 而集群广播的是 `172.21.0.2:6379` —— Windows 宿主机**没有**到 `172.21.0.0/16` 的路由
> （`Get-NetRoute` 查不到，实测 `Test-NetConnection` 全 NO）。
>
> 解法：**让集群广播宿主机可达的地址**：
> ```
> CONFIG SET cluster-announce-ip   127.0.0.1
> CONFIG SET cluster-announce-port  16379 / 16380 / …（转发端口）
> ```
> ⚠️ **踩坑：`cluster-announce-bus-port` 不能改**。它是节点**之间**通信用的，
> 改了会让集群内部链路断掉（节点全部变 `disconnected`）。改回 `0`（= 用真实 bus 端口）即恢复。
>
> 改完后（这是**运行期**改动，只针对这套一次性 E2E 集群，不是生产配置）：
> ```
> 198348f5… 127.0.0.1:16379@16379 myself,master - 0 0 1 connected 0-5460
> 1394f9b2… 127.0.0.1:16380@16380 master  - 0 1793170700000 2 connected 10923-16383
> efe15966… 127.0.0.1:16381@16381 master  - 0 1793170701272 7 connected 5461-10922
> ```
> 实测 Jedis 从宿主机：`set -> OK`、`get -> probe:value` ✅
> L3 契约测试 **2/2 绿、0 skipped**（真写真读了集群）。
>
> **变异检验**：把 `clusters` 指到错误端口 `127.0.0.1:19999` → 该条**跳过**（1 skipped）
> —— 证明它不是空转，也没有让没有集群的环境变红。

### Task 5 — 解开 `realserver-oms → realserver-entity` ✅

删掉 `opsHashSetPipeByHashData(List<HashData>)`，`OmsWriteDaoImpl.batchWriteByHashData`
改为先把 `List<HashData>` 聚成 `Map<String,Map<String,Object>>` 再调**已有的**
`opsHashSetPipe(Map)` —— 分组逻辑挪到业务侧。

- **证据**：56/56 绿；`mvn dependency:tree` 里 **oms 已经是零 `com.sac.platform` 依赖**
  （只剩自己），`idgenerator` 的依赖树也不再含 `realserver-entity`；
  `oms` 源码里对 `realserver.entity` 的引用只剩守卫测试自己那一条；
  `dao` / `rtdata-module` / `idgenerator` / `services` / `controller` 全部 `EXIT=0`

> **⭐ 我的测试设计有缺陷，被 subagent 抓出来了**：
> 我原本让测试扫 `target/classes/com/sac/platform/realserver/entity`，
> 但 **Maven 只把本模块自己的源编译进 `target/classes`，依赖 jar 不会解包进去** ——
> 所以这个检查**永远为真、约束不住任何东西**（变异后依然绿）。
> 而且我写的断言 `assertFalse(scan.contains("com/sac/platform/realserver/entity"))`
> 里，失败消息又拼了同一个字符串 —— **恒真的同义反复**。
>
> 改成真正的检查：`Class.forName("com.sac.platform.realserver.entity.HashData", false, classLoader)`
> 必须**加载失败**（entity jar 里有这个类，依赖存在时就会加载成功 → 测试红）。
>
> **我亲自复核了变异**：把 `realserver-entity` 依赖加回 pom → 测试**变红**
> （`got: ENTITY_DEPENDENCY_PRESENT`）→ 恢复后 56/56 绿。**证明这条守卫不是空转。**

> **⭐ 解耦暴露了一个真实的隐式依赖**：去掉 `realserver-entity` 后，
> `RedisUtilConfig` 里的 `GenericJackson2JsonRedisSerializer` 报
> `NoClassDefFoundError: com/fasterxml/jackson/databind/jsontype/impl/StdTypeResolverBuilder`
> —— Jackson 之前是**通过 `realserver-entity` 传递进来**的。
> 现在 `jackson-databind` 已**显式声明**为 oms 的直接依赖（版本仍由根 pom 的
> `${jackson.version}` = 2.13.5 管理，解析到的构件与之前完全一致）。
> **这就是"删掉一个传递依赖"的典型代价：藏着的直接依赖会被暴露出来。**

### Task 6 — 删两个死代码类 ✅

`JedisUtils.java`（~700 行，单节点 + `jedis.select()`，集群非法）与
`JedisPoolUtils.java`（~50 行，静态读**不存在的** `jedis.properties` → 一调用就 NPE）
已删除。

顺带处理了唯一的调用点：`OmsWriteByKafkaServiceImpl.batchWirteJedisStandalone`
（单机裸 Jedis pipeline 分支）**整个方法删除**，`batchWirteJedis` 改为集群与单机
统一走 `redisRealDataService.wirteOmsPip`（集群按 slot 分组 pipeline，单机用
`executePipelined`）。实测 `batchWirteJedis` **本身也无外部调用方**。

- **证据**：两个文件 `Test-Path` = `False`；全树（含 napstarweb）grep
  `JedisUtils|JedisPoolUtils` **无任何命中**；`oms/utils` 现在只剩 5 个活类
  （`RedisClusterHashPipeline` / `RedisClusterHelper` / `RedisPipelineUtil` /
  `RedisScanUtils` / `RedisUtil`）；`oms` 56/56 绿、`rtdata-module` 14/14 绿、
  `dao` / `rtdata` / `realserver` 全部 `EXIT=0`

> **两个 PowerShell 坑（都记一下）**：
> 1. **`-D` 参数在 PowerShell 里必须加引号**。`-Dproguard.skip=true` 不加引号会被
>    PowerShell 拆成 `.skip=true`，maven 报 `Unknown lifecycle phase ".skip=true"`。
>    写成 `"-Dproguard.skip=true"` 才对。
> 2. **本机 `JAVA_HOME` 有两个值**：`D:\java\java-se-8u42-ri`（JDK 8，我这个 shell）与
>    `D:\java\jdk-21.0.2`（subagent 那个 shell）。**oms 的 pom 配了 proguard，
>    它要 JDK 8 的 `rt.jar`**，JDK 9+ 没有这个文件 → `Can't read .../rt.jar`。
>    用 JDK 8 构建则正常。**涉及 `mvn install` 的任务要留意这个差异。**

### Task 7 — 修正错误注释 ✅

`modelserver/…/CacheServiceImpl.clearModelCacheCluster` 的注释原文说
"不能批量 delete：Jedis 3.10 的 `JedisCluster.del(byte[]...)` 以首个 key 定槽，
跨槽批量删除会报 CROSSSLOT" —— **这句是错的**（SDR 2.7.18 会按 slot 拆分，不抛）。
已改成准确的表述：不用批量 delete 的真正理由是
① 集群下 `redisTemplate.keys()` 只返回它落到的那**一个**节点的结果（漏删）
＋ `KEYS` 阻塞 O(N) ＋ 整个 keyspace 进 JVM 堆；
② 逐 key 删除可以边取边删，不用先把全集攒在内存。

- **证据**：`services EXIT=0`；`oms` 56/56 绿；无 BOM；行尾保持 CRLF

> **全树 CROSSSLOT 扫描结果**：Java 文件里共 27 处 ——
> `RedisUtil.java` 25 处**全部**是"不会抛 CROSSSLOT"的正确表述（Task 1 已修），
> `CacheServiceImpl.java` 2 处是本次改的。**无一处还在断言"会抛"。**
>
> 另有 8 处在 `docs/superpowers/` 下的**历史文档**里
> （2026-10-22 那轮的 plan/spec/session 记录）。**刻意不改** ——
> 那是已完成会话的**历史记录**，改它等于篡改当时的决策依据；
> 而且那些结论（逐 key 删除、流式 SCAN）本身仍然正确。

### Task 8 — 生成 patch 并留痕 ✅

三份 patch 进 `docs/superpowers/patches/`：

| 文件 | 目标根 | 文件数 |
|---|---|---|
| `2026-10-28-unified-redis-connection-platform-backend.patch` | `platform\backend` | 13 |
| `2026-10-28-unified-redis-connection-napstarweb.patch` | `application\backend\napstarweb` | 2 |
| `2026-10-28-unified-redis-connection.patch` | 两个根合并（合成仓库用）| 15 |

- **证据（我亲自复核）**：
  - `git apply --reverse --check` → backend **0**、napstarweb **0**
  - **正向重建**：从纯净基线 + patch 重建 → 与现网**逐文件 hash 比对**
    → backend `checked=15 mismatches=0`、napstarweb `mismatches=0`
  - patch 首 3 字节 = `100,105,102`（`dif`），无 BOM，UTF-8
  - 15 个 `diff --git`、5 个 `deleted file mode`；
    `^\+.*realserver-entity` **无命中**（确认依赖是被移除而非新增）

> **⭐ 计划里的 Step 2b 有个会静默出错的坑**（subagent 发现）：
> 它只"复制存在的文件"，**从不删除已删的文件**，于是 `git add -A` 认为它们没变，
> **5 个删除全部丢失** —— 第一版 patch 只有 10 个 `diff --git`、**0** 个 `deleted file mode`。
> 必须显式把不存在的文件从工作树里 `Remove-Item` 掉。
>
> **⭐⭐ 另一个更隐蔽的坑：`core.autocrlf=true` 会毁掉 patch**。
> 源文件**行尾是混的**（`pom.xml` 是 LF，`RedisUtil.java` 是 CRLF）。
> Windows 默认 `autocrlf=true` 会在提交时把 CRLF 规范化成 LF，
> 于是 patch 的"改动前"那一侧**与磁盘原始字节对不上** → patch 应用失败。
> 必须用 `core.autocrlf=false` / `core.eol=lf` 建工作仓库。
>
> **⭐ 还有一点：一个 patch 无法同时反向应用到两个根** —— 两条树的路径前缀不同
> （`realserver/...` 与 `web-controller/...` 分属不同的绝对根），
> 几何上不可能。所以**按根拆成两份**，合并版只用于合成仓库。README 里写清楚了。

### Task 9 — 三个应用最终验证 ✅

| 检查 | 结果 |
|---|---|
| `realserver` 全量 `clean install` | **EXIT=0** |
| `modelserver` 全量 `clean install` | **EXIT=0** |
| `napstarweb` 全量 `clean install` | **EXIT=0** |
| `realserver-oms` 单测 | **56/56 绿** |
| `rtdata-module` 单测 | **14/14 绿** |
| `oms` 依赖树 | 只剩自己，**零 `com.sac.platform` 依赖** |
| `idgenerator` 依赖树 | **不含 `realserver-entity`** |
| 三个应用启动 | **三个都打印** `*** Using Redis Cluster with nodes: 127.0.0.1:16379 (connectTimeout=2000ms, readTimeout=5000ms, maxWait=3000ms)` |
| 真集群契约测试 | `Tests run: 2, Failures: 0, Errors: 0, **Skipped: 0**` |

> **三个应用都只在 Nacos 上失败**（`node1:18848` 不可达，
> `NacosException: Client not connected, current status:STARTING`）——
> 与 Redis 无关。**Redis 的 bean 在那之前就已经装配好并打印了配置行**，
> 所以 Redis 侧的验证是成立的。

> **⭐ 一个验证工具链的坑**：`mvn spring-boot:run` **会 fork 一个新 JVM**，
> **不会把 Maven 的 `-D` 系统属性传进去** —— 所以
> `-Doms.clusters[0]=127.0.0.1:16379` **无效**，应用仍然读到 yml 里的占位符 `6379`。
> 正确写法是：
> ```powershell
> "-Dspring-boot.run.jvmArguments=-Doms.clusters[0]=127.0.0.1:16379 -Doms.password=CpsE2eClusterPw"
> ```
> （验证时用的，**没有写进任何 yml** —— 已核对三个 yml 里
> `16379` 与 `CpsE2eClusterPw` 出现 **0** 次。）

> **本轮结束时的工作树**：**10 改 + 5 删 + 2 未改**，与预期完全一致，
> **无任何意外改动**。未改的两个是 `RedisUtilConfig.java` 与
> `RedisConfigProperties.java`（它们本来就不需要改）。

### Task 10 — 终审发现的 5 个问题 ✅

终审（对整个实现的最后一遍审查）找出 5 个问题，**全部已修**。

| # | 问题 | 修法 | 证据 |
|---|---|---|---|
| **1** | **`CacheServiceImpl` 注释又引入了一个新的错误说法** —— 我在 Task 7 写"集群下 `redisTemplate.keys()` 只返回它落到的那**一个**节点的结果"，**这也是错的** | 改成准确表述，并注明 `JedisClusterKeyCommands.keys` 是 `executeCommandOnAllNodes` + 取并集 | **从 SDR 源码逐字核对**：`JedisClusterKeyCommands.keys` 确实是 `executeCommandOnAllNodes(...).resultsAsList()` 然后 `keys.addAll(keySet)` |
| **2** | **`oms.redisMode` 大小写敏感** → 写成 `CLUSTER` 时**三个分支一个都不激活**，**一个 `RedisConnectionFactory` bean 都不会创建**，报错停在 "No qualifying bean of type 'RedisConnectionFactory'"，完全指不到真正原因 | 三个 `@ConditionalOnExpression` 改成 `'${oms.redisMode:standalone}'.trim().toLowerCase() == 'cluster'`（与 `parseMode` 的归一化规则一致） | 实测：`CLUSTER`/`Cluster`/`STANDALONE` 修复前 **startupFailure=true**，修复后 **全部 PRESENT** |
| **3** | L3 契约测试**只断言了 `props`，没断言属性真的落进了 `JedisPoolConfig`** —— 把 `setMaxTotal` 写死成常量，测试依然绿 | 加断言：`JedisPoolConfig.getMaxTotal/MaxIdle/MinIdle/MaxWaitMillis` + `JedisConnectionFactory.getClientConfiguration().getConnectTimeout/getReadTimeout` | **变异检验**：把 `setMaxTotal` 写死 → 测试**变红** `expected: <16> but was: <200>`（改之前这个变异是绿的） |
| **4** | L3 契约测试**可能偶发变红** —— 守卫只护住了探针那一次 GET，真正的 `put` 没护 | 整段读写用 `catch (DataAccessException) → assumeTrue(false, …)` 守卫 | 集群不可达时**跳过**而不是变红 |
| **5** | 补丁生成用 `Out-File -Encoding ascii` 会把**中文全变成 `?`**，`git apply` 报 `corrupt patch` | 改用 `git diff --output=<file>`（原始字节） | 补丁里 `集群` 二字完好，**无 `?` 替换符**；反向校验 0、正向重建 0 mismatch |

另外新增了一条永久回归守卫 `RedisModeCaseSensitivityTest`（3 条），
把「模式大小写不敏感 + 未知模式必须**响亮地失败**」锁住。

> **⭐ 又一次印证：关于第三方库行为的断言必须去看源码。**
> 这次不是"我写错了注释"，而是"**审查者与我各错一半**"——
> 我在 Task 1 写"keys 只返回一个节点"，Task 7 又写了一遍；
> 终审用**在真集群上种 8 个 key 再查**的方式证伪了它。
> **从源码 + 实测两头对上，才算真结论。**

**patch 已重新生成**（含 4 个新增测试文件）：

| 文件 | 大小 | 校验 |
|---|---|---|
| `…-platform-backend.patch` | 107,604 B | 反向 0；正向 `checked=19 mismatches=0` |
| `…-napstarweb.patch` | 3,138 B | 反向 0；正向 `checked=2 mismatches=0` |
| `…-unified-redis-connection.patch`（合并） | 110,742 B | 20 个 `diff --git`（4 新增 / 5 删除） |

**最终测试基线**：`realserver-oms` **59/59 绿**（原 50 → 新增 9）。












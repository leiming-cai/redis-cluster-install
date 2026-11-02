# 设计：交付树集群修复 —— monitor 集群分支 + D7-b 源码对齐 + D2/D8 收口 + `oms:` 归位

**日期**：2026-11-02
**轮次**：华盾 napstar2.0 集群测试轮之后的第一轮修复
**状态**：设计已确认（用户逐条确认 D1–D4；D2 范围 = **全部 4 个类，含 `CacheServiceImpl`**）
**相关**：
- 上一轮存档：`docs/superpowers/sessions/2026-11-02-hd-redis-cluster-test.md`（D6 / D7-a / D7-b / D8）
- 上一轮 spec：`docs/superpowers/specs/2026-11-01-hd-redis-cluster-test-design.md`
- 缺陷清单：`docker/hd-napstar/DEFECTS.md`

> ⚠️ **2026-11-02 树名更正（后补）**：本文里的「**门户树**」/「**portal/SVN 树**」
> 指的是 `D:\javawork\1.2\cpscloud1.0\code` —— **那是「基线」，不是门户**。
> 真正的门户树是 `D:\work\info\web\extendsystem\集控-IV区门户\code`，
> **此前从未被检查过**。树图见 `docs/superpowers/sessions/2026-11-02-tree-map.md`。
> **本文的结论本身不受影响** —— 改的只是那棵树的**名字**。
---

## 一、为什么有这一轮

上一轮把底层集群（L0-L6，39 PASS）和应用层（A/B/C/D/E，32 PASS / 2 FAIL / 1 SKIP）都实测过了。
**底层集群是好的；华盾应用在集群模式下是坏的**，实测出两个真缺陷（D7-a / D7-b）和一个交付包事故（D8）。

本轮把上一轮存档 §九「下一轮的入口」的 5 项做完，并在做之前**重新核对了依赖解析**——
**核对结果推翻了存档里的两处结论，缩小了工作量，也暴露了一个新的风险。**

### 1.1 更正一：「jar 赢过 Nacos」只对**门户树编的 jar**成立

| | `application.yml` 里的 `oms:` 块 | 谁赢 |
|---|---|---|
| **树 A（交付树）** `web-controller:108` / `modelserver/controller:92` / `rtdata-consumer:43` | **`# oms:`（注释着）** | ✅ **Nacos 赢** |
| **树 B（门户树）** 同样三处 | **`oms:` 活的**（`redisMode: cluster` / `clusters:[127.0.0.1:6379]` / `password: ""`） | ❌ jar 赢 |

上一轮 §3.1「Nacos 赢不了 jar」那条证据，是在 **D8 那个门户树 jar**（`c41735d8`）上取的。
交付树编出来的 jar 里**根本没有 `oms:` 块** → **Nacos 是唯一配置源**。

⇒ 直接给出 **item 5 的答案：生产上 `oms:` 放 Nacos**，且
`docs/OPERATIONS.md` §4.5 上一轮被改掉的结论要**回改**（不是「不生效」）。

### 1.2 更正二：「5 个调用点」是**文件数**；实际是 7 处，而且**平台侧那处已经被基线解决**

上一轮的数字是在**当时部署的 jar** 上扫出来的，那些 jar 是 11-01 用**旧 pom** 编的
（那时 `[3.0.0,4.0.0)` 让 reactor 替换生效 → `rtdata-module-3.0.0` 也进包了）。
拆开看：

| 当时部署的 jar | 裸 `executePipelined` | 文件数 | 处数 |
|---|---|---|---|
| `monitor-3.0.0.jar`（树 A 自编，**无补丁**） | 4 个文件 | 4 | **6** |
| `rtdata-module-3.0.0.jar`（树 A 自编，**无补丁**） | 1 个文件 | 1 | 1 |
| `model-service-1.0.14.jar`（基线，**有补丁**） | 0 | 0 | 0 |

⇒ **「5 个调用点」是文件数；实际 7 处**。
**平台侧的 `CacheServiceImpl` 从来不是缺陷** —— 它在 `model-service-1.0.14` 里，
那个 jar 带着集群分支（§1.3 实测）。

另外，`executePipelined` 之外，`redisTemplate.execute(cb, true, true)` 在 SDR 2.7.18 里
**同样会调 `openPipeline()`** → 集群下一样抛 UOE。
实测（`javap -c spring-data-redis-2.7.18.jar`）：

```
public <T> T execute(RedisCallback<T>, boolean, boolean);
   58: iload_3                  // pipeline 参数
   59: ifeq 74
   62: iload 8
   64: ifne 74
   67: aload 7
   69: invokeinterface RedisConnection.openPipeline:()V   ← 同样炸
```

⇒ 扫「集群不安全点」时**不能只扫 `executePipelined`**，还要扫 `execute(cb, true, true)`
和 `redisTemplate.keys(...)`。

### 1.3 更正三：根因不是「树 A 的 platform 源码没进包」，而是「**进包的那几个 platform 模块是基线，而基线才是打过补丁的**」

**实测依赖树**（树 A 当前 pom，离线 `mvn -o dependency:tree`）：

```
Building model-controller 3.0.0
 +- com.sac.platform:model-service:jar:1.0.14:compile
 |  +- com.sac.platform:realserver-oms:jar:1.0.14:compile
 +- com.sac.platform:util:jar:1.0.14:compile
 +- com.sac.platform:taskmanage:jar:1.0.14:compile

Building web-controller 3.0.0
 +- com.sac.platform:model-service:jar:1.0.14:compile
 +- com.sac.platform:realserver-service:jar:1.0.14:compile
 +- com.sac.platform:realserver-oms:jar:1.0.14:compile

Building rtdata-consumer 3.0.0
 +- com.sac.platform:realserver-service:jar:1.0.14:compile
 +- com.sac.platform:realserver-oms:jar:1.0.14:compile
 \- com.sac.platform:rtdata-module:jar:1.0.14:compile
```

机制：`platform/backend/pom.xml:38` 写的是
`<platform.version>[1.0.0,2.0.0)</platform.version>`，
**3.0.0 不在这个区间内 → Maven 不做 reactor 替换 → 从共享 `mvnRepo` 取 1.0.14**。

全量实测（`dependency:list -DincludeGroupIds=com.sac.platform`）——
**每一个 `com.sac.platform` 依赖都是 1.0.14**：

```
util / userentity / publicentity / model-entity / model-dao / orm / springconfig /
userservice / userdao / idgenerator / napstaroa-dao / model-interface / menuservice /
menudao / menuentity / transnapstardata-dao / realserver-service / realserver-entity /
realserver-dao / model-service / realserver-oms          ← 全部 1.0.14
```

⇒ **树 A 的 platform 源码整体不进包**（`modelserver/{dao,services,interface}`、
`realserver/plugins/*` 编出来的 3.0.0 都被丢弃）。
**唯一还以树 A 源码形态进包的是 application 侧的 `monitor-3.0.0`**。

**而 `mvnRepo` 里的 1.0.14 是打过集群补丁的**（全量扫描 `com/sac/platform/*/1.0.14/*.jar`，
按「class 字节里是否出现 `isCluster`」统计）：

| 1.0.14 jar | 含 `isCluster` 的 class | 对应源码 | 内容 |
|---|---|---|---|
| `realserver-oms` | 14 | `common/oms`（树 A **没有这个模块**） | 集群工具箱 |
| `model-service` | 1（`impl/q.class` = 混淆后的 `CacheServiceImpl`） | `modelserver/services` | 5 个集群分支 |
| `rtdata-module` | 4 | `realserver/plugins/rtdata-module` | 集群写路径 + `writeWithRetry` + `.join()` |

`javap` 实测 1.0.14 的 `rtdata-module`：

```
OmsWriteByKafkaServiceImpl:
  private void writeWithRetry(String, String, List, Runnable)     ← 存在，被调用 3 次
  121: invokeinterface RedisRealDataService.wirteOmsPip(...)Ljava/util/concurrent/CompletableFuture;
       11: invokevirtual  CompletableFuture.join()Ljava/lang/Object;   ← join() 在
  private final boolean isCluster;
RedisRealDataServiceImpl:
  isCluster → batchWirteOmsByRedisCluster → clusterPipeline.putAllHashes(Map)
```

`model-service-1.0.14` 里的 `impl/q.class`：

```
Compiled from "CacheServiceImpl.java"
public class com.sac.platform.modelserver.service.impl.q implements CacheService {
  private com.sac.platform.realserver.oms.utils.RedisClusterHelper redisClusterHelper;
  private boolean b();        // = isCluster()
  public void clearModelCache(); / initAttributeType(); / initWiringPossibility();
  public void initObjectAttribute(); / initEnumDict();
}
```

⇒ **树 B（门户/SVN 工作副本）就是平台基线树**（它的 `platform/backend/pom.xml` 是
`<version>1.0.14</version>`），**它的源码里有全套集群补丁，而且已经 install 进 `mvnRepo`**。

### 1.4 结论：交付物里唯一还带裸 `executePipelined` 的，是树 A 自己编的 `monitor`

⚠️ **「现在部署的」和「按当前 pom 重编后」不一样** —— 上一轮的 C2/C3 FAIL 就是这么来的：

| 交付物 | **现在部署的**（11-01 用旧 pom 编） | **按当前 pom 重编后** | 还裸用 pipeline 吗 |
|---|---|---|---|
| `rtdata-consumer` | `rtdata-module-**3.0.0**`（树 A 自编，**无补丁**）❌ | `rtdata-module-**1.0.14**`（基线，**有补丁**）✅ | 旧：**是** → 新：**否** |
| `model-controller` | `model-service-**1.0.14**`（门户树 jar 带的）✅ | `model-service-**1.0.14**` ✅ | 否 |
| `web-controller` | `monitor-**3.0.0**`（树 A 自编，**无补丁**）❌ | `monitor-**3.0.0**` ❌ | **是（6 处）** |

⇒ **重编本身就可能把 rtdata-consumer 的 C2/C3 从 FAIL 变成 PASS**
（上一轮那两个 FAIL 的直接原因就是部署了 `rtdata-module-3.0.0`）。
⇒ **`monitor` 是唯一必须改源码的交付物** —— 它是树 A 自编的，且**没有**基线版本可替代。

`application/backend/pom.xml:32` `<app.version>[3.0.0,4.0.0)</app.version>`
→ `monitor:3.0.0` **在区间内 → reactor 替换生效 → 树 A 的 monitor 源码进包**。

---

## 二、范围

### 2.1 item 1（🔴）集群分支移植 —— **4 个文件 / 6 处**

树 A `application/backend/napstarweb/monitor`：

| # | 文件（相对 `monitor/src/main/java/com/sac/application/napstarweb/monitor/`） | 行 | 形态（实测回调体） | 集群分支方案 |
|---|---|---|---|---|
| 1 | `services/SVGParseService.java`（方法 `parseAllUseTag`，回调体 653-1755） | 653 | **多 key 写**：`BASE_SVG_SYMBOL+symbolId`（每个 symbol 一个 key）、`BASE_SVG_SYMBOL+"TextClass:"+symbolId`、`BASE_SVG_DATA`、`BASE_SVG_PARAM+graphId+":RT"` | 抽出 callback → `isCluster ? execute(cb) : executePipelined(cb)`（非 pipeline 模式每条命令按槽路由，**多 key 也安全**） |
| 2 | `services/SVGParseService.java`（方法 `batchGetSymbol`） | 2027 | **多 key** string 读（`BASE_SVG_SYMBOL+id`） | `isCluster ? getAllValues(keys) : executePipelined(...)` |
| 3 | `services/CalculateService.java`（方法 `batchConnectLineDefCache`） | 686 | **多 key** hash 读（`BASE_SVG_CONNECTLINE+svgId`） | `isCluster ? getAllHashes(keys) : executePipelined(...)` |
| 4 | `services/CalculateService.java`（方法 `batchGetParam`） | 718 | **多 key** hash 读（`keyPrefix+param+":RT"`） | `isCluster ? getAllHashes(keys) : executePipelined(...)` |
| 5 | `services/impl/SVGCacheServiceImpl.java`（方法 `loadRTConfigKafka`） | 49 | **单 key** 写（`BASE_SVG_REALSCOPE`） | `isCluster ? execute(cb) : executePipelined(cb)` |
| 6 | `kafka/RTListener.java`（方法 `commitDataIncre`） | 95 | **单 key** 写（`BASE_SVG_DATA`） | `isCluster ? execute(cb) : executePipelined(cb)` |

**不需改**（已实测确认集群安全）：

- `monitor` 里 7 处 `opsForHash().entries(key)` —— 单 key，按槽路由安全
- `SVGCacheServiceImpl` 的 4 处 `redisTemplate.keys(...)` —— SDR 2.7 的
  `JedisClusterKeyCommands.keys` 会在所有 master 上扫并求并集 → **结果正确**（只是 O(N) 慢）；
  树 B 也**没改**它 → 保持一致
- `napstarweb/system` 的 `ServerStatusServicesImpl` —— 单 key `HGET`
- `application/backend-gd/` —— 同一批代码的副本目录，**不参与发版**

**实现约束（重要）**：

- **不能整文件覆盖树 B 的版本**。两棵树的这些文件已经分叉：
  `SVGParseService` 树 A 2063 行 vs 树 B 1933 行（差异 380 行）、
  `CalculateService` 1163 vs 1153、`SVGCacheServiceImpl` 99 vs 104、`RTListener` 139 vs 155。
  ⇒ 只在树 A 的对应位置做**最小手术**，照抄树 B 的**分支形态**。
- **依赖已就位，不改 pom**：
  `monitor/pom.xml:88-91` 已声明 `com.sac.platform:realserver-oms` → 解析 1.0.14；
  `javap` 实测 1.0.14 提供 `RedisClusterHelper.isCluster()`、
  `RedisClusterHashPipeline.getAllHashes(List)→List<Map<String,Object>>` / `getAllValues(List)`。
- **bean 存在**：`web-controller` 的 `@ComponentScan(basePackages={"com.sac"})`
  覆盖 `com.sac.platform.realserver.oms.utils` → `RedisClusterHelper`（`@Component`）
  与 `RedisUtilConfig` 定义的 `redisClusterHashPipeline` 都会被扫到。
- **顺序是承重契约**：多 key 读的返回值必须与入参 `keys` **等长同序**
  （调用方用 `results.get(list.indexOf(t))` 对齐）→ `getAllHashes`/`getAllValues` 满足。
- **已知行为差异（接受）**：cluster 分支下 hSet **立即生效**，standalone 下攒到批次末才落库。
  树 B 的注释里已标为「风险 R2，本轮不修」→ 本轮照抄，不扩大范围。
- **写路径统一用 `execute(cb)`**：非 pipeline 模式下 JedisCluster **按 key 路由**，
  多 key 写（#1）也不会跨槽报错 —— 只是往返变多（每条命令一次 RTT）。
  树 B 的注释已论证「往返变多可接受：每条记录都夹着一次 DB 查询，Redis 不是瓶颈」。

### 2.2 item 2（🔴）D7-b —— **二进制已修好，补源码对齐**

**二进制层面**：`rtdata-module-1.0.14.jar` 已含 `writeWithRetry` + `.join()` + `isCluster`
（§1.3 实测）→ **D7-b 在交付物里已经不是缺陷**。

**源码层面**：树 A 的 platform 源码整体落后于基线 1.0.14。与**集群能力**相关的有 **4 个类**：

| # | 文件（树 A） | 树 A 现状 | 基线 1.0.14 |
|---|---|---|---|
| 1 | `platform/backend/realserver/plugins/rtdata-module/.../service/impl/RedisRealDataServiceImpl.java` | 带 `@Async`、裸 `executePipelined` | `isCluster` 分支 + `groupByKey` + `putAllHashes` |
| 2 | `platform/backend/realserver/plugins/rtdata-module/.../service/impl/OmsWriteByKafkaServiceImpl.java` | `batchWirtePip` 直接 `pop` 掉 `CompletableFuture` | `writeWithRetry` + `.join()` |
| 3 | `platform/backend/realserver/plugins/rtdata-module/.../config/FailSetCounter.java` | **不存在** | 存在（30 行 `LongAdder`） |
| 4 | `platform/backend/modelserver/services/.../service/impl/CacheServiceImpl.java` | 5 处集群盲点（`keys()` + 4× `execute(cb,true,true)`） | 5 个 `isCluster()` 分支 |

⇒ **本项 = 把这 4 个类对齐到 1.0.14 的内容**（= 树 B 的版本）。

**为什么必须做**（本轮新识别的风险，**机制已修正**）：

> ⚠️ **先纠正一个容易写错的说法**：树 A 的 platform 模块版本是 **3.0.0**，
> `mvn install` 装到 `mvnRepo/com/sac/platform/<artifact>/3.0.0/`，
> **与 `1.0.14/` 互不相干 —— 不会「覆盖」基线产物**（实测：两套并存，1.0.14 一个字节都没动）。
>
> **真正的机制是「版本区间会挑版本」**：
>
> | 触发方式 | 需要 `mvn install` 吗 | 后果 |
> |---|---|---|
> | 把区间切回 `[3.0.0,4.0.0)`（pom 里那几行**被注释掉的** `<version>${napstarserver.version}</version>` 就是这个开关） | **不需要**，`mvn package` 时 reactor 自动替换 | 树 A 的**无补丁**源码进包 → 集群能力静默消失 |
> | 发布一个 `1.0.15`（同一版本线的补丁版） | 需要 | 区间 `[1.0.0,2.0.0)` **自动选中更高的 1.0.15** → 无补丁的树 A platform 顶掉 1.0.14 |
>
> ⚠️ **第一条在 11-01 就是生效配置** —— `mvnRepo` 里那批 `3.0.0` 的时间戳
> （`model-service` 00:16 / `rtdata-module` 00:17）就是那次构建留下的。

⇒ 所以 item 2 的目的**不是**「保护 1.0.14 不被覆盖」（它不会被覆盖），
**而是「让树 A 的 platform 源码本身也具备集群能力」** ——
这样无论别人是切区间、还是发 1.0.15，**被选中的那份都带集群分支**。

**附带一条事实**（本轮新查明）：

> `mvnRepo` 里的 `1.0.14` 是 **11-01 00:13–00:15 从基线树当前源码 install 出来的快照**
> （基线树源码 mtime 10-22~10-28，之后未再改）。
> ⇒ **它不是仓库里的正式发布产物，而是「一次本地 install 的快照」。**
> ⇒ 「1.0.14 带集群补丁」是**当前恰好成立**的事实，**不是保证**
> —— 这正是上一轮存档 §4.1·二 担心的那件事，现在有了确切机制。

**item 2 对当前交付物的增量 = 0**（树 A 的 platform 源码当前不进包），
它的价值是**为「切区间 / 发 1.0.15」那一刻做准备**。

**范围边界（本轮明确不做）**：树 A 的 platform 源码与基线 1.0.14 还有**业务逻辑**层面的差异
（不止这 4 个类）。本轮**只对齐影响集群能力的这 4 个类**；
其余差异 → 记进 `DEFECTS.md`，并写明「**在完成整体对齐之前，
禁止对树 A 的 platform 执行 `mvn install`**」。

### 2.3 item 3（🟡）D2 + D8 —— 从交付树重编 `model-controller`

**改哪**：树 A `platform/backend/modelserver/controller/src/main/resources/bootstrap.yml`

```yaml
        # ⚠️ 不再引用 share_base.yaml / ext_base.yaml
        # （这两个 dataId 在安装包的 Nacos 导出包里不存在；
        #   而本应用真正需要的键全都在它自己的 dataId 里）
        shared-configs: []
        extension-configs:
          - data-id: napstarmappingconfig.yaml
            group: DEFAULT_GROUP
            refresh: true
```

（照抄树 B 的形态 + 那段解释性注释。）

**一次同时解决**：
- **D2**：交付树里 `share_base.yaml` / `ext_base.yaml` 的引用被去掉
  （安装包的 Nacos 导出包里 `DEFAULT_GROUP/` 只有 `hisdataproducer-ext.yaml` / `jk.yaml` /
  `napstarmappingconfig.yaml`；DM 那份也一样 → 不是导出遗漏）
- **D8**：jar 里的配置跟交付树同源（不再带门户树的 `oms:` 集群占位符）

**编之前必查**：`target/classes/application.yml` 的 `oms:` 块**仍然是注释的**
（这是「jar 里的配置跟树对得上」的最小检查）。

**编/部署**：

```
mvn -o -pl modelserver/controller -am -DskipTests package      # 绝不 mvn install
```

**新 jar 的 platform 集合**（实测依赖树）：
`model-service-1.0.14` / `model-dao-1.0.14` / `model-interface-1.0.14` /
`model-entity-1.0.14` / `realserver-oms-1.0.14` / `util-1.0.14` / `taskmanage-1.0.14` …
→ **与现在跑着的门户 jar 的 platform 集合一致** → **model-controller 的集群能力不降**。

### 2.4 item 4（🟡）回归前写清 model-controller 是怎么起来的

D8 的教训是「**结论对、推理错**」：jar 文件换回 ≠ 运行中的 JVM 换回。
⇒ 每一轮回归都必须能回答「这个 app 是用哪份 jar、怎么起来的」。

1. `scripts/start-hd-apps.sh`：启动前打印每个应用的
   **jar 路径 + md5 + mtime + 是否有 `--oms.*` 参数**
   （现在这些只散落在注释里，见该文件第 168-179 行）。
2. `scripts/verify-hd-napstar.sh`：A 段把「model-controller 的启动来源」
   作为**必答项**写进 SUMMARY 之前（jar md5 + 生效的 Redis 模式那行日志）。
3. 会话存档里记「本轮 model-controller 用的是哪个 jar、怎么起的」。

**本轮特别重要**：web-controller 的 jar 内容也变了（`model-service` 3.0.0 → 1.0.14）
→ **必须重跑回归，不能沿用上一轮的数字**。

### 2.5 item 5（🟡）生产上 `oms:` 放哪 —— **答案：Nacos**

- 交付树编出来的 jar 里 `oms:` 是注释的 → **Nacos 赢** →
  生产按 `docs/OPERATIONS.md` §4.5 原样做（三个 dataId 各一份）→
  **D6（Redis 密码出现在 JVM 命令行上）在生产不成立**。
- 命令行 `--oms.*` **降级为测试/应急通道**（`HD_REDIS_CLUSTER=1`），不是生产的配置入口。
- **不需要** `bootstrap.yml` 的 override 开关（那是「jar 里要写死 `oms:`」时的补救手段）。

**要改的文档**：

| 文件 | 改什么 |
|---|---|
| `docs/OPERATIONS.md` §4.5 | 上一轮改成「不生效」→ **回改**为「生效，但前提是 jar 里没有活的 `oms:` 块；门户树编的 jar 会把 cluster 占位符固化进产物 → 压过 Nacos」 |
| 上一轮存档 §3.1 | 优先级表加「适用条件」一列 |
| `scripts/start-hd-apps.sh:109-119` | 注释里「jar 内 application.yml 硬编码了 oms.redisMode=cluster」**只对门户 jar 成立** → 要改 |
| `docker/hd-napstar/DEFECTS.md` D6 | 补上「交付树的 jar 没有活 `oms:` → 密码不必上命令行」 |

**待确认**：`napstarweb/plugins/realalarmconsumer/application.yml:46` 有一块**活的** `oms:`
（`standalone` / `node1` / `sac888`）→ 那个 jar 的 `oms:` 会赢过 Nacos。
它不在本轮发版范围 → 记进 DEFECTS，不在本轮处理。

---

## 三、顺序与依赖

```
item 1（monitor 4 文件 6 处）
   └─→ item 2（rtdata-module 源码对齐）        ← 独立于 1，可并行
item 3（重编 model-controller）
   └─→ item 4（回归时记录启动来源）
item 5（文档回改）                            ← 依赖 item 3 之后的实测确认
```

**item 1 / 2 必须先于 item 3**：item 3 会重编并部署三个 jar，
带着未修的 monitor 去编，编出来的还是坏的。

---

## 四、判据（每条都必须**能失败**）

> 判据要能失败：先问「**这个断言在应用坏掉的时候会红吗？**」
> 答不上来，它就不是判据（上一轮存档 §7.1）。

| # | 判据 | 期望 |
|---|---|---|
| 1 | `monitor-3.0.0.jar` 里含 `isCluster` 的 class 数 | **> 0**（当前 = 0） |
| 2 | `monitor-3.0.0.jar` 里**同时含** `isCluster` **和** `executePipelined` 的 class 数 | **≥ 4**（4 个文件都进了分支；单机路径**仍要**保留 `executePipelined`，所以这个数不为 0 是正常的） |
| 2b | 树 A `rtdata-module` 源码里 `CompletableFuture.join` 出现次数 | **≥ 2**（与 1.0.14 字节码实测一致） |
| 3 | `hd-cluster-app-test.sh` 的 **C2**（rtdata-consumer 集群下真读写） | FAIL → **PASS**（**可能重编就过** —— 部署的是 `rtdata-module-3.0.0`，重编后是 1.0.14；判据必须能分辨「因为重编」还是「因为改代码」） |
| 4 | `hd-cluster-app-test.sh` 的 **C3**（无 UOE） | FAIL → **PASS**（同上） |
| 5 | 集群下写失败时日志出现 `write failed after N attempts` | 出现（证明异常不再被吞） |
| 6 | `verify-hd-napstar.sh` base 矩阵 | **47 PASS / 0 FAIL**（与上一轮基线逐条一致） |
| 7 | 新 `model-controller-3.0.0.jar` 的 `BOOT-INF/lib/` | `model-service-1.0.14` / `realserver-oms-1.0.14` 在 |
| 8 | 新 `model-controller-3.0.0.jar` 里的 `application.yml` | `oms:` **是注释的** |
| 9 | 矩阵输出里出现 model-controller 的 jar md5 | 出现 |
| 10 | standalone 下 model-controller 的日志 | `*** Using Redis Standalone at node1:6379`，致命错误 0 |
| 11 | `mvnRepo/com/sac/platform/*/1.0.14/*.jar` 前后 md5 一致 | 一致（本轮绝不 `mvn install`） |
| 12 | 门户前后快照逐项比对 | **0 处差异** |

**判据 1/2 的做法**：用 `unzip -p` + 字节扫描统计 class 文件里是否出现 `isCluster` /
`executePipelined`（`hd-node1` 容器里有 `unzip` / `strings`）。

---

## 五、对既有文档的更正（本轮必须一起改，否则下一轮又会拿错前提做决策）

| # | 位置 | 现在的说法 | 改成 |
|---|---|---|---|
| 1 | 上一轮存档 §3.1 | 「jar 内 application.yml 赢过 Nacos → OPERATIONS.md §4.5 不生效」 | **限定适用条件**：只在 **jar 里有活的 `oms:` 块**时成立；交付树的 jar 没有 → **Nacos 赢** |
| 2 | 上一轮存档 §3.6 | 「同一个交付 jar 里混了两版 platform」 | 更精确：**混的是「基线 1.0.14 + 应用侧自编 3.0.0」**；基线那份**才是打过集群补丁的**；应用侧的 `monitor-3.0.0` 是唯一还裸用 pipeline 的 |
| 3 | 上一轮存档 §9 第 1 条 | 「5 个调用点」 | **4 个文件 6 处**（且**不含**平台侧 —— 平台侧靠基线 1.0.14 解决；`rtdata-module` 那处也由基线解决） |
| 4 | 上一轮存档 §9 第 2 条 | 「D7-b 要移植 `.join()` + `writeWithRetry`」 | **二进制已由 `rtdata-module-1.0.14` 解决**（`javap` 实测有 `writeWithRetry` + `join()`）；剩下的是**源码对齐**（防 `mvn install` 回退） |
| 5 | 上一轮存档 §9 第 6 条 | 「同一个 jar 里混 1.0.14 和 3.0.0 两版 platform，是有意的吗？」 | ✅ **有答案了**（§1.3）：不是有意的 —— 交付物里的 platform 部分**全部**是基线 1.0.14，而基线才是打过集群补丁的那份；application 侧的 `monitor-3.0.0` 是唯一自编的，且**没有**补丁 → 这才是 D7-a 的真正落点 |
| 6 | `docker/hd-napstar/DEFECTS.md` D7-a / D7-b | 「补丁只落在 platform 侧，application 侧没跟上」 | 根因改为：**交付物里 platform 部分来自基线 1.0.14（**有**补丁），application 侧的 `monitor-3.0.0`（**没有**补丁）** |
| 7 | `docker/hd-napstar/DEFECTS.md` D8 | 「jar 被换成门户树编的那份」 | 补上**新事实**：交付树重编后 platform 集合与门户 jar 一致（都取 1.0.14）→ 重编**不会**降集群能力 |
| 8 | 上一轮存档 §4.1·二 | 「1.0.14 是最新的基线产物，所以 D7-a 的修法成立——但这个『是』是**运气**，不是**保证**」 | 补上**机制**：1.0.14 是 **11-01 00:13–00:15 的一次本地 `mvn install` 快照**（不是正式发布产物）；而「区间切回 `[3.0.0,4.0.0)`」**不需要 install** 就能让无补丁源码进包 |

---

## 六、明确不做

| # | 不做 | 原因 |
|---|---|---|
| 1 | 不 `mvn install` | 共享 `mvnRepo`，一次 install 会静默改写华盾树拿到的产物（上一轮存档 §四·4） |
| 2 | 不改 `napstarweb/plugins/realalarmconsumer` 的活 `oms:` 块 | 不在本轮发版范围；记进 DEFECTS |
| 3 | 不改 `application/backend-gd/`（副本目录） | 不参与发版 |
| 4 | 不改 `sche-viewer-server` 的 15 处裸 `executePipelined` | 当前 standalone，暂不参与构建；**将来切集群前必须一并处理**（记进 DEFECTS） |
| 5 | 不改 `napstarweb/monitor` 的 4 处 `redisTemplate.keys(...)` | 结果正确，只是慢；树 B 也没改 → 保持两棵树一致 |
| 6 | 不动 `hisDataProducer` / `hisDataSend` | D1：PG 驱动缺失，用户已决定不修改这两个模块 |
| 7 | 不新增 platform 模块 | 集群工具箱（`realserver-oms`）已在 classpath 上，缺的是调用点 |

---

## 七、风险

| # | 风险 | 怎么防 |
|---|---|---|
| R1 | **monitor 改动引入回归**（standalone 路径） | base 矩阵必须回到 **47 PASS / 0 FAIL**，与上一轮基线逐条一致；判据 6 |
| R2 | 改坏「返回值与入参等长同序」的契约 | 多 key 读只允许用 `getAllHashes`/`getAllValues`（它们的契约就是等长同序）；改完逐个核对 `results.get(list.indexOf(t))` 的对齐关系 |
| R3 | **树 B 的文件覆盖树 A 的文件** → 丢掉树 A 后来的改动 | 只做最小手术，禁止整文件替换；改完 diff 逐行核对（`Compare-Object`） |
| R4 | `rtdata-module` 源码对齐后**行为与 1.0.14 有细微差异** | 对齐时以 **1.0.14 的字节码为准**（`javap -c` 已记录方法与调用点），不是凭印象抄树 B |
| R5 | **有人切版本区间 / 发 1.0.15** → 树 A 的无补丁 platform 被选中 → 集群修复静默消失 | 本轮**绝不 install**（判据 11）；**item 2 把树 A 的 platform 源码补齐**（切开关的前置条件）；DEFECTS 里留档并写明「切区间前必须先做 item 2 + 回归」 |
| R6 | 换 jar 后回归数字不可比 | item 4：矩阵必须打出 jar md5；换过 jar 的回归必须重跑 |
| R7 | `RedisClusterHelper` bean 缺失导致启动失败 | 1.0.14 的 `CacheServiceImpl` 有 `@Autowired RedisClusterHelper` → 部署后**必须看启动日志**（判据 10） |

---

*本设计基于 2026-11-02 的实测（依赖树、jar 字节码扫描、`javap` 反编译、文件行号核对）。
所有"通过"都有原始输出支撑。*
*上一份存档：`docs/superpowers/sessions/2026-11-02-hd-redis-cluster-test.md`。*

# 统一 Redis 连接基础设施 —— 设计文档

**日期**：2026-10-28
**状态**：待评审（v2 —— 根据"realserver-oms 已是统一模块"的反馈修订）
**涉及工程**：`realserver`、`modelserver`、`napstarweb`（三个独立部署的进程）
**配置前缀**：沿用 `oms.*`（不改名，避免与 Nacos 现有配置脱节）

> **v2 修订说明**：v1 提出的"新建 `common/redis-starter` 中立模块"**作废**。
> `realserver-oms` **已经是**为此而抽出的共享模块，v1 属于重复劳动。
> 本版改为：**给已有的 `realserver-oms` 做减法（瘦身）**，而不是再造一个模块。
> 详见 §5。

---

## 一、问题陈述

三个工程各自部署、独立进程，需要用**同一套 Redis 连接配置与同一份连接代码**。
当前状态是"**事实上共用、但没设计过**"，导致四个具体缺陷。

### 1.1 现状实测

| 工程 | 部署形态 | Redis 连接来源 | `oms:` 配置块 |
|---|---|---|---|
| `realserver/controller` | 独立进程 | `realserver-oms` 的 `RedisUtilConfig` | **全注释**（`application.yml:22-27`） |
| `realserver/rtdata-consumer` | 独立进程 | 同上 | jar 内 `application.yml`（E2E 临时地址，**唯一填了真值的**） |
| `modelserver/controller` | 独立进程 | **同一份**（经 `idgenerator` 传递依赖 + `@ComponentScan("com.sac.platform")`） | **全注释**（`application.yml:89-96`） |
| `napstarweb/web-controller` | 独立进程 | **同一份**（经 `realserver-service` 传递依赖 + `@ComponentScan("com.sac")`） | **全注释**（`application.yml:108-113`） |

`realserver-oms` 的 `pom.xml` 自述：

```xml
<artifactId>realserver-oms</artifactId>
<name>realserver-oms</name>
<description>realserver oms</description>
```

并在根 `backend/pom.xml` 的 `dependencyManagement` 中统一版本管理
（`platform.version=[1.0.0,2.0.0)`）。

**结论：统一模块已经存在且已被三个工程共用。连接代码是统一的，配置层完全没跟上。**

依赖链实测：

```
backend/pom.xml (aggregator, artifactId: icms)
 ├─ common/idgenerator
 │    └─ depends on com.sac.platform:realserver-oms
 └─ realserver/common/oms (artifactId: realserver-oms)
      ├─ RedisUtilConfig          ← 唯一的 Redis 连接工厂配置
      ├─ RedisConfigProperties / RedisPropertiesConfig
      ├─ RedisClusterHelper / RedisScanUtils / RedisPipelineUtil
      ├─ RedisClusterHashPipeline
      ├─ RedisUtil
      └─ JedisUtils / JedisPoolUtils   ← 死代码
      └─ depends on realserver-entity ← ★ 问题所在

modelserver/controller → idgenerator → realserver-oms
modelserver/services   → idgenerator → realserver-oms
napstarweb/monitor     → realserver-service → realserver-oms
napstarweb/napstar-app → realserver-service → realserver-oms
```

### 1.2 四个缺陷

#### 缺陷 A（P0）：`oms:` 配置块全注释 → 启动失败

三个应用的 `application.yml` 里 `oms:` 块全部是注释（`realserver/controller:22-27`、
`modelserver/controller:89-96`、`napstarweb/web-controller:108-113`）：

```yaml
# oms:
#   database: 0
#   hostname: 10.137.220.108
#   port: 6379
#   password: sac888
#   timeout: 5000
```

`oms.redisMode` 缺失 → `RedisUtilConfig.parseMode` 返回 `STANDALONE`
（`RedisUtilConfig.java:71-83`）→ `RedisStandaloneConfig` 的
`@ConditionalOnExpression("'${oms.redisMode:standalone}' == 'standalone'")` 命中 →
`RedisUtilConfig.java:274-277` 因 `oms.hostname`/`oms.port` 为空抛
`IllegalStateException` → **应用启动失败**。

这三个应用目前能跑，**完全依赖 Nacos 补齐 `oms.*`**。Nacos 一旦漏配或改 dataId，
就是启动期硬失败，且报错信息不指向真实原因。

#### 缺陷 B（P0）：`RedisPropertiesConfig` bean 名冲突 → 跨工程复用配置行不通

`realserver-oms` 的 `RedisPropertiesConfig.java:18-21` 定义了 bean
`redisConfigProperties`（`@ConfigurationProperties(prefix = "oms")`）。

**实测发现：同一份「在消费方加一份自己的 `RedisPropertiesConfig`」的尝试，
在三个工程里各留了一个被注释掉的墓碑，内容完全相同：**

| 墓碑文件 | 行数 |
|---|---|
| `napstarweb/web-controller/…/config/RedisPropertiesConfig.java` | 35（全注释） |
| `modelserver/controller/…/config/RedisPropertiesConfig.java` | 26（全注释） |
| `realserver/plugins/rtdata-module/…/config/RedisPropertiesConfig.java` | 32（全注释） |

三者的内容都是：

```java
import com.sac.platform.realserver.oms.config.RedisConfigProperties;

@Configuration
public class RedisPropertiesConfig {
    @Bean
    @ConfigurationProperties(prefix = "oms")
    public RedisConfigProperties redisConfigProperties() { return new RedisConfigProperties(); }
}
```

**失败原因（三者相同）**：同一个类 + 同一个前缀 `@ConfigurationProperties(prefix="oms")`
+ **同一个 bean 名 `redisConfigProperties`** → 与 `realserver-oms` 里那份**重复定义**
→ `ConflictingBeanDefinitionException`。

而这正是"每个工程自己加一份"的必然结果：三个工程的 `@ComponentScan` 都会扫到
`com.sac.platform.realserver.oms.config`（`napstarweb` 扫 `com.sac`、
`modelserver` 扫 `com.sac.platform`、`realserver/controller` 扫 `com.sac.platform.realserver`
—— `realserver-oms` 的包名 `com.sac.platform.realserver.oms.*` 在其下）。

> **三个墓碑是同一个教训的三次重复**：这个问题的正确解法不是"每个工程各加一份"，
> 而是**全局只保留一份**。§4.1 改动 1 就是把那唯一的 bean 改个不会撞的名字，
> 并把三个墓碑删掉。

#### 缺陷 C（P1）：`realserver-oms` 依赖 `realserver-entity` → 基础设施层被业务实体污染

`realserver-oms/pom.xml` 声明了对 `realserver-entity` 的依赖。
而 `realserver-entity` 的全部内容是 **4 个实时数据域业务实体**：

```
com/sac/platform/realserver/entity/HashData.java
com/sac/platform/realserver/entity/RealAttribute.java
com/sac/platform/realserver/entity/RealData.java
com/sac/platform/realserver/entity/RealRequest.java
```

`realserver-entity` **不是共享模块** —— 实测只有 realserver 自己的
`oms` / `controller` / `dao` / `services` / `entity` 五个模块用它。

**耦合点是唯一的**（全仓库 grep `HashData` 实测，17 处匹配中与本缺陷相关的只有）：

```java
// realserver-oms/…/utils/RedisPipelineUtil.java:23
import com.sac.platform.realserver.entity.HashData;

public void opsHashSetPipeByHashData(List<HashData> hashDatas) { … }   // :271
```

唯一调用方：`OmsWriteDaoImpl.java:146`。

**后果**：

```
common/idgenerator (公共库)
  → realserver-oms → realserver-entity → 实时数据域实体
```

`idgenerator` 为了用一个 Redis 工具类，被迫拖进整个实时数据实体层。
`napstarweb`（告警/曲线/报表）也走同一条链 —— 它的业务与实时数据域毫无关系。

**`HashData` 本身只是一个 3 字段 DTO**（`key` / `fied` / `value`，67 行），
去掉这个耦合的代价极低。

#### 缺陷 D（P2）：共享模块里有 2100+ 行死代码，其中含集群不安全的方法

`realserver-oms` 当前的 10 个类：

| 类 | 行数量级 | 状态 |
|---|---|---|
| `RedisUtil.java` | ~1400 | 活，但含 **13 个集群不安全的死方法** |
| `JedisUtils.java` | ~700 | **整体死代码**（单节点 + `jedis.select()`，集群不支持） |
| `JedisPoolUtils.java` | ~50 | **整体死代码**（静态读不存在的 `jedis.properties` → 一旦调用即 NPE） |
| 其余 7 个 | — | 活 |

**三个工程共用的模块里，放着单节点 Jedis 工具和一个坏掉一半的 `RedisUtil`**，
是"一次手滑就是生产 CROSSSLOT"的地雷（§7 列出了具体清单）。

---

## 二、目标与非目标

### 2.1 目标

| # | 目标 | 验证方式 |
|---|---|---|
| G1 | 三个工程的 Redis 连接配置来自**同一份契约**（`oms.*`），且**不依赖 Nacos 是否补齐**就能启动 | 三个应用在**无 Nacos** 环境下用本地 `application.yml` 启动成功 |
| G2 | 消除 `RedisPropertiesConfig` bean 名冲突 | 三个工程中全局只存在一份 `@ConfigurationProperties(prefix="oms")` |
| G3 | `realserver-oms` 不再依赖 `realserver-entity` → 基础设施层与业务实体解耦 | `realserver-oms/pom.xml` 中 `realserver-entity` 依赖消失；`common/idgenerator` 的依赖树不再包含 `realserver-entity` |
| G4 | 连接池参数可按应用配置 | `oms.maxTotal` 等可在各应用 `application.yml` 覆盖 |
| G5 | 保留单机 / 哨兵 / 集群三种模式 | `RedisUtilConfig` 的三个 `@ConditionalOnExpression` 分支行为不变 |
| G6 | 共享模块里没有死代码与集群不安全的方法 | `JedisUtils` / `JedisPoolUtils` 删除；`RedisUtil` 的 13 个方法删除或 `@Deprecated` |

### 2.2 非目标（明确不做）

| # | 不做 | 理由 |
|---|---|---|
| N1 | **不注入 `JedisCluster` bean** | 见 §3.1。会造成第二个实例 → 连接池翻倍、slot 缓存分裂 |
| N2 | **不跨进程共享同一个连接池实例** | 三个进程独立部署，物理上不可能共享连接。统一的是**配置与代码** |
| N3 | **不改 `oms.*` 前缀** | 改名会与 Nacos 现有配置脱节 |
| N4 | **不新建 `common/redis-starter`** | `realserver-oms` 已是共享模块（v1 的方案作废） |
| N5 | **不移动 `realserver-oms` 的目录位置** | 见 §5.2 的取舍 |
| N6 | **不改 `realserver-oms` 的 artifactId** | 三个工程的 `pom.xml` 都不用改，迁移面最小 |
| N7 | **不改变 Redis 数据格式 / 序列化器** | 存量数据不可变 |
| N8 | **不合并 `idgenerator` / `modelserver` 各自的三套 `RedisUtil`** | 与本轮正交，另开一轮 |

---

## 三、关键设计决策

### 3.1 决策一：不注入 `JedisCluster`，注入的是"连接工厂"（已经是全局单例）

**事实基础**（反编译 `spring-data-redis-2.7.18` + `jedis-3.10.0` 验证）：

```
JedisConnectionFactory.afterPropertiesSet():
  221: invokespecial createCluster()   ← 创建 JedisCluster
  224: putfield      cluster            ← 存入 factory 私有字段
JedisConnectionFactory.destroy():
  Pool.destroy()                        ← 销毁
JedisConnectionFactory.getClusterConnection():
  26: getfield  cluster                 ← 返回同一个实例
  new JedisClusterConnection(cluster, …) ← 包装它
```

`getNativeConnection()` 返回的就是 factory 持有的**那一个 singleton**。
当前 `RedisClusterHashPipeline` 与 `RedisScanUtils` 都通过它获取，**现状是正确的、已共享的**。

**如果自己注入一个 `JedisCluster` bean：**
- 第二个 `JedisCluster` 实例 → 各自的 slot 缓存、各自的每节点连接池
- `maxTotal=200` 实际变成 400
- `RedisClusterHashPipeline.java:200` 明确"本类不共享 `JedisCluster` 的 slot 缓存，
  连接级失败必须自己刷新拓扑" —— 这个精心设计的边界会被破坏
- 单机/哨兵模式下 `JedisCluster` **不存在** → 要么启动失败，要么需要永远返回 null 的占位 bean

**结论**：正确的抽象是 `RedisConnectionFactory`（已经是全局单例 bean），而不是 `JedisCluster`。

### 3.2 决策二：给已有的 `realserver-oms` 瘦身，而不是新建模块

`realserver-oms` 已经承担了"共享 Redis 基础设施"的职责，**位置和命名的问题
（叫 `oms`、放在 `realserver/` 下）是命名问题，不是结构问题**。

三个候选与取舍：

| 方案 | 做法 | 评价 |
|---|---|---|
| **A. 新建 `common/redis-starter`** | 抽一个新的中立模块 | ❌ **作废**（v1）：重复劳动，且要改三个工程的 pom |
| **B. 瘦身 `realserver-oms`** | 去掉对 `realserver-entity` 的依赖；删死代码 | ✅ **采纳**：改动面最小，消除根因，不动 pom |
| **C. 拆分两个 artifactId** | 基础设施与实体侧彻底分开 | ❌ 过度：`realserver-entity` 只有 realserver 自己用，拆分收益低、改动面大 |

**采纳 B 的理由**：
- 缺陷 C 的根因是**一条依赖边**（`realserver-oms → realserver-entity`），
  去掉它就解决了，不需要动目录、不需要动 artifactId、不需要改任何 pom
- 三个工程的依赖关系**完全不变** → 回归面最小
- 命名问题（`oms`）在 §5.2 单独评估

### 3.3 决策三：`oms.*` 前缀保持不变，但**必须能脱离 Nacos 独立工作**

`oms.*` 保留，但每个应用的**本地 `application.yml` 里必须有完整的 `oms:` 块**，
Nacos 用来**覆盖**而不是**提供**。

这样：
- Nacos 漏配 → 应用仍能用本地配置启动（而不是硬失败）
- Nacos 正常 → 覆盖生效，行为不变

**这是缺陷 A 的根治办法**：把"Nacos 是唯一配置来源"改成"Nacos 是配置覆盖层"。

### 3.4 决策四：分步走，每步单独取证

依据 HANDOFF 里反复出现的教训 ——"**一次只改一件事，改完立刻取证**"。

| 步骤 | 内容 | 风险 | 取证 |
|---|---|---|---|
| **第一步** | 修配置契约（§4） | 低 | 三个应用本地启动 + 连接验证 |
| **第二步** | `realserver-oms` 瘦身（§5） | 中 | 全量编译 + 三个应用启动 + 依赖树核对 |

---

## 四、第一步：修配置契约

### 4.1 改动清单

| # | 文件 | 改动 | 目的 |
|---|---|---|---|
| 1 | `realserver-oms/…/config/RedisPropertiesConfig.java` | bean 名 `redisConfigProperties` → **`omsRedisConfigProperties`** | 缺陷 B |
| 2 | `realserver-oms/…/config/RedisUtilConfig.java` | 注入点改用新 bean 名 | 跟随改动 1 |
| 3 | `modelserver/controller/src/main/resources/application.yml` | `oms:` 块**取消注释并补全** | 缺陷 A |
| 4 | `napstarweb/web-controller/src/main/resources/application.yml` | 同上 | 缺陷 A |
| 3b | `realserver/controller/src/main/resources/application.yml` | 同上 | 缺陷 A |
| 5 | `napstarweb/web-controller/…/config/RedisPropertiesConfig.java` | **删除整个文件**（墓碑） | 缺陷 B |
| 6 | `modelserver/controller/…/config/RedisPropertiesConfig.java` | **删除整个文件**（墓碑） | 缺陷 B |
| 7 | `realserver/plugins/rtdata-module/…/config/RedisPropertiesConfig.java` | **删除整个文件**（墓碑） | 缺陷 B |
| 8 | `realserver-oms/…/config/RedisUtilConfig.java` | 连接池参数文档化（**已是** `maxTotal`/`maxIdle`/`minIdle`，补默认值说明） | 目标 G4 |

> **改动 1 的影响面已实测**：`redisConfigProperties` 这个 **bean 名**
> 在全仓库只有 1 处**定义**（`realserver-oms/…/RedisPropertiesConfig.java:20`）；
> 其余 55 处匹配都是**方法参数名**（`RedisConfigProperties redisConfigProperties`），
> **不是按名注入** —— Spring 按**类型**注入，参数名与 bean 名无关。
>
> **结论：改动 1 的实际风险接近零**，比原先估计的 R2（"中"）低得多。

### 4.2 `oms:` 块的统一契约

三个应用的本地 `application.yml` 使用**完全相同**的结构：

```yaml
oms:
  redisMode: cluster          # standalone | cluster | sentinel
  clusters:                   # redisMode=cluster 时必填
    - <A机IP>:6379
    - <A机IP>:6380
    - <B机IP>:6382
  password: <密码>
  database: 0                 # 集群模式忽略（Redis Cluster 只支持 db 0）
  timeout: 5000
  connectTimeout: 2000
  readTimeout: 5000
  maxWait: 3000
  maxTotal: 200
  maxIdle: 50
  minIdle: 10
```

**约定**：
- `redisMode` **显式写出**，不依赖默认值（默认值 `standalone` 是缺陷 A 的帮凶）
- 集群模式**必须**填 `clusters`
- `sentinel` 模式另需 `sentinels` / `masterName` / `sentinelsPassword`
- 值由 Nacos 覆盖时保持同一结构

### 4.3 配置加载顺序的验证（第一步最大的不确定性）

`oms.*` 有两个来源：本地 `application.yml` 与 Nacos。
`realserver/rtdata-consumer` 已在第十一轮验证过 Nacos 开关必须在命令行
（`spring.cloud.nacos.config.enabled=false` 写在 `application.yml` 里不生效，
因为 Nacos 客户端在 bootstrap 阶段创建）。

**实施时必须验证**：在 `bootstrap.yml` 正确配置 Nacos 的前提下，
本地 `application.yml` 的 `oms:` 块能否作为兜底生效。

> 若 Nacos 在 bootstrap 阶段就用空值覆盖了 `oms.*`，兜底不成立，
> 则需要换机制（见 §6 风险 R1）。

### 4.4 第一步的取证

| 检查 | 判据 |
|---|---|
| 三个应用本地启动（**断开 Nacos**） | 启动成功，日志出现 `*** Using Redis Cluster with nodes: …` |
| 集群写入 | `redis-cli -c HSET real_data:11:<obid> f v` → `GET` 读回一致 |
| bean 唯一性 | 启动日志中 `redisConfigProperties` 只出现一次；无 `ConflictingBeanDefinitionException` |
| 回归 | `realserver` 现有 64 条单测（oms 50 + rtdata 14）全绿 |

---

## 五、第二步：`realserver-oms` 瘦身

### 5.1 改动清单

#### 5.1.1 去掉对 `realserver-entity` 的依赖（缺陷 C / 目标 G3）

| # | 文件 | 改动 |
|---|---|---|
| 1 | `realserver-oms/pom.xml` | 删除对 `com.sac.platform:realserver-entity` 的依赖 |
| 2 | `realserver-oms/…/utils/RedisPipelineUtil.java` | 删除 `import …entity.HashData`；`opsHashSetPipeByHashData(List<HashData>)` → **改为不依赖实体的形式** |
| 3 | `realserver/dao/…/impl/OmsWriteDaoImpl.java` | 调用点适配新签名 |

**新签名的两种候选**：

| 候选 | 签名 | 评价 |
|---|---|---|
| **A1** | `opsHashSetPipeByHashData(Map<String, Map<String, Object>> grouped)` | 与已有的 `opsHashSetPipe(Map<String,Map<String,Object>>)` **完全重复** |
| **A2** | 保留方法名，参数改为 `List<Map.Entry<String, Map.Entry<String, Object>>>` | 结构奇怪，序列化器的 `Object` 值类型也要跟着改 |

**采纳**：**A1** —— 但**不新增方法**，而是**让 `OmsWriteDaoImpl` 直接调用已有的
`opsHashSetPipe(Map<String, Map<String, Object>>)`**（`RedisPipelineUtil.java:150-170`）。
两者在集群分支下的实现**逐字等价**：

```java
// opsHashSetPipeByHashData 的集群分支（现行 :275-282）
Map<String, Map<String, Object>> grouped = new LinkedHashMap<>();
for (HashData hashData : hashDatas) {
    grouped.computeIfAbsent(hashData.getKey(), k -> new LinkedHashMap<>())
            .put(hashData.getFied(), hashData.getValue());
}
grouped.forEach(redisTemplate.opsForHash()::putAll);

// opsHashSetPipe 的集群分支（:154-156）
map.forEach(redisTemplate.opsForHash()::putAll);
```

**因此 `opsHashSetPipeByHashData` 可以整个删除**，
`OmsWriteDaoImpl.batchWriteByHashData` 改为：把 `List<HashData>` 聚成
`Map<String, Map<String, Object>>` 后调 `opsHashSetPipe`。
**分组逻辑挪到调用方（`realserver-dao`）—— 那才是业务侧该做的事。**

> 单机分支也等价：`opsHashSetPipe` 的单机分支对每个 key 的每个 field 发一次 `hSet`
> （`:158-168`），与 `opsHashSetPipeByHashData` 的单机分支（`:284-292`）语义相同。
>
> **净效果**：`realserver-oms` 少一个方法、少一条依赖；
> `realserver-dao` 多几行分组代码（那里本来就 import 了 `HashData`）。
>
> **已决策（2026-10-28 评审）**：采纳 A1，**删除** `opsHashSetPipeByHashData`。

#### 5.1.2 清理死代码（缺陷 D / 目标 G6）

| # | 文件 | 改动 | 依据 |
|---|---|---|---|
| 4 | `realserver-oms/…/utils/JedisUtils.java` | **整个删除**（~700 行） | 全仓库零调用方；`jedis.select()` 在集群下非法 |
| 5 | `realserver-oms/…/utils/JedisPoolUtils.java` | **整个删除**（~50 行） | 静态初始化读不存在的 `jedis.properties` → 调用即 NPE；唯一调用方 `OmsWriteByKafkaServiceImpl:268` 在 `isCluster` 分支外 |
| 6 | `realserver-oms/…/utils/RedisUtil.java` | 13 个集群不安全的死方法：**加 `@Deprecated` 保留**，不删除 | 全部无调用方；保留可避免破坏潜在的外部/反射调用 |
| 7 | `realserver-oms/…/utils/RedisUtil.java` | 修正 `CacheServiceImpl:73-74` 那类**错误注释** | 见 §7.2 |

> **已决策（2026-10-28 评审）**：13 个方法采用 **`@Deprecated` 保留**，不删除。
> 理由：删除虽然零风险（已验证无调用方），但 `@Deprecated` 保留了 API 兼容性，
> 且能在 IDE / 编译警告里**主动提示**后续使用者"这个方法在集群下不安全"——
> 删除则只是让它们悄悄消失，下一个人可能重新写一个。
> 每个方法加 `@Deprecated` 时**必须同时加一行 javadoc 说明集群下的正确做法**，
> 例如"集群模式下请改用 `RedisPipelineUtil.delete(List)`（逐 key 删除）"。

#### 5.1.3 不动的部分

| 类 | 状态 |
|---|---|
| `RedisUtilConfig` / `RedisConfigProperties` / `RedisPropertiesConfig` | 不动（第一步只改 bean 名） |
| `RedisClusterHelper` / `RedisScanUtils` / `RedisClusterHashPipeline` | **一行不动** —— 第十轮的成果，集群安全的核心 |
| `RedisPipelineUtil` | 只删 `opsHashSetPipeByHashData` 与其 import |

### 5.2 关于 `realserver-oms` 的位置与命名（不采纳为改动项）

| 问题 | 现状 | 决定 |
|---|---|---|
| 目录在 `realserver/common/oms/` 下 | 看起来像"实时数据的内部模块" | **不动**（N5）。目录位置是命名问题，不影响依赖正确性；移动目录会让 §5.1 的改动面翻倍。**已决策（2026-10-28 评审）：不移动** |
| artifactId 叫 `realserver-oms` | "oms" 实为 order-management-system 的历史包袱，这里装的是 Redis 基础设施 | **不改**（N6）。改名要同步 `backend/pom.xml` 的 `dependencyManagement` + 三个工程的 pom + Artifactory 上架，是纯粹的仪式性成本。**已决策：不改** |
| 包名 `com.sac.platform.realserver.oms.*` | 同上 | **不动** |

> **如果将来要改**，建议一次性做：目录 → `common/oms/`，artifactId → `redis-starter`，
> 包名 → `com.sac.platform.redis.*`。**但那是独立的、可选的第三步**，
> 不应与本轮的功能性修复混在一起。

### 5.3 第二步的取证

| 检查 | 判据 |
|---|---|
| 全量编译 | `mvn -o clean install` 三个工程全绿 |
| **依赖树** | `common/idgenerator` 的依赖树**不再包含** `realserver-entity` |
| **依赖树** | `napstarweb` 仍能解析到 `realserver-oms`（未破坏） |
| pom 核对 | `realserver-oms/pom.xml` 中 `realserver-entity` 依赖消失 |
| 启动 | 三个应用启动成功，日志与第一步**逐字一致** |
| 集群写入/读取 | 与第一步取证结果一致 |
| 回归 | `realserver` 现有单测全绿（`RedisClusterHashPipelineTest` 等 mock 路径不受影响，因为被删的方法没有测试） |
| 死代码核对 | 全仓库 grep `JedisUtils` / `JedisPoolUtils` 无引用 |

---

## 六、风险

| # | 风险 | 等级 | 缓解 |
|---|---|---|---|
| R1 | **Nacos 在 bootstrap 阶段用空值覆盖 `oms.*`** → 本地兜底不生效 | **高** | 第一步 §4.3 专门验证。若不成立，改用 `spring.config.additional-location` 或把 `oms.*` 拆成两个前缀 |
| R2 | bean 名 `redisConfigProperties` 被多处按名字引用 | **低**（已实测排除） | 全仓库仅 1 处**定义**，其余 55 处是**方法参数名**（按类型注入，不受 bean 名影响） |
| R3 | 删除 `opsHashSetPipeByHashData` 后，单机路径行为有细微差异 | **低** | 两者单机分支均对每个 (key, field) 发一次 `hSet`，语义相同；用 `realserver` 现有单测 + 集群写入取证覆盖 |
| R4 | 删除 `JedisPoolUtils` 后 `OmsWriteByKafkaServiceImpl:268` 编译失败 | **低** | 该调用在 `batchWirteJedisStandalone` 内，只在 `!isCluster` 时可达；需一并处理该方法（见 §7.1 备注） |
| R5 | 三个应用同时改配置 → 生产启动失败 | 中 | 第一步**逐个应用**改、逐个取证，不批量改 |
| R6 | 删除三个墓碑文件后，某个工程其实一直依赖它们 | 低 | 实测：三者**全部是注释状态**，从未生效 |
| R7 | 三个工程共用一个 artifactId，`realserver-oms` 改动会同时影响三者 | 中 | 这是"统一"的代价。取证必须覆盖**三个**应用，不能只测 realserver |

---

## 七、附：`RedisUtil` 待清理清单

### 7.1 13 个集群不安全的方法（全部无调用方，已实测）

| # | 行 | 方法 | 集群行为 |
|---|---|---|---|
| 1 | `:60-62` | `delete(Collection<String>)` | SDR 2.7.18 实际**会拆分**（`isSameSlotForAllKeys`），但 `CacheServiceImpl:73` 的注释说会 CROSSSLOT —— **注释是错的** |
| 2 | `:113-115` | `keys(String)` | ⚠️ **真不安全**：集群下只扫一个节点 → 静默返回**部分结果** |
| 3 | `:124-126` | `move(String, int)` | ⚠️ 集群不支持 `MOVE` |
| 4 | `:261-263` | `multiGet(Collection<String>)` | SDR 会拆分，**安全**（但无调用方） |
| 5 | `:332-334` | `multiSet(Map)` | SDR 会拆分，**安全** |
| 6 | `:342-344` | `multiSetIfAbsent(Map)` | SDR 会拆分，**安全** |
| 7 | `:174-187` | `rename` / `renameIfAbsent` | ⚠️ 目标 key 跨槽 → CROSSSLOT（`JedisCluster.rename` 按源 key 定槽） |
| 8 | `:818` | `sMove` | ⚠️ 2 key → CROSSSLOT |
| 9 | `:721-722`, `:736-737` | `lRightPopAndLeftPush` | ⚠️ 2 key → CROSSSLOT |
| 10 | `:849-985` | `sIntersect` / `sUnion` / `sDifference`（+ `_STORE`） | ⚠️ 多 key（+ 写）→ CROSSSLOT |
| 11 | `:1323-1366` | `zUnionAndStore` / `zIntersectAndStore` | ⚠️ 多 key 写 → CROSSSLOT |

> **备注**：#1/#4/#5/#6 经字节码验证是**安全的**（SDR 会按 slot 拆分），
> 但既然**无调用方**，删除同样有价值 —— 少一批"看着危险其实安全"的方法，
> 免得下一个人再花时间反编译一遍。
>
> **#4 的特别说明**：`RedisPipelineUtil.java:110` 的注释
> "集群：multiGet 内部自动按 slot 路由" **是对的**，
> 已由 `JedisClusterStringCommands.mGet` 的字节码证实
> （`isSameSlotForAllKeys` → 不同槽则 `executeMultiKeyCommand` 按节点分组执行，
> 再用 `ResultByReferenceKeyPositionComparator` 恢复原顺序）。**不要改这条注释。**

### 7.2 需要修正的错误注释

| 位置 | 现内容 | 问题 |
|---|---|---|
| `modelserver/…/CacheServiceImpl.java:73-74` | "不能批量 delete：Jedis 3.10 的 JedisCluster.del(byte[]...) 以首个 key 定槽，跨槽批量删除会报 CROSSSLOT" | **错**：SDR 会拆分。正确理由是"集群下 `KEYS` 只返回单个节点结果，用它批量删会漏删；且 `KEYS` 是阻塞 O(N)" |

---

## 八、明确不做的事（防止范围蔓延）

- ❌ 不注入 `JedisCluster` bean（§3.1）
- ❌ 不新建 `common/redis-starter`（v1 作废）
- ❌ 不移动 `realserver-oms` 的目录 / 不改 artifactId / 不改包名（§5.2）
- ❌ 不改 `oms.*` 前缀
- ❌ 不合并 `idgenerator` / `modelserver` 各自的三套 `RedisUtil`（另开一轮）
- ❌ 不动 `RedisClusterHashPipeline` 的 slot 缓存策略
- ❌ 不引入 Lettuce / Redisson
- ❌ 不改 Redis 服务端配置（`cluster-config.sh` 那边的事）
- ❌ 不做读侧 pipeline（`getAllHashes`）—— 性能优化，与本设计正交

---

## 九、留痕

本仓库 `D:\work\rediscluterproject` **不含 Java 源码**（Java 源码在
`D:\javawork\1.2\cpscloud1.0\code\platform\backend`，
且 `napstarweb` 连 git 仓库都不是）。

因此：
- 本设计文档存放在本仓库 `docs/superpowers/specs/`
- 实施阶段的代码改动以 **patch** 形式留痕在
  `docs/superpowers/patches/YYYY-MM-DD-<topic>.patch`
- 验证方式（沿用第十轮的做法）：

```powershell
cd D:\javawork\1.2\cpscloud1.0\code\platform\backend
git -c core.autocrlf=false apply --reverse --check <patch>   # 退出码 0 = 磁盘上仍是 patch 的后像
```

`napstarweb` 无 git 仓库 → 其改动用**文件级备份 + 差异清单**留痕。

---

## 十、待评审确认的问题

1. **§5.1.1 的 A1 方案**是否接受？即：**删除** `opsHashSetPipeByHashData`，
   让 `OmsWriteDaoImpl` 改调已有的 `opsHashSetPipe(Map<String,Map<String,Object>>)`。
   备选：保留方法但把参数改成 `Map`（会与 `opsHashSetPipe` 重复）。
2. **§7.1 的 13 个方法**是**删除**还是加 `@Deprecated` 保留？
   （全部无调用方，删除零风险）
3. **§5.2 的"不移动 `realserver-oms`"**是否接受？
   若接受，命名/位置问题留作可选的第三步；若不接受，请指明期望的目录与 artifactId。
4. **`oms:` 块里的真实值**（IP / 密码）由谁提供、写到哪？
   本地 `application.yml` 写真值，还是写占位 + 只在 Nacos 放真值（但那就回到 R1）？
5. **三个墓碑文件（§4.1 改动 5/6/7）确认删除？** 它们从未生效，删除是安全的；
   但需要确认**没有**人记得这些文件并在某个分支里手工取消过注释。
6. **第二步是否与第一步合并成一次提交？** 建议分开（§3.4）。

# 统一 Redis 工具类（合并 idgenerator 与 oms 的两套 RedisUtil）

**日期**：2026-10-29
**状态**：设计已批准，待实施
**Java 源码不在本仓库** → 改动以 patch 留痕在 `docs/superpowers/patches/`

---

## 一、问题

### 1.1 实际存在的是**两套**，不是三套

交接文档第十三轮写的是「合并三套 `RedisUtil`：`oms` / `idgenerator` / `modelserver` 各一份」。
第十五轮实测：**只有两套**。

| 位置 | 行数 | public 方法 | bean 名 | 状态 |
|---|---|---|---|---|
| `oms` `…/realserver/oms/utils/RedisUtil.java` | 1699 | 102（去重后 102 个方法名） | `realRedisUtil`（`@Bean`） | 第十三轮给 27 个集群不安全方法加了 `@Deprecated` |
| `idgenerator` `…/common/utils/redis/RedisUtil.java` | 170 | 13 | `redisUtil`（`@Component`） | **未标注任何集群风险** |
| `modelserver` | — | — | — | **没有第三套** —— `CacheServiceImpl` 与 `NapstarOaTransformerServiceImpl` 都经 idgenerator 传递依赖拿到 idgenerator 那套 |

### 1.2 真正的债不是「102 vs 13」

idgenerator 那 13 个 public 方法的构成：

| 类别 | 数量 | 具体 |
|---|---|---|
| **有实质内容** | **2 段** | 锁（`tryLock` / `unLock`）、`deleteNamespace` |
| 死方法（零调用方） | 3 | `setHash` / `getHashList` / `getPushList` |
| 一行包装 | 4 | `getValue` / `setValue` / `delete` / `scan` |
| 注入 setter | 2 | `setRedisTemplate` / `setRedisClusterHelper` |
| 匿名内部类的 public 方法 | 1 | `execute`（`getHashList` 里的 `SessionCallback`） |

也就是说 **idgenerator 的这个类，是一个装着两段实质代码的薄壳**。

| 能力 | 现状 | 谁在用 | oms 的 `RedisUtil` 有吗 |
|---|---|---|---|
| 锁 `tryLock` / `unLock` | idgenerator（**静态方法**，`SET NX EX`） | **只有 `IdUtil`** | ❌ 没有（oms 的 `setIfAbsent` 只有 2 参版，**没有带超时的**） |
| `deleteNamespace(pattern)` | idgenerator（用 `RedisScanUtils.forEachKey`，集群安全） | 只有 `NapstarOaTransformerServiceImpl`（model-service） | ❌ 没有（oms 的 `keys()` 已 `@Deprecated`） |

### 1.3 反向依赖

`common/idgenerator`（**公共库**）→ `realserver/oms`（业务模块）—— 这是方向反了的依赖。
第十三轮刚刚把 `oms` 从 `realserver-entity` 解耦，方向是「公共库不被业务层拖住」。

idgenerator 对 oms 的**唯一**引用就是它自己那个 `RedisUtil` 的两个 import：

```
common/idgenerator/src/main/java/…/redis/RedisUtil.java:3  import com.sac.platform.realserver.oms.utils.RedisClusterHelper;
common/idgenerator/src/main/java/…/redis/RedisUtil.java:4  import com.sac.platform.realserver.oms.utils.RedisScanUtils;
```

删掉它 → idgenerator 主源码**一个 oms 的类都不用** → 这条反向依赖可以彻底消失。

---

## 二、目标

**一份 Redis 基础设施实现**：通用能力全在 oms 的 `RedisUtil`；ID 序列号专用的锁留在
`IdUtil` 旁边；idgenerator 不再有自己的 `RedisUtil`；
**`common/idgenerator → realserver/oms` 这条反向依赖彻底消失**。

---

## 三、改动清单（4 个源文件 + 2 个 pom）

| # | 文件 | 改动 |
|---|---|---|
| 1 | `realserver/common/oms/…/oms/utils/RedisUtil.java` | **加** `deleteNamespace(String pattern)` |
| 2 | `common/idgenerator/…/common/utils/redis/RedisUtil.java` | **删**（整个类，170 行） |
| 3 | `common/idgenerator/…/common/utils/IdUtil.java` | 锁搬进来（私有）；改用 `RedisTemplate`；模板**惰性**获取 |
| 4 | `modelserver/services/…/NapstarOaTransformerServiceImpl.java` | import 换成 oms 的 `RedisUtil`（调用点不变） |
| 5 | `common/idgenerator/pom.xml` | 删掉 `realserver-oms` 依赖 |
| 6 | `modelserver/services/pom.xml` | **加** `realserver-oms`（显式声明） |

---

## 四、五个关键决定

### ① oms 的 `RedisUtil` 只加 `deleteNamespace`，不加带超时的 `setIfAbsent`

锁留在 `IdUtil`，`IdUtil` 直接用 `RedisTemplate` → oms 那边**没人**需要那个 4 参
`setIfAbsent` → **不加**（YAGNI）。oms 现有的 2 参 `setIfAbsent(String, String)` 保持不变。

### ② `IdUtil` 的模板用「惰性获取 + 缓存」，不在静态初始化时解析

**现状**：`IdUtil` 的静态初始化只解析三样东西 —— `CommonDataMapper`、`DataSource`、
`IdWorker` —— **不需要 Redis**。

**若改成静态初始化就解析 `RedisTemplate`**：没有 Redis 的应用在**加载 `IdUtil` 时**
就会炸（例如只用 `getNextIdBySnowflake()` 的场景）。

**决定**：惰性解析（首次使用时从 `SpringContextHolder` 取，缓存进一个 `volatile` 静态字段），
**保持现有失败面不变**。

> 取法：`SpringContextHolder.getBean(RedisTemplate.class)`。
> 容器里有**两个** `RedisTemplate` bean（oms 的 `redisTemplate` 带 `@Primary`，
> `realRedisTemplate` 不带）→ 按类型查找时 `@Primary` 胜出，取到的就是
> idgenerator 现在注入的那一个 ✓。
> ⚠️ 按**名字**取（`getBean("redisTemplate")`）也能工作，但那是把 oms 的 bean 名
> 硬编码进 idgenerator —— **不采用**，按类型取。

### ③ Redis 里的值格式一个字节都不变

原来 `redisUtil.setValue(key, id)` 存的是 **Long**（JSON `100`）。

若改用 oms 的 `RedisUtil.set(String key, String value)` → 会存成字符串 `"100"`
→ **Redis 里已有的计数器格式就变了**。

**决定**：`IdUtil` 直接用 `redisTemplate.opsForValue().set(key, id)`（`Object` 重载）
→ 格式不变 ✓。同理读回用 `opsForValue().get(key)`。

### ④ `deleteNamespace` 统一用流式 `forEachKey`

idgenerator 那份原本是「集群流式 / 单机批量」两套分支。统一走
`RedisScanUtils.forEachKey(template, pattern, count, consumer)` —— 它内部按连接类型
（`JedisClusterConnection` / `RedisClusterConnection` / 单机）自适应。

- 结果一致 ✓
- **流式**：不把全部 key 拉进内存 ✓
- 行为变化：单机下从「1 次批量 DEL」变成「N 次逐个 DEL」（可接受）

### ⑤ 锁的语义一字不改，第 15 轮的三处修复原样保留

第 15 轮（2026-10-29）刚修好的：

1. 锁在 `finally` 里释放，且**只在真的拿到锁时**释放；
2. `tryLock` 的 catch 释放**正确的键**（`delete(lockKey)`，不是 `unLock(lockKey)`）；
3. `tryLock` 的 catch 吞掉释放本身的异常（`tryLock` 的契约是返回布尔值）。

**顺带修**（本次批准）：`tryLock` 的**忙等自旋没有 sleep** —— 锁被占用时以无限速的
`SET NX` 空转，最长 10 秒。循环里 sleep 几毫秒再重试。

---

## 五、锁搬进 `IdUtil` 后的样子

`IdUtil` 内部（**私有**，不再对外暴露）：

```java
private static final String LOCK_PREFIX = "locked#";
private static final long LOCK_TIMEOUT_MS = 9999L;
private static final long LOCK_RETRY_INTERVAL_MS = 10L;

/** 抢锁。key 是**原始** key（前缀由本方法加）。返回是否拿到。 */
private static boolean tryLock(String key, String value, long expireSeconds) { … }

/** 释放锁。key 是**原始** key（前缀由本方法加）。 */
private static void unLock(String key) { … }
```

- 前缀 `locked#`、超时 9999 ms、TTL 由调用方给（`IdUtil` 传 5 秒）—— **与现状一致**
- `tryLock` / `unLock` 从 `public static` 变成 `private static`（全树 grep 确认无外部调用方）
- **键的约定要写清楚**：`tryLock` / `unLock` 收**原始** key，内部加前缀；
  而 `tryLock` 的 catch 分支要释放的是**已经带前缀**的那个键 → 直接
  `redisTemplate.delete(LOCK_PREFIX + key)`，**不能再经过 `unLock`**（那会拼第二次前缀
  —— 这正是第 15 轮修掉的缺陷 D2）
- **忙等**：抢不到锁时 `Thread.sleep(LOCK_RETRY_INTERVAL_MS)` 再重试，
  直到累计 `LOCK_TIMEOUT_MS` 才返回 false

---

## 六、测试

| 位置 | 内容 |
|---|---|
| `oms` **新增** `RedisUtilDeleteNamespaceLiveTest`（真集群） | ① 只删匹配 pattern 的，**不匹配的必须还在** ② 跨多个 master 的 key 都能删掉 ③ 删完确实不存在 |
| `idgenerator` 改 `IdUtilRedisLockLiveTest` | 去掉对「要删的 bean」的注册与 `RedisClusterHelper` import；**3 条锁断言原样保留** |
| `model-service` | **没有 `src/test`**（已确认）→ 只能靠编译验证 |

> **顺带一个发现**：oms 的 `RedisUtil`（1699 行 / 102 个方法）**目前一个单测都没有**。
> `deleteNamespace` 会是它**第一个**被测的方法。

真集群测试沿用第十四/十五轮的模式：`ApplicationContextRunner` → 真的
`JedisConnectionFactory` → 真的 Docker 集群；集群不可达时**跳过**而不是变红。

---

## 七、验证

| 项 | 期望 |
|---|---|
| `cd $BE\common\idgenerator; mvn -o clean test` | 3 通过 / 0 失败 / 0 跳过 |
| `cd $BE\realserver\common\oms; mvn -o clean test` | 63 + N 通过 / 0 失败 |
| `cd $BE\realserver\plugins\rtdata-module; mvn -o test` | 14 通过 / 0 失败 |
| `cd $BE; mvn -o clean install -DskipTests` | 44 个模块全 SUCCESS |
| `cd $AB; mvn -o clean install -DskipTests` | napstarweb reactor 全 SUCCESS |
| `cd $BE\common\idgenerator; mvn -o dependency:tree` | **不含 `realserver-oms`**（新增进 handoff 基线表） |
| patch 反向校验 / 往返校验 | exit 0 / `mismatches=0` |

> 构建必须用 **JDK 8**（`D:\java\java-se-8u42-ri`）：`oms` 的 proguard 要
> `${JAVA_HOME}/jre/lib/rt.jar`，**只有 JDK 8 有这个路径**。

---

## 八、风险

| # | 风险 | 结论 |
|---|---|---|
| 1 | 删掉 idgenerator 的 `RedisUtil` = 删掉一个 public API | 全树 grep 确认**只有 2 个调用方**（`IdUtil`、`NapstarOaTransformerServiceImpl`），**都在这个改动里** ✓ |
| 2 | `model-service` 里 `RedisUtil` 换了包 → 构造器按类型注入 | oms 的 `RedisUtil` 只有一个候选 bean（`realRedisUtil`）✓ |
| 3 | `model-service` 显式依赖 oms | 相比之前靠 `realserver-service` 的传递依赖，是**变稳**而不是变脆 ✓ |
| 4 | Redis 里已有计数器的格式 | **不变**（见决定③）✓ |
| 5 | `IdUtil` 类初始化的失败面 | **不变**（见决定②）✓ |

---

## 九、不在本次范围内

- **读侧 pipeline**（`RedisClusterHashPipeline.getAllHashes`）—— 另一件事
- **`oms` 的 `RedisUtil` 那 102 个方法的系统性测试** —— 本次只测新加的 `deleteNamespace`
- **填生产真值 / `cluster_require_full_coverage=no`** —— 需要生产真值与真机

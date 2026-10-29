# 统一 Redis 工具类 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 idgenerator 那份只做别名的 `RedisUtil` 壳删掉，通用能力归到 oms 的 `RedisUtil`，ID 序列号专用的锁留在 `IdUtil` 旁边，并让 `common/idgenerator → realserver/oms` 这条反向依赖彻底消失。

**Architecture:** oms 的 `RedisUtil` 是唯一的通用 Redis 工具类（新增 `deleteNamespace`）；`IdUtil` 改为直接用 `RedisTemplate`，锁（`tryLock`/`unLock`）变成它的私有方法；`model-service` 改注入 oms 的 `RedisUtil`。idgenerator 的 pom 不再依赖 `realserver-oms`，`model-service` 显式声明它。

**Tech Stack:** Java 8、Spring Data Redis 2.7.18、Jedis 3.10.0、JUnit 5 + Mockito（真集群测试沿用第十四/十五轮的 `ApplicationContextRunner` 模式）、Maven 3.8.6。

**设计文档：** `docs/superpowers/specs/2026-10-29-unify-redis-util-design.md`

---

## 通用约定

**Java 源码不在本仓库**（`D:\javawork\1.2\cpscloud1.0\code\platform\backend` 不是 git 仓库），
所以：

- 改动落在 Java 树上 → 结束时以 patch 留痕到
  `docs/superpowers/patches/2026-10-29-unify-redis-util.patch`
- 本仓库只改文档 → 正常 `git add` / `git commit` / SSH 推送

**根目录记号**（下文 `$BE` / `$AB`）：

```powershell
$BE = "D:\javawork\1.2\cpscloud1.0\code\platform\backend"
$AB = "D:\javawork\1.2\cpscloud1.0\code\application\backend"
```

**必须用 JDK 8**：`$env:JAVA_HOME` 已经是 `D:\java\java-se-8u42-ri`。
`oms` 的 proguard 配了 `${JAVA_HOME}/jre/lib/rt.jar`，**只有 JDK 8 有这个路径**。

**行尾**：源文件行尾是**混的**（`.java` 是 CRLF，`pom.xml` 是 LF）。
**一律用编辑工具改**，**绝不要用 `Set-Content` / `Out-File`**（会加 BOM + 改行尾）。
改完用这个脚本核对字节：

```powershell
& "$env:TEMP\opencode\to-crlf.ps1" -Path "<改过的文件>"
# 期望：.java → CRLF=n bareLF=0 BOM=False；pom.xml → CRLF=0 bareLF=n BOM=False
```

**改之前先备份**（Java 树不是 git 仓库，回滚只能靠备份）：

```powershell
$base = "$env:TEMP\opencode\unify-redis-baseline"
New-Item -ItemType Directory -Force -Path $base | Out-Null
# 每个要改的文件都备份一份（Task 1 开始前做一次）
```

**PowerShell 没有 heredoc**：`git commit -F -` 之类的写法用不了，提交信息一律写成文件再 `-F <file>`。

**提交推送走 SSH**（PAT 没有 `workflow` scope；且本轮不改 workflow，但保持一致）：

```powershell
$env:GIT_SSH="C:\Windows\System32\OpenSSH\ssh.exe"
git -c remote.origin.pushurl=git@github.com:leiming-cai/redis-cluster-install.git push origin main
```

---

### Task 1: oms 的 `RedisUtil` 加 `deleteNamespace`（真集群测试先行）

**Files:**
- Create: `$BE\realserver\common\oms\src\test\java\com\sac\platform\realserver\oms\utils\RedisClusterTestSupport.java`
- Create: `$BE\realserver\common\oms\src\test\java\com\sac\platform\realserver\oms\utils\RedisUtilDeleteNamespaceLiveTest.java`
- Modify: `$BE\realserver\common\oms\src\main\java\com\sac\platform\realserver\oms\utils\RedisUtil.java`（文件末尾，L1690-1699 之后）
- Modify: `$BE\realserver\common\oms\src\test\java\com\sac\platform\realserver\oms\utils\RedisClusterHashPipelineLiveTest.java`（把两个拓扑 helper 挪到共享类里）

**背景：** oms 的 `RedisUtil`（1699 行 / 102 个方法）**一个单测都没有**。
`deleteNamespace` 会是它第一个被测的方法 —— 所以这条断言必须真的有力。

- [x] **Step 1: 备份本轮要改的所有 Java 文件**

```powershell
$base = "$env:TEMP\opencode\unify-redis-baseline"
New-Item -ItemType Directory -Force -Path $base | Out-Null
$files = @(
  "realserver\common\oms\src\main\java\com\sac\platform\realserver\oms\utils\RedisUtil.java",
  "realserver\common\oms\src\test\java\com\sac\platform\realserver\oms\utils\RedisClusterHashPipelineLiveTest.java",
  "common\idgenerator\src\main\java\com\sac\platform\common\utils\IdUtil.java",
  "common\idgenerator\src\main\java\com\sac\platform\common\utils\redis\RedisUtil.java",
  "common\idgenerator\src\test\java\com\sac\platform\common\utils\IdUtilRedisLockLiveTest.java",
  "common\idgenerator\pom.xml",
  "modelserver\services\src\main\java\com\sac\platform\modelserver\service\impl\NapstarOaTransformerServiceImpl.java",
  "modelserver\services\pom.xml"
)
foreach ($f in $files) {
  Copy-Item (Join-Path $BE $f) (Join-Path $base ($f -replace '\\','__')) -Force
}
"backed up $($files.Count) files"
```

- [x] **Step 2: 建共享的拓扑测试支撑类**

新建 `$BE\realserver\common\oms\src\test\java\com\sac\platform\realserver\oms\utils\RedisClusterTestSupport.java`：

```java
package com.sac.platform.realserver.oms.utils;

import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

import org.springframework.data.redis.connection.jedis.JedisClusterConnection;
import org.springframework.data.redis.connection.jedis.JedisConnectionFactory;
import org.springframework.data.redis.core.RedisTemplate;

import redis.clients.jedis.Jedis;
import redis.clients.jedis.JedisCluster;
import redis.clients.jedis.JedisPool;
import redis.clients.jedis.util.JedisClusterCRC16;

/**
 * 真集群测试的共享支撑：算某个 key 落在哪个 master 上。
 *
 * <p>为什么需要它：**「key 落在多个 master 上」这件事必须被断言**，
 * 否则一个只扫了第一个 master 的实现也能让测试变绿。
 */
final class RedisClusterTestSupport {

    private RedisClusterTestSupport() {
    }

    /**
     * 集群里所有 master 的 host:port（来自 CLUSTER SLOTS 的 master 段）。
     *
     * <p>不依赖 JedisCluster 的连接池：那里面也包含副本，而副本广播的地址
     * （172.21.0.3:638x）在宿主机上**不可达**，借连接会超时。
     */
    static List<String> masterAddresses(RedisTemplate<String, Object> template) {
        JedisConnectionFactory factory = (JedisConnectionFactory) template.getConnectionFactory();
        JedisCluster nativeCluster = ((JedisClusterConnection) factory.getConnection())
                .getNativeConnection();

        LinkedHashSet<String> masters = new LinkedHashSet<String>();
        for (JedisPool pool : nativeCluster.getClusterNodes().values()) {
            Jedis seed = null;
            try {
                seed = pool.getResource();
                for (Object range : seed.clusterSlots()) {
                    List<?> r = (List<?>) range;
                    List<?> master = (List<?>) r.get(2);
                    String host = new String((byte[]) master.get(0), "UTF-8");
                    int port = ((Number) master.get(1)).intValue();
                    masters.add(host + ":" + port);
                }
                break;
            } catch (Exception e) {
                // 试下一个节点
            } finally {
                if (seed != null) {
                    seed.close();
                }
            }
        }
        return new java.util.ArrayList<String>(masters);
    }

    /**
     * 统计每个 master 各自持有本次这批 key 的多少个。
     *
     * <p>用 CLUSTER SLOTS 拿到 slot -&gt; master 的映射，再用 KEYSLOT 算出每个 key
     * 的槽位，然后按属主计数。
     */
    static Map<String, Integer> countKeysPerMaster(RedisTemplate<String, Object> template,
            Set<String> keys) {
        JedisConnectionFactory factory = (JedisConnectionFactory) template.getConnectionFactory();
        JedisCluster nativeCluster = ((JedisClusterConnection) factory.getConnection())
                .getNativeConnection();

        Map<String, Integer> counts = new LinkedHashMap<String, Integer>();
        try {
            Map<Integer, String> slotOwner = new LinkedHashMap<Integer, String>();
            boolean topologyRead = false;
            for (JedisPool pool : nativeCluster.getClusterNodes().values()) {
                Jedis seed = null;
                try {
                    seed = pool.getResource();
                    for (Object range : seed.clusterSlots()) {
                        List<?> r = (List<?>) range;
                        List<?> master = (List<?>) r.get(2);
                        String host = new String((byte[]) master.get(0), "UTF-8");
                        int port = ((Number) master.get(1)).intValue();
                        String hostPort = host + ":" + port;
                        for (int slot = (int) toNumber(r.get(0)); slot <= toNumber(r.get(1)); slot++) {
                            slotOwner.put(slot, hostPort);
                        }
                    }
                    topologyRead = true;
                    break;
                } catch (Exception e) {
                    // 试下一个节点：集群里可能有宿主机不可达的地址
                } finally {
                    if (seed != null) {
                        seed.close();
                    }
                }
            }
            if (!topologyRead) {
                throw new IllegalStateException("could not read CLUSTER SLOTS from any node");
            }

            for (String key : keys) {
                int slot = JedisClusterCRC16.getSlot(key.getBytes("UTF-8"));
                String owner = slotOwner.get(slot);
                if (owner == null) {
                    throw new IllegalStateException("no slot owner for slot " + slot + " (key " + key + ")");
                }
                Integer count = counts.get(owner);
                counts.put(owner, count == null ? 1 : count + 1);
            }
        } catch (RuntimeException e) {
            throw e;
        } catch (Exception e) {
            throw new IllegalStateException("could not read the cluster topology", e);
        }
        return counts;
    }

    private static int toNumber(Object value) {
        return ((Number) value).intValue();
    }
}
```

- [x] **Step 3: 写失败测试**

新建 `$BE\realserver\common\oms\src\test\java\com\sac\platform\realserver\oms\utils\RedisUtilDeleteNamespaceLiveTest.java`：

```java
package com.sac.platform.realserver.oms.utils;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.Map;
import java.util.Set;

import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.Test;
import org.springframework.boot.autoconfigure.AutoConfigurations;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;
import org.springframework.data.redis.core.RedisTemplate;

import com.sac.platform.realserver.oms.config.RedisPropertiesConfig;
import com.sac.platform.realserver.oms.config.RedisUtilConfig;

/**
 * 真集群验证：{@code RedisUtil.deleteNamespace(pattern)}。
 *
 * <p>它是 idgenerator 那份 RedisUtil 里**唯一有实质内容又通用**的能力
 * （按模式删除 key），现在搬到 oms 的 RedisUtil。
 *
 * <p>两条断言各自锁住一件事：
 * <ul>
 *   <li><b>只删匹配的</b> —— 不匹配的 key 必须还在。删多了是数据丢失。</li>
 *   <li><b>跨多个 master 都能删</b> —— 一个只扫了第一个 master 的实现
 *       也能让「删得掉」变绿，所以必须显式断言这批 key 落在多个 master 上。</li>
 * </ul>
 *
 * <p>默认连本机 127.0.0.1:16379（Docker 集群转发到宿主机的端口）；
 * 可用 {@code -Dtest.clusters} / {@code -Dtest.password} 覆盖。
 * 集群不可达时**跳过**而不是变红（CI 的 runner 上没有 Redis）。
 */
class RedisUtilDeleteNamespaceLiveTest {

    private static final String CLUSTERS =
            System.getProperty("test.clusters", "127.0.0.1:16379");

    private static final String PASSWORD =
            System.getProperty("test.password", "CpsE2eClusterPw");

    /** 本次运行用的 key 前缀：便于结束时精确删除，不碰集群里的其它数据。 */
    private static final String KEY_PREFIX = "delete_namespace_test:";

    private final ApplicationContextRunner runner = new ApplicationContextRunner()
            .withConfiguration(AutoConfigurations.of(
                    RedisPropertiesConfig.class, RedisUtilConfig.class))
            .withPropertyValues(
                    "oms.redisMode=cluster",
                    "oms.clusters[0]=" + CLUSTERS,
                    "oms.password=" + PASSWORD,
                    "oms.database=0",
                    "oms.timeout=5000",
                    "oms.connectTimeout=2000",
                    "oms.readTimeout=5000",
                    "oms.maxWait=3000",
                    "oms.maxTotal=16",
                    "oms.maxIdle=4",
                    "oms.minIdle=1")
            .withInitializer(ctx -> org.springframework.boot.context.properties
                    .ConfigurationPropertiesBindingPostProcessor.register(
                            (org.springframework.beans.factory.support.BeanDefinitionRegistry) ctx
                                    .getBeanFactory()));

    /**
     * 只删匹配的 key，不匹配的必须还在。
     */
    @Test
    void deletesOnlyTheKeysThatMatchThePattern() {
        withLiveCluster((template, util) -> {
            Set<String> matching = new LinkedHashSet<String>();
            Set<String> keep = new LinkedHashSet<String>();
            for (int i = 0; i < 20; i++) {
                matching.add(KEY_PREFIX + "match:" + i);
                keep.add(KEY_PREFIX + "keep:" + i);
            }
            writeAll(template, matching);
            writeAll(template, keep);

            util.deleteNamespace(KEY_PREFIX + "match:*");

            for (String key : matching) {
                assertFalse(Boolean.TRUE.equals(template.hasKey(key)),
                        "the matching key was not deleted: " + key);
            }
            for (String key : keep) {
                assertTrue(Boolean.TRUE.equals(template.hasKey(key)),
                        "deleteNamespace deleted a key that does NOT match the pattern: " + key);
            }
        });
    }

    /**
     * 落在**多个 master** 上的 key 都要删掉。
     *
     * <p>如果只删了第一个 master 上的那部分，这条断言会红 —— 所以先断言这批 key
     * 确实落在多个 master 上（否则这条断言就是空转的）。
     */
    @Test
    void deletesKeysThatLiveOnSeveralMasters() {
        withLiveCluster((template, util) -> {
            Set<String> keys = new LinkedHashSet<String>();
            for (int i = 0; i < 60; i++) {
                keys.add(KEY_PREFIX + "spread:" + i);
            }
            writeAll(template, keys);

            Map<String, Integer> perMaster =
                    RedisClusterTestSupport.countKeysPerMaster(template, keys);
            assertTrue(perMaster.size() >= 2,
                    "the batch was expected to span several masters, but only saw: " + perMaster);

            util.deleteNamespace(KEY_PREFIX + "spread:*");

            for (String key : keys) {
                assertFalse(Boolean.TRUE.equals(template.hasKey(key)),
                        "the key was not deleted: " + key
                                + " (it lived on " + perMaster + ")");
            }
        });
    }

    private void writeAll(RedisTemplate<String, Object> template, Set<String> keys) {
        Map<String, String> batch = new LinkedHashMap<String, String>();
        for (String key : keys) {
            batch.put(key, "value-of-" + key);
        }
        for (Map.Entry<String, String> entry : batch.entrySet()) {
            template.opsForValue().set(entry.getKey(), entry.getValue());
        }
    }

    /**
     * 在一个活着的集群上下文里跑 body；集群不可达就跳过。
     *
     * <p>body 必须写在回调内部 —— 回调返回后上下文会被销毁。
     */
    private void withLiveCluster(java.util.function.BiConsumer<RedisTemplate<String, Object>,
            RedisUtil> body) {
        runner.run(context -> {
            assertNotNull(context.getBean("omsRedisConfigProperties"));
            @SuppressWarnings("unchecked")
            RedisTemplate<String, Object> template =
                    (RedisTemplate<String, Object>) context.getBean("redisTemplate");
            assertNotNull(template);
            RedisUtil util = context.getBean(RedisUtil.class);
            assertNotNull(util);

            if (!isReachable(template)) {
                Assumptions.assumeTrue(false,
                        "Redis cluster not reachable at " + CLUSTERS + " (skipping)");
                return;
            }
            try {
                body.accept(template, util);
            } finally {
                cleanUp(template);
            }
        });
    }

    private boolean isReachable(RedisTemplate<String, Object> template) {
        try {
            template.opsForValue().get("__live_probe__");
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    /** 删掉本次测试写入的所有 key，保持集群干净。 */
    private void cleanUp(RedisTemplate<String, Object> template) {
        try {
            Set<String> found = template.keys(KEY_PREFIX + "*");
            if (found != null && !found.isEmpty()) {
                template.delete(new java.util.ArrayList<String>(found));
            }
        } catch (Exception e) {
            // 清理失败不影响其它断言的结论
        }
    }
}
```

- [x] **Step 4: 运行测试，确认它失败（编译失败 = 方法还不存在）**

```powershell
cd $BE\realserver\common\oms
mvn -o clean test
```

期望：`BUILD FAILURE`，编译错误指向 `RedisUtil.deleteNamespace` **找不到符号**。
（这一步的"红"是编译期的 —— 方法还没写。）

- [x] **Step 5: 实现 `deleteNamespace`**

在 `$BE\realserver\common\oms\src\main\java\com\sac\platform\realserver\oms\utils\RedisUtil.java`
的**文件末尾**（`scan(String pattern)` 之后、类的最后一个 `}` 之前）加上：

```java
    /**
     * 按模式删除 key（集群/单机自适应）。
     *
     * <p>用 SCAN 流式扫描并逐个删除：不把全部 key 一次性读进内存，
     * 集群下逐 key 删除也不会触发跨槽问题。
     *
     * <p>原本这个方法在 idgenerator 的 RedisUtil 里（只有 model-service 用它）。
     * 那份实现是「集群流式 / 单机批量」两套分支；这里统一走
     * {@link RedisScanUtils#forEachKey}，它内部按连接类型自适应。
     *
     * @param pattern 表达式，如：abc*，删除所有以abc开始的键
     */
    public void deleteNamespace(String pattern) {
        RedisScanUtils.forEachKey(redisTemplate, pattern, 500, key -> redisTemplate.delete(key));
    }
```

（`RedisScanUtils` 与 `RedisUtil` **同一个包** → 不需要 import。）

- [x] **Step 6: 运行测试，确认它通过**

```powershell
cd $BE\realserver\common\oms
mvn -o clean test
```

期望：`Tests run: 65, Failures: 0, Errors: 0, Skipped: 0`（基线 63 + 新增 2）。
若集群不在，新用例会 **Skipped: 2**，`BUILD SUCCESS`。

- [x] **Step 7: 变异检验 —— 证明断言不是空转**

把实现改成「只扫第一个 master」是不容易的，但**「删多了」是容易的**：
把 `deleteNamespace` 里的 pattern 改成 `"*"`（删掉一切）→ 第一条用例必须变红。

```powershell
# 临时把实现里的 pattern 改成 "*"，跑一次，然后改回来
cd $BE\realserver\common\oms
mvn -o clean test
```

期望：`deletesOnlyTheKeysThatMatchThePattern` 变红
（`deleteNamespace deleted a key that does NOT match the pattern`）。

- [x] **Step 8: 把已有 live test 里的两个拓扑 helper 换成共享类**

`$BE\realserver\common\oms\src\test\java\com\sac\platform\realserver\oms\utils\RedisClusterHashPipelineLiveTest.java`：
删掉 `masterAddresses(...)` 与 `countKeysPerMaster(...)` 两个方法
（分别在 L271-298 与 L372-429），把两处调用改成
`RedisClusterTestSupport.masterAddresses(template)` 与
`RedisClusterTestSupport.countKeysPerMaster(template, keys)`。
其余不动。

- [x] **Step 9: 重新跑，确认 63 + 2 仍然全绿**

```powershell
cd $BE\realserver\common\oms
mvn -o clean test
```

期望：`Tests run: 65, Failures: 0, Errors: 0, Skipped: 0`。

- [x] **Step 10: 提交（Java 树不是 git 仓库 → 只提交本仓库的进度记录）**

本任务的产出全在 Java 树上，**此时还没有 patch**（patch 在 Task 4 统一生成）。
所以本任务**不提交**，只更新本仓库的进度记录：

```powershell
cd D:\work\rediscluterproject
# 更新 docs/superpowers/plans/2026-10-29-unify-redis-util.md 的勾选框
```

> **为什么不每次都提交**：Java 树没有 git，提交粒度只能落在本仓库的文档上，
> 而真正的代码留痕是最后那个 patch。分批提交只会产生一堆只改文档的提交。

---

**鎵ц璁板綍锛堝疄闄呬笌璁″垝鐨勫嚭鍏ワ級**锛歚n
**Step 10 的期望值写错了**：它说 `.java` 应当是 CRLF，但 `oms/src/test/.../oms/utils/`
这个包里**本来就是 LF**（`RedisClusterHashPipelineTest` / `RedisPipelineUtilTest` /
`RedisScanUtilsTest` / `RedisPipelineUtilNoEntityDependencyTest` 全是 LF，第十四轮
新增的 live test 也是 LF）。按 Step 10 无脑转成 CRLF 会让
`RedisClusterHashPipelineLiveTest` 的 diff 变成 **448 行行尾噪音**而不是 ~104 行。
→ 已改回 LF，并给两个新文件也用 LF（与同包一致）。**教训：行尾要「跟邻居一致」，
不是「一律 CRLF」。**

**计划里的测试代码缺一个 `UtilsPackageScan`**：`RedisUtilConfig.realRedisPipelineUtil`
需要 `RedisClusterHelper` bean，而它是 `@Component`，`ApplicationContextRunner` 不做
组件扫描 → 计划那版测试的上下文**起不来**。已按仓库既有模式补上嵌套的
`UtilsPackageScan`（与 `RedisModeCaseSensitivityTest` / `RedisClusterOmsContractTest` /
`RedisClusterHashPipelineLiveTest` 三个兄弟类一致）。

**代码审查（两轮）追加的修复**（计划里没有，但都属于本任务）：
- `masterAddresses` 读不到拓扑时**返回空列表** → `totalMovedErrors` 的
  「没有 MOVED 重定向」断言会**空转通过**（没测到任何东西也算 0 次重定向）。
  已改成抛 `IllegalStateException`。
- `deleteNamespace` 的 javadoc 补上了**非原子性**（中途失败会停在部分删除的状态）
  与**代价**（每个 key 一次 DEL 往返，几百个 key 没问题、几万个不合适）。
- 测试清理原来用 `template.keys(...)` —— 那正是 `RedisUtil.delete(Collection)` 的
  javadoc 里点名警告的集群级阻塞操作。已改成 `RedisScanUtils.scan(...)`，
  **并把同样的改动应用到了既有的 `RedisClusterHashPipelineLiveTest`**（只改清理，
  不动任何断言）。
- 「匹配不到任何 key」这条边界补了一条用例。
- `totalMovedErrors` 的空转洞：原来每个 master 的 `INFO` 失败都只贡献 0。
  **第一版的修法又踩了一个坑**：它去数「有几个 master 报了 `errorstat_MOVED:` 行」——
  但 **Redis 不打印计数为 0 的 errorstat**，本机 16380 这个健康的 master 一个
  `errorstat_*` 行都没有 → 在「从没发生过 MOVED」的集群上（正是这个用例要证明的健康
  情形）**会误报红**。已改成数「INFO 成功读到的 master 数」，并另立一条断言检查
  `# Errorstats` 段是否存在（该**段头**即使计数全为 0 也会打印 —— 已实测）。

**结果**：`oms` **66 通过 / 0 失败 / 0 跳过**（基线 63 + 3 条新用例），
4 个文件行尾与邻居一致，集群里没有残留 key。
变异检验做了三轮：改宽 pattern → 「只删匹配的」变红；只删第一个 master 的槽位 →
两条都变红；把 `errorstat_MOVED` 的匹配串改坏 → 「没测到」的断言变红。
### Task 2: `IdUtil` 自给自足（锁搬进来 + 惰性取模板）

**Files:**
- Modify: `$BE\common\idgenerator\src\main\java\com\sac\platform\common\utils\IdUtil.java`
- Modify: `$BE\common\idgenerator\src\test\java\com\sac\platform\common\utils\IdUtilRedisLockLiveTest.java`

- [ ] **Step 1: 改测试：去掉「要删掉的 bean」，加两个用替身的用例**

`$BE\common\idgenerator\src\test\java\com\sac\platform\common\utils\IdUtilRedisLockLiveTest.java`
整体替换为下面这份（**两个 runner**：一个真集群、一个替身）：

```java
package com.sac.platform.common.utils;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.atMost;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.Map;
import java.util.concurrent.TimeUnit;

import javax.sql.DataSource;

import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.redis.RedisConnectionFailureException;
import org.springframework.data.redis.core.RedisTemplate;
import org.springframework.data.redis.core.ValueOperations;

import com.alibaba.druid.pool.DruidDataSource;
import com.sac.platform.common.dao.CommonDataMapper;
import com.sac.platform.common.entity.CommonData;
import com.sac.platform.common.utils.snowflake.IdWorker;

/**
 * {@code IdUtil} 的 Redis 序列号**锁**的行为。
 *
 * <p>这个类里现在混着两种用例：
 * <ul>
 *   <li><b>真集群</b>（前两条）：锁必须被释放、序列号必须继续推进。
 *       集群不可达时**跳过**而不是变红。</li>
 *   <li><b>替身</b>（后两条）：释放的必须是自己那把锁；抢不到锁时不能无限速空转。
 *       不需要集群。</li>
 * </ul>
 *
 * <p>替身为什么是**上下文里的那个 bean**而不是一个静态字段：
 * {@code IdUtil} 的模板是**每次使用时从当前上下文里取**的（不缓存 ——
 * 上下文会被销毁，缓存下来会拿到已失效的工厂）。
 * 所以想让 {@code IdUtil} 用上替身，就得把替身放进上下文。
 */
class IdUtilRedisLockLiveTest {

    private static final String CLUSTERS =
            System.getProperty("test.clusters", "127.0.0.1:16379");

    private static final String PASSWORD =
            System.getProperty("test.password", "CpsE2eClusterPw");

    /** 被测的「业务表」名。它只作为计数器 key 的一部分出现，不碰任何真实表。 */
    private static final String TABLE = "LOCK_TEST";

    /**
     * 「锁被别人占着」那条用例用的**另一张表**。
     *
     * <p>必须与 {@link #TABLE} 分开：那条用例会在集群里放一把**别人持有的锁**，
     * 而清理是尽力而为的（清理失败只记日志）。如果两条用例共用一把锁，
     * 一次清理失败就会让另一条用例白等锁过期 —— 测试之间会互相污染。
     */
    private static final String HELD_LOCK_TABLE = "LOCK_HELD_TEST";

    /**
     * {@code IdUtil} 的 database 取自数据源 URL；测试里的数据源没有 URL，
     * 解析会失败并退回默认值 {@code info}。
     */
    private static final String COUNTER_KEY = "info_" + TABLE;

    /** {@code IdUtil} 给锁 key 加的前缀。 */
    private static final String LOCK_KEY = "locked#" + COUNTER_KEY;

    /** {@code IdUtil} 申请锁时用的 TTL（秒）。 */
    private static final int LOCK_TTL_SECONDS = 5;

    /** 真集群的上下文。 */
    private final ApplicationContextRunner liveRunner = new ApplicationContextRunner()
            .withUserConfiguration(
                    SharedBeans.class, LiveTemplateConfig.class, SpringContextHolder.class);

    /** 替身的上下文：{@code setIfAbsent} 直接抛异常。 */
    private final ApplicationContextRunner throwingRunner = new ApplicationContextRunner()
            .withUserConfiguration(
                    SharedBeans.class, ThrowingTemplateConfig.class, SpringContextHolder.class);

    /** 替身的上下文：{@code setIfAbsent} 永远返回 false（永远抢不到锁）。 */
    private final ApplicationContextRunner contendedRunner = new ApplicationContextRunner()
            .withUserConfiguration(
                    SharedBeans.class, ContendedTemplateConfig.class, SpringContextHolder.class);

    /**
     * 核心契约：取一次 ID 之后，锁**必须已经被释放**。
     *
     * <p>这条断言直接对着缺陷：锁没释放时，它会一直留到 TTL（5 秒）过期，
     * 这期间每一次取号都拿不到锁 —— 要么干等到锁过期（**每次调用白等 5 秒**），
     * 要么在等待超过 {@code tryLock} 的超时（10 秒）时彻底拿不到序列号。
     */
    @Test
    void releasesTheRedisLockSoTheNextAcquisitionSucceeds() {
        withLiveCluster(template -> {
            Long first = IdUtil.getNextId(TABLE);
            assertNotNull(first, "the first acquisition must succeed");

            assertFalse(Boolean.TRUE.equals(template.hasKey(LOCK_KEY)),
                    "the redis lock " + LOCK_KEY + " is still held after the id was taken; "
                            + "every acquisition in the next " + LOCK_TTL_SECONDS
                            + " seconds has to wait for the lock to expire");

            Long second = IdUtil.getNextId(TABLE);
            assertNotNull(second,
                    "the second acquisition must succeed: the lock was never released");

            // 释放锁不等于放掉序列号：计数器必须继续推进。
            assertNotEquals(first, second, "the sequence did not advance");
            assertTrue(second > first,
                    "the second id must be greater than the first; first=" + first
                            + " second=" + second);
        });
    }

    /**
     * 锁被别人占着时，取号必须**失败得很清楚**，而不是抛一个裸的 NPE。
     *
     * <p>这条锁的是「诊断能力」：序列号取不到时，
     * {@code Long.toBinaryString(null)} 抛的 NullPointerException 既不说是哪张表，
     * 也不说是因为锁没拿到 —— 排障时只能靠猜。
     *
     * <p>把 {@code tryLock} 的等待上限调到 300 ms，免得用例干等 10 秒。
     */
    @Test
    void aHeldLockProducesADiagnosableErrorInsteadOfANullPointerException() {
        withLiveCluster(template -> {
            String counterKey = "info_" + HELD_LOCK_TABLE;
            String lockKey = "locked#" + counterKey;

            // 模拟「另一个持有者占着这把锁」。
            template.opsForValue().set(lockKey, "someone-else", 30, TimeUnit.SECONDS);

            long originalTimeout = currentLockTimeout();
            try {
                setLockTimeout(300L);

                NullPointerException npe = null;
                RuntimeException reported = null;
                try {
                    IdUtil.getNextId(HELD_LOCK_TABLE);
                } catch (NullPointerException e) {
                    npe = e;
                } catch (RuntimeException e) {
                    reported = e;
                }

                assertNotNull(reported,
                        "the acquisition must fail with a diagnosable error; instead it threw "
                                + (npe == null ? "nothing" : "a NullPointerException: " + npe));

                assertTrue(reported.getMessage() != null
                                && reported.getMessage().contains(HELD_LOCK_TABLE),
                        "the error must name the table it was about; message was: "
                                + reported.getMessage());
            } finally {
                setLockTimeout(originalTimeout);
                // 这把锁是本用例放进去的，必须由本用例自己收掉，
                // 不能指望外层的清理（外层清理是尽力而为的）。
                try {
                    template.delete(lockKey);
                    template.delete(counterKey);
                } catch (Exception ignored) {
                    // 清理失败只记日志
                }
            }
        });
    }

    /**
     * {@code tryLock} 在**申请失败**时释放的必须是它自己那把锁。
     *
     * <p>原来的写法是 {@code unLock(lockKey)}，而 {@code unLock} 内部还会再拼一次
     * {@code "locked#"} 前缀，于是删掉的是 {@code locked#locked#xxx} ——
     * 既没释放自己那把锁，又可能删掉别人的键。
     *
     * <p>这条用例不需要真集群：一个「{@code setIfAbsent} 直接抛异常」的替身就够。
     */
    @Test
    void tryLockReleasesOnlyTheLockItTookWhenTheAcquireCallFails() {
        throwingRunner.run(context -> {
            @SuppressWarnings("unchecked")
            RedisTemplate<String, Object> broken = context.getBean("redisTemplate");
            assertNotNull(broken);

            assertFalse(tryLockDirectly("contract"),
                    "tryLock must report the failure, not throw it at the caller");

            verify(broken).delete("locked#contract");
        });
    }

    /**
     * 抢不到锁时不能无限速空转 {@code SET NX}。
     *
     * <p>替身让 {@code setIfAbsent} 永远返回 false，把等待上限调到 300 ms，
     * 然后数它被调了多少次：加了 sleep 之后应该是几十次，没加就是成千上万次。
     */
    @Test
    void doesNotSpinOnSetIfAbsentWhileWaitingForTheLock() {
        contendedRunner.run(context -> {
            @SuppressWarnings("unchecked")
            RedisTemplate<String, Object> busy = context.getBean("redisTemplate");
            assertNotNull(busy);

            long originalTimeout = currentLockTimeout();
            try {
                setLockTimeout(300L);

                long start = System.currentTimeMillis();
                try {
                    IdUtil.getNextId("RETRY_TEST");
                } catch (RuntimeException expected) {
                    // 抢不到锁 -> 取不到序列号 -> 明确失败。这正是期望的路径。
                }
                long elapsed = System.currentTimeMillis() - start;

                assertTrue(elapsed >= 250L,
                        "the wait must actually have happened; elapsed=" + elapsed);
                verify(busy, atMost(60)).setIfAbsent(anyString(), any(), anyLong(),
                        any(TimeUnit.class));
            } finally {
                setLockTimeout(originalTimeout);
            }
        });
    }

    /**
     * 直接调用 {@code IdUtil} 的私有锁方法（用反射），只为验证「释放的是哪把锁」。
     *
     * <p>不这么做的话，就得让整条 {@code getNextId} 路径跑一遍才能碰到锁 ——
     * 而那条路径会先读计数器，把断言搅浑。
     */
    private boolean tryLockDirectly(String key) {
        try {
            Method method = IdUtil.class.getDeclaredMethod(
                    "tryLock", String.class, String.class, long.class);
            method.setAccessible(true);
            return (Boolean) method.invoke(null, key, "1", 5L);
        } catch (Exception e) {
            throw new IllegalStateException("cannot invoke IdUtil.tryLock", e);
        }
    }

    /** {@code IdUtil} 抢锁的等待上限（毫秒）。 */
    private long currentLockTimeout() {
        try {
            Field field = IdUtil.class.getDeclaredField("lockTimeoutMs");
            field.setAccessible(true);
            return field.getLong(null);
        } catch (Exception e) {
            throw new IllegalStateException("cannot read IdUtil.lockTimeoutMs", e);
        }
    }

    private void setLockTimeout(long millis) {
        try {
            Field field = IdUtil.class.getDeclaredField("lockTimeoutMs");
            field.setAccessible(true);
            field.setLong(null, millis);
        } catch (Exception e) {
            throw new IllegalStateException("cannot set IdUtil.lockTimeoutMs", e);
        }
    }

    /**
     * 在一个活着的集群上下文里跑 body；集群不可达就跳过。
     *
     * <p>body 必须写在回调内部 —— 回调返回后上下文会被销毁。
     */
    private void withLiveCluster(java.util.function.Consumer<RedisTemplate<String, Object>> body) {
        liveRunner.run(context -> {
            @SuppressWarnings("unchecked")
            RedisTemplate<String, Object> template =
                    (RedisTemplate<String, Object>) context.getBean("redisTemplate");
            assertNotNull(template);

            if (!isReachable(template)) {
                Assumptions.assumeTrue(false,
                        "Redis cluster not reachable at " + CLUSTERS + " (skipping)");
                return;
            }
            try {
                body.accept(template);
            } finally {
                cleanUp(template);
            }
        });
    }

    private boolean isReachable(RedisTemplate<String, Object> template) {
        try {
            template.opsForValue().get("__live_probe__");
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    /** 删掉本次测试用到的计数器与锁，保持集群干净。 */
    private void cleanUp(RedisTemplate<String, Object> template) {
        try {
            template.delete(COUNTER_KEY);
            template.delete(LOCK_KEY);
        } catch (Exception e) {
            // 清理失败不影响其它断言的结论
        }
    }

    /**
     * {@code IdUtil} 的静态初始化需要三样东西：mapper、数据源、雪花 ID。
     * 这里给的都是**替身** —— 本用例要验的是锁的生命周期，不是数据库。
     */
    @Configuration
    static class SharedBeans {

        @Bean
        CommonDataMapper commonDataMapper() {
            return new FakeCommonDataMapper();
        }

        @Bean
        DataSource dataSource() {
            return new DruidDataSource();
        }

        @Bean
        IdWorker idWorker() {
            return new IdWorker(1L, 1L);
        }
    }

    /**
     * mapper 的替身。
     *
     * <p>{@code selectMaxId} 的真实 SQL 是 {@code SELECT IFNULL(MAX(id), 0) + 1}，
     * 返回的是**下一个可用 id**，不是当前最大值。
     */
    static class FakeCommonDataMapper implements CommonDataMapper {

        @Override
        public CommonData selectMaxId(Map<String, String> map) {
            CommonData data = new CommonData();
            data.setId(100L);
            return data;
        }

        @Override
        public CommonData selectObjType(Map<String, String> map) {
            CommonData data = new CommonData();
            data.setObjType(1);
            return data;
        }
    }
}
```

> ⚠️ 这份代码里 `tryLockDirectly` 用到了 `java.lang.reflect.Method` ——
> **import 段里已经有 `import java.lang.reflect.Method;`**（Step 1 的 import 块里）。
> `LiveTemplateConfig` / `ThrowingTemplateConfig` / `ContendedTemplateConfig`
> 三个类在 Step 5 里补齐（它们各自提供一个名为 `redisTemplate` 的 bean）。
> **在它们补齐之前这个测试文件编译不过 —— 那正是这一步期望的「红」。**

- [ ] **Step 2: 确认它变红**

```powershell
cd $BE\common\idgenerator
mvn -o clean test
```

期望：**编译失败**，错误指向缺失的 `LiveTemplateConfig` / `ThrowingTemplateConfig` /
`ContendedTemplateConfig`（以及 `IdUtil.tryLock` / `IdUtil.lockTimeoutMs` 还不存在）。

- [ ] **Step 3: 实现 `IdUtil` 的改造**

`$BE\common\idgenerator\src\main\java\com\sac\platform\common\utils\IdUtil.java`：

**3a. 加 import**（在 import 段里加）：

```java
import org.springframework.data.redis.core.RedisTemplate;
import org.springframework.data.redis.core.ValueOperations;

import java.util.concurrent.TimeUnit;
```

**3b. 加三个常量 + 惰性取模板**（放在类的静态字段区，`idWorker` 之后）：

```java
    /**
     * 抢锁的等待上限（毫秒）。非 final：测试要能把它调小。
     */
    private static long lockTimeoutMs = 9999L;

    /** 锁 key 的前缀。与原 idgenerator 的 RedisUtil 保持一致。 */
    private static final String LOCK_PREFIX = "locked#";

    /**
     * 抢不到锁时的重试间隔（毫秒）。
     *
     * <p>没有它就是**无限速空转 SET NX**：把 CPU 和 Redis 都打满，直到等满整个超时。
     */
    private static final long LOCK_RETRY_INTERVAL_MS = 10L;

    /**
     * 取 Redis 模板。
     *
     * <p>**每次都从当前上下文里取，不缓存**：上下文会被销毁
     * （ApplicationContextRunner 那种用法），缓存下来的模板会指向已失效的工厂。
     * 代价只是一次 bean 查找 —— {@code getNextId} 本来就要走一次 Redis 往返
     * 加一次 DB 查询，量级可忽略。
     *
     * <p>按类型取：容器里有两个 RedisTemplate bean（oms 的 {@code redisTemplate}
     * 带 {@code @Primary}），按类型查找时 @Primary 胜出。
     */
    @SuppressWarnings("unchecked")
    private static RedisTemplate<String, Object> redisTemplate() {
        return (RedisTemplate<String, Object>) SpringContextHolder.getBean(RedisTemplate.class);
    }
```

**3c. 加锁的两个方法**（放在 `getNextSeqFromRedis` 之前）：

```java
    /**
     * 抢锁（非阻塞，但有等待上限）。
     *
     * @param key           原始 key（前缀由本方法加）
     * @param value         锁的持有者标记
     * @param expireSeconds 锁的存活时间（秒）
     * @return 是否拿到锁
     */
    private static boolean tryLock(String key, String value, long expireSeconds) {
        String lockKey = LOCK_PREFIX + key;
        long deadline = System.currentTimeMillis() + lockTimeoutMs;
        try {
            while (true) {
                Boolean acquired = redisTemplate().opsForValue()
                        .setIfAbsent(lockKey, value, expireSeconds, TimeUnit.SECONDS);
                if (Boolean.TRUE.equals(acquired)) {
                    return true;
                }
                if (System.currentTimeMillis() >= deadline) {
                    return false;
                }
                try {
                    // 等一下再重试。没有这个 sleep 的话这里会无限速空转 SET NX。
                    Thread.sleep(LOCK_RETRY_INTERVAL_MS);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    return false;
                }
            }
        } catch (Exception ex) {
            logger.error(ex);
            // 释放的是**这把锁本身**：delete(lockKey)，不能再经过 unLock ——
            // unLock 会再加一次前缀，删掉的是 "locked#locked#xxx"。
            try {
                redisTemplate().delete(lockKey);
            } catch (Exception releaseError) {
                logger.error("failed to release the redis lock " + lockKey, releaseError);
            }
            return false;
        }
    }

    /**
     * 释放锁。
     *
     * @param key 原始 key（前缀由本方法加）
     */
    private static void unLock(String key) {
        redisTemplate().delete(LOCK_PREFIX + key);
    }
```

**3d. 改 `getNextSeqFromRedis`**（把 `redisUtil.xxx` 换成 `redisTemplate().opsForValue().xxx`）：

```java
    private static Long getNextSeqFromRedis(String database, String tableName) {
        // 首先锁表
        String key = database + "_" + tableName;
        Long id = null;
        // 只有真的拿到锁才允许释放它：异常发生在 tryLock 成功之前时，
        // 这把锁是别人的，删掉它会放走另一个持有者。
        boolean locked = false;
        try {
            locked = tryLock(key, "1", 5);
            if (locked) {
                Object ret = redisTemplate().opsForValue().get(key);
                // 如果ret为空，有两种情况，一种情况是 第一次初始化，ret 尚未赋值，另外一种情况是错误导致 redis 中无数据，无论哪一种，都需要去DB确认
                if (ret == null) {
                    id = IdUtil.getNextSeqFromDB(database, tableName);
                } else if (ret instanceof ArrayList) {
                    if (ret != null && ((ArrayList) ret).size() > 0 && ((ArrayList) ret).get(0) != null) {
                        id = Long.parseLong(((ArrayList) ret).get(0).toString()) + 1;
                    } else {
                        id = getNextSeqFromDB(database, tableName) + 1;
                    }
                } else {
                    id = Long.parseLong(ret.toString()) + 1;
                }

                // 用 Object 重载的 set：值的序列化结果与改造前**完全一致**
                // （原来走的是 opsForValue().set(key, Object)）。
                redisTemplate().opsForValue().set(key, id);
                return id;
            }
        } catch (Exception ex) {
            logger.error(ex);
        } finally {
            // 锁必须在 finally 里释放。
            // 原来的写法是在成功路径上直接 return —— 没有人释放这把锁，
            // 只能等它自己过期（TTL 是 5 秒）。这 5 秒里每一次取号都拿不到锁：
            // 要么白等到锁过期（每次调用多等 5 秒），要么在等待超过 tryLock
            // 的超时（10 秒）时彻底拿不到序列号。
            if (locked) {
                try {
                    unLock(key);
                } catch (Exception releaseError) {
                    // 序列号已经分配并写回了，释放失败不应该把这次取号变成失败
                    // （调用方会重试，白白再消耗一个序列号）。
                    logger.error("failed to release the redis lock for " + key, releaseError);
                }
            }
        }
        return id;
    }
```

- [ ] **Step 4: 确认「变红」的原因被消除了（还差三个配置类）**

```powershell
cd $BE\common\idgenerator
mvn -o clean test
```

期望：编译错误只剩 `LiveTemplateConfig` / `ThrowingTemplateConfig` / `ContendedTemplateConfig` 三个类缺失。

- [ ] **Step 5: 补上三个配置类（放到测试文件里）**

在 `IdUtilRedisLockLiveTest` 的**内部**（与 `SharedBeans` 同级）加：

```java
    /**
     * 真集群的模板。
     *
     * <p>照着生产代码（oms 的 RedisUtilConfig）搭一遍：序列化器必须一致，
     * 否则值读回来会变形，测的就不是生产行为了。
     */
    @Configuration
    static class LiveTemplateConfig {

        @Bean
        RedisTemplate<String, Object> redisTemplate() {
            RedisClusterConfiguration clusterConfig =
                    new RedisClusterConfiguration(Collections.singletonList(CLUSTERS));
            clusterConfig.setPassword(PASSWORD);
            clusterConfig.setMaxRedirects(3);

            redis.clients.jedis.JedisPoolConfig pool =
                    new redis.clients.jedis.JedisPoolConfig();
            pool.setMaxTotal(16);
            pool.setMaxIdle(4);
            pool.setMinIdle(1);
            pool.setMaxWait(Duration.ofMillis(3000));

            JedisClientConfiguration clientConfig = JedisClientConfiguration.builder()
                    .connectTimeout(Duration.ofMillis(2000))
                    .readTimeout(Duration.ofMillis(5000))
                    .usePooling()
                    .poolConfig(pool)
                    .build();

            JedisConnectionFactory factory =
                    new JedisConnectionFactory(clusterConfig, clientConfig);
            factory.afterPropertiesSet();

            RedisTemplate<String, Object> template = new RedisTemplate<String, Object>();
            template.setConnectionFactory(factory);
            template.setKeySerializer(new StringRedisSerializer());
            template.setHashKeySerializer(new StringRedisSerializer());
            template.setHashValueSerializer(new GenericJackson2JsonRedisSerializer());
            template.setValueSerializer(new GenericJackson2JsonRedisSerializer());
            template.afterPropertiesSet();
            return template;
        }
    }

    /** 替身：{@code setIfAbsent} 直接抛异常（模拟连接断了）。 */
    @Configuration
    static class ThrowingTemplateConfig {

        @Bean
        @SuppressWarnings("unchecked")
        RedisTemplate<String, Object> redisTemplate() {
            RedisTemplate<String, Object> broken = mock(RedisTemplate.class);
            ValueOperations<String, Object> valueOps = mock(ValueOperations.class);
            when(broken.opsForValue()).thenReturn(valueOps);
            when(valueOps.setIfAbsent(anyString(), any(), anyLong(), any(TimeUnit.class)))
                    .thenThrow(new RedisConnectionFailureException("simulated connection loss"));
            return broken;
        }
    }

    /** 替身：{@code setIfAbsent} 永远返回 false（永远抢不到锁）。 */
    @Configuration
    static class ContendedTemplateConfig {

        @Bean
        @SuppressWarnings("unchecked")
        RedisTemplate<String, Object> redisTemplate() {
            RedisTemplate<String, Object> busy = mock(RedisTemplate.class);
            ValueOperations<String, Object> valueOps = mock(ValueOperations.class);
            when(busy.opsForValue()).thenReturn(valueOps);
            when(valueOps.setIfAbsent(anyString(), any(), anyLong(), any(TimeUnit.class)))
                    .thenReturn(false);
            return busy;
        }
    }
```

并补上这些 import：

```java
import java.time.Duration;
import java.util.Collections;

import org.springframework.data.redis.connection.RedisClusterConfiguration;
import org.springframework.data.redis.connection.jedis.JedisClientConfiguration;
import org.springframework.data.redis.connection.jedis.JedisConnectionFactory;
import org.springframework.data.redis.serializer.GenericJackson2JsonRedisSerializer;
import org.springframework.data.redis.serializer.StringRedisSerializer;
```

- [ ] **Step 6: 运行测试，确认它通过**

```powershell
cd $BE\common\idgenerator
mvn -o clean test
```

期望：`Tests run: 4, Failures: 0, Errors: 0, Skipped: 0`（3 条原有的 + 1 条新增的忙等用例）。

- [ ] **Step 7: 变异检验 —— 三个变异各自让一条用例变红**

| 变异 | 做法 | 期望变红的用例 |
|---|---|---|
| A | 把 `finally` 里的 `unLock(key)` 去掉 | `releasesTheRedisLockSoTheNextAcquisitionSucceeds` |
| B | 把 `tryLock` catch 里的 `redisTemplate().delete(lockKey)` 换成 `unLock(lockKey)` | `tryLockReleasesOnlyTheLockItTookWhenTheAcquireCallFails` |
| C | 把 `Thread.sleep(LOCK_RETRY_INTERVAL_MS)` 去掉 | `doesNotSpinOnSetIfAbsentWhileWaitingForTheLock` |

每次改完跑一次 `mvn -o clean test`，确认**恰好**对应的用例变红，然后改回来。

- [ ] **Step 8: 确认改回来之后仍然全绿**

```powershell
cd $BE\common\idgenerator
mvn -o clean test
```

期望：`Tests run: 4, Failures: 0, Errors: 0, Skipped: 0`。

---

### Task 3: 删掉 idgenerator 的 `RedisUtil` 壳，改 `model-service` 的 import 与两个 pom

**Files:**
- Delete: `$BE\common\idgenerator\src\main\java\com\sac\platform\common\utils\redis\RedisUtil.java`
- Modify: `$BE\modelserver\services\src\main\java\com\sac\platform\modelserver\service\impl\NapstarOaTransformerServiceImpl.java:40`
- Modify: `$BE\common\idgenerator\pom.xml:85-89`
- Modify: `$BE\modelserver\services\pom.xml`

- [ ] **Step 1: 改 `model-service` 的 import**

`$BE\modelserver\services\src\main\java\com\sac\platform\modelserver\service\impl\NapstarOaTransformerServiceImpl.java`：

把

```java
import com.sac.platform.common.utils.redis.RedisUtil;
```

换成

```java
import com.sac.platform.realserver.oms.utils.RedisUtil;
```

其余**一行不动**（构造器注入的是同一个类型 `RedisUtil`，调用点 `redisUtil.deleteNamespace(...)` 也不变）。

> ⚠️ 构造器按**类型**注入。容器里 `com.sac.platform.realserver.oms.utils.RedisUtil`
> 只有一个候选 bean（`realRedisUtil`）→ 注入得到的就是它 ✓。

- [ ] **Step 2: 删掉 idgenerator 的 `RedisUtil`**

```powershell
Remove-Item "$BE\common\idgenerator\src\main\java\com\sac\platform\common\utils\redis\RedisUtil.java" -Force
```

（包里还剩 `RedisConfig.java` 和 `RedisLock.java` —— **不要动它们**，本轮不碰。）

- [ ] **Step 3: 改两个 pom**

**3a.** `$BE\common\idgenerator\pom.xml`：删掉这一段

```xml
		<dependency>
			<groupId>com.sac.platform</groupId>
			<artifactId>realserver-oms</artifactId>
		</dependency>
```

**3b.** `$BE\modelserver\services\pom.xml`：在依赖列表里加一段。
锚点是 `idgenerator` 那段（`<artifactId>idgenerator</artifactId>`）——
**紧跟其后**加：

```xml
		<dependency>
			<groupId>com.sac.platform</groupId>
			<artifactId>realserver-oms</artifactId>
		</dependency>
```

> 为什么 model-service 必须**显式**加：它之前是**靠 `idgenerator` 的传递依赖**拿到 oms 的。
> idgenerator 删掉这个依赖之后，它就看不到了。
> 显式声明比传递依赖**更稳**（用了就该直接声明）。

- [ ] **Step 4: 编译整个 backend reactor**

```powershell
cd $BE
mvn -o clean install -DskipTests
```

期望：`BUILD SUCCESS`，**44 个模块**全 SUCCESS。

> 如果报「找不到 `com.sac.platform.realserver.oms.utils.RedisUtil`」，
> 说明 3b 的 pom 没加对（或者加在了错误的模块）。

- [ ] **Step 5: 跑三套单测**

```powershell
cd $BE\common\idgenerator;            mvn -o clean test   # 期望 4 / 0 / 0 跳过
cd $BE\realserver\common\oms;        mvn -o clean test   # 期望 65 / 0 / 0 跳过
cd $BE\realserver\plugins\rtdata-module; mvn -o test      # 期望 14 / 0
```

> `model-service` **没有 `src/test`** → 只能靠编译验证。

- [ ] **Step 6: 核对依赖树**

```powershell
cd $BE\common\idgenerator
mvn -o dependency:tree | Select-String "realserver-oms"
```

期望：**没有任何输出**（idgenerator 已经不认识 oms 了）。

```powershell
cd $BE\modelserver\services
mvn -o dependency:tree | Select-String "realserver-oms"
```

期望：能看到 `com.sac.platform:realserver-oms:jar:1.0.14:compile`。

- [ ] **Step 7: 编译 napstarweb**

```powershell
cd $AB
mvn -o clean install -DskipTests
```

期望：`BUILD SUCCESS`，**13 个模块**全 SUCCESS。

---

### Task 4: 生成 patch、更新文档、提交推送

**Files:**
- Create: `docs/superpowers/patches/2026-10-29-unify-redis-util.patch`
- Modify: `docs/superpowers/patches/README.md`
- Modify: `docs/HANDOFF.md`
- Create: `docs/superpowers/plans/2026-10-29-unify-redis-util.md`（本文件，已存在）

- [ ] **Step 1: 生成 patch**

Java 树不是 git 仓库 → 用**合成 repo** 的办法（和第十五轮一样）：
基线文件先提交，再覆盖成改完的版本，最后让 git 自己出 diff。

```powershell
$BE   = "D:\javawork\1.2\cpscloud1.0\code\platform\backend"
$base = "$env:TEMP\opencode\unify-redis-baseline"
$repo = "$env:TEMP\opencode\unify-redis-patch-repo"
$patch = "D:\work\rediscluterproject\docs\superpowers\patches\2026-10-29-unify-redis-util.patch"

# 相对路径 -> 基线里的文件名（备份时用 __ 替换了 \）
$files = @(
  "realserver\common\oms\src\main\java\com\sac\platform\realserver\oms\utils\RedisUtil.java",
  "realserver\common\oms\src\test\java\com\sac\platform\realserver\oms\utils\RedisClusterHashPipelineLiveTest.java",
  "common\idgenerator\src\main\java\com\sac\platform\common\utils\IdUtil.java",
  "common\idgenerator\src\main\java\com\sac\platform\common\utils\redis\RedisUtil.java",
  "common\idgenerator\src\test\java\com\sac\platform\common\utils\IdUtilRedisLockLiveTest.java",
  "common\idgenerator\pom.xml",
  "modelserver\services\src\main\java\com\sac\platform\modelserver\service\impl\NapstarOaTransformerServiceImpl.java",
  "modelserver\services\pom.xml"
)
# 新增的两个文件：基线里没有
$added = @(
  "realserver\common\oms\src\test\java\com\sac\platform\realserver\oms\utils\RedisClusterTestSupport.java",
  "realserver\common\oms\src\test\java\com\sac\platform\realserver\oms\utils\RedisUtilDeleteNamespaceLiveTest.java"
)

if (Test-Path $repo) { Remove-Item -Recurse -Force $repo -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $repo | Out-Null

# 1) 铺基线
foreach ($f in $files) {
  $dst = Join-Path $repo $f
  New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
  Copy-Item (Join-Path $base ($f -replace '\\','__')) $dst -Force
}

# 2) 提交基线
Push-Location $repo
git init -q
git config user.email "opencode@local"
git config user.name "opencode"
git config core.autocrlf false
git config core.eol lf
git add -A
git commit -q -m "baseline"

# 3) 覆盖成改完的版本
Pop-Location
foreach ($f in $files) {
  $dst = Join-Path $repo $f
  if (Test-Path (Join-Path $BE $f)) {
    Copy-Item (Join-Path $BE $f) $dst -Force
  } else {
    # 被删掉的文件：从合成 repo 里删掉 -> diff 里才会出现 deleted file mode
    Remove-Item $dst -Force
  }
}
foreach ($f in $added) {
  $dst = Join-Path $repo $f
  New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
  Copy-Item (Join-Path $BE $f) $dst -Force
}

# 4) 出 patch
Push-Location $repo
git add -A
git -c core.autocrlf=false -c core.eol=lf diff --cached --output=$patch
Pop-Location
"patch bytes = " + (Get-Item $patch).Length
```

> ⚠️ **`core.autocrlf=false` / `core.eol=lf` 必须加**：源文件行尾是混的
> （`.java` CRLF、`pom.xml` LF），默认设置会规范化行尾，patch 的「改动前」侧
> 就与磁盘对不上 → **应用失败**。
>
> ⚠️ **被删的文件必须显式处理**：`common/idgenerator/…/redis/RedisUtil.java`
> 在基线里**保留**、在改完的版本里**删掉**（上面的 `Remove-Item`），
> 这样 diff 里才会出现 `deleted file mode` 条目。
> 只复制还存在的文件 → `git add -A` 认为没变 → **删除会静默丢失**。

- [ ] **Step 2: 校验 patch**

```powershell
cd $BE
git -c core.autocrlf=false apply --reverse --check "D:\work\rediscluterproject\docs\superpowers\patches\2026-10-29-unify-redis-util.patch"
```

期望：退出码 **0**（磁盘上仍是 patch 的后像）。

往返校验（从纯净基线重建 → 与现网逐文件 SHA-256 比对）：
期望 `checked=N mismatches=0`。

- [ ] **Step 3: 更新 `docs/superpowers/patches/README.md`**

加一节「2026-10-29 — idgenerator 的 RedisUtil 壳被删掉」，
写明：改了什么、为什么（两段实质代码 + 三个死方法 + 一个壳）、
patch 的目标根与文件数、以及**验证 performed**（反向校验 exit 0 / 往返校验 mismatches=0 /
三个变异各自让一条用例变红）。

- [ ] **Step 4: 更新 `docs/HANDOFF.md`**

要改的地方：

1. 顶部的基线块：加上第十六轮的推送号、`idgenerator` 的单测数（4）、`oms` 的单测数（65）。
2. 「当前测试基线」表：`idgenerator` 3 → **4**；`oms` 63 → **65**；
   加上 `cd $BE\common\idgenerator; mvn -o dependency:tree` → **不含 `realserver-oms`**（新条目）。
3. 新增一节「第十六轮（2026-10-29）：合并两套 RedisUtil」，
   内容：问题（真正的债是「两段实质代码住在一个薄壳里」）、改动清单、
   四个关键决定（尤其是**不缓存模板**与**值格式不变**）、变异检验表、
   验证结果、留痕。
4. 「会话存档」一节：更新「一、代码在哪、改了什么」与「四、下一次会话该做什么」
   —— 把「合并三套 RedisUtil」标成**已完成**，并写清实际是**两套**。
5. 「五、这一轮踩过的坑」：加两条 ——
   ① **上下文会被销毁，模板不能缓存**（第十四轮的教训在这里再咬一次）；
   ② **napstarweb 的上下文里没有 `CommonDataMapper`** → `IdUtil` 绝不能变成 `@Component`。

- [ ] **Step 5: 提交并推送**

```powershell
cd D:\work\rediscluterproject
git add -A
git commit -F <提交信息文件>
$env:GIT_SSH="C:\Windows\System32\OpenSSH\ssh.exe"
git -c remote.origin.pushurl=git@github.com:leiming-cai/redis-cluster-install.git push origin main
```

> 提交信息写成**文件**再 `-F <file>`（PowerShell 没有 heredoc）。

---

## 完成标准

- [ ] `cd $BE\common\idgenerator; mvn -o clean test` → **4 通过 / 0 失败 / 0 跳过**
- [ ] `cd $BE\realserver\common\oms; mvn -o clean test` → **65 通过 / 0 失败 / 0 跳过**
- [ ] `cd $BE\realserver\plugins\rtdata-module; mvn -o test` → **14 通过 / 0 失败**
- [ ] `cd $BE; mvn -o clean install -DskipTests` → **44 个模块**全 SUCCESS
- [ ] `cd $AB; mvn -o clean install -DskipTests` → **13 个模块**全 SUCCESS
- [ ] `cd $BE\common\idgenerator; mvn -o dependency:tree` → **不含 `realserver-oms`**
- [ ] 三个变异**各自**让**恰好一条**用例变红
- [ ] patch 反向校验 exit 0；往返校验 `mismatches=0`
- [ ] `git status -sb` → `main...origin/main`（0 ahead / 0 behind）

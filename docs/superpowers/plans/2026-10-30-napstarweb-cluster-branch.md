# napstarweb 集群分支 + 读侧 pipeline 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 napstarweb 的 10 处 `executePipelined` 在 Redis Cluster 模式下不再抛 `UnsupportedOperationException`，并给 `oms` 的 `RedisClusterHashPipeline` 补上读侧按节点 pipeline（`getAllHashes` / `getAllValues`）。

**Architecture:** 两棵 Java 树各改一处：
① `oms` 的 `RedisClusterHashPipeline` 复用现有的槽位快照 / 节点分组 / 逐 key 兜底机制，新增两个读方法；
② napstarweb 的 10 个调用点各加一个 `if (redisClusterHelper.isCluster())` 分支 —— 写站点用 `redisTemplate.execute(cb)`（非 pipeline，回调体逐字复用），读站点用 oms 的读侧方法。

**Tech Stack:** Java 8 · Spring Data Redis 2.7.18 · Jedis 3.10.0 · JUnit 5 + Mockito（oms 已有）· Docker Redis 8 集群（`127.0.0.1:16379`）· bash（仓库守卫脚本）

**设计文档：** `docs/superpowers/specs/2026-10-30-napstarweb-cluster-branch-design.md`

---

## 环境常量

```powershell
# 本仓库（唯一的 git 仓库）
$REPO   = "D:\work\rediscluterproject"

# Java 源码树（都不是 git 仓库 → 改动只能以 patch 留痕）
$BE     = "D:\javawork\1.2\cpscloud1.0\code\platform\backend"        # realserver + modelserver
$AB     = "D:\javawork\1.2\cpscloud1.0\code\application\backend"    # napstarweb

# 构建必须用 JDK 8（oms 的 proguard 要 ${JAVA_HOME}/jre/lib/rt.jar，只有 JDK 8 有）
$JAVA8  = "D:\java\java-se-8u42-ri"
$M2     = "D:\java\apache-maven\mvnRepo"

# 真集群（Docker E2E 集群，socat 转发到宿主机）
$CLUSTER = "127.0.0.1:16379"
$PASSWORD = "CpsE2eClusterPw"
```

> ⚠️ **构建前确认 `JAVA_HOME`**：`oms` 的 proguard 配了 `${JAVA_HOME}/jre/lib/rt.jar`，
> JDK 9+ 没有这个路径 → `Can't read .../jre/lib/rt.jar`。
> ⚠️ **改完源码等 8 秒再构建** —— VSCode 的 ECJ 语言服务器会异步写进 `target/classes`，
> 产出带 `Error: Unresolved compilation problem` 的 class 文件（坑 21）。
> ⚠️ **绝不要用 `Set-Content` / `Out-File` 改 Java / YAML / 本仓库的 md** —— 会加 BOM + 把 LF 换成 CRLF。
> 一律用编辑工具。

## 文件清单

### `platform/backend`（Java 源码，非 git 仓库）

| 动作 | 文件 |
|---|---|
| Modify | `realserver/common/oms/src/main/java/com/sac/platform/realserver/oms/utils/RedisClusterHashPipeline.java` |
| Test | `realserver/common/oms/src/test/java/com/sac/platform/realserver/oms/utils/RedisClusterHashPipelineTest.java`（扩现有 28 条） |
| Test | `realserver/common/oms/src/test/java/com/sac/platform/realserver/oms/utils/RedisClusterHashPipelineLiveTest.java`（扩现有 4 条） |

### `application/backend`（Java 源码，非 git 仓库）

| 动作 | 文件 | 站点 |
|---|---|---|
| Modify | `napstarweb/monitor/pom.xml` | 显式声明 `realserver-oms` |
| Modify | `napstarweb/monitor/.../monitor/services/impl/SVGCacheServiceImpl.java` | W1（写） |
| Modify | `napstarweb/monitor/.../monitor/kafka/RTListener.java` | W2（写） |
| Modify | `napstarweb/monitor/.../monitor/services/SVGParseService.java` | W3（写）+ R5（string 读） |
| Modify | `napstarweb/monitor/.../monitor/cimg/services/impl/CanvasMonitorServiceImpl.java` | W4（写）+ R6（string 读） |
| Modify | `napstarweb/monitor/.../monitor/services/CalculateService.java` | R1 + R2（hash 读） |
| Modify | `napstarweb/monitor/.../monitor/services/CalculateForCanvasService.java` | R3 + R4（hash 读） |

### 本仓库（git）

| 动作 | 文件 |
|---|---|
| Create | `tests/probes/cluster-execute-probe.java` |
| Create | `scripts/probe-cluster-execute.sh` |
| Create | `tests/validate_java_pipelines.sh` |
| Modify | `tests/check_syntax.sh`（纳入新脚本的 `bash -n`） |
| Modify | `docs/OPERATIONS.md`（§4.5 加一条必读） |
| Modify | `docs/HANDOFF.md`（第十八轮章节） |
| Create | `docs/superpowers/patches/2026-10-30-napstarweb-cluster-branch-platform-backend.patch` |
| Create | `docs/superpowers/patches/2026-10-30-napstarweb-cluster-branch-application-backend.patch` |

---

## Task 0: 备份基线文件（**必须在任何改动之前**）

**Files:**
- Create: `%TEMP%/opencode/napstarweb-cluster-branch-baseline/`（**两棵 Java 树的基线副本**）

> **为什么放在最前面**：两棵 Java 树**都不是 git 仓库** → 没有 `git diff` 可用 →
> patch 只能靠「基线副本 vs 当前文件」对比生成。
> **一旦动手改了，基线就永远拿不回来了。**
> 所以这一步是整个计划的**前置条件**，不是收尾工作。

- [ ] **Step 1: 建基线目录并拷贝 platform 侧的 3 个文件**

```powershell
$BE    = "D:\javawork\1.2\cpscloud1.0\code\platform\backend"
$AB    = "D:\javawork\1.2\cpscloud1.0\code\application\backend"
$BASE  = "$env:TEMP\opencode\napstarweb-cluster-branch-baseline"

Remove-Item -Recurse -Force $BASE -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $BASE | Out-Null

$platformFiles = @(
  "realserver\common\oms\src\main\java\com\sac\platform\realserver\oms\utils\RedisClusterHashPipeline.java",
  "realserver\common\oms\src\test\java\com\sac\platform\realserver\oms\utils\RedisClusterHashPipelineTest.java",
  "realserver\common\oms\src\test\java\com\sac\platform\realserver\oms\utils\RedisClusterHashPipelineLiveTest.java"
)
foreach ($f in $platformFiles) {
    $dest = Join-Path $BASE "platform\$f"
    New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
    Copy-Item (Join-Path $BE $f) $dest
    "copied: $f"
}
```

- [ ] **Step 2: 拷贝 application 侧的 8 个文件**

```powershell
$applicationFiles = @(
  "pom.xml",
  "napstarweb\monitor\pom.xml",
  "napstarweb\monitor\src\main\java\com\sac\application\napstarweb\monitor\services\impl\SVGCacheServiceImpl.java",
  "napstarweb\monitor\src\main\java\com\sac\application\napstarweb\monitor\kafka\RTListener.java",
  "napstarweb\monitor\src\main\java\com\sac\application\napstarweb\monitor\services\SVGParseService.java",
  "napstarweb\monitor\src\main\java\com\sac\application\napstarweb\monitor\cimg\services\impl\CanvasMonitorServiceImpl.java",
  "napstarweb\monitor\src\main\java\com\sac\application\napstarweb\monitor\services\CalculateService.java",
  "napstarweb\monitor\src\main\java\com\sac\application\napstarweb\monitor\services\CalculateForCanvasService.java"
)
foreach ($f in $applicationFiles) {
    $dest = Join-Path $BASE "application\$f"
    New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
    Copy-Item (Join-Path $AB $f) $dest
    "copied: $f"
}
```

- [ ] **Step 3: 记录基线的 SHA-256（收尾时用来核对「磁盘上仍是 patch 的后像」）**

```powershell
Get-ChildItem $BASE -Recurse -File |
    Get-FileHash -Algorithm SHA256 |
    ForEach-Object { "{0}  {1}" -f $_.Hash, $_.Path.Substring($BASE.Length + 1) } |
    Set-Content -Encoding UTF8 "$env:TEMP\opencode\napstarweb-cluster-branch-baseline.sha256"
```

> ⚠️ 这个 `.sha256` 文件用 `Set-Content -Encoding UTF8` 是**安全的**（它不是 Java / YAML / md，
> 只是给人看的清单）。**不要**用它写 Java 或本仓库的 md。

- [ ] **Step 4: 确认基线里有 11 个文件**

```powershell
(Get-ChildItem $BASE -Recurse -File).Count
```

Expected: **11**（3 + 8）。

---

## Task 1: oms — 读侧按节点 pipeline（`getAllHashes` / `getAllValues`）

**Files:**
- Modify: `$BE/realserver/common/oms/src/main/java/com/sac/platform/realserver/oms/utils/RedisClusterHashPipeline.java`
- Test: `$BE/realserver/common/oms/src/test/java/com/sac/platform/realserver/oms/utils/RedisClusterHashPipelineTest.java`

> **前置事实（已核实，不要重新推导）**
> - `redis.clients.jedis.PipelineBase` 有 `hgetAll(byte[]) -> Response<Map<byte[],byte[]>>` 与 `get(byte[]) -> Response<byte[]>`（javap 确认）
> - `org.springframework.data.redis.serializer.SerializationUtils.deserialize(Map<byte[],byte[]>, RedisSerializer, RedisSerializer)` 是 **public static**
> - `RedisTemplate.postProcessResult` **原样返回**结果 → `redisTemplate.execute(cb)` 拿到的是**原始字节**，不会被二次反序列化
> - `JedisClusterConnection.hGetAll(byte[])` → `JedisCluster.hgetAll(key)`（按槽路由）
> - `JedisClusterConnection.get(byte[])` → `JedisCluster.get(key)`（按槽路由）

- [ ] **Step 1: 写失败的 Mockito 用例**

在 `RedisClusterHashPipelineTest` 里新增一个 serializer（**不动现有 28 条用的 `utf8Serializer()`** —— 那个只 stub 了 `serialize`）：

```java
    /** 读路径用的 serializer：serialize 与 deserialize 都要能用。 */
    @SuppressWarnings("unchecked")
    private static RedisSerializer<Object> utf8Codec() {
        RedisSerializer<Object> serializer = mock(RedisSerializer.class);
        when(serializer.serialize(any())).thenAnswer(
                invocation -> String.valueOf((Object) invocation.getArgument(0)).getBytes(StandardCharsets.UTF_8));
        when(serializer.deserialize(any())).thenAnswer(
                invocation -> new String((byte[]) invocation.getArgument(0), StandardCharsets.UTF_8));
        return serializer;
    }
```

再新增 5 条用例：

```java
    @Test
    void getAllHashesReturnsOneEntryPerKeyInTheGivenOrder() {
        Fixture f = new Fixture();
        f.seedSlots();
        doReturn(utf8Codec()).when(f.template).getHashKeySerializer();
        doReturn(utf8Codec()).when(f.template).getHashValueSerializer();

        List<String> low = keysInRange(0, 8191, 1);        // -> node A (10.0.0.1:6379)
        List<String> high = keysInRange(8192, 16383, 1);   // -> node B (10.0.0.2:6380)
        List<String> keys = new ArrayList<String>();
        keys.add(high.get(0));
        keys.add(low.get(0));
        keys.add(high.get(0));      // 同一个 key 出现两次：顺序不能塌成一格

        Map<byte[], byte[]> replyA = new LinkedHashMap<byte[], byte[]>();
        replyA.put("fieldA".getBytes(StandardCharsets.UTF_8), "valueA".getBytes(StandardCharsets.UTF_8));
        Map<byte[], byte[]> replyB = new LinkedHashMap<byte[], byte[]>();
        replyB.put("fieldB".getBytes(StandardCharsets.UTF_8), "valueB".getBytes(StandardCharsets.UTF_8));
        when(f.pipelineA.syncAndReturnAll()).thenReturn(Arrays.<Object>asList(replyA));
        when(f.pipelineB.syncAndReturnAll()).thenReturn(Arrays.<Object>asList(replyB, replyB));

        RedisClusterHashPipeline pipeline = new RedisClusterHashPipeline(f.template, f.factory);
        List<Map<String, Object>> result = pipeline.getAllHashes(keys);

        assertEquals(3, result.size());
        assertEquals("valueB", result.get(0).get("fieldB"));
        assertEquals("valueA", result.get(1).get("fieldA"));
        assertEquals("valueB", result.get(2).get("fieldB"));
    }

    @Test
    void getAllHashesReturnsAnEmptyMapForAMissingKey() {
        Fixture f = new Fixture();
        f.seedSlots();
        doReturn(utf8Codec()).when(f.template).getHashKeySerializer();
        doReturn(utf8Codec()).when(f.template).getHashValueSerializer();

        List<String> keys = keysInRange(0, 8191, 1);
        when(f.pipelineA.syncAndReturnAll())
                .thenReturn(Arrays.<Object>asList(new LinkedHashMap<byte[], byte[]>()));

        RedisClusterHashPipeline pipeline = new RedisClusterHashPipeline(f.template, f.factory);
        List<Map<String, Object>> result = pipeline.getAllHashes(keys);

        assertEquals(1, result.size());
        assertNotNull(result.get(0));
        assertTrue(result.get(0).isEmpty());
    }

    @Test
    void getAllHashesFallsBackToPerKeyReadsWhenTheConnectionIsNotAJedisCluster() {
        RedisTemplate<String, Object> template = mock(RedisTemplate.class);
        RedisConnectionFactory factory = mock(RedisConnectionFactory.class);
        RedisConnection plainConnection = mock(RedisConnection.class);
        doReturn(utf8Codec()).when(template).getKeySerializer();
        doReturn(utf8Codec()).when(template).getHashKeySerializer();
        doReturn(utf8Codec()).when(template).getHashValueSerializer();
        when(factory.getConnection()).thenReturn(plainConnection);

        Map<byte[], byte[]> raw = new LinkedHashMap<byte[], byte[]>();
        raw.put("f".getBytes(StandardCharsets.UTF_8), "v".getBytes(StandardCharsets.UTF_8));
        doReturn(raw).when(template).execute(any(RedisCallback.class));

        RedisClusterHashPipeline pipeline = new RedisClusterHashPipeline(template, factory);
        List<Map<String, Object>> result = pipeline.getAllHashes(Arrays.asList("k1"));

        assertEquals(1, result.size());
        assertEquals("v", result.get(0).get("f"));
    }

    @Test
    void getAllHashesReadsPerKeyWhenThePipelineRejectsAKey() {
        Fixture f = new Fixture();
        f.seedSlots();
        doReturn(utf8Codec()).when(f.template).getHashKeySerializer();
        doReturn(utf8Codec()).when(f.template).getHashValueSerializer();

        List<String> keys = keysInRange(0, 8191, 1);
        // MOVED 是「返回值」不是异常
        when(f.pipelineA.syncAndReturnAll()).thenReturn(Arrays.<Object>asList(
                new JedisMovedDataException("127.0.0.9:6379", 1)));
        Map<byte[], byte[]> raw = new LinkedHashMap<byte[], byte[]>();
        raw.put("f".getBytes(StandardCharsets.UTF_8), "fallback".getBytes(StandardCharsets.UTF_8));
        doReturn(raw).when(f.template).execute(any(RedisCallback.class));

        RedisClusterHashPipeline pipeline = new RedisClusterHashPipeline(f.template, f.factory);
        List<Map<String, Object>> result = pipeline.getAllHashes(keys);

        assertEquals(1, result.size());
        assertEquals("fallback", result.get(0).get("f"));
    }

    @Test
    void getAllValuesReturnsOneEntryPerKeyInTheGivenOrder() {
        Fixture f = new Fixture();
        f.seedSlots();
        doReturn(utf8Codec()).when(f.template).getValueSerializer();

        List<String> low = keysInRange(0, 8191, 1);
        List<String> high = keysInRange(8192, 16383, 1);
        List<String> keys = new ArrayList<String>();
        keys.add(high.get(0));
        keys.add(low.get(0));

        when(f.pipelineA.syncAndReturnAll())
                .thenReturn(Arrays.<Object>asList("valueA".getBytes(StandardCharsets.UTF_8)));
        when(f.pipelineB.syncAndReturnAll())
                .thenReturn(Arrays.<Object>asList("valueB".getBytes(StandardCharsets.UTF_8)));

        RedisClusterHashPipeline pipeline = new RedisClusterHashPipeline(f.template, f.factory);
        List<Object> result = pipeline.getAllValues(keys);

        assertEquals(2, result.size());
        assertEquals("valueB", result.get(0));
        assertEquals("valueA", result.get(1));
    }
```

需要新增的 import：`static org.junit.jupiter.api.Assertions.assertNotNull`、
`org.springframework.data.redis.core.RedisCallback`。

- [ ] **Step 2: 跑测试，确认它们失败**

```powershell
cd $BE\realserver\common\oms
$env:JAVA_HOME=$JAVA8
mvn -o -Dtest=RedisClusterHashPipelineTest test
```

Expected: **编译失败**，报 `cannot find symbol: method getAllHashes(List<String>)`。
（这正是「先红」的形态 —— 红在编译期，而不是「方法返回 null」。）

- [ ] **Step 3: 实现 `getAllHashes` / `getAllValues`**

在 `RedisClusterHashPipeline.java` 里：

**(a) 加 import**

```java
import org.springframework.data.redis.core.RedisCallback;
import org.springframework.data.redis.serializer.SerializationUtils;
```
**(b) 加两个公开方法 + 一个私有枚举**（放在 `putAllHashes` 之后）

```java
    /** 读操作的种类：hash（多 field）还是 string（单值）。 */
    private enum ReadKind {
        HASH, VALUE
    }

    /**
     * 集群模式下按节点 pipeline 读一批 hash key。
     *
     * <p>返回列表与 {@code keys} <b>等长同序</b> —— 调用方常用「下标对齐」消费结果
     * （napstarweb 的 {@code CalculateService.batchGetParam} 就是这样），
     * 顺序错了会<b>静默返回错位数据</b>。
     *
     * <p>每个元素是该 key 的 hash（按 hashKeySerializer / hashValueSerializer 反序列化），
     * key 不存在时是空 map。非集群部署（单机 / 哨兵）时退化为逐 key 读。
     */
    public List<Map<String, Object>> getAllHashes(List<String> keys) {
        List<Object> raw = readAll(keys, ReadKind.HASH);
        List<Map<String, Object>> result = new ArrayList<Map<String, Object>>(raw.size());
        for (Object item : raw) {
            result.add(deserializeHash(asHashBytes(item)));
        }
        return result;
    }
```

**(b2) 加 `getAllValues`**（放在 `getAllHashes` 之后）

```java
    /**
     * 集群模式下按节点 pipeline 读一批 string key。
     *
     * <p>返回列表与 {@code keys} <b>等长同序</b>；key 不存在时对应元素是 null。
     * 值用 valueSerializer 反序列化 —— 与写侧
     * （{@code valueSerializer.serialize(...)}）对称。
     */
    public List<Object> getAllValues(List<String> keys) {
        List<Object> raw = readAll(keys, ReadKind.VALUE);
        List<Object> result = new ArrayList<Object>(raw.size());
        RedisSerializer valueSerializer = redisTemplate.getValueSerializer();
        for (Object item : raw) {
            result.add(item == null ? null : valueSerializer.deserialize((byte[]) item));
        }
        return result;
    }
```

**(c) 加私有实现**（放在 `writePerKey` 之后）

```java
    /**
     * 按节点分组 pipeline 读一批 key。
     *
     * @return 与 keys 等长同序的<b>原始回复</b>（HASH 是 Map&lt;byte[],byte[]&gt;，
     *         VALUE 是 byte[]，key 不存在时是 null）。
     */
    private List<Object> readAll(List<String> keys, ReadKind kind) {
        if (keys == null || keys.isEmpty()) {
            return new ArrayList<Object>();
        }
        JedisCluster jedisCluster = clusterOrNull();
        if (jedisCluster == null) {
            return readPerKey(keys, kind);
        }

        SlotSnapshot snapshot = snapshot(false);
        // 按「下标」分组而不是按 key —— 同一个 key 在一批里出现多次也能正确回填
        Map<String, List<Integer>> byNode = new LinkedHashMap<String, List<Integer>>();
        List<Integer> unmapped = new ArrayList<Integer>();
        for (int i = 0; i < keys.size(); i++) {
            String owner = null;
            if (snapshot != null) {
                owner = snapshot.ownerOf(JedisClusterCRC16.getSlot(keyBytes(keys.get(i))));
            }
            if (owner == null) {
                unmapped.add(Integer.valueOf(i));
                continue;
            }
            List<Integer> indices = byNode.get(owner);
            if (indices == null) {
                indices = new ArrayList<Integer>();
                byNode.put(owner, indices);
            }
            indices.add(Integer.valueOf(i));
        }

        Object[] values = new Object[keys.size()];
        boolean needsTopologyRefresh = false;
        for (Map.Entry<String, List<Integer>> entry : byNode.entrySet()) {
            JedisPool pool = poolFor(jedisCluster, entry.getKey());
            if (pool == null) {
                logger.warn("No JedisPool for {}; reading {} keys one by one",
                        entry.getKey(), entry.getValue().size());
                needsTopologyRefresh = true;
                readPerKeyInto(keys, entry.getValue(), kind, values);
                continue;
            }
            List<Object> replies;
            try {
                replies = runReadPipeline(pool, entry.getValue(), keys, kind);
            } catch (JedisConnectionException e) {
                logger.warn("Node {} unreachable ({}); refreshing topology and reading {} keys one by one",
                        entry.getKey(), e.getMessage(), entry.getValue().size());
                refreshQuietly();
                readPerKeyInto(keys, entry.getValue(), kind, values);
                continue;
            }
            if (replies == null || replies.size() != entry.getValue().size()) {
                logger.warn("Read pipeline on node {} returned {} replies for {} keys; reading them one by one",
                        entry.getKey(), replies == null ? 0 : replies.size(), entry.getValue().size());
                needsTopologyRefresh = true;
                readPerKeyInto(keys, entry.getValue(), kind, values);
                continue;
            }
            for (int i = 0; i < replies.size(); i++) {
                Object reply = replies.get(i);
                int index = entry.getValue().get(i).intValue();
                if (reply instanceof JedisDataException) {
                    // MOVED / ASK / WRONGTYPE … 是「返回值」不是异常
                    if (!(reply instanceof JedisAskDataException)) {
                        needsTopologyRefresh = true;
                    }
                    values[index] = readOneKey(keys.get(index), kind);
                    continue;
                }
                values[index] = reply;
            }
        }
        if (needsTopologyRefresh) {
            refreshQuietly();
        }
        for (Integer index : unmapped) {
            values[index.intValue()] = readOneKey(keys.get(index.intValue()), kind);
        }

        List<Object> result = new ArrayList<Object>(values.length);
        for (int i = 0; i < values.length; i++) {
            result.add(values[i]);
        }
        return result;
    }

    /** 一条节点 pipeline：逐 key 发命令，返回原始回复。 */
    private List<Object> runReadPipeline(JedisPool pool, List<Integer> indices, List<String> keys, ReadKind kind) {
        Jedis jedis = pool.getResource();
        Pipeline pipeline = null;
        boolean synced = false;
        try {
            pipeline = jedis.pipelined();
            for (Integer index : indices) {
                byte[] rawKey = keyBytes(keys.get(index.intValue()));
                if (kind == ReadKind.HASH) {
                    pipeline.hgetAll(rawKey);
                } else {
                    pipeline.get(rawKey);
                }
            }
            List<Object> replies = pipeline.syncAndReturnAll();
            synced = true;
            return replies;
        } finally {
            if (!synced && pipeline != null) {
                // 构建期异常：先把已排队的命令刷出去，恢复协议对齐
                try {
                    pipeline.sync();
                } catch (Exception e) {
                    logger.warn("Failed to drain an aborted read pipeline: {}", e.getMessage());
                }
            }
            jedis.close();
        }
    }

    private List<Object> readPerKey(List<String> keys, ReadKind kind) {
        Object[] values = new Object[keys.size()];
        List<Integer> all = new ArrayList<Integer>(keys.size());
        for (int i = 0; i < keys.size(); i++) {
            all.add(Integer.valueOf(i));
        }
        readPerKeyInto(keys, all, kind, values);
        List<Object> result = new ArrayList<Object>(values.length);
        for (int i = 0; i < values.length; i++) {
            result.add(values[i]);
        }
        return result;
    }

    private void readPerKeyInto(List<String> keys, List<Integer> indices, ReadKind kind, Object[] values) {
        for (Integer index : indices) {
            values[index.intValue()] = readOneKey(keys.get(index.intValue()), kind);
        }
    }

    /**
     * 逐 key 读。用 redisTemplate.execute 而不是 opsForHash().entries()，
     * 是为了拿到<b>原始字节</b> —— 与 pipeline 路径的返回形态一致，
     * 反序列化只在一个地方做。
     */
    private Object readOneKey(String key, ReadKind kind) {
        if (kind == ReadKind.HASH) {
            return redisTemplate.execute((RedisCallback<Map<byte[], byte[]>>) connection ->
                    connection.hGetAll(keyBytes(key)));
        }
        return redisTemplate.execute((RedisCallback<byte[]>) connection ->
                connection.get(keyBytes(key)));
    }

    @SuppressWarnings("unchecked")
    private Map<byte[], byte[]> asHashBytes(Object raw) {
        if (raw == null) {
            return null;
        }
        return (Map<byte[], byte[]>) raw;
    }

    /**
     * 反序列化 hash。
     *
     * <p>形状与 SDR 的 {@code deserializeMixedResults} 对齐：非空 hash 走
     * {@code SerializationUtils.deserialize(raw, hashKeySerializer, hashValueSerializer)}
     * → {@code LinkedHashMap<String,Object>}。
     *
     * <p>⚠️ SDR 对<b>空 hash</b> 有特例（{@code !isEmpty()} 判断落空 → 返回未反序列化的
     * 原始 map）。本方法返回反序列化后的空 map —— <b>差异不可观测</b>
     * （空 map 的 get 都返回 null），真集群测试会钉住这一点。
     */
    @SuppressWarnings("unchecked")
    private Map<String, Object> deserializeHash(Map<byte[], byte[]> raw) {
        if (raw == null || raw.isEmpty()) {
            return new LinkedHashMap<String, Object>();
        }
        RedisSerializer hashKeySerializer = redisTemplate.getHashKeySerializer();
        RedisSerializer hashValueSerializer = redisTemplate.getHashValueSerializer();
        return (Map<String, Object>) SerializationUtils.deserialize(
                raw, hashKeySerializer, hashValueSerializer);
    }
```

- [ ] **Step 4: 跑测试，确认它们变绿**

```powershell
cd $BE\realserver\common\oms
$env:JAVA_HOME=$JAVA8
mvn -o -Dtest=RedisClusterHashPipelineTest test
```

Expected: 33 条全绿（原 28 + 新 5），`BUILD SUCCESS`。

- [ ] **Step 5: 跑整模块，确认没有回归**

```powershell
mvn -o clean test
```

Expected: **71 通过 / 0 失败 / 0 跳过**（基线 66 + 新 5；live test 的 5 条需要集群在跑）。

- [ ] **Step 6: 提交（Java 树不是 git 仓库 → 不提交，只做 patch 留痕）**

⚠️ **两棵 Java 树都不是 git 仓库** → 这一步**不做 git commit**。
patch 留痕统一在 Task 14。先记录一下当前状态：

```powershell
# 确认磁盘上的文件确实被改了（反向校验的原料）
Select-String -Path "$BE\realserver\common\oms\src\main\java\com\sac\platform\realserver\oms\utils\RedisClusterHashPipeline.java" -Pattern "getAllHashes|getAllValues"
```

Expected: 4 处匹配（2 个方法签名 + 2 个调用点）。

---

## Task 2: oms — 真集群 live test + 变异检验

**Files:**
- Test: `$BE/realserver/common/oms/src/test/java/com/sac/platform/realserver/oms/utils/RedisClusterHashPipelineLiveTest.java`

> **前置**：集群必须在跑。
> ```powershell
> docker ps --format "{{.Names}}`t{{.Status}}"
> docker exec rc-cpsweb-node-a /opt/software/redis-8.10.0/bin/redis-cli -a CpsE2eClusterPw --no-auth-warning -h 127.0.0.1 -p 6379 cluster info
> ```
> Expected: `cluster_state:ok` / `cluster_slots_assigned:16384` / `cluster_known_nodes:6`。
> ⚠️ **容器重启过就会变成 `cluster_state:fail`** → 必须重跑
> `%TEMP%\opencode\set-announce.sh`（**注意是 `set-announce.sh`，不是 `restore-cluster.sh`** ——
> 后者会把 bus-port 也改掉，正是「坑 9」说的会让节点链路断掉的改法）。

- [ ] **Step 1: 写 5 条真集群用例**

在 `RedisClusterHashPipelineLiveTest` 里新增（复用现有的 `withLiveCluster((template, pipeline) -> {...})` 助手）：

```java
    /**
     * 读侧的核心契约：批量写进去的每一个 hash，都必须能被 getAllHashes 原样读回来。
     *
     * <p>这条断言同时覆盖：分组有没有算错 slot、有没有读到错误的 master、
     * 以及**值序列化**是否与写路径一致（不一致的话读出来是乱码或类型不符）。
     */
    @Test
    void readsEveryHashOfTheBatchBackUnchanged() {
        withLiveCluster((template, pipeline) -> {
            Map<String, Map<String, String>> batch = new LinkedHashMap<>();
            for (int i = 0; i < 200; i++) {
                String key = KEY_PREFIX + "readback:" + i;
                Map<String, String> hash = new LinkedHashMap<>();
                hash.put("Value", "12.34,171234567800" + (i % 10) + ",1");
                hash.put("Quality", "1");
                batch.put(key, hash);
            }
            pipeline.putAllHashes(batch);

            List<String> keys = new ArrayList<>(batch.keySet());
            List<Map<String, Object>> read = pipeline.getAllHashes(keys);

            assertEquals(keys.size(), read.size());
            for (int i = 0; i < keys.size(); i++) {
                Map<String, Object> entry = read.get(i);
                assertNotNull(entry, "hash was not read back: " + keys.get(i));
                assertEquals(batch.get(keys.get(i)).size(), entry.size(),
                        "hash size mismatch for " + keys.get(i));
                for (Map.Entry<String, String> field : batch.get(keys.get(i)).entrySet()) {
                    assertEquals(field.getValue(), String.valueOf(entry.get(field.getKey())),
                            "value mismatch for " + keys.get(i) + " field " + field.getKey());
                }
            }
        });
    }

    /**
     * 读侧的顺序契约：返回列表必须与入参 key 顺序一致。
     *
     * <p>为什么这条必须钉死：napstarweb 的调用方是**按下标**对齐的
     * （{@code results.get(svgIdList.indexOf(t))}），
     * 顺序错了会**静默返回错位数据** —— 不报错，只是数据对不上。
     */
    @Test
    void getAllHashesReturnsEntriesInTheSameOrderAsTheKeys() {
        withLiveCluster((template, pipeline) -> {
            Map<String, Map<String, String>> batch = new LinkedHashMap<>();
            for (int i = 0; i < 50; i++) {
                Map<String, String> hash = new LinkedHashMap<>();
                hash.put("f", "value-" + i);
                batch.put(KEY_PREFIX + "order:" + i, hash);
            }
            pipeline.putAllHashes(batch);

            // 故意打乱成倒序，并插入一个不存在的 key
            List<String> keys = new ArrayList<>(batch.keySet());
            java.util.Collections.reverse(keys);
            keys.add(KEY_PREFIX + "order:missing");

            List<Map<String, Object>> read = pipeline.getAllHashes(keys);

            assertEquals(keys.size(), read.size());
            for (int i = 0; i < keys.size(); i++) {
                String expected = keys.get(i).endsWith(":missing")
                        ? null : "value-" + keys.get(i).substring(keys.get(i).lastIndexOf(':') + 1);
                if (expected == null) {
                    assertTrue(read.get(i).isEmpty(),
                            "a missing key must read back as an empty hash: " + keys.get(i));
                } else {
                    assertEquals(expected, String.valueOf(read.get(i).get("f")),
                            "order mismatch at index " + i + " for " + keys.get(i));
                }
            }
        });
    }

    /** 空 hash 的特例：SDR 的 deserializeMixedResults 对空 hash 返回未反序列化的原始 map，
     *  本类返回反序列化后的空 map —— 差异必须不可观测。 */
    @Test
    void readSideReturnsAnEmptyMapForAMissingKey() {
        withLiveCluster((template, pipeline) -> {
            List<String> keys = Arrays.asList(KEY_PREFIX + "definitely-missing");
            List<Map<String, Object>> read = pipeline.getAllHashes(keys);

            assertEquals(1, read.size());
            assertNotNull(read.get(0));
            assertTrue(read.get(0).isEmpty());
            assertNull(read.get(0).get("anything"));
        });
    }

    /** string 读：值必须与写进去的一致。 */
    @Test
    void readsEveryValueOfTheBatchBackUnchanged() {
        withLiveCluster((template, pipeline) -> {
            List<String> keys = new ArrayList<>();
            for (int i = 0; i < 50; i++) {
                String key = KEY_PREFIX + "value:" + i;
                template.opsForValue().set(key, "v-" + i);
                keys.add(key);
            }
            List<Object> read = pipeline.getAllValues(keys);

            assertEquals(keys.size(), read.size());
            for (int i = 0; i < keys.size(); i++) {
                assertEquals("v-" + keys.get(i).substring(keys.get(i).lastIndexOf(':') + 1),
                        String.valueOf(read.get(i)));
            }
        });
    }

    /** 一个批次必须真的被分到多个 master —— 否则「分组」这件事根本没被验证。 */
    @Test
    void readSideSpreadsTheBatchAcrossSeveralMastersWithoutAnyMovedRedirect() {
        withLiveCluster((template, pipeline) -> {
            Map<String, Map<String, String>> batch = new LinkedHashMap<>();
            for (int i = 0; i < 300; i++) {
                Map<String, String> hash = new LinkedHashMap<>();
                hash.put("f", "v" + i);
                batch.put(KEY_PREFIX + "spread:" + i, hash);
            }
            pipeline.putAllHashes(batch);

            List<String> keys = new ArrayList<>(batch.keySet());
            List<Map<String, Object>> read = pipeline.getAllHashes(keys);

            assertEquals(keys.size(), read.size());
            // 这批 key 必须落在多个 master 上 —— 只扫第一个 master 的实现也必须被抓出来
            Map<String, Integer> perMaster =
                    RedisClusterTestSupport.countKeysPerMaster(template, new LinkedHashSet<>(keys));
            int mastersWithKeys = 0;
            for (Integer count : perMaster.values()) {
                if (count != null && count > 0) {
                    mastersWithKeys++;
                }
            }
            assertTrue(mastersWithKeys > 1,
                    "the batch must span several masters, but spanned " + mastersWithKeys
                            + " (" + perMaster + ")");
        });
    }
```

需要新增的 import：`java.util.ArrayList`、`java.util.Arrays`、`java.util.LinkedHashMap`、
`java.util.LinkedHashSet`、`java.util.List`、`java.util.Map`、
`static org.junit.jupiter.api.Assertions.assertNull`。

> ✅ `RedisClusterTestSupport` 已有两个包级 static 方法（本测试类同包，直接可用）：
> `masterAddresses(RedisTemplate)` 与 `countKeysPerMaster(RedisTemplate, Set<String>)`。
> **不要新造方法名**。

- [ ] **Step 2: 跑 live test，确认它们通过**

```powershell
cd $BE\realserver\common\oms
$env:JAVA_HOME=$JAVA8
mvn -o -Dtest=RedisClusterHashPipelineLiveTest test
```

Expected: 9 条全绿（原 4 + 新 5），`Skipped: 0`。

> ⚠️ **集群不在时它们会「跳过」而不是变红**（`Assumptions.assumeTrue`）。
> → **必须确认 `Skipped: 0`**，否则等于没跑。

- [ ] **Step 3: 变异检验 —— 每条变异各自让**恰好一条**用例变红**

逐条做，做完立刻还原。记录每条变红的是哪条用例。

| # | 变异 | 预期变红的用例 |
|---|---|---|
| M1 | 把 `readAll` 里的「按入参顺序回填」改成「按节点分组顺序回填」（即 `values[index]` 改成 `values[position++]`，忽略原下标） | `getAllHashesReturnsEntriesInTheSameOrderAsTheKeys` + `getAllHashesReturnsOneEntryPerKeyInTheGivenOrder` |
| M2 | 把 `getAllHashes` 里的 `deserializeHash` 换成「直接返回原始 map，不反序列化」 | `readsEveryHashOfTheBatchBackUnchanged` |
| M3 | 把 `deserializeHash` 的空 map 分支去掉（返回 `null`） | `readSideReturnsAnEmptyMapForAMissingKey` |
| M4 | 把分组改成「所有 key 都塞给第一个节点」 | `readSideSpreadsTheBatchAcrossSeveralMastersWithoutAnyMovedRedirect` + `getAllHashesReturnsOneEntryPerKeyInTheGivenOrder` |
| M5 | 把 `readOneKey` 的 `execute` 换成 `opsForHash().entries()`（形状变了：已反序列化） | `getAllHashesReadsPerKeyWhenThePipelineRejectsAKey` |

```powershell
# 变异示例（M1）：把 values[index] = reply; 改成 values[position++] = reply;
# 做完必须 git-less 还原 —— 用编辑工具把代码改回去，并确认文件内容与变异前一致
```

- [ ] **Step 4: 确认还原，跑全套**

```powershell
mvn -o clean test
```

Expected: **76 通过 / 0 失败 / 0 跳过**（原 66 + 5 Mockito + 5 live）。

---

## Task 3: 重装 `oms`（下游必须拿到新方法）

**Files:**
- Build: `$BE/realserver/common/oms`

- [ ] **Step 1: 装到本地仓库**

```powershell
cd $BE\realserver\common\oms
$env:JAVA_HOME=$JAVA8
mvn -o clean install -DskipTests
```

Expected: `BUILD SUCCESS`，`Installing .../realserver-oms-1.0.14.jar`。

> ⚠️ **这一步不能跳过**：napstarweb 编译时取的是**本地仓库里的 jar**，不是源码树。
> 不重装 → napstarweb 编译报 `cannot find symbol: method getAllHashes`。

- [ ] **Step 2: 确认 jar 里真的有新方法**

```powershell
& "$JAVA8\bin\javap.exe" -classpath "$M2\com\sac\platform\realserver-oms\1.0.14\realserver-oms-1.0.14.jar" `
    com.sac.platform.realserver.oms.utils.RedisClusterHashPipeline | Select-String "getAllHashes|getAllValues"
```

Expected: 两行（`public java.util.List<java.util.Map<java.lang.String, java.lang.Object>> getAllHashes(java.util.List<java.lang.String>);` 与 `... getAllValues(...)`）。

> ⚠️ **本地仓库里的 oms jar 是 proguard 处理过的** —— `RedisPropertiesConfig` / `RedisUtilConfig`
> **已被改名**。这不影响 `RedisClusterHashPipeline`（它不是配置类），
> 但如果 javap 找不到类，先 `jar tf` 看一眼里面到底有什么。

---

## Task 4: 把实测证据固化进仓库（探针脚本）

**Files:**
- Create: `tests/probes/cluster-execute-probe.java`
- Create: `scripts/probe-cluster-execute.sh`

> **为什么做**：整个改造的地基是「集群下 `executePipelined` 抛异常、`execute` 正常」。
> 这个事实现在只存在于 `%TEMP%\opencode\probe\`（临时目录）。
> 固化进仓库 → 下一个会话不必重新推导，也能随时复现。

- [ ] **Step 1: 写探针**

`tests/probes/cluster-execute-probe.java`（**内容照抄本会话已跑过并验证过的探针**）：

```java
import org.springframework.data.redis.connection.RedisClusterConfiguration;
import org.springframework.data.redis.connection.RedisConnection;
import org.springframework.data.redis.connection.jedis.JedisClientConfiguration;
import org.springframework.data.redis.connection.jedis.JedisConnectionFactory;
import org.springframework.data.redis.core.RedisCallback;
import org.springframework.data.redis.core.RedisTemplate;
import org.springframework.data.redis.core.SessionCallback;
import org.springframework.data.redis.serializer.GenericJackson2JsonRedisSerializer;
import org.springframework.data.redis.serializer.StringRedisSerializer;

import java.util.Arrays;
import java.util.Collections;
import java.util.List;

/**
 * 探针：SDR 2.7.18 + jedis 3.10.0，在【真 Redis 集群】下对比
 * executePipelined(...) 与 execute(...) 的行为。
 *
 * 这是 napstarweb 集群分支改造的【地基】：
 *   - executePipelined 在集群下必抛 UnsupportedOperationException（回调体一次都不跑）
 *   - execute 在集群下正常，且每条单 key 命令按 slot 正确路由
 *
 * 装配方式与生产 RedisUtilConfig.RedisClusterConfig 一致。
 */
public class ClusterExecuteProbe {

    public static void main(String[] args) {
        try {
            run(args);
        } catch (Throwable t) {
            System.out.println("FATAL: " + t);
            t.printStackTrace(System.out);
            System.exit(2);
        }
        System.out.flush();
        System.exit(0);
    }

    static void run(String[] args) {
        String nodes = args.length > 0 ? args[0] : "127.0.0.1:16379";
        String password = args.length > 1 ? args[1] : "CpsE2eClusterPw";

        RedisClusterConfiguration clusterConfig =
                new RedisClusterConfiguration(Arrays.asList(nodes.split(",")));
        if (!password.isEmpty()) {
            clusterConfig.setPassword(password);
        }
        clusterConfig.setMaxRedirects(3);

        JedisClientConfiguration clientConfig = JedisClientConfiguration.builder()
                .usePooling()
                .poolConfig(new org.apache.commons.pool2.impl.GenericObjectPoolConfig())
                .and()
                .build();

        JedisConnectionFactory factory = new JedisConnectionFactory(clusterConfig, clientConfig);
        factory.afterPropertiesSet();

        RedisTemplate<String, Object> template = new RedisTemplate<>();
        template.setConnectionFactory(factory);
        template.setKeySerializer(new StringRedisSerializer());
        template.setHashKeySerializer(new StringRedisSerializer());
        template.setHashValueSerializer(new GenericJackson2JsonRedisSerializer());
        template.setValueSerializer(new GenericJackson2JsonRedisSerializer());
        template.afterPropertiesSet();

        int failures = 0;

        RedisConnection conn = factory.getConnection();
        System.out.println("connection class = " + conn.getClass().getName());
        if (!"org.springframework.data.redis.connection.jedis.JedisClusterConnection".equals(
                conn.getClass().getName())) {
            System.out.println("FAIL: expected JedisClusterConnection");
            failures++;
        }
        System.out.println("PING = " + conn.ping());
        conn.close();

        // 1. 对照组：非 pipeline 的 opsForHash().putAll()
        try {
            template.opsForHash().putAll("probe:ctl", Collections.singletonMap("f1", "v1"));
            System.out.println("OK   opsForHash().putAll -> " + template.opsForHash().entries("probe:ctl"));
            template.delete("probe:ctl");
        } catch (Throwable e) {
            System.out.println("FAIL opsForHash().putAll -> " + e);
            failures++;
        }

        // 2. executePipelined 在集群下必须抛（这是改造的前提）
        try {
            template.executePipelined(new RedisCallback<Object>() {
                @Override
                public Object doInRedis(RedisConnection c) {
                    c.hSet("probe:single".getBytes(), "f".getBytes(), "v".getBytes());
                    System.out.println("  >>> 回调体执行了（说明命令发出去了）");
                    return null;
                }
            });
            System.out.println("FAIL executePipelined did NOT throw (cluster mode?)");
            failures++;
        } catch (UnsupportedOperationException e) {
            System.out.println("OK   executePipelined threw UnsupportedOperationException: " + e.getMessage());
        } catch (Throwable e) {
            System.out.println("FAIL executePipelined threw the wrong type: " + e);
            failures++;
        }

        // 3. execute 在集群下必须能写能读
        try {
            template.execute(new RedisCallback<Object>() {
                @Override
                public Object doInRedis(RedisConnection c) {
                    c.hSet("probe:exec".getBytes(), "f".getBytes(), "v".getBytes());
                    System.out.println("  >>> 回调体执行了（说明命令发出去了）");
                    return null;
                }
            });
            Object read = template.opsForHash().get("probe:exec", "f");
            System.out.println("OK   execute wrote, read back = " + read);
            if (!"v".equals(String.valueOf(read))) {
                System.out.println("FAIL execute write did not land");
                failures++;
            }
            template.delete("probe:exec");
        } catch (Throwable e) {
            System.out.println("FAIL execute -> " + e);
            failures++;
        }

        // 4. SessionCallback 重载同样抛
        try {
            template.executePipelined(new SessionCallback<Object>() {
                @Override
                @SuppressWarnings("unchecked")
                public <K, V> Object execute(
                        org.springframework.data.redis.core.RedisOperations<K, V> operations) {
                    return null;
                }
            });
            System.out.println("FAIL executePipelined(SessionCallback) did NOT throw");
            failures++;
        } catch (UnsupportedOperationException e) {
            System.out.println("OK   executePipelined(SessionCallback) threw UnsupportedOperationException");
        } catch (Throwable e) {
            System.out.println("FAIL executePipelined(SessionCallback) threw the wrong type: " + e);
            failures++;
        }

        factory.destroy();
        System.out.println(failures == 0 ? "PROBE PASSED" : "PROBE FAILED (" + failures + ")");
        if (failures != 0) {
            throw new IllegalStateException("probe failures: " + failures);
        }
    }
}
```

- [ ] **Step 2: 写运行脚本**

`scripts/probe-cluster-execute.sh`：

```bash
#!/usr/bin/env bash
# 在真 Redis 集群上验证「executePipelined 抛异常 / execute 正常」这条地基事实。
#
# 用法:
#   PROBE_JAR=<napstarweb 的 fat jar> bash scripts/probe-cluster-execute.sh
#
# 默认从 application/backend 的构建产物里取 classpath
# （那里面是 napstarweb 真正打包进去的依赖版本）。
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AB_DIR="${AB_DIR:-D:/javawork/1.2/cpscloud1.0/code/application/backend}"
PROBE_JAR="${PROBE_JAR:-$AB_DIR/napstarweb/web-controller/target/web-controller-1.0.14.jar}"
JAVA_HOME="${JAVA_HOME:-D:/java/java-se-8u42-ri}"
CLUSTERS="${CLUSTERS:-127.0.0.1:16379}"
PASSWORD="${PASSWORD:-CpsE2eClusterPw}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

die() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$PROBE_JAR" ] || die "fat jar not found: $PROBE_JAR (set PROBE_JAR, or build napstarweb first)"
[ -x "$JAVA_HOME/bin/javac" ] || die "JDK 8 not found: $JAVA_HOME (set JAVA_HOME)"

echo "== extracting BOOT-INF/lib from $PROBE_JAR =="
( cd "$WORK_DIR" && "$JAVA_HOME/bin/jar" xf "$PROBE_JAR" \
    BOOT-INF/lib/spring-data-redis-2.7.18.jar \
    BOOT-INF/lib/spring-data-commons-2.7.18.jar \
    BOOT-INF/lib/spring-data-keyvalue-2.7.18.jar \
    BOOT-INF/lib/jedis-3.10.0.jar \
    BOOT-INF/lib/commons-pool2-2.11.1.jar \
    BOOT-INF/lib/spring-core-5.3.39.jar \
    BOOT-INF/lib/spring-beans-5.3.39.jar \
    BOOT-INF/lib/spring-context-5.3.39.jar \
    BOOT-INF/lib/spring-tx-5.3.39.jar \
    BOOT-INF/lib/spring-jcl-5.3.39.jar \
    BOOT-INF/lib/spring-expression-5.3.39.jar \
    BOOT-INF/lib/spring-aop-5.3.39.jar \
    BOOT-INF/lib/jackson-databind-2.14.2.jar \
    BOOT-INF/lib/jackson-core-2.13.5.jar \
    BOOT-INF/lib/jackson-annotations-2.13.5.jar \
    BOOT-INF/lib/slf4j-api-1.7.36.jar ) || die "failed to extract BOOT-INF/lib"

CP="$(find "$WORK_DIR/BOOT-INF/lib" -name '*.jar' | tr '\n' ';')"
[ -n "$CP" ] || die "no jars extracted"

echo "== compiling the probe =="
"$JAVA_HOME/bin/javac" -encoding UTF-8 -cp "$CP" -d "$WORK_DIR" \
    "$REPO_DIR/tests/probes/cluster-execute-probe.java" || die "compile failed"

echo "== running the probe against $CLUSTERS =="
"$JAVA_HOME/bin/java" -cp "$WORK_DIR;$CP" ClusterExecuteProbe "$CLUSTERS" "$PASSWORD"
rc=$?
[ "$rc" -eq 0 ] || die "probe exited with $rc"
echo "PROBE OK"
```

- [ ] **Step 3: 跑探针，确认它通过**

```bash
docker run --rm -v "D:/work/rediscluterproject:/repo" -w /repo rc-e2e-runner:local \
  bash /repo/scripts/probe-cluster-execute.sh
```

> ⚠️ **宿主机没有可用 bash**（`bash.exe` 是坏的 WSL shim）→ 必须走容器。
> 若容器里没有 JDK 8，就在**宿主机**跑（Windows 上有 JDK 8 的 `java.exe`）：
> ```powershell
> $env:JAVA_HOME="D:\java\java-se-8u42-ri"
> bash scripts/probe-cluster-execute.sh    # 需要一个可用的 bash；否则在 Git Bash / WSL 里跑
> ```

Expected: 输出 `PROBE PASSED`，且 `PROBE OK`。

- [ ] **Step 4: 提交**

```powershell
cd $REPO
git add tests/probes/cluster-execute-probe.java scripts/probe-cluster-execute.sh
git commit -m "test(probe): pin the fact that cluster mode rejects SDR pipelines

SDR 2.7.18 throws UnsupportedOperationException from
JedisClusterConnection.openPipeline(), so RedisTemplate.executePipelined
never runs the callback in cluster mode. execute() works and routes each
single-key command by slot.

This probe keeps that premise reproducible instead of leaving it in a
temporary directory."
```

---

## Task 5: napstarweb — 显式声明 `realserver-oms` 依赖

**Files:**
- Modify: `$AB/pom.xml`（dependencyManagement）
- Modify: `$AB/napstarweb/monitor/pom.xml`

> **为什么要显式声明**：napstarweb 要 `import com.sac.platform.realserver.oms.utils.RedisClusterHashPipeline`
> 与 `RedisClusterHelper`。它们现在只是**传递依赖**（`monitor → realserver-service → realserver-oms`）。
> 直接 import 传递依赖的类属于「用了未声明的依赖」——
> 第十六轮给 `model-service` 加 `realserver-oms` 就是这个先例。

- [ ] **Step 1: 在 `application/backend/pom.xml` 的 dependencyManagement 里加一条**

在 `realserver-service` 那条之后：

```xml
			<dependency>
				<groupId>com.sac.platform</groupId>
				<artifactId>realserver-oms</artifactId>
				<version>${platform.version}</version>
			</dependency>
```

> `${platform.version}` 是版本区间 `[1.0.0,2.0.0)`，覆盖已安装的 `1.0.14` ✅

- [ ] **Step 2: 在 `napstarweb/monitor/pom.xml` 里加一条**

在 `realserver-service` 那条之后：

```xml
		<dependency>
			<groupId>com.sac.platform</groupId>
			<artifactId>realserver-oms</artifactId>
		</dependency>
```

- [ ] **Step 3: 编译验证依赖能解析**

```powershell
cd $AB\napstarweb\monitor
$env:JAVA_HOME=$JAVA8
mvn -o -DskipTests compile
```

Expected: `BUILD SUCCESS`。

---

## Task 6: W1 — `SVGCacheServiceImpl.loadRTConfigKafka`

**Files:**
- Modify: `$AB/napstarweb/monitor/src/main/java/com/sac/application/napstarweb/monitor/services/impl/SVGCacheServiceImpl.java:39`

> **W1 的影响**：`StartupRunner.run()` 的 try 块**第一句**。
> 它抛异常 → 后面 7 个初始化（colorConfig / hangTag / jkParse / popupMenu）**全部被跳过**，
> 而 catch 只打日志 → **应用启动成功、功能却是残的**。

- [ ] **Step 1: 加 import 与字段**

```java
import com.sac.platform.realserver.oms.utils.RedisClusterHelper;
```

```java
    @Autowired
    private RedisClusterHelper redisClusterHelper;
```

- [ ] **Step 2: 把回调体抽成局部变量，两个分支共用**

把

```java
        redisTemplate.executePipelined(new RedisCallback<Object>() {
            @Override
            public Object doInRedis(RedisConnection redisConnection) throws DataAccessException {
                ...
            }
        });
```

改成

```java
        final RedisCallback<Object> callback = new RedisCallback<Object>() {
            @Override
            public Object doInRedis(RedisConnection redisConnection) throws DataAccessException {
                ...
            }
        };
        if (redisClusterHelper.isCluster()) {
            // 集群模式下 SDR 的 pipeline 不可用（JedisClusterConnection.openPipeline 抛
            // UnsupportedOperationException，回调体一次都不会执行）。
            // 改用非 pipeline 的 execute：每条命令一次往返，但 JedisCluster 会按 slot 路由。
            redisTemplate.execute(callback);
        } else {
            redisTemplate.executePipelined(callback);
        }
```

> ⚠️ **回调体一个字都不要改**（包括 `valueSerializer.serialize(...)` 与
> `redisConnection.hSet(...)` 的字节形式）—— 改了就是改数据格式。

- [ ] **Step 3: 编译 + 跑探针**

```powershell
cd $AB\napstarweb\monitor
$env:JAVA_HOME=$JAVA8
mvn -o -DskipTests compile
```

Expected: `BUILD SUCCESS`。

- [ ] **Step 4: 确认这个文件里不再有裸 `executePipelined`**

```powershell
Select-String -Path "$AB\napstarweb\monitor\src\main\java\com\sac\application\napstarweb\monitor\services\impl\SVGCacheServiceImpl.java" -Pattern "executePipelined"
```

Expected: **1 行**（else 分支里的那个），不是 0 —— 本仓库的守卫规则只针对**完全没有**分支的文件。

---

## Task 7: W2 — `RTListener.commitDataIncre`

**Files:**
- Modify: `$AB/napstarweb/monitor/src/main/java/com/sac/application/napstarweb/monitor/kafka/RTListener.java:95`

> **W2 的影响**：`@KafkaListener(topics = "COMMITDATAINCRE")` —— 实时数据增量入口。
> 树里**没有自定义 `KafkaListenerErrorHandler`** → Spring Kafka 2.8 默认
> `DefaultErrorHandler(FixedBackOff(0, 9))` → 重试 9 次后 `Skipping message` 并提交 offset
> → **增量数据被丢掉，只有一行日志**。

- [ ] **Step 1: 加 import 与字段**（同 Task 6）

- [ ] **Step 2: 同样的 if/else 改法**

```java
        final RedisCallback<Object> callback = new RedisCallback<Object>() {
            @Override
            public Object doInRedis(RedisConnection redisConnection) throws DataAccessException {
                ...
            }
        };
        if (redisClusterHelper.isCluster()) {
            // 集群模式下 SDR 的 pipeline 不可用；execute 走 JedisCluster 的按槽路由。
            redisTemplate.execute(callback);
        } else {
            redisTemplate.executePipelined(callback);
        }
```

> ⚠️ 这个回调体里有 `graphDataService.handleModeDataByObid(objectId, svgInitSupervisor, graphDataMap, redisConnection, null, logger)`
> —— 它**会往传进来的 connection 上写**（`GraphDataServiceImpl:234/240` 的 `hSet`）。
> 集群分支里这个 connection 是 `JedisClusterConnection` → `hSet` 按槽路由 ✅
> → **`GraphDataService` 的接口签名不用改**。

- [ ] **Step 3: 编译**

```powershell
cd $AB\napstarweb\monitor
$env:JAVA_HOME=$JAVA8
mvn -o -DskipTests compile
```

Expected: `BUILD SUCCESS`。

---

## Task 8: W3 + R5 — `SVGParseService`

**Files:**
- Modify: `$AB/napstarweb/monitor/src/main/java/com/sac/application/napstarweb/monitor/services/SVGParseService.java`
  - W3：`parseAllUseTag(String, Document, Logger)`，pipeline 在 L564
  - R5：`batchGetSymbol(List, Boolean)`，pipeline 在 L1864

- [ ] **Step 1: 加 import 与两个字段**

```java
import com.sac.platform.realserver.oms.utils.RedisClusterHashPipeline;
import com.sac.platform.realserver.oms.utils.RedisClusterHelper;
```

```java
    @Autowired
    private RedisClusterHelper redisClusterHelper;
    @Autowired
    private RedisClusterHashPipeline redisClusterHashPipeline;
```

- [ ] **Step 2: W3 —— 写站点的 if/else**

与 Task 6 同形。⚠️ 这个回调体里写的是 **2 个不同的 string key**
（`BASE_SVG_SYMBOL + symbolId` 与 `BASE_SVG_SYMBOL + "TextClass:" + symbolId`）
→ 每条命令只碰一个 key → 集群下各自路由，**没有跨槽问题**。

- [ ] **Step 3: R5 —— `batchGetSymbol` 的集群分支**

原代码：

```java
        List results = redisTemplate.executePipelined(new RedisCallback() {
            @Override
            public Object doInRedis(RedisConnection connection) throws DataAccessException {
                for (String symbolId : symbolIdList) {
                    connection.get((RedisKey.BASE_SVG_SYMBOL + symbolId).getBytes());
                }
                return null;
            }
        });
```

改成：

```java
        // 先把 key 列表提出来（原来是在回调体里现拼的）
        List<String> keys = new ArrayList<>();
        for (String symbolId : symbolIdList) {
            keys.add(RedisKey.BASE_SVG_SYMBOL + symbolId);
        }

        List results;
        if (redisClusterHelper.isCluster()) {
            // string 读：集群下 SDR 的 pipeline 不可用，改走按节点分组的读
            results = redisClusterHashPipeline.getAllValues(keys);
        } else {
            results = redisTemplate.executePipelined(new RedisCallback() {
                @Override
                public Object doInRedis(RedisConnection connection) throws DataAccessException {
                    for (String key : keys) {
                        connection.get(key.getBytes());
                    }
                    return null;
                }
            });
        }
```

> ⚠️ **key 的拼法一个字都不能改**（`RedisKey.BASE_SVG_SYMBOL + symbolId`）。
> ⚠️ `keys` 必须是 **effectively final**（匿名类要捕获它）→ 声明为 `final List<String> keys`。
> ⚠️ `connection.get(key.getBytes())` 用的是 **String 的默认 charset**（原代码就是这样），
> 保持一致 —— **不要**改成 `keySerializer.serialize(key)`，那会改变读到的 key。

- [ ] **Step 4: 编译**

Expected: `BUILD SUCCESS`。

---

## Task 9: W4 + R6 — `CanvasMonitorServiceImpl`

**Files:**
- Modify: `$AB/napstarweb/monitor/src/main/java/com/sac/application/napstarweb/monitor/cimg/services/impl/CanvasMonitorServiceImpl.java`
  - W4：`parseAllUseTag(String, Element, Logger)`，pipeline 在 L285
  - R6：`batchGetSymbol(List, Boolean)`，pipeline 在 L399

- [ ] **Step 1: 加 import 与两个字段**（同 Task 8）

- [ ] **Step 2: W4 —— 写站点的 if/else**（同 Task 6）

> ⚠️ W4 的回调体里调 `graphDataService.handleModeDataByObid(...)`（L360/367），
> 它会往 connection 上写（`hSet`）→ 集群下按槽路由 ✅ → 接口签名不用改。

- [ ] **Step 3: R6 —— `batchGetSymbol` 的集群分支**（与 Task 8 的 Step 3 同形）

- [ ] **Step 4: 编译**

Expected: `BUILD SUCCESS`。

---

## Task 10: R1 + R2 — `CalculateService`

**Files:**
- Modify: `$AB/napstarweb/monitor/src/main/java/com/sac/application/napstarweb/monitor/services/CalculateService.java`
  - R1：`batchConnectLineDefCache(List, SVGSupervisor)`，pipeline 在 L685
  - R2：`batchGetParam(String, List, Boolean)`，pipeline 在 L717

- [ ] **Step 1: 加 import 与两个字段**（同 Task 8）

- [ ] **Step 2: R1 —— `batchConnectLineDefCache`**

原代码：

```java
        List results = redisTemplate.executePipelined(new RedisCallback() {
            @Override
            public Object doInRedis(RedisConnection connection) throws DataAccessException {
                for (String svgId : svgIdList) {
                    connection.hGetAll((RedisKey.BASE_SVG_CONNECTLINE + svgId).getBytes());
                }
                return null;
            }
        });
```

改成：

```java
        final List<String> keys = new ArrayList<>();
        for (String svgId : svgIdList) {
            keys.add(RedisKey.BASE_SVG_CONNECTLINE + svgId);
        }

        List results;
        if (redisClusterHelper.isCluster()) {
            // hash 读：集群下按 slot 分组，每个 master 一条 pipeline
            results = redisClusterHashPipeline.getAllHashes(keys);
        } else {
            results = redisTemplate.executePipelined(new RedisCallback() {
                @Override
                public Object doInRedis(RedisConnection connection) throws DataAccessException {
                    for (String key : keys) {
                        connection.hGetAll(key.getBytes());
                    }
                    return null;
                }
            });
        }
```

> ⚠️ **返回形状必须与旧路径一致**：旧路径返回的每个元素是 `LinkedHashMap<String,Object>`
> （SDR 的 `deserializeMixedResults` 对非空 hash 的处理）。
> `getAllHashes` 返回的也是 `Map<String,Object>` ✅
> → 下面那句 `(Map<String, ConnectLineDefinition>) res` 的**既有骗人 cast 保持原样**，
> **本轮不修**（spec 的 N5）。

- [ ] **Step 3: R2 —— `batchGetParam`**

key 形态是 `keyPrefix + param + ":RT"`，`keyPrefix` 是**方法参数**（由调用方给）→ **不得写死**：

```java
        final List<String> keys = new ArrayList<>();
        for (String param : paramList) {
            keys.add(keyPrefix + param + ":RT");
        }

        List results;
        if (redisClusterHelper.isCluster()) {
            results = redisClusterHashPipeline.getAllHashes(keys);
        } else {
            results = redisTemplate.executePipelined(new RedisCallback() {
                @Override
                public Object doInRedis(RedisConnection connection) throws DataAccessException {
                    for (String key : keys) {
                        connection.hGetAll(key.getBytes());
                    }
                    return null;
                }
            });
        }
```

- [ ] **Step 4: 编译**

Expected: `BUILD SUCCESS`。

---

## Task 11: R3 + R4 — `CalculateForCanvasService`

**Files:**
- Modify: `$AB/napstarweb/monitor/src/main/java/com/sac/application/napstarweb/monitor/services/CalculateForCanvasService.java`
  - R3：`batchConnectLineDefCache(List, SVGSupervisor)`，pipeline 在 L688
  - R4：`batchGetParam(String, List, Boolean)`，pipeline 在 L720

- [ ] **Step 1: 加 import 与两个字段**（同 Task 8）

- [ ] **Step 2: R3 / R4** —— 与 Task 10 的 Step 2 / Step 3 **完全同形**

> ⚠️ `CalculateForCanvasService` 与 `CalculateService` 是**两份几乎一样的代码**
> （本仓库已经吃过「两份必然漂移」的亏）。本轮**不合并它们**（不在范围内），
> 但**两处都要改** —— 守卫脚本会同时检查两个文件。

- [ ] **Step 3: 编译**

Expected: `BUILD SUCCESS`。

---

## Task 12: 静态守卫脚本

**Files:**
- Create: `tests/validate_java_pipelines.sh`
- Modify: `tests/check_syntax.sh`

- [ ] **Step 1: 写守卫脚本**

`tests/validate_java_pipelines.sh`：

```bash
#!/usr/bin/env bash
# 守卫：napstarweb 树里不得出现**裸的** executePipelined。
#
# 为什么需要它：
#   SDR 2.7.18 的 JedisClusterConnection.openPipeline() 抛 UnsupportedOperationException，
#   所以集群模式下 redisTemplate.executePipelined(...) 一定会炸，且回调体一次都不执行。
#   napstarweb 的 10 处调用点已经全部加了集群分支（见 docs/OPERATIONS.md §4.5）。
#   这个脚本防止将来有人又写回裸调用。
#
# 用法:
#   bash tests/validate_java_pipelines.sh <application-backend-root> [platform-backend-root]
#
# 退出码:
#   0 = 通过
#   1 = 有违规（napstarweb 树里出现了裸 executePipelined）
#   2 = 用法错误 / 路径不存在（**不静默跳过** —— 一个从不失败的断言等于没有断言）
set -uo pipefail

PASS=0
FAIL=0

die() { echo "ERROR: $*" >&2; exit 2; }

if [ "$#" -lt 1 ]; then
    die "usage: bash tests/validate_java_pipelines.sh <application-backend-root> [platform-backend-root]"
fi

AB_ROOT="$1"
PB_ROOT="${2:-}"

[ -d "$AB_ROOT" ] || die "application backend root not found: $AB_ROOT"

echo "== scanning $AB_ROOT =="

# 只扫 napstarweb 应用树；sche-viewer-server 单独处理（见下面）。
# 排除 target/（编译产物）与 .git。
scan_dir() {
    find "$1" -type d \( -name target -o -name .git \) -prune -o \
        -type f -name '*.java' -print 2>/dev/null
}

violations=0
counted=0

# ---- 规则 1：napstarweb 应用树里的每一处 executePipelined 都必须在集群分支后面 ----
#
# 判据（不能用计数！改造后 executePipelined 的**数量不变**，只是位置变了）：
#   每一处 executePipelined 调用的**上面 40 行内**必须出现 isCluster(。
#   没有分支的裸调用 → 上面 40 行内不会有 isCluster( → 判违规。
#
# 这个判据必须用**变异检验**证明它真的会红（见下面的 Step 3）。
NAPSTAR_DIR="$AB_ROOT/napstarweb"
if [ -d "$NAPSTAR_DIR" ]; then
    while IFS= read -r file; do
        n=$(grep -c 'executePipelined[[:space:]]*(' "$file" 2>/dev/null || true)
        [ "$n" -eq 0 ] && continue
        counted=$((counted + n))
        bad=$(awk -v WINDOW=40 '
            {
                line[NR] = $0
                if ($0 ~ /executePipelined[[:space:]]*\(/) { hit[NR] = 1 }
            }
            END {
                bad = 0
                for (n in hit) {
                    found = 0
                    from = n - WINDOW
                    if (from < 1) from = 1
                    for (i = from; i < n; i++) {
                        if (line[i] ~ /isCluster[[:space:]]*\(/) { found = 1; break }
                    }
                    if (!found) { printf "line %d: no cluster branch within %d lines above\n", n, WINDOW; bad++ }
                }
                print bad
            }
        ' "$file")
        if [ "$bad" != "0" ]; then
            echo "VIOLATION: $file has $bad unguarded executePipelined call(s):"
            echo "$bad"
            violations=$((violations + 1))
        fi
    done < <(scan_dir "$NAPSTAR_DIR")
else
    echo "note: $NAPSTAR_DIR not found; skipping rule 1"
fi

# ---- 规则 2：sche-viewer-server 只报告，不判失败 ----
# 它的模块在 application/backend/pom.xml 里是注释掉的（不参与构建），
# 且 oms: 块整段注释（standalone）→ 当前不会进集群路径。
# 但它有同样的形状：将来切集群时必须一并处理。
SCHE_DIR="$AB_ROOT/sche-viewer-server"
if [ -d "$SCHE_DIR" ]; then
    sche_count=0
    while IFS= read -r file; do
        n=$(grep -c 'executePipelined[[:space:]]*(' "$file" 2>/dev/null || true)
        sche_count=$((sche_count + n))
    done < <(scan_dir "$SCHE_DIR")
    if [ "$sche_count" -gt 0 ]; then
        echo "ADVISORY: sche-viewer-server has $sche_count executePipelined call(s)."
        echo "           It is not built (module is commented out in the aggregator) and its"
        echo "           oms: block is fully commented out (standalone), so it is safe today."
        echo "           It MUST be fixed before it is switched to cluster mode."
    fi
fi

# ---- 规则 3：platform 树里的 executePipelined 必须在 isCluster 分支后面 ----
# platform 树（realserver / modelserver）已有 isCluster 分支，本轮不改它；
# 这里只做**计数守恒**：数量不得超过基线 11。
PB_BASELINE=11
if [ -n "$PB_ROOT" ] && [ -d "$PB_ROOT" ]; then
    echo "== scanning $PB_ROOT =="
    pb_count=0
    while IFS= read -r file; do
        n=$(grep -c 'executePipelined[[:space:]]*(' "$file" 2>/dev/null || true)
        pb_count=$((pb_count + n))
    done < <(scan_dir "$PB_ROOT")
    echo "platform tree executePipelined count = $pb_count (baseline $PB_BASELINE)"
    if [ "$pb_count" -gt "$PB_BASELINE" ]; then
        echo "VIOLATION: the platform tree grew from $PB_BASELINE to $pb_count executePipelined call(s)."
        echo "           New ones must sit behind an isCluster() branch."
        violations=$((violations + 1))
    fi
fi

if [ "$violations" -gt 0 ]; then
    FAIL=1
    echo "FAIL=$FAIL PASS=$PASS"
    exit 1
fi

PASS=$((counted + 1))
echo "PASS=$PASS FAIL=$FAIL"
exit 0
```

> ⚠️ **规则 1 不能用「计数」当判据** —— 改造后 napstarweb 树里 `executePipelined`
> 的**数量不变**（10 处，每处各留一个 `else` 分支），只是位置变了。
> 计数守恒**区分不了**「有分支」与「没分支」。
> → 上面用的判据是「**每一处调用的上面 40 行内必须有 `isCluster(`**」。
> 这个判据必须用 **Step 3 的变异检验**证明它真的会红。

- [ ] **Step 2: 跑守卫脚本，确认它能抓到裸调用**

```powershell
cd $REPO
bash tests/validate_java_pipelines.sh "D:\javawork\1.2\cpscloud1.0\code\application\backend" `
     "D:\javawork\1.2\cpscloud1.0\code\platform\backend"
```

Expected: `PASS=n FAIL=0`，退出码 0。

> ⚠️ **宿主机没有可用 bash** → 在容器里跑：
> ```powershell
> docker run --rm -v "D:/work/rediscluterproject:/repo" -w /repo rc-control:bats `
>   bash -c "bash tests/validate_java_pipelines.sh /ab /pb"
> ```
> （把两棵 Java 树也挂进去：`-v "D:/javawork/1.2/cpscloud1.0/code/application/backend:/ab:ro"`）

- [ ] **Step 3: 变异检验 —— 脚本真的会红吗**

临时把某个 napstarweb 文件里的 `if (redisClusterHelper.isCluster())` 删掉，
再跑一次 → **必须退出码 1 并打出 VIOLATION**。
做完立刻还原（用编辑工具），再跑一次确认回到 0。

> **这一步不能省** —— 本项目的教训反复是「一个从不失败的断言等于没有断言」。

- [ ] **Step 4: 接入 `tests/check_syntax.sh`**

看 `tests/check_syntax.sh` 现在怎么列文件，把 `tests/validate_java_pipelines.sh` 加进去
（**注意**：`validate_java_pipelines.sh` 是**要执行**的脚本，不是被 `bash -n` 检查的对象；
但它自己**也必须**能被 `bash -n` 通过 → 所以它既要在 `bash -n` 的名单里，
也要能独立执行）。

- [ ] **Step 5: 跑语法检查与守卫**

```powershell
docker run --rm -v "D:/work/rediscluterproject:/repo" -w /repo rc-control:bats bash -c "bash tests/check_syntax.sh"
```

Expected: `TOTAL=46 FAIL=0`（新增 1 个脚本）。

- [ ] **Step 6: 提交**

```powershell
cd $REPO
git add tests/validate_java_pipelines.sh tests/check_syntax.sh
git commit -m "test(guard): fail when a bare executePipelined comes back to napstarweb

SDR 2.7.18 rejects pipelines in cluster mode. The ten napstarweb call sites
now branch on RedisClusterHelper.isCluster(); this guard makes sure nobody
reintroduces an unguarded one."
```

---

## Task 13: 文档

**Files:**
- Modify: `$REPO/docs/OPERATIONS.md`（§4.5）
- Modify: `$REPO/docs/HANDOFF.md`（第十八轮章节）

- [ ] **Step 1: `docs/OPERATIONS.md` §4.5 加一条**

在「生产真值填写清单」里加一条**必读**警告（位置：Redis 侧清单之后）：

```markdown
> ⛔ **切集群前必读：napstarweb 的 `executePipelined` 集群分支**
>
> SDR 2.7.18 在 Redis Cluster 模式下**不支持 pipeline** ——
> `JedisClusterConnection.openPipeline()` 直接抛 `UnsupportedOperationException`，
> **回调体一次都不会执行**（Redis 命令一条都没发出去）。
>
> napstarweb 树里原本有 **10 处** `redisTemplate.executePipelined(...)`，
> 其中：
> - **4 处写**（`SVGCacheServiceImpl` / `RTListener` / `SVGParseService` / `CanvasMonitorServiceImpl`）
>   → 已加集群分支，改用 `redisTemplate.execute(cb)`（非 pipeline，每条命令一次往返，按槽路由）
> - **6 处读**（`CalculateService` / `CalculateForCanvasService` / `SVGParseService.batchGetSymbol` /
>   `CanvasMonitorServiceImpl.batchGetSymbol`）
>   → 已加集群分支，改用 `oms` 的 `RedisClusterHashPipeline.getAllHashes` / `getAllValues`
>   （按 slot 分组，每个 master 一条 pipeline，**返回顺序与入参一致**）
>
> ⚠️ **不带上这份改造就切集群**，后果是：
> ① `StartupRunner` 的初始化被中断 → **应用启动成功、功能却是残的**
> ② `RTListener`（`COMMITDATAINCRE`）抛异常 → Spring Kafka 默认错误处理器
>    **跳过并提交 offset** → **实时数据增量静默丢失**
>
> 改造细节见 `docs/superpowers/specs/2026-10-30-napstarweb-cluster-branch-design.md`。
> 另：`sche-viewer-server` 还有 **15 处**同样的裸调用 —— 它当前不参与构建且是
> standalone，**暂时安全**，但**将来切集群前必须一并处理**。
```

- [ ] **Step 2: `docs/HANDOFF.md` 加「第十八轮」章节**

写在「第十七轮」之后，结构照第十八轮的先例（结论 → 改了什么 → 验证 → 留痕）：

```markdown
## 第十八轮（2026-10-30）：napstarweb 集群分支 + 读侧 pipeline

**这一轮改的是 Java 侧**（`platform/backend` 的 oms 模块 + `application/backend` 的 napstarweb），
仓库里的 `cluster-config.sh` 一行没动。

### 一、结论先行

**napstarweb 的 10 处 `executePipelined` 在集群模式下必然炸。**

SDR 2.7.18 的 `JedisClusterConnection.openPipeline()` 直接抛
`UnsupportedOperationException("Pipeline is currently not supported for JedisClusterConnection.")`，
而 `RedisTemplate.executePipelined(...)` 是**先 `openPipeline()` 再执行回调体**
→ **回调体一次都没跑，Redis 命令一条都没发出去**。

真集群实测（探针见 `tests/probes/cluster-execute-probe.java`）：
`executePipelined` 两个重载都抛；对照组 `opsForHash().putAll()` 正常 → **集群本身没问题**。

**为什么第十三轮没发现**：那一轮统一的是**配置契约**（三个应用的 `oms:` 块补全），
没管**调用点**。platform 树的 11 处**早就有 `isCluster()` 分支**（第十轮做的），
只有 napstarweb 漏了。

### 二、改了什么（8 个 Java 文件 + 2 个 pom）

| # | 文件 | 改动 |
|---|---|---|
| 1 | `oms/…/oms/utils/RedisClusterHashPipeline.java` | **加** `getAllHashes` / `getAllValues`（读侧按节点 pipeline） |
| 2 | `oms/…/oms/utils/RedisClusterHashPipelineTest.java` | **加** 5 条 Mockito 用例（+1 个 `utf8Codec()` serializer） |
| 3 | `oms/…/oms/utils/RedisClusterHashPipelineLiveTest.java` | **加** 5 条真集群用例 |
| 4 | `application/backend/pom.xml` | dependencyManagement 加 `realserver-oms` |
| 5 | `napstarweb/monitor/pom.xml` | 显式声明 `realserver-oms` |
| 6 | `napstarweb/monitor/…/monitor/services/impl/SVGCacheServiceImpl.java` | W1 集群分支 |
| 7 | `napstarweb/monitor/…/monitor/kafka/RTListener.java` | W2 集群分支 |
| 8 | `napstarweb/monitor/…/monitor/services/SVGParseService.java` | W3 集群分支 + R5 `getAllValues` |
| 9 | `napstarweb/monitor/…/monitor/cimg/services/impl/CanvasMonitorServiceImpl.java` | W4 集群分支 + R6 `getAllValues` |
| 10 | `napstarweb/monitor/…/monitor/services/CalculateService.java` | R1 + R2 `getAllHashes` |
| 11 | `napstarweb/monitor/…/monitor/services/CalculateForCanvasService.java` | R3 + R4 `getAllHashes` |

### 三、关键设计决定

1. **集群分支统一用 `redisTemplate.execute(cb)`**（回调体逐字复用，`RedisConnection` 参数原样传下去）
   → `JedisClusterConnection.hSet/hDel/set` 都按槽路由 → **`GraphDataService` 接口签名不用改**。
2. **多 key 读走 oms 的 `getAllHashes` / `getAllValues`** → 按 slot 分组，每 master 一条 pipeline
   → **返回顺序与入参一致**（napstarweb 是按下标对齐消费的，顺序错了会静默返回错位数据）。
3. **反序列化必须复刻 SDR 的 `deserializeMixedResults`**
   → 用 public static 的 `SerializationUtils.deserialize(raw, hashKeySerializer, hashValueSerializer)`。
   ⚠️ SDR 对**空 hash** 有特例（返回未反序列化的原始 map）；本类返回反序列化后的空 map
   → **差异不可观测**，但单独立了一条真集群测试钉住。
4. **类名 `RedisClusterHashPipeline` 不改**（现在也承载 string 读 → 命名债）：
   改名会破坏 bean 名、32 条已有测试、7 份 patch 留痕 → 收益不抵成本。

### 四、验证

| 检查 | 结果 |
|---|---|
| `oms` 单测 | **76 通过 / 0 失败 / 0 跳过**（基线 66 + 5 Mockito + 5 真集群） |
| `idgenerator` | 6 / 0 / 0 跳过（未受影响） |
| `rtdata-module` | 14 / 0（未受影响） |
| backend reactor | **44 个模块全 SUCCESS** |
| napstarweb reactor | **13 个模块全 SUCCESS** |
| 探针 | `PROBE PASSED` |
| 守卫脚本 | 退出码 0；变异检验确认它会红 |
| bats / check_syntax / validate_libs | 203/0 · TOTAL=46 FAIL=0 · PASS=54 FAIL=0 |

### 五、留痕

| 东西 | 位置 |
|---|---|
| 设计文档 | `docs/superpowers/specs/2026-10-30-napstarweb-cluster-branch-design.md` |
| 实施计划 | `docs/superpowers/plans/2026-10-30-napstarweb-cluster-branch.md` |
| patch | `docs/superpowers/patches/2026-10-30-napstarweb-cluster-branch-platform-backend.patch`<br>`docs/superpowers/patches/2026-10-30-napstarweb-cluster-branch-application-backend.patch` |
| 探针 | `tests/probes/cluster-execute-probe.java` + `scripts/probe-cluster-execute.sh` |
| 守卫 | `tests/validate_java_pipelines.sh` |

### 六、留了一个「已知差异」没修

集群分支（非 pipeline）**每条命令立即生效**，单机分支（pipeline）**批量生效**。
`GraphDataServiceImpl.fillBaseModelData` 里有「先 `opsForHash().get()` 再 `redisConnection.hSet()`」
的读后写 → 集群下后一次能读到前一次，单机 pipeline 下读不到。
**这是两种模式本来就有的差异**，集群分支反而更正确。**本轮不修**（修它要动单机路径 → 风险外溢）。
```

- [ ] **Step 3: 提交**

```powershell
cd $REPO
git add docs/OPERATIONS.md docs/HANDOFF.md
git commit -m "docs: record round eighteen, the napstarweb cluster branch

The operations manual's production checklist now says that switching
napstarweb to cluster mode requires the pipeline branch first, and the
handoff records what was found, changed and verified."
```

---

## Task 14: patch 留痕 + 全量验证 + 推送

**Files:**
- Create: `$REPO/docs/superpowers/patches/2026-10-30-napstarweb-cluster-branch-platform-backend.patch`
- Create: `$REPO/docs/superpowers/patches/2026-10-30-napstarweb-cluster-branch-application-backend.patch`

- [ ] **Step 1: 生成 platform 侧的 patch**

两棵 Java 树**都不是 git 仓库** → 用 **Task 0 备好的基线副本** 做对比，
在一个**临时 git 仓库**里生成标准 unified diff（与第十六轮同一套路）：

```powershell
$REPO  = "D:\work\rediscluterproject"
$BE    = "D:\javawork\1.2\cpscloud1.0\code\platform\backend"
$BASE  = "$env:TEMP\opencode\napstarweb-cluster-branch-baseline"
$STAGE = "$env:TEMP\opencode\patch-stage"

$platformFiles = @(
  "realserver\common\oms\src\main\java\com\sac\platform\realserver\oms\utils\RedisClusterHashPipeline.java",
  "realserver\common\oms\src\test\java\com\sac\platform\realserver\oms\utils\RedisClusterHashPipelineTest.java",
  "realserver\common\oms\src\test\java\com\sac\platform\realserver\oms\utils\RedisClusterHashPipelineLiveTest.java"
)

# ① 暂存区：先放基线，再建 git 仓库并提交基线
Remove-Item -Recurse -Force $STAGE -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $STAGE | Out-Null
foreach ($f in $platformFiles) {
    $dest = Join-Path $STAGE $f
    New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
    Copy-Item (Join-Path "$BASE\platform" $f) $dest
}
Push-Location $STAGE
git init -q
git config core.autocrlf false
git config core.eol lf
git config user.email "agent@local"
git config user.name "agent"
git add -A
git commit -q -m "baseline"

# ② 用当前文件覆盖 → git diff 就是本轮的改动
foreach ($f in $platformFiles) {
    Copy-Item (Join-Path $BE $f) (Join-Path $STAGE $f) -Force
}

# ③ 生成 patch（--output= 写原始字节，不会把中文变成 ?）
git diff --output="$REPO\docs\superpowers\patches\2026-10-30-napstarweb-cluster-branch-platform-backend.patch" -- .
Pop-Location
```

> ⚠️ **patch 生成的三条铁律**（HANDOFF 坑 5/7/8）：
> - 用 `git diff --output=<file>`（**不要** `Out-File -Encoding ascii` —— 会把中文变成 `?`）
> - `core.autocrlf=false` / `core.eol=lf`（源文件行尾是**混的**：`pom.xml` 是 LF、`.java` 是 CRLF）
> - 本轮**没有删除任何文件**；若有，必须显式 `Remove-Item`（只复制存在的文件 →
>   `git add -A` 认为没变 → 删除全部静默丢失）

- [ ] **Step 2: 生成 application 侧的 patch**

同 Step 1，换成 application 的 8 个文件与另一份输出：

```powershell
$AB = "D:\javawork\1.2\cpscloud1.0\code\application\backend"

$applicationFiles = @(
  "pom.xml",
  "napstarweb\monitor\pom.xml",
  "napstarweb\monitor\src\main\java\com\sac\application\napstarweb\monitor\services\impl\SVGCacheServiceImpl.java",
  "napstarweb\monitor\src\main\java\com\sac\application\napstarweb\monitor\kafka\RTListener.java",
  "napstarweb\monitor\src\main\java\com\sac\application\napstarweb\monitor\services\SVGParseService.java",
  "napstarweb\monitor\src\main\java\com\sac\application\napstarweb\monitor\cimg\services\impl\CanvasMonitorServiceImpl.java",
  "napstarweb\monitor\src\main\java\com\sac\application\napstarweb\monitor\services\CalculateService.java",
  "napstarweb\monitor\src\main\java\com\sac\application\napstarweb\monitor\services\CalculateForCanvasService.java"
)

Remove-Item -Recurse -Force $STAGE -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $STAGE | Out-Null
foreach ($f in $applicationFiles) {
    $dest = Join-Path $STAGE $f
    New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
    Copy-Item (Join-Path "$BASE\application" $f) $dest
}
Push-Location $STAGE
git init -q
git config core.autocrlf false
git config core.eol lf
git config user.email "agent@local"
git config user.name "agent"
git add -A
git commit -q -m "baseline"
foreach ($f in $applicationFiles) {
    Copy-Item (Join-Path $AB $f) (Join-Path $STAGE $f) -Force
}
git diff --output="$REPO\docs\superpowers\patches\2026-10-30-napstarweb-cluster-branch-application-backend.patch" -- .
Pop-Location
```

- [ ] **Step 3: 反向校验两份 patch**

```powershell
cd $BE
git -c core.autocrlf=false apply --reverse --check "$REPO\docs\superpowers\patches\2026-10-30-napstarweb-cluster-branch-platform-backend.patch"
"platform reverse-check exit=$LASTEXITCODE"     # 期望 0
cd $AB
git -c core.autocrlf=false apply --reverse --check "$REPO\docs\superpowers\patches\2026-10-30-napstarweb-cluster-branch-application-backend.patch"
"application reverse-check exit=$LASTEXITCODE"  # 期望 0
```

Expected: 两个都是 **exit 0**（磁盘上仍是 patch 的后像，源码没漂移）。

> 这是**比逐文件比 SHA-256 更便宜**的核对法 —— 以后核对「源码有没有漂移」直接用它。

- [ ] **Step 4: 全量验证**

```powershell
# ① oms
cd $BE\realserver\common\oms
$env:JAVA_HOME=$JAVA8
mvn -o clean test
#    期望 76 / 0 / 0 跳过

# ② idgenerator（未受影响）
cd $BE\common\idgenerator
mvn -o clean test
#    期望 6 / 0 / 0 跳过

# ③ rtdata-module（未受影响）
cd $BE\realserver\plugins\rtdata-module
mvn -o test
#    期望 14 / 0

# ④ backend reactor
cd $BE
mvn -o clean install -DskipTests
#    期望 44 个模块全 SUCCESS（含 proguard，JDK 8）

# ⑤ napstarweb reactor
cd $AB
mvn -o clean install -DskipTests
#    期望 13 个模块全 SUCCESS（含 proguard，JDK 8）

# ⑥ 仓库侧
cd $REPO
docker run --rm --user 1000:1000 -v "D:/work/rediscluterproject:/repo" -w /repo rc-control:bats `
  bash -c "find tests -name '*.bats' -print0 | xargs -0 bats"
#    期望 203 通过 / 0 失败
docker run --rm -v "D:/work/rediscluterproject:/repo" -w /repo rc-control:bats bash -c "bash tests/check_syntax.sh"
#    期望 TOTAL=46 FAIL=0
docker run --rm -v "D:/work/rediscluterproject:/repo" -w /repo rc-control:bats bash -c "bash tests/validate_libs.sh"
#    期望 PASS=54 FAIL=0
```

- [ ] **Step 5: 提交 patch**

```powershell
cd $REPO
git add docs/superpowers/patches/
git commit -m "docs(patch): keep the napstarweb cluster branch as patches

The Java trees are not git repositories, so the only durable record of the
change is the patch. Reverse-apply checks exit 0 on both roots."
```

- [ ] **Step 6: 推送**

```powershell
cd $REPO
git status -sb                    # 期望 main...origin/main（推送前会 ahead）
git push origin main
```

> ⚠️ **HTTPS 常常被 reset**（坑 26）→ 失败时走 SSH：
> ```powershell
> $env:GIT_SSH="C:\Windows\System32\OpenSSH\ssh.exe"
> git -c remote.origin.pushurl=git@github.com:leiming-cai/redis-cluster-install.git push origin main
> ```
> ⚠️ **推送前先 `git diff HEAD --stat` 看一眼改了什么**（坑 27：VS Code 会用旧缓冲区覆盖文件），
> 推送后用 `git grep <commit> -- <file>` 验证提交内容（**不要**用 `git show | Select-String`，
> PowerShell 会把 UTF-8 管道解码坏，看起来像"内容丢了"）。

---

## 完成判据

| # | 判据 |
|---|---|
| 1 | `oms` 单测 **76 通过 / 0 失败 / 0 跳过**（`Skipped: 0` 必须确认 —— 否则等于没跑真集群） |
| 2 | backend reactor **44 个模块全 SUCCESS**；napstarweb reactor **13 个模块全 SUCCESS** |
| 3 | 探针 `PROBE PASSED` |
| 4 | 守卫脚本退出码 0，且**变异检验证明它会红** |
| 5 | 两份 patch 的反向校验都是 exit 0 |
| 6 | bats 203/0 · `check_syntax` TOTAL=46 FAIL=0 · `validate_libs` PASS=54 FAIL=0 |
| 7 | `git status -sb` 干净且与 `origin/main` 同步 |
| 8 | `docs/OPERATIONS.md` §4.5 与 `docs/HANDOFF.md` 第十八轮章节已写好 |

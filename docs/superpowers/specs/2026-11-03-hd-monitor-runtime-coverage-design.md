# 设计：给 `monitor` 的 6 处集群分支补运行时覆盖（路线 A —— 最小模型元数据种子）

**日期**：2026-11-03
**轮次**：树名更正轮之后的第一轮
**范围**：`docker/hd-napstar/DEFECTS.md` §七 #1（`monitor` 的 6 处补运行时覆盖）
**状态**：待用户确认

---

## 一、要解决的是什么

上轮给 `monitor` 的 **6 处**裸 `executePipelined` 加了集群分支（4 文件 6 处），但**验收只做到了静态**：

| 验收手段 | 结果 | 强度 |
|---|---|---|
| jar 里 `isCluster` 的 class 数 **0 → 4** | ✅ | **静态**：只证明代码在，不证明跑得对 |
| 逐处审阅「都在 `if (isCluster())` 的 `else` 分支里」 | ✅ | **静态** |
| 集群模式下应用日志**无 `UnsupportedOperationException`** | ✅ | **假绿**（见下） |

**「无 UOE」是假绿**（实测确认）：
- `info.model_objecttype` / `model_attribute` / `model_objectattribute` **全是 0 行**
- ⇒ `CacheServiceImpl.matchOTypeCode(name)` 走 `else` 分支 → **`throw new OTypeException(name)`**
- ⇒ 写路径在 `matchOType(...)` 就抛了，**根本走不到那行 `executePipelined`/`execute`**
- ⇒ 「没有 UOE」是「**没跑**」换来的，不是「**跑对了**」
- **实测佐证**：web-controller 日志里 `OTypeException` **23 次**、`属性名称非法或不存在` 3 次、`UnsupportedOperationException` **0 次**

⇒ **这 6 处到今天为止，一次都没有在集群模式下真正执行过。**

---

## 二、关键发现：6 处的「可达性」分三档

逐处追调用链（实测，不是推测）：

| # | 位置 | 集群分支做什么 | 到达它需要什么 | 现状 |
|---|---|---|---|---|
| **A** | `SVGCacheServiceImpl:85` | `redisTemplate.execute(callback)` | **`matchOType(oname)` 成功** —— `oname` 来自 **Nacos 的 `kafkabus.yaml`**（MVPoint / DPSPoint / Machine） | ⚠️ **只差元数据** |
| **B** | `RTListener:142` | `redisTemplate.execute(callback)` | Kafka `COMMITDATAINCRE` 消息 | ⚠️ **只差一条消息** |
| **C** | `CalculateService:702`（`batchConnectLineDefCache`） | `redisClusterHashPipeline.getAllHashes(keys)` | `svgIdList` —— 来自 **websocket 的订阅** 或 **SVG 文件** | ❌ 缺输入 |
| **D** | `CalculateService:749`（`batchGetParam`） | `redisClusterHashPipeline.getAllHashes(keys)` | 同上 | ❌ 缺输入 |
| **E** | `SVGParseService:2057`（`batchGetSymbol`） | `redisClusterHashPipeline.getAllValues(keys)` | `symboleIdList` —— 来自 **SVG 解析结果** | ❌ 缺输入 |
| **F** | `SVGParseService:1762` | `redisTemplate.execute(callback)` | **SVG 文件** + `matchOType("MeasurementType")` 等 | ❌ 缺输入 |

**A 和 B 只需「一份元数据 / 一条消息」就能真正跑到**；
C/D/E/F 需要 **SVG 文件**或 **websocket 订阅**作为输入 —— 那是**图形侧**的数据准备，不在本轮范围。

---

## 三、种子数据方案（最小集）

### 3.1 数据从哪来 —— **不用编**

Nacos 里现成的 `kafkabus.yaml`（`NAPSTARWEB_GROUP`，HTTP 200，241 字节）就是应用自己要的元数据清单：

```yaml
kafkabus:
  config:
    - oname: MVPoint
      aname: Value,Quality
    - oname: DPSPoint
      aname: State,Unacknowledged
    - oname: Machine
      aname: CPUStatus,MemStatus,CPUSystemEx,DiskSystem,DiskCPS,MemSystemEx,SyncStatus,SyncPhase
```

`loadRTConfigKafka()` 对每个 `oname` 调 `matchOType(oname)`，然后对每个 `aname` 找同名属性并 `hSet`。
⇒ **3 个 objecttype + 12 个 attribute + 12 条 objectattribute 关联**，一条不多。

### 3.2 落哪三张表

| 表 | 需要填什么 | 依据（实测的 mapper） |
|---|---|---|
| `info.model_objecttype` | `obj_name`（3 个）、`obj_type`（自定编号）、`source_code='NAPStar'` | `readByObjectName`：`where obj_name = #{objName}` |
| `info.model_attribute` | `attr_name`（12 个）、`attr_type`、`dt_type`（用现成的 `model_datatype`） | `findByParams`：`model_attribute a LEFT JOIN model_datatype b ON a.dt_type=b.dt_type` |
| `info.model_objectattribute` | `obj_type` × `attr_type` 关联（12 条）、`attr_order` | `findByParams`：`model_objectattribute oa LEFT JOIN model_attribute a ON oa.attr_type=a.attr_type` |

现成的、**不用造**的：
- `info.model_datatype` **19 行**（`dt_type` 0–18，`Boolean/Short/Long/Float/String/Link/…`）→ 属性直接挂上去
- `info.model_source` 2 行（`NAPStar` / `MSystem`）→ `source_code` 取 `NAPStar`
- `info.base_user` 2 行 → `create_operator` 取 `1561967773586952192`（超级用户）

### 3.3 `obj_type` / `attr_type` 怎么编号

**必须避开真实业务的编号空间** —— `obj_type` 会进 Redis key（`real_graph:realscope` 的 field = `<objType>_<attrType>`）。
⇒ 用一个**显眼的测试段**：`obj_type ∈ [900001, 900099]`、`attr_type ∈ [900001, 900099]`。
⇒ 好处：任何时候一眼能看出是测试数据；且不会撞 `real_data:<otype>:<obid>` 那套业务编号。

### 3.4 幂等与回滚

- 脚本用 `DELETE ... WHERE source_code = 'HDTEST'`（**只删自己那批**）+ `INSERT` ⇒ **可重复执行**
- 回滚 = 再跑一次「只删」那一半
- ⚠️ **不写生产** —— 只在本环境的 `napstar` 库

---

## 四、跑完之后怎么证明「真的跑到了」

**这是本设计的重点** —— 不能只看「没抛异常」。

### 4.1 判据从 SKIP 变 PASS

`hd-cluster-app-test.sh` 的 **A2** 判据本来就写了「元数据表有行 ⇒ 执行 A2」（`A_META_ROWS -eq 0` 才 SKIP）。
⇒ **灌完数据后，重跑集群测试，A2 自动从 SKIP 变成真跑** —— 判据本身**不用改**。

### 4.2 新增一条**正向**证据判据

A2 现有判据是「应用写的 key 在集群里」——
但那正是**上一轮已经能过**的判据。我们要的是**新的**、能区分「跑到集群分支」和「没跑到」的判据：

| 新判据 | 怎么测 | 为什么它有区分力 |
|---|---|---|
| **A2-R：集群分支的 key 落地了** | `real_graph:realscope` 这个 hash 存在，且 **field 数 = 12**（= 3 类型 × 各自属性数） | 空表时这个 hash **一个 field 都没有**（`continue` 掉了）⇒ 有 field 就证明 `hSet` 真执行了 |
| **A2-V：field 里的 objType 段 = 种子编号** | field 形如 `900001_900001` | 证明是**种子数据**驱动的写入，不是别的路径 |
| **A2-N：单机模式下也应有同样的 12 个 field** | 单机跑一遍对比 | 证明**集群分支与单机分支行为等价**（不是「集群多写了/少写了」） |
| **A2-U：kafkabus 那 3 个类型的 `OTypeException` 归零** | `grep -c 'oType数值非法或不存在：\(MVPoint\|DPSPoint\|Machine\)'` | 这 3 个类型各 1 次 → **0 次**。⚠️ **不是**「总数 23 → 0」—— 另外 20 次来自**别的类型**（PMSQltInfo×6 / PT / CT / Fuse / Jumper 等），由 **SVG 解析路径**触发，不在本轮范围 |

### 4.3 判据的「诚实性」检查

> ⚠️ **必须同时验单机模式**：因为 `loadRTConfigKafka()` 在**单机**模式下也会写这个 hash。
> 只验集群模式 ⇒ 无法排除「写进去了但用的是单机分支」（比如 `isCluster()` 判断错了）。
> ⇒ **两边都跑、都数 field 数、都比内容** —— 这才是「集群分支正确」的完整证据。

---

## 五、实施步骤

| 步 | 做什么 | 产出 | 验证 |
|---|---|---|---|
| 1 | 写种子脚本 | `scripts/seed-hd-model-metadata.sh`（含 `--seed` / `--clean` 两个动作） | `bash -n` 通过 |
| 2 | 灌种子 | 活库 `info` 三张表各 +N 行 | `psql` 查行数 + 抽样打印 |
| 3 | **清 Redis 缓存（防御性）** | `matchOTypeCode` 带 `@Cacheable("objecttypes:names")`。⚠️ **实测：现在是 0 个 key**（失败不缓存）⇒ 严格说**不必清**；但仍清一次以防万一 | `redis-cli --scan --pattern "objecttypes*" | xargs -r redis-cli DEL` |
| 4 | 重启应用 | `start-hd-apps.sh 1` + `1b` | 启动日志无致命错误 |
| 5 | **单机模式**跑一遍 | `real_graph:realscope` 应有 12 个 field | 记录 field 列表（基线） |
| 6 | **集群模式**跑一遍 | `initGraph` 触发 → 集群里应有**同样的 12 个 field** | 逐 field 比对 |
| 7 | 加判据 | `hd-cluster-app-test.sh` 的 A2 段加 A2-R/V/N/U | 判据自身有测试 |
| 8 | 跑完整矩阵 | 集群层 + base 矩阵 | 与上一轮基线逐条比对 |

---

## 六、明确的**不做**

| 不做 | 理由 |
|---|---|
| **C/D/E/F 四处**（`CalculateService` ×2、`SVGParseService` ×2） | 需要 **SVG 文件**（容器里一个 `*-ScheFile.svg` 都没有）或 **websocket 订阅**才能到达 —— 那是**图形侧**的数据准备，与「集群分支对不对」无关。⇒ 本轮**不碰**，但要在 DEFECTS 里写明「仍无运行时覆盖」 |
| 灌 **35 个** `matchOType` 类型 | 用户已选定最小集。35 个里大部分只在图形解析路径上用，而图形路径本来就走不到（没 SVG 文件）⇒ 灌了也是**用不上** |
| 改 `model_datatype` / `model_source` / `base_user` | 它们**已经够了**（19 + 2 + 2 行）⇒ 一行都不动 |
| 碰 `sac` / `cmt` / `hds` | 第三方只读域，与本轮无关（见 D10 的新定性） |
| 用产品自带的 XML 导入通道（`/write/importModelEntityData`） | 那条路要 `base_modelversion` 有行（现在 **0 行**）且要匹配 `modelfile_path` ⇒ 比重灌 27 行**麻烦得多**，且它本来就是给「完整模型包」设计的 |

---

## 七、风险与对策

| # | 风险 | 对策 |
|---|---|---|
| 1 | **`@Cacheable("objecttypes:names")` 挡住新数据** | `matchOTypeCode` 上有 `@Cacheable(value={"objecttypes:names"}, key="#name", unless="#result < 0")`。⚠️ **实测（2026-11-03）**：单机 Redis 里 `objecttypes*` **0 个 key** ⇒ 失败（抛 `OTypeException`）**确实不写缓存** ⇒ **灌完数据不需要清缓存**。但脚本**仍然清一次** —— 防御性，且若将来有别的路径缓存了负结果也不会中招 |
| 2 | 种子编号撞真实业务编号 | 用 **900001+** 显眼段；且 `real_graph:realscope` 是独立 key namespace，不与 `real_data:*` 混 |
| 3 | 判据变成「假绿」（跟 A2 一样的坑） | 判据**必须**是**正向的 field 数**（12 个），不是「没抛异常」；且**单机/集群两边都验** |
| 4 | 种子数据被误当生产数据 | `source_code='HDTEST'` 标记 + `--clean` 脚本可一键清 |
| 5 | 灌完数据后**其它**判据（base 矩阵）数字变了 | `matchOType` 成功 ⇒ 可能让原本 SKIP 的判据变成 PASS ⇒ base 矩阵的 `SKIP` 数会变 ⇒ **逐条比对并说明差异**，不能当成「退化」 |

---

## 八、验收标准（Definition of Done）

- [ ] 种子脚本存在且幂等（连跑两次结果一致）
- [ ] `info.model_objecttype` +3 行、`model_attribute` +12 行、`model_objectattribute` +12 行，全部 `source_code='HDTEST'`
- [ ] Redis `objecttypes:*` 已清
- [ ] **单机模式**下 `real_graph:realscope` 有 **12 个 field**
- [ ] **集群模式**下 `real_graph:realscope` 有**同样的 12 个 field**（field 名与内容逐个相等）
- [ ] web-controller 日志里 **kafkabus 那 3 个类型**的 `OTypeException` 从各 1 次 → **0 次**
      （⚠️ **总数不会归零**：另有 20 次来自 SVG 解析路径的其它类型 —— PMSQltInfo×6 / PT / CT / Fuse / Jumper 等 —— 不在本轮范围）

- [ ] `hd-cluster-app-test.sh` 的 A2 从 **SKIP → PASS**（附新增的 A2-R/V/N/U 判据）
- [ ] 集群层 `FAIL=0`；base 矩阵的差异**逐条解释**
- [ ] DEFECTS.md 更新：#1 的状态 + C/D/E/F 四处**仍无运行时覆盖**的诚实声明

---

## 九、给下一轮的一句话

> **灌 27 行元数据，换 6 处里的 1 处（`SVGCacheServiceImpl`）真正在集群模式下跑一次，
> 并让 A2 判据从「跳过」变成「真跑且可核对」。**
> 另外 4 处**仍缺运行时覆盖**（缺 SVG 文件/订阅），**不假装覆盖了**。
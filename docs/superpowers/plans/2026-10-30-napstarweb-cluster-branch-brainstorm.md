# 第十八轮：napstarweb 集群分支 + 读侧 pipeline —— brainstorming 清单

> 来源：`docs/HANDOFF.md` 第十七轮 + 本次实测探针
> 状态：进行中（brainstorming）

## 背景（实测结论，非推断）

- SDR 2.7.18 的 `JedisClusterConnection.openPipeline()` 抛
  `UnsupportedOperationException("Pipeline is currently not supported for JedisClusterConnection.")`
- `RedisTemplate.executePipelined(...)` 先 `openPipeline()` 再执行回调体
  → **回调体一次都没跑，Redis 命令一条都没发出去**
- 探针：`%TEMP%\opencode\probe\ClusterPipelineProbe.java`（JAVA_EXIT=0）
- napstarweb 树 **10 处** `executePipelined` 无集群分支；部署包 `BOOT-INF/classes/application.yml`
  是 `oms.redisMode: cluster`
- platform 树 **11 处** 全部在 `isCluster()` 分支后 → 安全
- `sche-viewer-server` 另 15 处，但模块在 aggregator 里被注释、不参与构建，`oms:` 块整段注释 → 现在是 standalone

## Checklist

- [x] 1. 探索项目上下文（代码 / 配置 / 依赖链 / 实测探针）
- [x] 2. 视觉伴侣 —— 不适用（后端 Java 改造，无视觉问题）
- [ ] 3. 逐个提问澄清（一次一个）
      - [ ] Q1 多 key 读的集群分支落在哪
      - [ ] Q2 sche-viewer-server 的 15 处是否纳入本轮
      - [ ] Q3 napstarweb 没有测试基建 → 新测试放哪
      - [ ] Q4 `handleModeDataByObid(..., RedisConnection, ...)` 签名怎么改
- [ ] 4. 提 2–3 个方案 + 权衡 + 推荐
- [ ] 5. 分段呈现设计，逐段确认
- [ ] 6. 写设计文档 `docs/superpowers/specs/2026-10-30-napstarweb-cluster-branch-design.md` + 提交
- [ ] 7. spec 自审（占位符 / 矛盾 / 歧义 / 范围）
- [ ] 8. 用户复核 spec
- [ ] 9. 转入 writing-plans

## 关键事实速查

| 项 | 事实 |
|---|---|
| 依赖链 | `web-controller → monitor → realserver-service → realserver-oms` |
| 组件扫描 | `NapstarWebRestApplication` = `@ComponentScan("com.sac")` → **覆盖 oms 的 `config` 与 `utils`** |
| 可注入的 bean | `RedisClusterHelper`（@Component，`isCluster()`）、`RedisClusterHashPipeline`（@Bean `redisClusterHashPipeline`） |
| napstarweb 测试基建 | **完全没有**：`web-controller/src/test/java` 是空目录，pom 无测试依赖 |
| oms 测试基建 | 齐全：Mockito 单测 + 真集群 live test（`RedisClusterHashPipelineLiveTest`）+ `RedisClusterTestSupport` |
| 单 key 站位（4 处） | `SVGCacheServiceImpl:39`、`RTListener:95`、`SVGParseService:564`、`CanvasMonitorServiceImpl:285` |
| 多 key 站位（6 处） | `CalculateService:685/717`、`CalculateForCanvasService:688/720`、`SVGParseService:1864`、`CanvasMonitorServiceImpl:399` |
| 多 key 的 key 形态 | `BASE_SVG_CONNECTLINE+svgId`、`keyPrefix+param+":RT"` → **跨槽** |
| 顺序敏感 | 第十四轮已用 `readPathReturnsEntriesInTheSameOrderAsTheKeys` 锁住读路径顺序 |

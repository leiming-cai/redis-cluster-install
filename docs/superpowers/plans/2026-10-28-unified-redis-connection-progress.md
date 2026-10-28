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
| 0 | 备份原始文件（17 个 + manifest） | ☐ |
| 1 | `RedisUtil` 13 组方法加 `@Deprecated` | ☐ |
| 2 | `RedisPropertiesConfig` bean 改名 | ☐ |
| 3 | 删三个墓碑文件 | ☐ |
| 4 | 补全三个应用的 `oms:` 配置块 | ☐ |
| 5 | 删 `opsHashSetPipeByHashData`，解开对 `realserver-entity` 的依赖 | ☐ |
| 6 | 删 `JedisUtils` / `JedisPoolUtils` | ☐ |
| 7 | 修正错误注释 | ☐ |
| 8 | 生成 patch 并留痕 | ☐ |
| 9 | 三个应用最终验证（含真集群 L3） | ☐ |

## 完成记录

（每完成一个 Task 在此追加：改了什么 / 证据命令与输出 / 遇到的问题）

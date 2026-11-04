# 会话存档（2026-11-04 · 续）：华盾 napstar2.0 — 把「生产真值」补全到升级版

> **这份文件是给「下一个会话」看的。**
> 打开它 == 拿到本会话的**全部产出**：**升级前后两份配置的逐字 diff**、
> **手册里被改掉的 13 处**、**三处「沿用 / 改了 / 新增」的判定**，
> 以及**两条我自己犯的错**（框架判断错 + 数字算错）。
>
> - **上一份存档（本会话的起点）**：`docs/superpowers/sessions/2026-11-04-hd-operations-manual.md`
>   （运维手册轮 —— 手册本体 + 两个被推翻的拓扑假设 + 11/4 的真值清单）
> - **本轮的产出**：`docs/HD-OPERATIONS.md`（**2410 行 / 10 章**，2196 → 2410）
> - 缺陷清单：`docker/hd-napstar/DEFECTS.md`（本轮**没有新缺陷**）

---

## 一、一句话现状

**本轮一行生产代码都没改**，产出的是**一份被补全的真值清单** + **手册的 13 处更正**。

上一轮把「生产真值」定在 `单机(华盾)\web_install\` 的导出包上（**11 个 dataId / 4 个 `oms:`**）。
本轮查清了真相：

> **`web_napstar2.0` 是 `web_install` 的升级版，Nacos 配置在升级版里继续沿用。**
> ⇒ 上一轮那份清单**当时是对的**（就是升级前的配置），**不是「选错了包」**；
> ⇒ **要补的是「升级版相对旧版的增量」**。

**实测（逐字 diff，不是推断）**：

| 项 | 结果 |
|---|---|
| 11 个**共有** dataId 的 `oms:` 块 | **10 个逐字相同**（只有 `icms-hisDataProducer.yaml` 不同） |
| 5 个带 `spring.redis:` 的 | **4 个 host/port/database 完全相同**（同样只有 `hisDataProducer` 不同） |
| 整体文件 | 4 个相同 · **7 个不同** —— 差异全在 datasource / `helper-dialect` / `alarmParam` / `kafkabus` 的 `aname` / `svg` 符号表，**与 Redis 无关** |

⇒ **Redis 配置是沿用的。** 升级版相对旧版，**Redis 相关的变化只有三处**：

| # | 变化 | 说明 |
|---|---|---|
| 1 | **新增 3 个 dataId** | `NAPSTARWEB_GROUP/scheviewer.yaml`（带 `oms:`）· `MODELSERVER_GROUP/icms-hisDataSend`（带 `oms:`，**没有扩展名**）· `DEFAULT_GROUP/hisdataproducer-ext.yaml`（不带 `oms:`） |
| 2 | **`icms-hisDataProducer.yaml` 的 Redis 从 6379 改成 6389** | 旧版**没有** `oms:` 块、`spring.redis:` 是 `node1:6379`；新版**新增** `oms:` 块且**两个都是 6389** |
| 3 | **Redis 实例从 1 个变 2 个** | 新版才有 6389（`redis.conf`）与 `redismaster.conf`（6379）并存 |

⇒ **补全后的真值 = 14 个 dataId / 7 个有 `oms:`**（旧版 11/4 的升级版）。

---

## 二、本轮的提交（2 个，全部已推送）

```
a0a9295  docs(hd): repoint the production truth at the napstar2.0 install package
3bc8f5e  docs(hd): frame the two packages as an upgrade pair, not two truths
```

> `a0a9295` 是「重新指向」（结论正确，但框架措辞有偏差）；
> `3bc8f5e` 是「框架更正」（把「两个包别拿错」改成「升级前后 + 配置沿用」）。

---

## 三、⭐ 本轮最重要的产出：**「结论对」不等于「过程对」**

这一轮我犯了**两个错**，而且**第二个错是被第一个错掩盖的**：

| # | 错 | 严重度 | 怎么抓出来的 |
|---|---|---|---|
| 1 | **框架判断错**：我一度把 `web_install` 当成「另一个产品线的真相」⇒ 手册里写成「两个安装包，别拿错」 | ⭐⭐ | **用户说明**：「`web_napstar2.0` 是 `web_install` 的升级，配置在升级版里沿用」⇒ 框架整个不成立 |
| 2 | **数字算错**：第一次写 §0.4 时用了 `find -name '*.yaml'`，**漏掉 `icms-hisDataSend`** ⇒ 把 **7 个 `oms:` 写成 6 个** | ⭐ | **脚本独立复算**：复算脚本报 `with oms: = 7` vs 我写的 6 |

> 🔴 **错 2 的讽刺之处**：**我自己在手册里写下了「`find -name '*.yaml'` 会漏掉 `icms-hisDataSend`」这条警告，然后当场就踩了它。**
>
> 📌 **错 2 还有一个同源的小错**：我写的「9 个有 `spring.redis:` 的里 8 个相同」也是错的
> ⇒ 实测是 **5 个里 4 个相同**（我的 awk 把「没有 `redis:` 段」和「有但内容为空」混为一谈了）。
>
> ⇒ **教训（与上一轮 §十一 同级）：**
> **① 版本关系要先问清楚** —— 「这是哪一份」比「这份对不对」更前置。
> **② 数字必须能被独立复算** —— 不能靠「我数过了」。

---

## 四、手册改了 13 处（`docs/HD-OPERATIONS.md`，2196 → 2410 行）

| 位置 | 改动 |
|---|---|
| **§0.2** | 改成「**升级前 / 升级后**」对照表 + 「**配置是沿用的**」实测结论 + 三处增量 + MD5 判据 |
| **§0.4** | 真值清单 11/4 → **14/7**，并加一列「**相对升级前**」（沿用 / 改了 / 新增） |
| **§0.4.1** | **新增** —— `updateconfig\` 覆盖层（第三层） |
| **§2.1** | 补「**6389 不是闲置实例，上面有真实数据**」 |
| **§4.2** | 「另外两个 dataId」→「另外的 dataId」（5 个），并标注 3 个是升级版新增 |
| **§4.7** | 汇总表 4 行 → **9 行**；`oms:` 模板「三处」→「**七处**」；`database` 说明 |
| **§4.8** | 验证循环加 3 个 app（3 → 6） |
| **§6.1** | 加 2 行新症状（「某些 app 起来了某些没有」/「hisDataProducer 读不到数据」） |
| **§7.4** | 巡检第 10 条：不止四个 app；补回 `maxmemory` 警告 |
| **§8.3** | 易错点加 19~23（**23 条**） |
| **§8.3.1** | 「生产没有组名撞车」→ 补上 `scheviewer.yaml` 的撞名 + 「实际不抢」的实测理由 |
| **§8** | 文件布局：指向 `-napstar2.0.zip` + 加 `updateconfig\` |
| **§9** | 一页速查：7 个 `oms:`、6389 有数据、无扩展名那个 |

---

## 五、⭐ 三个由此翻出来的坑（写进手册 §0.4 / §2.1 / §4.7）

| # | 坑 | 后果 |
|---|---|---|
| 1 | **`hisDataProducer` / `hisDataSend` 的 `oms:` 指向 `6389`** | 它们连的是**第二个实例** ⇒ 只改 6379 那批 ⇒ 这俩留在单机；且 **6389 的数据必须一并迁**（迁前 `DBSIZE` 两个都要对比） |
| 2 | **`scheviewer.yaml` 是升级版新增的**（带 `oms:`） | 集群化时**必须一起改**；且它有 **15 处裸 `executePipelined`**（集群下必抛 `UnsupportedOperationException`）⇒ **切集群前必须先修** |
| 3 | **`icms-hisDataSend` 没有 `.yaml` 扩展名** | 用 `find -name '*.yaml'` 扫会**漏掉它** ⇒ 漏改 ⇒ **7 变成 6** |

### 5.1 §8.3.1 的「生产没有组名撞车」要补一句

`scheviewer.yaml`（升级版新增）与 `napstarweb-controller.yaml` **都是 `group-id: svg`** ⇒ 升级版**确实**撞名。
不过 **sche-viewer-server 零 `@KafkaListener`、零 `KafkaTemplate`** ⇒ **实际不消费 Kafka ⇒ 不会真抢消息**。
⇒ **配置上撞名，实际不抢**；但**它的 `oms:` 仍然要改**。

---

## 六、⭐ 还有第三层：`updateconfig\` 覆盖包（上一轮完全没提）

`单机(华盾)\updateconfig\` 下有 3 个 `-napstar2.0-update.zip`
（kingbase 2026-04-07 / dm 2026-04-07 / postgresql 2026-10-31），
仓库里的 docx 写明「**配置统一使用 nacos 的导入包：…-update.zip 里的内容**」。

| update 包 | 含哪些 dataId |
|---|---|
| kingbase | `icms-commitDataIncreProducer.yaml` / `icms-controller.yaml` / `napstarweb-controller.yaml` |
| dm | 同上 **+** `DEFAULT_GROUP/napstarmappingconfig.yaml` |
| postgresql | 同上 **+** `DEFAULT_GROUP/napstarmappingconfig.yaml` |

**它改了什么**：DB URL `node2` → `node1`（三个 dataId 里各 2~3 处 `jdbc:`）、去掉 `/rtwebsocket/**` 的 `anon` 权限。

> 📌 **实测：update 包是基于「升级版」基线的补丁**，不是基于旧版 ——
> 与升级版基线差 **4 / 4 / 12** 行，与旧版差 **12 / 27 / 31** 行。
> ⇒ **确认它覆盖的是升级版。**
> 💡 **好消息：update 层不碰 `oms:`**（实测 update 包的 `oms:` 与基础包**逐字相同**）⇒ **改 Redis 时不必区分层次。**

---

## 七、⭐ 判据：怎么确认现场装的是哪一版

**实测 MD5**（容器 `hd-node1` 的 `/pkg`）—— 7 个文件与 `web_napstar2.0` **逐字节相同**：

```
/pkg/env/redis/install_redis.sh   f91df93c…      /pkg/bin/1start_env.sh    983fe4e7…
/pkg/env/redis/redis.conf          b9d392b3…      /pkg/bin/2start_kafka.sh  d15bc539…
/pkg/env/redis/redismaster.conf    c0ac44b9…      /pkg/bin/3start_nacos.sh  d747a9f2…
/pkg/env/redis/redis-full.conf     facf8bc6…
```

⇒ **验证环境复现的是升级版。**

**现场怎么一眼分辨**：

| 现场 | 说明 |
|---|---|
| `1start_env.sh` 起 **2 个** Redis（6379 + 6389） | **升级版** |
| `1start_env.sh` 起 **1 个** Redis（6379） | 升级前 |

💡 **两种情况 Redis 配置几乎一样**（除 `icms-hisDataProducer` 外逐字相同）
⇒ **清单以升级版（14/7）为准，两种情况都能覆盖。**

---

## 八、这一轮**没有**做的事（明确记下来）

| # | 事 | 为什么 |
|---|---|---|
| 1 | **改任何 Java 源码** | 文档轮不改代码 |
| 2 | **改生产 Nacos 的配置** | 那是**生产环境**的动作，不在本地文档轮里做 |
| 3 | **给 `sche-viewer-server` 的 15 处裸 `executePipelined` 加集群分支** | 那是**代码改动**；本轮只把「它也在改造范围内」这件事记进手册（§十 第 7 条 🔴） |
| 4 | **真机验证** | 真机跑一遍要改生产环境 |
| 5 | **建 `sac`/`cmt`/`hds` 的表** | 🚫 第三方系统的表，本项目只有读权限 |
| 6 | **写数据迁移脚本** | 用户早已决定不做 —— 手册里是「人工操作 + 迁前迁后 `DBSIZE` 核对」 |

---

## 九、最终状态

| 项 | 状态 |
|---|---|
| 仓库 | 工作区**干净**，HEAD = `3bc8f5e`，**已推送**（`rev-list --left-right --count` = `0 0`） |
| 手册 | `docs/HD-OPERATIONS.md` **2410 行 / 10 章** |
| 真值指向 | **升级版 `web_napstar2.0`**（14 dataId / 7 `oms:`）+ `updateconfig` 覆盖层 |
| 脱敏 | 真实内网 IP / 口令 **0 处残留** |
| `tests/check_syntax.sh` | `TOTAL=46 FAIL=0` |
| `tests/validate_libs.sh` | `PASS=54 FAIL=0` |
| 容器环境 | 未动（集群仍停 · 4 个 app 跑在 Standalone · Nacos 200 · 夹具 3 行） |
| 独立复算 | **20/20 通过**（本轮所有数字都用脚本从包本身重新算过一遍） |

---

## 十、下一轮照做

| # | 事 | 严重度 | 说明 |
|---|---|---|---|
| **1** | **实施时抽查生产 Nacos 的实时值** | 🟡 | 手册以**升级版 `web_napstar2.0` 的 kingbase-napstar2.0 导出包**为准（+ `updateconfig` 覆盖层）。若运维后来手工改过 `oms:`，**以控制台为准**，并同步回手册 |
| **1b** | **确认生产上装的是升级前还是升级后的包** | 🟡 | **起 2 个 Redis = 升级版 / 起 1 个 = 升级前**（§七）。**两者 Redis 配置除 `icms-hisDataProducer` 外逐字相同** ⇒ 清单以升级版为准，两种情况都能覆盖 |
| **2** | **真机上跑一遍 §3** | 🟡 | 跑通后可把「未在真机验证」的标记改成「已实测」 |
| **3** | **`monitor` 另外 5 处集群分支的运行时覆盖** | 🟡 | D11 仍未变（C/D/E/F 需 SVG 文件或订阅，`RTListener` 需一条 Kafka 消息） |
| **4** | **交付方确认交付流程** | 🔴 | 「先编 platform 再 `mvn install`」吗？若是 ⇒ 在此之前**禁止 install 树 A 的 platform**、**禁止把区间切到 `[3.0.0,4.0.0)`**（D9） |
| **5** | **`sac`/`cmt`/`hds` 建表脚本找第三方要** | 🔴 | 本项目**只读**，不建表 |
| **6** | **门户线要切集群** | 🟡 | 门户树**一个集群标记都没有** ⇒ 得从基线把整套补丁搬过去 |
| **7** | **`sche-viewer-server` 的 15 处裸 `executePipelined`** | 🔴 **升级** | 本轮查明：**它的 `scheviewer.yaml` 在生产 kingbase 里就有，且带 `oms:`** ⇒ 它**在本次改造范围内**（不再是「将来再说」）⇒ **切集群前必须先修** |

---

## 十一、给下一轮的一句提醒

> **写「生产」文档之前，先问三个问题：**
> ① 我读的那些文件**是不是生产上的**？
> ② 我读的那些文件**是哪个版本的**？—— **「对的文件」可能只是「旧的文件」**
> ③ 我列的清单**是不是查全了**？（用 `find -type f`，别只数 `.yaml`）
>
> **第二条最隐蔽** —— ①③ 查一下就知道，**②自己不会暴露**：
> 旧配置**本身没错**，错的是「以为它就是全部」。
>
> 📌 **还有一条方法上的**：**每个数字都要能被脚本独立复算一遍。**
> 本轮「7 写成 6」和「9/8 写成 9/8」两个错，**都是复算抓出来的**，
> 靠「我数过了」是发现不了的。

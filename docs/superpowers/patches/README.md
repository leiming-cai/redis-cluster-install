# Patches

Unified-diff patches for the Java source trees that live **outside** this git repo.

## 2026-10-29 — jedis version ceiling + live-cluster test

Two things changed in the Java trees during the fourteenth round:

1. **`backend/pom.xml` and `application/backend/pom.xml`** — `jedis.version` was
   changed to `8.1.0-beta2` by an external editor (not by this work) and left
   the whole tree uncompilable. It is now `3.10.0`, with the measured ceiling
   documented in place. **3.10.0 is the highest jedis that works with
   spring-data-redis 2.7.18 on JDK 8** — see `docs/HANDOFF.md` §14.
2. **A new live-cluster integration test** in the `oms` module:
   `RedisClusterHashPipelineLiveTest.java` (4 cases). The write path
   (`RedisClusterHashPipeline.putAllHashes`) had **28 Mockito-based tests and
   zero** coverage against a real Redis cluster; this file exercises it against
   one.

### Which patch to use

| Patch | Target root | Files |
|---|---|---|
| `2026-10-29-jedis-ceiling-platform-backend.patch` | `D:\javawork\1.2\cpscloud1.0\code\platform\backend` | 2 (`pom.xml` + the new test) |
| `2026-10-29-jedis-ceiling-application-backend.patch` | `D:\javawork\1.2\cpscloud1.0\code\application\backend` | 1 (`pom.xml`) |

### Applying

```powershell
cd D:\javawork\1.2\cpscloud1.0\code\platform\backend
git apply --reverse --check ..\..\..\..\work\rediscluterproject\docs\superpowers\patches\2026-10-29-jedis-ceiling-platform-backend.patch
git apply ..\..\..\..\work\rediscluterproject\docs\superpowers\patches\2026-10-29-jedis-ceiling-platform-backend.patch
```

### Verification performed

- Reverse-apply check against both live roots: exit `0` for `platform-backend`
  and for `application-backend`.
- Round-trip: reverse-apply the live tree to the "before" state, then
  forward-apply the same patch again — `apply_exit=0` and **0 mismatches**
  against the live tree (`platform-backend`: 2 files checked,
  `application-backend`: 1 file checked).
- Both patch files start with the bytes `dif`, no BOM.

## 2026-10-28 — unified redis connection

The redis client was unified across three deployables. The Java trees are not git
repositories, so the change is captured here as a unified diff against a pristine
"before" snapshot.

### Which patch to use

| Patch | Target root | Files |
|---|---|---|
| `2026-10-28-unified-redis-connection-platform-backend.patch` | `D:\javawork\1.2\cpscloud1.0\code\platform\backend` | 18 |
| `2026-10-28-unified-redis-connection-napstarweb.patch` | `D:\javawork\1.2\cpscloud1.0\code\application\backend\napstarweb` | 2 |
| `2026-10-28-unified-redis-connection.patch` | both roots combined | 20 |

The **combined** patch contains all 20 file changes but its paths are relative to
two different trees, so it only applies from a directory that holds both trees
side by side (e.g. a synthetic repo). For applying to a real checkout use the
per-root patches.

### What is in the platform-backend patch (18 files)

| Kind | Files |
|---|---|
| modified (10) | `RedisUtil`, `RedisPipelineUtil`, `RedisPropertiesConfig` (oms), `RedisUtilConfig`, `pom.xml`, `OmsWriteDaoImpl`, `OmsWriteByKafkaServiceImpl`, `CacheServiceImpl`, `application.yml` (realserver-controller), `application.yml` (modelserver-controller) |
| deleted (4) | `JedisUtils`, `JedisPoolUtils`, `RedisPropertiesConfig` (rtdata-module), `RedisPropertiesConfig` (modelserver-controller) |
| added (4) | `RedisPropertiesConfigBeanNameTest`, `RedisModeCaseSensitivityTest`, `RedisClusterOmsContractTest`, `RedisPipelineUtilNoEntityDependencyTest` |

The four **added** files are the new regression guards written during this work;
they did not exist in the baseline snapshot, so they show up as `new file mode`
entries. `RedisConfigProperties.java` is *not* in the patch — it was never
changed.

The napstarweb patch has 1 modified file (`application.yml`) and 1 deleted file
(`RedisPropertiesConfig`).

### Applying

```powershell
cd D:\javawork\1.2\cpscloud1.0\code\platform\backend
git apply --reverse --check ..\..\..\..\work\rediscluterproject\docs\superpowers\patches\2026-10-28-unified-redis-connection-platform-backend.patch
git apply ..\..\..\..\work\rediscluterproject\docs\superpowers\patches\2026-10-28-unified-redis-connection-platform-backend.patch
```

### Line endings

The source files are **mixed**: some are CRLF, some LF. The patches were generated
with `core.autocrlf=false` so that the hunks match the bytes on disk exactly.
Do not re-normalise these files, or the patches will stop applying.

### Regenerating the patches

Two things will silently produce a broken patch if you get them wrong:

- **Do not pipe `git diff` through `Out-File -Encoding ascii`.** It mangles the
  UTF-8 Chinese comments into `?` and the resulting patch is *corrupt* — `git
  apply` fails with "corrupt patch at …". Use `git diff --output=<file>`, which
  writes the raw bytes.
- **Delete the removed files from the work tree explicitly** before `git add -A`.
  Copying only the files that still exist makes git see no change, and the
  deletions vanish from the patch.

### Verification performed

- Reverse-apply check against both live roots: exit `0` for `platform-backend`
  and for `napstarweb`.
- Forward-apply of each patch onto a fresh copy of the baseline, then
  byte-for-byte hash comparison against the live tree:
  - `platform-backend` — `apply_exit=0`, 19 files checked, **0 mismatches**
  - `napstarweb` — `apply_exit=0`, 2 files checked, **0 mismatches**
  - combined — `apply_exit=0`, 21 files checked, **0 mismatches**
- Each patch file starts with the bytes `100,105,102` (`dif`), no BOM.
- The BE patch records **4** `new file mode` entries (the new regression guards)
  and **4** `deleted file mode` entries (the dead `JedisUtils` /
  `JedisPoolUtils` classes and the two duplicate `RedisPropertiesConfig`
  classes).

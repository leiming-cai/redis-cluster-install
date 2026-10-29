# Patches

Unified-diff patches for the Java source trees that live **outside** this git repo.

## 2026-10-29 — the two RedisUtil copies are now one

There were **two** `RedisUtil` classes (the handoff said three — there is no
third: `modelserver` consumed idgenerator's through the dependency chain). This
patch deletes the thin one and moves what was in it to where it belongs.

### What was actually in the 179-line class

| Kind | Members |
|---|---|
| real content | the `SET NX EX` lock (`tryLock`/`unLock`) and the pattern delete (`deleteNamespace`) |
| dead code | `setHash`, `getHashList`, `getPushList` — zero call sites |
| one-line wrappers | `getValue`, `setValue`, `delete`, `scan` |
| injection setters | `setRedisTemplate`, `setRedisClusterHelper` |
| one more | `execute` — the public method of the anonymous `SessionCallback` inside `getHashList` |

That is 13 public methods in all.

So it was a thin shell around two things. Both have moved:

- **`deleteNamespace`** (generic) → oms' `RedisUtil`, now the only implementation
  of it anywhere, with a live-cluster test.
- **the lock** (only `IdUtil` ever used it, and its `locked#` prefix is that
  caller's own convention) → `IdUtil` itself, as private methods.

`IdUtil` now talks to `RedisTemplate` directly and owns its lock.

### The dependency direction is fixed

`common/idgenerator` (a common library) depended on `realserver/oms` (a business
module) — the wrong way. That dependency existed **only** because the deleted
class was a `@Component` that `@Autowired` an oms `RedisClusterHelper`.

- `common/idgenerator/pom.xml` no longer declares `realserver-oms`.
- `modelserver/services/pom.xml` (artifactId `model-service`) now declares it
  **explicitly** — it was relying on an accidental transitive path through
  idgenerator.

### ⚠️ Published-contract change (needs a release note)

The published transitive closure of **four** modules shrank:
`idgenerator`, `userservice`, `model-interface`, `menuservice`. Before, 20
modules could reach `realserver-oms`; now 16 — the four that lost it never used
an oms class themselves, and **zero** edges now route through idgenerator.

**`lettuce-core` disappeared from those four as well** (they inherited it via
idgenerator → oms; idgenerator's starter excludes lettuce). An out-of-repo
consumer that relied on `model-interface` → `realserver-oms`, or that expected
`lettuce-core` on that classpath, will notice.

### Which patch to use

| Patch | Target root | Files |
|---|---|---|
| `2026-10-29-unify-redis-util.patch` | `D:\javawork\1.2\cpscloud1.0\code\platform\backend` | 10 (7 modified, 1 deleted, 2 added) |

### Applying

```powershell
cd D:\javawork\1.2\cpscloud1.0\code\platform\backend
git apply --reverse --check ..\..\..\..\work\rediscluterproject\docs\superpowers\patches\2026-10-29-unify-redis-util.patch
git apply ..\..\..\..\work\rediscluterproject\docs\superpowers\patches\2026-10-29-unify-redis-util.patch
```

### Verification performed

- Reverse-apply check against the live root: exit `0`.
- Round-trip: forward-apply onto a pristine baseline → `apply_exit=0`, 9 files
  checked, **0 mismatches**; the deleted file is absent from both the rebuild
  and the live tree.
- `oms` **66 tests** (3 new live-cluster cases), `idgenerator` **6 tests**
  (3 new), `rtdata-module` **14 tests**; backend reactor **44 modules**
  SUCCESS, napstarweb reactor **13 modules** SUCCESS.
- `mvn -o dependency:tree` on idgenerator → **no `realserver-oms`** at all;
  on `model-service` → a direct `compile` dependency.
- Six mutation checks. Five turn **exactly one** test red; the sixth (scan only
  `finally` release; release the doubled-prefix key; drop the retry sleep;
  release a lock that was never acquired; store the counter as a string; scan
  the first master) turns two red. The list: drop the

### Known issues left in place (deliberately)

The lock has two **ownership** hazards that predate this work and that the
approved design pins, so they were not changed here:

1. `tryLock`'s catch deletes the lock even though a throwing `SET NX` means we
   never held it — it could free another holder's lock.
2. The 5 s TTL is shorter than the critical section (which contains a DB round
   trip), and the lock value is the constant `"1"`, so the release cannot check
   ownership. If the DB call exceeds the TTL, the lock expires while we still
   hold it, and our `finally` then deletes the *new* holder's lock.

The proper fix for both is a unique token per acquisition plus a Lua
compare-and-delete on release, and a TTL longer than the DB timeout.

## 2026-10-29 — idgenerator: the redis lock was never released

`IdUtil.getNextSeqFromRedis` takes a redis lock (`SET NX EX`) around
"read the counter → increment → write it back", and then **returned without
releasing it**. The lock only went away when its TTL (5 s) expired, so:

- every acquisition in the next 5 s had to wait for the lock to expire
  (the second call blocked for ~5 s), and
- once the wait exceeded `tryLock`'s own timeout (10 s) the sequence could not
  be obtained at all — and `getNextId` then dereferenced the `null` sequence,
  throwing a bare `NullPointerException` that named neither the table nor the
  cause.

Two smaller defects in the same code path:

- `tryLock`'s catch block released the wrong key: it called `unLock(lockKey)`,
  and `unLock` prepends `"locked#"` **again**, so it deleted
  `locked#locked#xxx` instead of the lock it actually held.
- `IdUtil`'s catch block released the lock **unconditionally**, even when the
  exception happened before the lock was acquired — which frees *another*
  holder's lock.

The fix releases the lock in a `finally` (only when it was really taken),
releases the right key, and replaces the bare `NullPointerException` with an
`IllegalStateException` that names the table. It deliberately does **not** fall
back to the snowflake id: the `obj_type` is encoded in the high bits of the id,
so a made-up id would be read back as a different type — a silent data error.

### Which patch to use

| Patch | Target root | Files |
|---|---|---|
| `2026-10-29-idutil-redis-lock-fix.patch` | `D:\javawork\1.2\cpscloud1.0\code\platform\backend` | 4 (2 modified `.java`, 1 modified `pom.xml`, 1 added test) |

### Applying

```powershell
cd D:\javawork\1.2\cpscloud1.0\code\platform\backend
git apply --reverse --check ..\..\..\..\work\rediscluterproject\docs\superpowers\patches\2026-10-29-idutil-redis-lock-fix.patch
git apply ..\..\..\..\work\rediscluterproject\docs\superpowers\patches\2026-10-29-idutil-redis-lock-fix.patch
```

### The new test

`common/idgenerator/src/test/java/com/sac/platform/common/utils/IdUtilRedisLockLiveTest.java`
(3 cases). `idgenerator` had **no `src/test` at all** before this, so its `pom`
gained `spring-boot-starter-test` (test scope) — the same dependency the `oms`
module already uses.

The test builds its own `JedisConnectionFactory`/`RedisTemplate` instead of
reusing oms's `RedisUtilConfig`, because **the `realserver-oms` jar in the local
maven repository is proguarded**: `RedisPropertiesConfig` and `RedisUtilConfig`
have been renamed (to `a` and `b`), so they cannot be referenced from
idgenerator's test classpath at all.

### Verification performed

- The 3 cases were run **before** the fix: all 3 failed. The lock assertion
  reported `the redis lock locked#info_LOCK_TEST is still held after the id
  was taken`, and the held-lock case reported
  `instead it threw a NullPointerException`.
- Mutation check, one defect at a time — each part of the fix is load-bearing:
  | Mutation | Case that turns red |
  |---|---|
  | drop the `finally` release | `releasesTheRedisLockSoTheNextAcquisitionSucceeds` |
  | `unLock(lockKey)` instead of `delete(lockKey)` | `tryLockReleasesOnlyTheLockItTookWhenTheAcquireCallFails` |
  | drop the null-sequence guard | `aHeldLockProducesADiagnosableErrorInsteadOfANullPointerException` |
- After the fix: 3/3 green, and **5 consecutive runs** were stable
  (no flakes). The two live cases use **different** table names on purpose, so
  a failed cleanup in one cannot poison the other.
- Reverse-apply check against the live root: exit `0`.
- Round-trip: forward-apply onto a pristine baseline → `apply_exit=0`,
  4 files checked, **0 mismatches** (SHA-256 against the live tree).

### Known issue left in place (deliberately)

`tryLock` busy-waits **without sleeping** while the lock is held (up to its
10 s timeout), so it hammers `SET NX` in a tight loop. After the fix above,
contention is rare, so the practical impact is much smaller — but it is still
there and is not addressed by this patch.

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

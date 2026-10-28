# Patches

Unified-diff patches for the Java source trees that live **outside** this git repo.

## 2026-10-28 — unified redis connection

The redis client was unified across three deployables. The Java trees are not git
repositories, so the change is captured here as a unified diff against a pristine
"before" snapshot.

### Which patch to use

| Patch | Target root | Files |
|---|---|---|
| `2026-10-28-unified-redis-connection-platform-backend.patch` | `D:\javawork\1.2\cpscloud1.0\code\platform\backend` | 13 |
| `2026-10-28-unified-redis-connection-napstarweb.patch` | `D:\javawork\1.2\cpscloud1.0\code\application\backend\napstarweb` | 2 |
| `2026-10-28-unified-redis-connection.patch` | both roots combined | 15 |

The **combined** patch contains all 15 file changes but its paths are relative to
two different trees, so it only applies from a directory that holds both trees
side by side (e.g. a synthetic repo). For applying to a real checkout use the
per-root patches.

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

### Verification performed

- Reverse-apply check against both live roots: exit `0`.
- Forward-apply of the patch onto a fresh copy of the baseline, then byte-for-byte
  hash comparison against the live tree: **0 mismatches** for both roots and for
  the combined patch.

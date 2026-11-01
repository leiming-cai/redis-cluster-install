#!/bin/bash
# compare-hd-portal-baseline.sh 的**边界情况**测试。
#
# ⚠️ **这个测试调用的是发布的那份脚本本身**
#    （scripts/compare-hd-portal-baseline.sh），**不是它的复制品**。
#
# 用法（在 rc-e2e-runner:local 里跑，仓库挂 /repo、.hd-work 挂 /out）：
#   bash /repo/scripts/test-hd-portal-baseline.sh
#
# ⚠️ 这里造出来的快照都是**临时的**（在 mktemp 目录里），
#    不会碰 .hd-work 里真的那份。
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/compare-hd-portal-baseline.sh"
[ -f "$SCRIPT" ] || SCRIPT=/repo/scripts/compare-hd-portal-baseline.sh
if [ ! -f "$SCRIPT" ]; then
  echo "!! 找不到 compare-hd-portal-baseline.sh" >&2
  exit 2
fi
echo "被测脚本: $SCRIPT"

# 需要一份**真实**的快照当输入。
# ⚠️ 优先用命令行给的，其次用 /out/portal-snapshot-cluster.txt
#    （verify-hd-portal-untouched.sh 的输出约定）。
REAL="${1:-/out/portal-snapshot-cluster.txt}"
if [ ! -f "$REAL" ]; then
  echo "!! 找不到真实快照: $REAL" >&2
  echo "   先跑 verify-hd-portal-untouched.sh 生成一份。" >&2
  exit 2
fi
echo "真实快照: $REAL"

TPASS=0; TFAIL=0
ok()  { echo "  PASS  $*"; TPASS=$((TPASS+1)); }
bad() { echo "  FAIL  $*"; TFAIL=$((TFAIL+1)); }

T=$(mktemp -d "${TMPDIR:-/tmp}/hd-portal-baseline-test.XXXXXX") || { echo "mktemp 失败" >&2; exit 2; }
# ⚠️ 清理：只删**自己建的**目录。
cleanup() { [ -n "${T:-}" ] && [ -d "${T:-}" ] && rm -rf "$T"; return 0; }
trap cleanup EXIT

run() {  # run <快照> -> 退出码留在 $rc，输出留在 $out
  out="$T/out.$$"
  bash "$SCRIPT" "$1" >"$out" 2>&1
  rc=$?
}
expect_rc() {  # expect_rc <标签> <期望非0?> <实际rc>
  local label="$1" want_nonzero="$2" got="$3"
  if [ "$want_nonzero" = "yes" ]; then
    [ "$got" -ne 0 ] && ok "$label （退出码 $got，非 0 ✅）" || bad "$label 期望非 0 退出码，实得 0"
  else
    [ "$got" -eq 0 ] && ok "$label （退出码 0 ✅）" || bad "$label 期望退出码 0，实得 $got"
  fi
}
has_line() {  # has_line <标签> <正则>
  local label="$1" re="$2"
  if grep -qE "$re" "$out"; then ok "$label"; else bad "$label （输出里找不到 /$re/）"; fi
}
no_line() {
  local label="$1" re="$2"
  if grep -qE "$re" "$out"; then bad "$label （输出里不该有 /$re/）"; else ok "$label"; fi
}

echo "=== 场景1：快照文件不存在 → 必须非 0 退出（不能假绿）==="
run "$T/does-not-exist-xyz.txt"
expect_rc "场景1 缺失快照" yes "$rc"
has_line "场景1 明确说了找不到文件" "找不到门户快照文件"

echo "=== 场景2：真实快照 → 结论有意义，且能 exit 0 ==="
run "$REAL"
expect_rc "场景2 真实快照" no "$rc"
has_line "场景2 结论是逐项一致" "逐项一致"
no_line "场景2 没有 MISS" "MISS"
no_line "场景2 没有 DIFF" "DIFF"

echo "=== 场景3：在 '### 2.' 后面插一行噪声 → 取值必须不变 ==="
awk '{
  print
  if (index($0, "### 2. cpspg info table count") == 1) print "SOME NOISE"
  if (index($0, "### 4. portal napstar info table count") == 1) print "   "
  if (index($0, "### 6. image id") == 1) print "another noise line"
}' "$REAL" > "$T/noisy.txt"
run "$T/noisy.txt"
expect_rc "场景3 噪声不改变判定" no "$rc"
no_line "场景3 没有 MISS（取值没被噪声带偏）" "MISS"
has_line "场景3 表数仍取到 36" "cpspg info 表数 = 36"
has_line "场景3 镜像 ID 仍取到" "镜像 ID = 07c4dac1a041"

echo "=== 场景4：快照缺了一段 → 必须非 0 + MISS（取不到 ≠ 取错）==="
grep -v '^36$' "$REAL" > "$T/broken.txt"
run "$T/broken.txt"
expect_rc "场景4 快照残缺" yes "$rc"
has_line "场景4 点名 MISS" "MISS"

echo "=== 场景5：真的改一个值 → 必须非 0 + DIFF ==="
sed 's/^07c4dac1a041$/deadbeef1234/' "$REAL" > "$T/modified.txt"
run "$T/modified.txt"
expect_rc "场景5 值变了" yes "$rc"
has_line "场景5 点名 DIFF" "DIFF"

echo "=== 场景6：门户容器**被重启过** → 必须非 0（这是这个门禁最该证明的东西）==="
sed 's/restarts=0/restarts=3/' "$REAL" > "$T/restarted.txt"
run "$T/restarted.txt"
expect_rc "场景6 门户被重启" yes "$rc"
has_line "场景6 点名重启次数" "重启次数"
has_line "场景6 点名被重启过" "被重启过"

echo "=== 场景7：门户容器 OOM 标记变了（= 被重建过）→ 必须非 0 ==="
sed 's/oom=true/oom=false/' "$REAL" > "$T/oom.txt"
run "$T/oom.txt"
expect_rc "场景7 OOM 标记变了" yes "$rc"
has_line "场景7 点名被重建过" "被重建过"

echo "=== 场景8：门户 Nacos 从 000 变成 200（**良性**变化）→ 不该报 DIFF ==="
sed 's|^000$|200|' "$REAL" > "$T/nacos200.txt"
run "$T/nacos200.txt"
expect_rc "场景8 Nacos 恢复" no "$rc"
no_line "场景8 没有 DIFF（门户恢复正常不是问题）" "DIFF"
no_line "场景8 没有 MISS" "MISS"

echo "=== 场景9：在 '--- java process count' 段里插噪声 → java 进程数不能被带偏 ==="
# ⚠️ 噪声要插在**段的中间**（header 之后、下一段 header 之前），
#    而且**不能自己长得像一个 header** —— 否则它就是**另一个段**了，
#    那是合法的结构变化，不是噪声。
#    （之前这个场景插的是 '--- extra' + 42 —— '--- extra' 自己就是个
#      '--- ' 级的 header，它**开启了一个新段**，
#      于是 '--- java process count' 段里只剩 42 → 取到 42。
#      那是**正确**的行为，不是 bug。）
awk '{
  print
  if (index($0, "--- java process count") == 1) { print "some noise here"; print "42" }
  if (index($0, "--- redis dbsize (6379)") == 1) { print "another noise"; print "99" }
}' "$REAL" > "$T/noisy2.txt"
run "$T/noisy2.txt"
expect_rc "场景9 段内噪声不改变判定" no "$rc"
no_line "场景9 没有 MISS" "MISS"
no_line "场景9 没有 DIFF" "DIFF"
has_line "场景9 java 进程数仍是 2" "java 进程数 = 2"

echo "=== 场景9b：'--- ' 级 header 开启**新段** → 前一段的值**取不到**，必须点名 MISS ==="
# ⚠️ 这一条断言的是**诚实的行为**，不是「照样取到 2」：
#    '--- extra' 自己就是一个 '--- ' 级的 header → 它**开启了一个新段**
#    → '--- java process count' 段里**确实没有**那个值了。
#    ⇒ 脚本必须说「MISS（取不到）」并 exit 非 0，
#      **不能**去别的地方找一个 2 蒙混过关，也不能读成 42。
awk '{
  print
  if (index($0, "--- java process count") == 1) { print "--- extra"; print "42" }
}' "$REAL" > "$T/noisy3.txt"
run "$T/noisy3.txt"
expect_rc "场景9b 取不到就非 0" yes "$rc"
has_line "场景9b 点名 MISS（没蒙混过关）" "MISS"
no_line "场景9b 没有把 42 当成 java 进程数" "java 进程数 = 42"

echo "=== 场景10：不传参数 → 用默认路径（/out/portal-snapshot-cluster.txt）==="
out="$T/out.$$"
bash "$SCRIPT" >"$out" 2>&1
rc=$?
expect_rc "场景10 默认路径" no "$rc"
has_line "场景10 结论是逐项一致" "逐项一致"

echo "=== 场景12：噪声里的数字**绝不能**被当成真值（回归：曾经会读成 42）==="
# 在每个 header 后面插噪声 + 一个**别的数字**，真值仍在后面。
# 判据：脚本必须读到**真值**，不能读到噪声里的那个数。
awk '{
  print
  if (index($0, "### 2. cpspg info table count") == 1) { print "SOME NOISE"; print "42" }
  if (index($0, "### 4. portal napstar info table count") == 1) { print "SOME NOISE"; print "42" }
  if (index($0, "--- java process count") == 1) { print "some noise here"; print "42" }
}' "$REAL" > "$T/noisy4.txt"
run "$T/noisy4.txt"
expect_rc "场景12 噪声数字没被当成真值" no "$rc"
no_line "场景12 没有 MISS" "MISS"
no_line "场景12 没有 DIFF" "DIFF"
has_line "场景12 表数仍是 36（不是 42）" "cpspg info 表数 = 36"
has_line "场景12 napstar 表数仍是 30（不是 42）" "门户 napstar info 表数 = 30"
has_line "场景12 java 进程数仍是 2（不是 42）" "java 进程数 = 2"
no_line "场景12 没有出现 42" "= 42"

echo "=== 场景13：'### 2x.' 不能被当成 '### 2.'（字面量匹配，不是正则）==="
sed 's/^### 2\. cpspg info table count$/### 2x. cpspg info table count/' "$REAL" > "$T/2x.txt"
run "$T/2x.txt"
expect_rc "场景13 标题被改 -> 那一项取不到" yes "$rc"
has_line "场景13 点名 MISS" "MISS"

echo
echo "TEST SUMMARY: PASS=$TPASS FAIL=$TFAIL"
[ "$TFAIL" -eq 0 ]

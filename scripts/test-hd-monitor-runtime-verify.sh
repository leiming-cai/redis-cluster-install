#!/bin/bash
# hd-monitor-runtime-verify.sh 的**边界情况**测试（防假绿）
#
# ⚠️ **这个测试测的是「判据会不会把坏的当成好的」**：
#    如果判据在「集群比单机少字段」「字段数不对」「前置条件不满足」时
#    仍然报 PASS，那它就是上一轮那个假绿判据的翻版。
#
# 用法:
#   bash scripts/test-hd-monitor-runtime-verify.sh
set -uo pipefail

TPASS=0; TFAIL=0
ok()  { echo "  PASS  $*"; TPASS=$((TPASS+1)); }
bad() { echo "  FAIL  $*"; TFAIL=$((TFAIL+1)); }

T=$(mktemp -d "${TMPDIR:-/tmp}/hd-mrv-test.XXXXXX") || { echo "mktemp 失败" >&2; exit 2; }
# ⚠️ 清理：只删**自己建的**目录。
cleanup() { [ -n "${T:-}" ] && [ -d "$T" ] && rm -rf "$T"; return 0; }
trap cleanup EXIT

# 被测代码里那两个「比对」函数 —— 从判据脚本里**抽出来**，
# 测的时候 source 判据脚本的**副本**。
# ⚠️ 这里**不 source 判据脚本本身** —— 它会立刻跑起来（起应用、连集群）。
#     判据脚本必须把「纯逻辑」的部分放进一个可 source 的库里 ——
#     所以判据脚本要拆成两个文件：
#       hd-monitor-runtime-verify.sh   —— 编排（起应用、跑两遍）
#       hd-monitor-runtime-lib.sh      —— 纯逻辑（比对 field、判异常数）
#     这个测试 source 的是**后者**（发布的那份，不是复制品）。

LIB=/opt/hd/hd-monitor-runtime-lib.sh
[ -f "$LIB" ] || LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hd-monitor-runtime-lib.sh"
if [ ! -f "$LIB" ]; then
  echo "!! 找不到 hd-monitor-runtime-lib.sh" >&2
  exit 2
fi
echo "被测代码: $LIB"
# shellcheck source=/dev/null
. "$LIB"

# ---- 场景 1：两边 field 完全相同 ⇒ 必须判「一致」 ----
cat > "$T/a.txt" <<'EOF'
900001_900101
900001_900102
900002_900103
EOF
cp "$T/a.txt" "$T/b.txt"
if mrv_fields_match "$T/a.txt" "$T/b.txt"; then
  ok "场景1 两边相同 ⇒ 判一致"
else
  bad "场景1 两边相同却判不一致"
fi

# ---- 场景 2：集群少一个 field ⇒ 必须判「不一致」----
cat > "$T/c.txt" <<'EOF'
900001_900101
900002_900103
EOF
if mrv_fields_match "$T/a.txt" "$T/c.txt"; then
  bad "场景2 少一个 field 却判一致 —— 这是假绿！"
else
  ok "场景2 少一个 field ⇒ 判不一致"
fi

# ---- 场景 3：集群多一个 field ⇒ 必须判「不一致」----
cat > "$T/d.txt" <<'EOF'
900001_900101
900001_900102
900002_900103
900003_900105
EOF
if mrv_fields_match "$T/a.txt" "$T/d.txt"; then
  bad "场景3 多一个 field 却判一致 —— 这是假绿！"
else
  ok "场景3 多一个 field ⇒ 判不一致"
fi

# ---- 场景 4：field 数不对 ⇒ 必须判「不对」----
if mrv_field_count_ok "$T/a.txt" 3; then
  ok "场景4 field 数对 ⇒ 判对"
else
  bad "场景4 field 数对却判不对"
fi
if mrv_field_count_ok "$T/c.txt" 3; then
  bad "场景5 field 数不对却判对 —— 这是假绿！"
else
  ok "场景5 field 数不对 ⇒ 判不对"
fi

# ---- 场景 6：空文件 ⇒ 必须判「不对」（0 个 field 不等于期望的 N）----
: > "$T/empty.txt"
if mrv_field_count_ok "$T/empty.txt" 3; then
  bad "场景6 空文件却判对 —— 这是假绿！"
else
  ok "场景6 空文件 ⇒ 判不对"
fi

# ---- 场景 7：objType 段是不是种子编号 ----
if mrv_field_is_seed "900001_900101" "900001 900002 900003"; then
  ok "场景7 种子编号的 field ⇒ 认得"
else
  bad "场景7 种子编号的 field 却认不得"
fi
if mrv_field_is_seed "12345_67890" "900001 900002 900003"; then
  bad "场景8 非种子编号的 field 却认得 —— 这是假绿！"
else
  ok "场景8 非种子编号的 field ⇒ 认不得"
fi

echo
echo "TEST SUMMARY: PASS=$TPASS FAIL=$TFAIL"
[ "$TFAIL" -eq 0 ]

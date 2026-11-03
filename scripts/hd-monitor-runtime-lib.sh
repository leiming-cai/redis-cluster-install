#!/bin/bash
# hd-monitor-runtime-verify.sh 的**纯逻辑**部分（可被 source）
#
# ⚠️ **为什么要拆出来**：
#    判据脚本本身会立刻起应用、连集群 —— 不能被 source（否则一 source 就跑起来了）。
#    把「比对」这层拆出来，才能对它写边界测试（假绿防线）。
#
# 这个文件**不碰网络 / 数据库 / Redis**，只读「已经取到本地的 field 列表」文件。

# ---------------------------------------------------------------
# ⚠️ **被直接执行时的保护**（不是被 source 时）。
#
# 这个文件是**库**，直接 `bash hd-monitor-runtime-lib.sh` 什么都不会发生，
# 而且**退出码是 0** —— 看着像「跑过了」，其实什么都没干。
# 那是个假绿：调用方以为跑了，其实没有。
#
# 判据：`${BASH_SOURCE[0]}` 是「谁在执行这个文件」，`$0` 是「谁在跑这个进程」。
# 被 source 时两者**不同**（BASH_SOURCE 是本文件，$0 是 source 它的那个脚本）；
# 被直接执行时两者**相同**。
# ---------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "!! $0 是一个**库**（要被 source），不是可执行脚本。" >&2
  echo "   它只定义 mrv_fields_match / mrv_field_count_ok / mrv_field_is_seed，不跑任何检查 —— 直接跑它什么都不会做。" >&2
  echo "   要测它请跑: bash scripts/test-hd-monitor-runtime-verify.sh" >&2
  exit 2
fi

# 两个 field 列表是否**逐个相等**（两边都已排序去重）。
# ⚠️ 空文件（0 个 field）不算「相等」—— 空比空不是「逐个相等」。
mrv_fields_match() {
  local a="$1" b="$2"
  [ -f "$a" ] || return 1
  [ -f "$b" ] || return 1
  [ -s "$a" ] || return 1
  [ -s "$b" ] || return 1
  diff -q "$a" "$b" >/dev/null 2>&1
}

# field 数是否等于期望值
mrv_field_count_ok() {
  local f="$1" want="$2" n
  [ -f "$f" ] || return 1
  n=$(grep -c . "$f" 2>/dev/null)
  [ "${n:-0}" -eq "$want" ]
}

# 某个 field 的 objType 段（`_` 前面那半）是不是种子编号之一。
# ⚠️ 只认 <数字>_<数字> 的形状（同 dump_fields 的 ^[0-9]+_[0-9]+$ 过滤）：
#    没有下划线（"900001"）、某一段为空（"900001_"）都算畸形，不认得。
mrv_field_is_seed() {
  local field="$1" seeds="$2" ot attr
  case "$field" in
    *"_"*) ;;           # 有下划线，往下判
    *) return 1 ;;      # 没有下划线 → 畸形
  esac
  case "$field" in
    *[!0-9_]*) return 1 ;;  # 有数字/下划线以外的字符
    *_*_*)     return 1 ;;  # 多于一个下划线
  esac
  ot="${field%%_*}"
  attr="${field#*_}"
  [ -n "$ot" ] || return 1
  [ -n "$attr" ] || return 1
  case " $seeds " in
    *" $ot "*) return 0 ;;
    *) return 1 ;;
  esac
}

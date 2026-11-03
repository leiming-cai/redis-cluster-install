#!/bin/bash
# hd-monitor-runtime-verify.sh 的**纯逻辑**部分（可被 source）
#
# ⚠️ **为什么要拆出来**：
#    判据脚本本身会立刻起应用、连集群 —— 不能被 source（否则一 source 就跑起来了）。
#    把「比对」这层拆出来，才能对它写边界测试（假绿防线）。
#
# 这个文件**不做任何 IO**，只处理「已经取到本地的 field 列表」。

# 两个 field 列表是否**逐个相等**（两边都已排序去重）
mrv_fields_match() {
  local a="$1" b="$2"
  [ -f "$a" ] || return 1
  [ -f "$b" ] || return 1
  diff -q "$a" "$b" >/dev/null 2>&1
}

# field 数是否等于期望值
mrv_field_count_ok() {
  local f="$1" want="$2" n
  [ -f "$f" ] || return 1
  n=$(grep -c . "$f" 2>/dev/null)
  [ "${n:-0}" -eq "$want" ]
}

# 某个 field 的 objType 段（`_` 前面那半）是不是种子编号之一
mrv_field_is_seed() {
  local field="$1" seeds="$2" ot
  ot="${field%%_*}"
  case " $seeds " in
    *" $ot "*) return 0 ;;
    *) return 1 ;;
  esac
}

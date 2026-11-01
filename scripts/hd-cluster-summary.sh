#!/bin/bash
# 集群验证结果的**计数合并**逻辑 —— 从 verify-hd-napstar.sh 里抽出来，
# 单独放一个文件是为了**能被人（和测试）直接 source**。
#
# ⚠️ **不要在这里改语义** —— verify-hd-napstar.sh 的 C 段直接用这些函数，
#    任何改动都会同时改掉回归矩阵的计数。
#    真要改，先跑 scripts/test-hd-cluster-summary.sh（它 source 的是**这个文件**）。
#
# ⚠️ 这是一个**被 source 的库**，不是独立脚本：
#    所以它**不开** `set -e`（那会连累 source 它的矩阵），
#    也不自己跑任何检查。
#
# 用法：
#   source /opt/hd/hd-cluster-summary.sh
#   merge_cluster_summary <子脚本输出文件> <子脚本退出码>
#   → 把 PASS/FAIL 加到调用方的 $PASS / $FAIL，
#     异常情况记到 $CLUSTER_SUMMARY_NOTES（由调用方决定怎么打印），
#     解析出来的计数放在 $CLUSTER_SUMMARY_PASS / $CLUSTER_SUMMARY_FAIL 里。
#
# ⚠️ 这里的函数**只做计数 + 记备注**，不打印 —— 打印由调用方决定，
#    这样测试可以只测计数，不用解析输出。

# ---------------------------------------------------------------
# ⚠️ **被直接执行时的保护**（不是被 source 时）。
#
# 这个文件是**库**，直接 `bash hd-cluster-summary.sh` 什么都不会发生，
# 而且**退出码是 0** —— 看着像「跑过了」，其实什么都没干。
# 那是个假绿：调用方以为跑了，其实没有。
#
# 判据：`${BASH_SOURCE[0]}` 是「谁在执行这个文件」，`$0` 是「谁在跑这个进程」。
# 被 source 时两者**不同**（BASH_SOURCE 是本文件，$0 是 source 它的那个脚本）；
# 被直接执行时两者**相同**。
# ---------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "!! $0 是一个**库**（要被 source），不是可执行脚本。" >&2
  echo "   它只定义 merge_cluster_summary，不跑任何检查 —— 直接跑它什么都不会做。" >&2
  echo "   要测它请跑: bash scripts/test-hd-cluster-summary.sh" >&2
  exit 2
fi

# 从子脚本的输出里解析出它自己的 SUMMARY 计数，并并进 $PASS / $FAIL。
#
# 参数：$1 = 子脚本输出文件；$2 = 子脚本退出码
# 副作用：改 $PASS / $FAIL；往 $CLUSTER_SUMMARY_NOTES 追加说明行；
#         设 $CLUSTER_SUMMARY_PASS / $CLUSTER_SUMMARY_FAIL（解析出来的计数）
# 返回：0 = 一切正常；1 = 有异常（异常**已经**计入 $FAIL）
#
# ⚠️ **调用方必须提供 $PASS / $FAIL 这两个变量**（矩阵里有，测试里也有）。
#
# ⚠️ **这个函数自己加 $FAIL，不去调调用方的 bad()**：
#    bad() 加的是**调用方自己的**计数器，而调用方（矩阵）的 bad() 恰好
#    也是加 $FAIL —— 看着一样，但在**测试**里就不一样了：
#    测试的 bad() 记的是「断言失败」，跟「被测代码合并进来的失败」
#    是**两回事**，混在一起就测不准。
#    ⇒ 计数一律在这里直接改 $FAIL（**只加一次**）；
#      要不要**打印**由调用方决定（见 $CLUSTER_SUMMARY_NOTES）。
#
# ⚠️ 取最后一行 SUMMARY，不是第一行：hd-cluster-verify.sh 在
#    「L0 探活失败提前退出」的路径上也会打一行 SUMMARY，
#    而它的 EXIT trap 在异常退出时还会**再补打一行**。
#    只有最后一行是最终结论。
#
# ⚠️ **没有 SUMMARY ≠ 「0 个失败」**：脚本崩了 / 被杀了 / 输出被截断，
#    都可能一行 SUMMARY 都没有。那种情况必须记 FAIL ——
#    把「没测到」当成「通过了」，正是这个矩阵要防的假绿。
merge_cluster_summary() {
  local cv_out="$1" cv_rc="$2"
  local cv_sum cv_p cv_f

  # ⚠️ **把「实际并进计数器的增量」交出去** —— 调用方要打印
  #    「已并入本轮计数」，而**不能自己再解析一遍**。
  #    之前调用方自己又解析了一遍，两处解析各走各的：
  #    异常路径下（没有 SUMMARY / 退出码与计数打架）helper 实际记了 +1 FAIL，
  #    调用方那份独立解析却得到 0 → 打印出「FAIL +0」，
  #    **跟最终 SUMMARY 里的 FAIL 数自相矛盾**。
  #
  # ⚠️ 而且要报的是**实际增量**，不是**解析出来的原始计数**：
  #    「没有 SUMMARY」那条路径上，解析出来是 0（没有可解析的东西），
  #    但 helper 实际给 $FAIL 加了 **1**（异常本身算一个失败）。
  #    ⇒ 报 0 就是**报错了** —— 那正是「自己解析一遍」的老毛病。
  #    ⇒ 所以这里记的是**计数器的前后差值**，不是解析结果。
  local before_pass="$PASS" before_fail="$FAIL"

  cv_sum=$(grep '^SUMMARY: ' "$cv_out" 2>/dev/null | tail -1)
  cv_p=$(echo "$cv_sum" | grep -oP 'PASS=\K[0-9]+' || true)
  cv_f=$(echo "$cv_sum" | grep -oP 'FAIL=\K[0-9]+' || true)
  cv_p=${cv_p:-0}; cv_f=${cv_f:-0}

  if [ -z "$cv_sum" ]; then
    # 脚本崩了 / 没来得及打 SUMMARY —— 不能当成「0 个失败」。
    FAIL=$((FAIL + 1))
    CLUSTER_SUMMARY_NOTES="${CLUSTER_SUMMARY_NOTES:-}
C 集群验证没有产出 SUMMARY（退出码 $cv_rc）—— 集群验证本身异常"
    CLUSTER_SUMMARY_PASS=$((PASS - before_pass))
    CLUSTER_SUMMARY_FAIL=$((FAIL - before_fail))
    return 1
  fi

  PASS=$((PASS + cv_p))
  FAIL=$((FAIL + cv_f))

  # ⚠️ 退出码与它自己的 FAIL 计数不一致时要点名 ——
  #    「计数说 0 个失败，但退出码非 0」意味着它的判定逻辑和它的输出打架了，
  #    这时候不能只信计数。
  if [ "$cv_rc" -ne 0 ] && [ "$cv_f" -eq 0 ]; then
    FAIL=$((FAIL + 1))
    CLUSTER_SUMMARY_NOTES="${CLUSTER_SUMMARY_NOTES:-}
C 集群验证退出码非 0（$cv_rc）但它自己报 FAIL=0 —— 计数与退出码不一致"
  fi

  # ⚠️ **最后**再算增量 —— 这时候计数才是最终的
  #    （异常路径上前面已经多加过一个 FAIL）。
  CLUSTER_SUMMARY_PASS=$((PASS - before_pass))
  CLUSTER_SUMMARY_FAIL=$((FAIL - before_fail))
  [ "$cv_rc" -ne 0 ] && [ "$cv_f" -eq 0 ] && return 1
  return 0
}

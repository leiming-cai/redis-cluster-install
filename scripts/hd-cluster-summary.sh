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
#     异常情况记到 $CLUSTER_SUMMARY_NOTES（由调用方决定怎么打印）。
#
# ⚠️ 这里的函数**只做计数 + 记备注**，不打印 —— 打印由调用方决定，
#    这样测试可以只测计数，不用解析输出。

# 从子脚本的输出里解析出它自己的 SUMMARY 计数，并并进 $PASS / $FAIL。
#
# 参数：$1 = 子脚本输出文件；$2 = 子脚本退出码
# 副作用：改 $PASS / $FAIL；往 $CLUSTER_SUMMARY_NOTES 追加说明行
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

  cv_sum=$(grep '^SUMMARY: ' "$cv_out" 2>/dev/null | tail -1)
  cv_p=$(echo "$cv_sum" | grep -oP 'PASS=\K[0-9]+' || true)
  cv_f=$(echo "$cv_sum" | grep -oP 'FAIL=\K[0-9]+' || true)
  cv_p=${cv_p:-0}; cv_f=${cv_f:-0}

  if [ -z "$cv_sum" ]; then
    # 脚本崩了 / 没来得及打 SUMMARY —— 不能当成「0 个失败」。
    FAIL=$((FAIL + 1))
    CLUSTER_SUMMARY_NOTES="${CLUSTER_SUMMARY_NOTES:-}
C 集群验证没有产出 SUMMARY（退出码 $cv_rc）—— 集群验证本身异常"
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
    return 1
  fi
  return 0
}

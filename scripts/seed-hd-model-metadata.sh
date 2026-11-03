#!/bin/bash
# 华盾 napstar2.0 —— 最小模型元数据种子（**只为了让 monitor 的集群分支跑到**）
#
# ⚠️ **这不是产品数据，是测试夹具。**
#    `sac` / `cmt` / `hds` 是第三方系统的表（只读），
#    `info` 是本项目自有域 —— 本脚本只动 `info` 的三张表。
#
# 数据来源：**Nacos 里的 `kafkabus.yaml`**（NAPSTARWEB_GROUP）——
#    应用自己声明它要哪些对象类型和属性，这里照抄，不另造。
#
# 用法:
#   bash scripts/seed-hd-model-metadata.sh --seed    # 灌进去
#   bash scripts/seed-hd-model-metadata.sh --clean   # 删掉（只删 source_code='HDTEST'）
#   bash scripts/seed-hd-model-metadata.sh --status  # 只看行数
#
# ⚠️ **幂等**：--seed 会先删掉同 source_code 的旧行再插 ⇒ 连跑两次结果一致。
# ⚠️ **编号用 900001+ 显眼段** —— obj_type 会进 Redis field 名（`<objType>_<attrType>`），
#    不能撞真实业务编号。
#
# 退出码约定（给下游判定脚本用）:
#   0 = 成功（--status 只要读得到行数就算 0）
#   1 = 连上了库、但行数不对（--seed 期望 3/12/12，--clean 期望 0/0/0）
#   2 = 连不上库 / 写操作失败 / 读不到行数
set -uo pipefail

export PGPASSWORD="${PGPASSWORD:-postgres}"
REDIS_CLI=/opt/software/redis-8.10.0/bin/redis-cli

# 标记：所有种子行都带这个 source_code ⇒ 清理时只删自己那批
SEED_SRC=HDTEST
# 超级用户的 id（info.base_user 里那行）
OPERATOR=1561967773586952192

# ⚠️ 用函数而不是「多词变量 + 无引号展开」——
#    无引号展开靠 word splitting，参数一旦带空格就散架。
psqlq() {
  psql -U postgres -h 127.0.0.1 -d napstar -At "$@"
}

# 跑一条「写」类 psql（delete / insert）。输出照旧缩进；失败时打诊断并返回非 0。
# （用 ${PIPESTATUS[0]} 抓 psql 的真实退出码，不依赖 sed 的退出码。）
psql_write() {
  psqlq "$@" 2>&1 | sed 's/^/  /'
  local rc=${PIPESTATUS[0]}
  if [ "${rc:-0}" -ne 0 ]; then
    echo "!! 数据库操作失败（psql 退出码 ${rc}）" >&2
  fi
  return "${rc:-0}"
}

usage() {
  echo "用法: $0 --seed | --clean | --status" >&2
  exit 2
}

[ $# -eq 1 ] || usage
ACTION="$1"

# ---------------------------------------------------------------
# 灌数据
# ---------------------------------------------------------------
# ⚠️ **属性名必须与 kafkabus.yaml 逐字相同** ——
#    `loadRTConfigKafka()` 是拿 `aname` 跟 `oa.getAttrName()` 做 `equals` 比的，
#    差一个字符就匹配不上 ⇒ hSet 一次都不执行。
#    （MVPoint=2 个 / DPSPoint=2 个 / Machine=8 个 ⇒ 共 12 个属性）
seed() {
  echo "=== 清理旧的种子行（source_code='$SEED_SRC'）==="
  psql_write -c "delete from info.model_objectattribute where source_code='$SEED_SRC'" || return 2
  psql_write -c "delete from info.model_attribute where source_code='$SEED_SRC'" || return 2
  psql_write -c "delete from info.model_objecttype where source_code='$SEED_SRC'" || return 2

  echo "=== 插入种子 ==="
  # --- 1) model_objecttype：3 个类型 ---
  psql_write -c "
insert into info.model_objecttype
  (id, obj_type, obj_name, obj_desc, sort_attribute_type, source_code, isused,
   create_time, update_time, create_operator, update_operator)
values
  (900001, 900001, 'MVPoint',  'HDTEST seed: kafkabus MVPoint',  900001, '$SEED_SRC', 1, now(), now(), $OPERATOR, $OPERATOR),
  (900002, 900002, 'DPSPoint', 'HDTEST seed: kafkabus DPSPoint', 900002, '$SEED_SRC', 1, now(), now(), $OPERATOR, $OPERATOR),
  (900003, 900003, 'Machine',  'HDTEST seed: kafkabus Machine',  900003, '$SEED_SRC', 1, now(), now(), $OPERATOR, $OPERATOR);
" || return 2

  # --- 2) model_attribute：12 个属性（dt_type 挂现成的 model_datatype）---
  psql_write -c "
insert into info.model_attribute
  (id, attr_type, attr_name, attr_desc, dt_type, wiringtable, source_code,
   create_time, update_time, create_operator, update_operator)
values
  (900101, 900101, 'Value',          'HDTEST seed', 4, null, '$SEED_SRC', now(), now(), $OPERATOR, $OPERATOR),
  (900102, 900102, 'Quality',        'HDTEST seed', 4, null, '$SEED_SRC', now(), now(), $OPERATOR, $OPERATOR),
  (900103, 900103, 'State',          'HDTEST seed', 9, null, '$SEED_SRC', now(), now(), $OPERATOR, $OPERATOR),
  (900104, 900104, 'Unacknowledged', 'HDTEST seed', 9, null, '$SEED_SRC', now(), now(), $OPERATOR, $OPERATOR),
  (900105, 900105, 'CPUStatus',      'HDTEST seed', 1, null, '$SEED_SRC', now(), now(), $OPERATOR, $OPERATOR),
  (900106, 900106, 'MemStatus',      'HDTEST seed', 1, null, '$SEED_SRC', now(), now(), $OPERATOR, $OPERATOR),
  (900107, 900107, 'CPUSystemEx',    'HDTEST seed', 9, null, '$SEED_SRC', now(), now(), $OPERATOR, $OPERATOR),
  (900108, 900108, 'DiskSystem',     'HDTEST seed', 9, null, '$SEED_SRC', now(), now(), $OPERATOR, $OPERATOR),
  (900109, 900109, 'DiskCPS',        'HDTEST seed', 4, null, '$SEED_SRC', now(), now(), $OPERATOR, $OPERATOR),
  (900110, 900110, 'MemSystemEx',    'HDTEST seed', 9, null, '$SEED_SRC', now(), now(), $OPERATOR, $OPERATOR),
  (900111, 900111, 'SyncStatus',     'HDTEST seed', 9, null, '$SEED_SRC', now(), now(), $OPERATOR, $OPERATOR),
  (900112, 900112, 'SyncPhase',      'HDTEST seed', 1, null, '$SEED_SRC', now(), now(), $OPERATOR, $OPERATOR);
" || return 2

  # --- 3) model_objectattribute：12 条关联 ---
  psql_write -c "
insert into info.model_objectattribute
  (obj_type, attr_type, attr_order, data_scope, strlen, enumtype_code,
   numeric_precision, numeric_scale, source_code, isused, isprimkey,
   create_time, update_time, create_operator, update_operator)
values
  (900001, 900101, 1, 0, null, null, null, null, '$SEED_SRC', 1, 0, now(), now(), $OPERATOR, $OPERATOR),
  (900001, 900102, 2, 0, null, null, null, null, '$SEED_SRC', 1, 0, now(), now(), $OPERATOR, $OPERATOR),
  (900002, 900103, 1, 0, null, null, null, null, '$SEED_SRC', 1, 0, now(), now(), $OPERATOR, $OPERATOR),
  (900002, 900104, 2, 0, null, null, null, null, '$SEED_SRC', 1, 0, now(), now(), $OPERATOR, $OPERATOR),
  (900003, 900105, 1, 0, null, null, null, null, '$SEED_SRC', 1, 0, now(), now(), $OPERATOR, $OPERATOR),
  (900003, 900106, 2, 0, null, null, null, null, '$SEED_SRC', 1, 0, now(), now(), $OPERATOR, $OPERATOR),
  (900003, 900107, 3, 0, null, null, null, null, '$SEED_SRC', 1, 0, now(), now(), $OPERATOR, $OPERATOR),
  (900003, 900108, 4, 0, null, null, null, null, '$SEED_SRC', 1, 0, now(), now(), $OPERATOR, $OPERATOR),
  (900003, 900109, 5, 0, null, null, null, null, '$SEED_SRC', 1, 0, now(), now(), $OPERATOR, $OPERATOR),
  (900003, 900110, 6, 0, null, null, null, null, '$SEED_SRC', 1, 0, now(), now(), $OPERATOR, $OPERATOR),
  (900003, 900111, 7, 0, null, null, null, null, '$SEED_SRC', 1, 0, now(), now(), $OPERATOR, $OPERATOR),
  (900003, 900112, 8, 0, null, null, null, null, '$SEED_SRC', 1, 0, now(), now(), $OPERATOR, $OPERATOR);
" || return 2

  echo "=== 灌完的行数（期望 3 / 12 / 12）==="
  status
  if [ "${STATUS_OK:-1}" -ne 0 ]; then
    echo "!! 无法读取行数（数据库不可达或查询失败）" >&2
    return 2
  fi
  if [ "${STATUS_O:-}" != "3" ] || [ "${STATUS_A:-}" != "12" ] || [ "${STATUS_OA:-}" != "12" ]; then
    echo "!! 灌完后行数不对：期望 3 / 12 / 12，实际 ${STATUS_O:-ERR} / ${STATUS_A:-ERR} / ${STATUS_OA:-ERR}" >&2
    return 1
  fi

  clear_model_cache
}

# ---------------------------------------------------------------
# 清理
# ---------------------------------------------------------------
clean() {
  echo "=== 删除种子行（source_code='$SEED_SRC'）==="
  psql_write -c "delete from info.model_objectattribute where source_code='$SEED_SRC'" || return 2
  psql_write -c "delete from info.model_attribute where source_code='$SEED_SRC'" || return 2
  psql_write -c "delete from info.model_objecttype where source_code='$SEED_SRC'" || return 2
  echo "=== 剩余行数（期望 0 / 0 / 0）==="
  status
  if [ "${STATUS_OK:-1}" -ne 0 ]; then
    echo "!! 无法读取行数（数据库不可达或查询失败）" >&2
    return 2
  fi
  if [ "${STATUS_O:-}" != "0" ] || [ "${STATUS_A:-}" != "0" ] || [ "${STATUS_OA:-}" != "0" ]; then
    echo "!! 删除后行数不对：期望 0 / 0 / 0，实际 ${STATUS_O:-ERR} / ${STATUS_A:-ERR} / ${STATUS_OA:-ERR}" >&2
    return 1
  fi

  clear_model_cache
}

# ---------------------------------------------------------------
# 状态
# ---------------------------------------------------------------
status() {
  local o a oa
  o=$(psqlq -c "select count(*) from info.model_objecttype where source_code='$SEED_SRC'" 2>/dev/null | tr -d '\r')
  a=$(psqlq -c "select count(*) from info.model_attribute where source_code='$SEED_SRC'" 2>/dev/null | tr -d '\r')
  oa=$(psqlq -c "select count(*) from info.model_objectattribute where source_code='$SEED_SRC'" 2>/dev/null | tr -d '\r')
  echo "  model_objecttype     = ${o:-ERR}"
  echo "  model_attribute      = ${a:-ERR}"
  echo "  model_objectattribute= ${oa:-ERR}"
  # 把「能否读到」和原始计数交给调用方（全局变量）。
  STATUS_O="${o:-}"
  STATUS_A="${a:-}"
  STATUS_OA="${oa:-}"
  if [ -n "$o" ] && [ -n "$a" ] && [ -n "$oa" ]; then
    STATUS_OK=0
  else
    STATUS_OK=1
  fi
}

# ---------------------------------------------------------------
# 清 Redis 的模型缓存（**防御性**）。
#
# ⚠️ **实测（2026-11-03）：真实的缓存 key 名带 `model:` 前缀**：
#     model:objecttypes:names:<objName>
#     model:objecttypes:types:<objType>
#     model:attributetypes:names:<attrName>
#     model:attributetypes:atypes:<attrType>
#   （`CacheServiceImpl` 的 `@Cacheable(value={"objecttypes:names"})` 等
#     经 RedisCacheManager 序列化后是这个形状。）
#   ⚠️ **原来这里写的是 `objecttypes*` —— 匹配 0 个 key，清缓存是空操作。**
#      留着已删行的缓存条目会让「夹具已清」变成假象。
#
# --seed 和 --clean 都调 —— 万一缓存里真有 key，清掉避免指向已删的行。
# ---------------------------------------------------------------
clear_model_cache() {
  echo "=== 清 Redis 的模型缓存（model:*）==="
  local_keys=$($REDIS_CLI -h 127.0.0.1 -p 6379 -a sac888 --no-auth-warning KEYS 'model:*' 2>/dev/null | grep -c 'model:')
  echo "  找到 model:* key: $local_keys 个"
  if [ "${local_keys:-0}" -gt 0 ]; then
    $REDIS_CLI -h 127.0.0.1 -p 6379 -a sac888 --no-auth-warning KEYS 'model:*' 2>/dev/null \
      | grep 'model:' \
      | while read -r k; do $REDIS_CLI -h 127.0.0.1 -p 6379 -a sac888 --no-auth-warning DEL "$k" >/dev/null 2>&1; done
    echo "  已清"
  else
    echo "  没有要清的"
  fi
}

case "$ACTION" in
  --seed)   seed ;;
  --clean)  clean ;;
  --status)
    status
    [ "${STATUS_OK:-1}" -eq 0 ] || exit 2
    ;;
  *)        usage ;;
esac

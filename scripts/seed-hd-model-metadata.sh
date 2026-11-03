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
set -uo pipefail

PSQL="psql -U postgres -h 127.0.0.1 -d napstar -At"
export PGPASSWORD="${PGPASSWORD:-postgres}"
REDIS_CLI=/opt/software/redis-8.10.0/bin/redis-cli

# 标记：所有种子行都带这个 source_code ⇒ 清理时只删自己那批
SEED_SRC=HDTEST
# 超级用户的 id（info.base_user 里那行）
OPERATOR=1561967773586952192

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
  $PSQL -c "delete from info.model_objectattribute where source_code='$SEED_SRC'" 2>&1 | sed 's/^/  /'
  $PSQL -c "delete from info.model_attribute where source_code='$SEED_SRC'" 2>&1 | sed 's/^/  /'
  $PSQL -c "delete from info.model_objecttype where source_code='$SEED_SRC'" 2>&1 | sed 's/^/  /'

  echo "=== 插入种子 ==="
  # --- 1) model_objecttype：3 个类型 ---
  $PSQL -c "
insert into info.model_objecttype
  (id, obj_type, obj_name, obj_desc, sort_attribute_type, source_code, isused,
   create_time, update_time, create_operator, update_operator)
values
  (900001, 900001, 'MVPoint',  'HDTEST seed: kafkabus MVPoint',  900001, '$SEED_SRC', 1, now(), now(), $OPERATOR, $OPERATOR),
  (900002, 900002, 'DPSPoint', 'HDTEST seed: kafkabus DPSPoint', 900002, '$SEED_SRC', 1, now(), now(), $OPERATOR, $OPERATOR),
  (900003, 900003, 'Machine',  'HDTEST seed: kafkabus Machine',  900003, '$SEED_SRC', 1, now(), now(), $OPERATOR, $OPERATOR);
" 2>&1 | sed 's/^/  /'

  # --- 2) model_attribute：12 个属性（dt_type 挂现成的 model_datatype）---
  $PSQL -c "
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
" 2>&1 | sed 's/^/  /'

  # --- 3) model_objectattribute：12 条关联 ---
  $PSQL -c "
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
" 2>&1 | sed 's/^/  /'

  echo "=== 灌完的行数（期望 3 / 12 / 12）==="
  status

  echo "=== 清 Redis 的 objecttypes 缓存（防御性：实测失败不写缓存，这里只是以防万一）==="
  local_keys=$($REDIS_CLI -h 127.0.0.1 -p 6379 -a sac888 --no-auth-warning KEYS 'objecttypes*' 2>/dev/null | grep -c 'objecttypes')
  echo "  找到 objecttypes* key: $local_keys 个"
  if [ "${local_keys:-0}" -gt 0 ]; then
    $REDIS_CLI -h 127.0.0.1 -p 6379 -a sac888 --no-auth-warning KEYS 'objecttypes*' 2>/dev/null \
      | grep 'objecttypes' \
      | while read -r k; do $REDIS_CLI -h 127.0.0.1 -p 6379 -a sac888 --no-auth-warning DEL "$k" >/dev/null 2>&1; done
    echo "  已清"
  else
    echo "  没有要清的（符合预期：matchOTypeCode 失败时不写缓存）"
  fi
}

# ---------------------------------------------------------------
# 清理
# ---------------------------------------------------------------
clean() {
  echo "=== 删除种子行（source_code='$SEED_SRC'）==="
  $PSQL -c "delete from info.model_objectattribute where source_code='$SEED_SRC'" 2>&1 | sed 's/^/  /'
  $PSQL -c "delete from info.model_attribute where source_code='$SEED_SRC'" 2>&1 | sed 's/^/  /'
  $PSQL -c "delete from info.model_objecttype where source_code='$SEED_SRC'" 2>&1 | sed 's/^/  /'
  echo "=== 剩余行数（期望 0 / 0 / 0）==="
  status
}

# ---------------------------------------------------------------
# 状态
# ---------------------------------------------------------------
status() {
  local o a oa
  o=$($PSQL -c "select count(*) from info.model_objecttype where source_code='$SEED_SRC'" 2>/dev/null | tr -d '\r')
  a=$($PSQL -c "select count(*) from info.model_attribute where source_code='$SEED_SRC'" 2>/dev/null | tr -d '\r')
  oa=$($PSQL -c "select count(*) from info.model_objectattribute where source_code='$SEED_SRC'" 2>/dev/null | tr -d '\r')
  echo "  model_objecttype     = ${o:-ERR}"
  echo "  model_attribute      = ${a:-ERR}"
  echo "  model_objectattribute= ${oa:-ERR}"
}

case "$ACTION" in
  --seed)   seed ;;
  --clean)  clean ;;
  --status) status ;;
  *)        usage ;;
esac

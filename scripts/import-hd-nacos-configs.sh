#!/bin/bash
# 把安装包 env/nacos/nacos_config_export_postgresql-napstar2.0/ 导入 hd-node1 的 Nacos。
set -uo pipefail
TREE="${1:?导出包路径}"
NACOS="${NACOS:-http://127.0.0.1:18848/nacos}"
export CURL_HOME=${CURL_HOME:-}

post() {
  local group="$1" dataId="$2" file="$3"
  local resp
  resp=$(curl -s -m 20 -X POST "$NACOS/v1/cs/configs" \
      --data-urlencode "dataId=$dataId" \
      --data-urlencode "group=$group" \
      --data-urlencode "type=yaml" \
      --data-urlencode "content@$file")
  printf "  %-46s -> %s\n" "$group/$dataId" "$resp"
}

cd "$TREE" || exit 1
for f in $(find . -type f -name '*.yaml' | sort); do
  group=$(dirname "$f" | sed 's|^\./||')
  dataId=$(basename "$f")
  post "$group" "$dataId" "$f"
done
# 没有扩展名的那一个
post "MODELSERVER_GROUP" "icms-hisDataSend" "./MODELSERVER_GROUP/icms-hisDataSend"

echo "=== published configs (dataId list) ==="
curl -s -m 20 "$NACOS/v1/cs/configs?search=accurate&dataId=&group=&pageNo=1&pageSize=100" \
  | tr ',' '\n' | grep '"dataId"' | sed 's/.*"dataId":"\([^"]*\)".*/  \1/' | sort
echo "=== count ==="
curl -s -m 20 "$NACOS/v1/cs/configs?search=accurate&dataId=&group=&pageNo=1&pageSize=100" \
  | tr ',' '\n' | grep -c '"dataId"'

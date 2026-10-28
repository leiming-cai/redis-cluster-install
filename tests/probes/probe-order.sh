#!/usr/bin/env bash
# probe-order.sh — does the ORDER of the node list decide whether a whole host
# can be lost without taking the cluster down?
#
# Measures (spec section 3.3), 6 instances over 2 hosts:
#   L1 grouped  A,A,A,B,B,B -> all 3 masters on A; killing A = CLUSTERDOWN
#   L2 interleaved A,B,A,B,A,B -> A holds 2 masters; killing A = CLUSTERDOWN
#      (only 1 master alive, below the majority a replica needs to be promoted)
#
# Hence: the master set must be chosen explicitly, and replicas must be
# attached to a master on ANOTHER host. That is what lib/topology.sh computes.

# probe: does the ORDER of the node list decide whether a host failure is survivable?
#   layout L1: A A A B B B   (grouped, what a config file produces today)
#   layout L2: A B A B A B   (interleaved)
set -uo pipefail
NET=probeord
cleanup() {
  for i in 1 2 3 4 5 6; do docker rm -f "po-$i" >/dev/null 2>&1 || true; done
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

run_layout() {
  local tag="$1"; shift
  local order=("$@")          # each entry: "ip:port" prefixed with A or B label
  local A1="${order[0]%%:*}" # first node's IP, used as the entry point

  for i in 1 2 3 4 5 6; do docker rm -f "po-$i" >/dev/null 2>&1 || true; done
  docker network rm "$NET" >/dev/null 2>&1 || true
  docker network create "$NET" >/dev/null
  for i in 1 2 3 4 5 6; do
    docker run -d --name "po-$i" --network "$NET" --hostname "po-$i" \
      redis:8 redis-server --port 6379 --cluster-enabled yes \
      --cluster-config-file /data/nodes.conf --cluster-node-timeout 5000 \
      --appendonly no --save '' >/dev/null
  done
  sleep 3

  local AIP=() BIP=() LIST=()
  for i in 1 2 3; do AIP+=("$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "po-$i")"); done
  for i in 4 5 6; do BIP+=("$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "po-$i")"); done
  for spec in "$@"; do
    case "$spec" in
      A1) LIST+=("${AIP[0]}:6379");; A2) LIST+=("${AIP[1]}:6379");; A3) LIST+=("${AIP[2]}:6379");;
      B1) LIST+=("${BIP[0]}:6379");; B2) LIST+=("${BIP[1]}:6379");; B3) LIST+=("${BIP[2]}:6379");;
    esac
  done

  local cli="docker run --rm --network $NET redis:8 redis-cli"
  echo "############ layout $tag : ${LIST[*]} ############"
  $cli --cluster create "${LIST[@]}" --cluster-replicas 1 --cluster-yes >/dev/null 2>&1
  sleep 3

  echo "--- roles (A1,A2,A3 | B1,B2,B3) ---"
  local k
  for k in "${AIP[@]}"; do echo "  A $k -> $($cli -h "$k" -p 6379 role 2>&1 | head -1)"; done
  for k in "${BIP[@]}"; do echo "  B $k -> $($cli -h "$k" -p 6379 role 2>&1 | head -1)"; done

  echo "--- kill host A (3 instances) ---"
  for i in 1 2 3; do docker rm -f "po-$i" >/dev/null 2>&1; done
  local ok=0
  for _ in $(seq 1 14); do
    sleep 5
    if $cli -h "${BIP[0]}" -p 6379 cluster info 2>&1 | grep -qE '^cluster_state:ok'; then ok=1; break; fi
  done
  if [ "$ok" -eq 1 ]; then
    echo "  >>> cluster_state:ok  (host failure survivable)"
    echo "  write: $($cli -h "${BIP[0]}" -p 6379 -c SET probe:key hello 2>&1)"
  else
    echo "  >>> cluster NOT ok  (host failure is FATAL)"
    echo "  write: $($cli -h "${BIP[0]}" -p 6379 -c SET probe:key hello 2>&1)"
  fi
  echo
}

run_layout "L1-grouped-AAABBB"   A1 A2 A3 B1 B2 B3
run_layout "L2-interleaved-ABABAB" A1 B1 A2 B2 A3 B3

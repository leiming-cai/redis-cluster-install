#!/usr/bin/env bash
set -u
ROOT="${PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"

PASS=0
FAIL=0

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then ok "$desc"
    else bad "$desc (expected=[$expected] actual=[$actual])"
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then ok "$desc"
    else bad "$desc (needle=[$needle] not in [$haystack])"
    fi
}

#####################################################################
echo "=== lib/common.sh ==="
. lib/common.sh
out=$(log_info hi);             assert_contains "log_info has [INFO]" "[INFO]" "$out"
out=$(log_warn hi 2>&1 >/dev/null);  assert_contains "log_warn has [WARN]" "[WARN]" "$out"
out=$(log_error hi 2>&1 >/dev/null); assert_contains "log_error has [ERROR]" "[ERROR]" "$out"

err=$( (. lib/common.sh; die custom_msg 7 2>/tmp/stderr_die.log; exit 0) ; echo "EXIT_CODE=$?"; cat /tmp/stderr_die.log)
assert_contains "die exits with custom code 7" "EXIT_CODE=7" "$err"
assert_contains "die writes custom_msg to stderr" "custom_msg" "$err"
rm -f /tmp/stderr_die.log

ret=$(. lib/common.sh; file_exists lib/common.sh; echo $?)
assert_eq "file_exists true" "0" "$ret"
ret=$(. lib/common.sh; file_exists nonexistent_xyz_$$; echo $?)
assert_eq "file_exists false" "1" "$ret"

#####################################################################
echo
echo "=== lib/password.sh ==="
. lib/password.sh
out=$(gen_password 32); assert_eq "gen_password default length=32" "32" "${#out}"
out=$(gen_password 48); assert_eq "gen_password custom length=48" "48" "${#out}"
out=$(gen_password 16)
if [[ "$out" =~ ^[A-Za-z0-9]+$ ]]; then ok "gen_password alphanumeric"
else bad "gen_password alphanumeric (got [$out])"
fi
out1=$(gen_password 32); out2=$(gen_password 32)
if [ "$out1" != "$out2" ]; then ok "gen_password unique per call"
else bad "gen_password unique per call"
fi

#####################################################################
echo
echo "=== lib/prompt.sh (PROMPT_NO_TTY=1) ==="
PROMPT_NO_TTY=1
. lib/prompt.sh
out=$(echo "" | read_default "prompt" "x" 2>/dev/null)
assert_eq "read_default empty input returns default" "x" "$out"
out=$(echo "y" | read_default "prompt" "x" 2>/dev/null)
assert_eq "read_default non-empty returns input" "y" "$out"
out=$(printf "\ny\n" | read_required "prompt" 2>/dev/null)
assert_eq "read_required accepts after empty" "y" "$out"
out=$(echo "y" | read_required "prompt" 2>/dev/null)
assert_eq "read_required accepts first non-empty" "y" "$out"
out=$(echo "y" | read_confirm "prompt" 2>/dev/null)
assert_eq "read_confirm y" "y" "$out"
out=$(echo "n" | read_confirm "prompt" 2>/dev/null)
assert_eq "read_confirm n" "n" "$out"
out=$(echo "" | read_confirm "prompt" 2>/dev/null)
assert_eq "read_confirm empty -> n" "n" "$out"

#####################################################################
echo
echo "=== lib/ssh.sh ==="
. lib/ssh.sh
out=$(sship_host "10.0.0.1:2222"); assert_eq "sship_host extracts host" "10.0.0.1" "$out"
out=$(sship_port "10.0.0.1:2222"); assert_eq "sship_port extracts port" "2222" "$out"
out=$(sship_port "10.0.0.1"); assert_eq "sship_port default 22" "22" "$out"
out=$(sship_target "root" "10.0.0.1" "2222"); assert_eq "sship_target non-standard port" "root@10.0.0.1:2222" "$out"
out=$(sship_target "root" "10.0.0.1" "22"); assert_eq "sship_target default port omits :22" "root@10.0.0.1" "$out"

#####################################################################
echo
echo "=== lib/config_gen.sh ==="
TMP=$(mktemp -d)
echo 'port %PORT%
bind %BIND_ADDR%
requirepass %PASSWORD%
node %NODE_NAME%' > "$TMP/redis.conf.template"

. lib/config_gen.sh
out=$(render_redis_conf "$TMP/redis.conf.template" 6379 "secret123" "nodeA" "192.168.1.1")
assert_contains "render_redis_conf port" "port 6379" "$out"
assert_contains "render_redis_conf password" "requirepass secret123" "$out"
assert_contains "render_redis_conf node name" "node nodeA" "$out"
assert_contains "render_redis_conf bind" "bind 192.168.1.1" "$out"

# Missing template -> returns 1
ret=$(. lib/config_gen.sh; render_redis_conf "/tmp/no_such_template_$$" 1 2 3 4 5; echo $?)
assert_eq "render_redis_conf returns 1 on missing template" "1" "$ret"

rm -rf "$TMP"

#####################################################################
echo
echo "=== lib/systemd.sh ==="
TMP=$(mktemp -d)
cat > "$TMP/svc.template" <<'EOF'
[Unit]
Description=Redis cluster instance on port %PORT% node %NODE_NAME%
[Service]
ExecStart=/usr/local/bin/redis-server %CFG_PATH%
EOF

. lib/systemd.sh
out=$(render_systemd_unit "$TMP/svc.template" 6379 "nodeA" "")
assert_contains "render_systemd_unit port" "port 6379" "$out"
assert_contains "render_systemd_unit node name" "node nodeA" "$out"

# With password
cat > "$TMP/svc2.template" <<'EOF'
ExecStart=/usr/local/bin/redis-server --requirepass %PASSWORD%
EOF
out=$(render_systemd_unit "$TMP/svc2.template" 6379 "nodeA" "mypass")
assert_contains "render_systemd_unit password" "requirepass mypass" "$out"

out=$(systemd_unit_name 6379)
assert_eq "systemd_unit_name" "redis-6379.service" "$out"
out=$(systemd_unit_path 6379)
assert_eq "systemd_unit_path" "/etc/systemd/system/redis-6379.service" "$out"

ret=$(. lib/systemd.sh; render_systemd_unit "/tmp/no_such_template_$$" 1 2 3; echo $?)
assert_eq "render_systemd_unit returns 1 on missing template" "1" "$ret"

rm -rf "$TMP"

#####################################################################
echo
echo "=== lib/cluster.sh ==="
. lib/cluster.sh

out=$(printf 'cluster_known_nodes:6\ncluster_state:ok\n' | cluster_known_nodes)
assert_eq "cluster_known_nodes parses 6" "6" "$out"

out=$(printf 'cluster_state:ok\ncluster_known_nodes:7\n' | cluster_known_nodes)
assert_eq "cluster_known_nodes parses 7" "7" "$out"

out=$(printf 'no_such_key_here\n' | cluster_known_nodes)
assert_eq "cluster_known_nodes empty on missing" "" "$out"

ret=$(printf 'cluster_state:ok\ncluster_slots_assigned:16384\n' | is_cluster_healthy; echo $?)
assert_eq "is_cluster_healthy ok+16384 -> 0" "0" "$ret"

ret=$(printf 'cluster_state:ok\ncluster_slots_assigned:16000\n' | is_cluster_healthy; echo $?)
assert_eq "is_cluster_healthy ok+16000 -> 1" "1" "$ret"

ret=$(printf 'cluster_state:fail\ncluster_slots_assigned:16384\n' | is_cluster_healthy; echo $?)
assert_eq "is_cluster_healthy fail+16384 -> 1" "1" "$ret"

out=$(build_create_command "mypass" "127.0.0.1:6379" "127.0.0.1:6380")
assert_contains "build_create_command has redis-cli" "redis-cli" "$out"
assert_contains "build_create_command has --cluster create" "--cluster
create" "$out"
assert_contains "build_create_command has --cluster-replicas 1" "--cluster-replicas
1" "$out"
assert_contains "build_create_command has --cluster-yes" "--cluster-yes" "$out"
assert_contains "build_create_command has -a mypass" "-a
mypass" "$out"
assert_contains "build_create_command has first node arg" "127.0.0.1:6379" "$out"
assert_contains "build_create_command has second node arg" "127.0.0.1:6380" "$out"

echo
echo "============================="
echo "SUMMARY: PASS=$PASS  FAIL=$FAIL"
echo "============================="
exit $FAIL
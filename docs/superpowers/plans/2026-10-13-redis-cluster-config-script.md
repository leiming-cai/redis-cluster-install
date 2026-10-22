# Redis Cluster Config Script Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `cluster-config.sh` — a config-file-driven script that renders, deploys and starts Redis cluster instances on machines where the Redis binaries, `redis` user and directories already exist, then creates the cluster and verifies it.

**Architecture:** Three new files, no modification to existing scripts. `lib/conf.sh` is a pure, non-executing INI-style parser. `cluster-config.sh` is an 8-step orchestrator reusing the existing `lib/` helpers (`ssh.sh`, `config_gen.sh`, `systemd.sh`, `prompt.sh`, `cluster.sh`) and the existing `config/*.template` files. `cluster.conf.example` documents the config format.

**Tech Stack:** Bash 4+, `sshpass`, `redis-cli`, `systemd`, `bats`. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-10-13-redis-cluster-config-script-design.md`

---

## File Structure

| Path | Responsibility |
|---|---|
| `lib/conf.sh` | Parse `cluster.conf` into globals + parallel arrays. Never `source`/`eval`. Collects unknown keys instead of erroring. |
| `cluster-config.sh` | 8-step orchestrator: parse conf → CLI → credentials → preflight → auth.conf → render/deploy → start/PING → cluster create/health. |
| `cluster.conf.example` | Annotated config template the operator copies to `cluster.conf`. |
| `tests/lib/conf.bats` | Unit tests for the parser (~12 cases). |
| `tests/cluster_config_render.bats` | Contract tests asserting rendered `redis.conf` / systemd unit content (guards the D8 regression). |
| `tests/cluster_config.bats` | CLI smoke tests for `cluster-config.sh` (`--help`, missing config). |
| `scripts/e2e-cluster-config.sh` | Docker two-node end-to-end validation. |

**Existing files this plan reads but does not modify:** `lib/common.sh`, `lib/ssh.sh`, `lib/config_gen.sh`, `lib/systemd.sh`, `lib/prompt.sh`, `lib/cluster.sh`, `config/redis.conf.template`, `config/redis-cluster.service.template`, `tests/setup.bash`.

---

## Parser output contract

`lib/conf.sh` exposes these after `parse_conf FILE` succeeds. Every task below relies on these exact names.

| Variable | Meaning |
|---|---|
| `CONF_REDIS_PREFIX` | install prefix, default `/opt/software/redis` |
| `CONF_PASSWORD` | cluster password (required) |
| `CONF_BIND_ADDR` | bind address, default `0.0.0.0` |
| `CONF_REPLICAS` | replicas per master, fixed at 1 |
| `CONF_TOTAL_INSTANCES` | sum of ports across all groups — this is what `redis-cli --cluster create` treats as its node count |
| `CONF_NODE_COUNT` | number of node groups (NOT the instance count) |
| `CONF_NODE_GROUP[i]` | raw group label from `[node.X]`, e.g. `a` |
| `CONF_NODE_ENVKEY[i]` | env-var prefix for that node, e.g. `NODE_A` |
| `CONF_NODE_HOST[i]` | host IP/name |
| `CONF_NODE_SSH_PORT[i]` | SSH port, default `22` |
| `CONF_NODE_PORTS[i]` | normalised comma-separated port list |
| `CONF_UNKNOWN_KEYS` | newline-separated unknown key names (empty string if none) |

Arrays are 1-based; `CONF_NODE_ENVKEY` uppercases the group label and replaces
any character outside `[A-Za-z0-9]` with `_`.

---

## Task 1: Repo bootstrap + `.gitignore` entry

**Files:**
- Create: `cluster.conf.example`
- Modify: `.gitignore`

- [ ] **Step 1: Create `cluster.conf.example`**

```bash
cat > cluster.conf.example <<'EOF'
# cluster.conf — Redis 集群配置
#
# 用法：cp cluster.conf.example cluster.conf，然后按实际情况修改。
# cluster.conf 含集群密码，不应提交到版本库。
#
# 解析器不会执行本文件中的任何内容，只做键值切分。

# ---------------------------------------------------------------------------
# 全局配置
# ---------------------------------------------------------------------------

# Redis 安装根目录。必须与目标节点上的实际路径一致，否则生成的配置与
# systemd 单元会指向不同目录，在 ProtectSystem=strict 下导致无法启动。
redis_prefix = /opt/software/redis

# 集群密码。必填。同时用作 redis.conf 的 requirepass 与 masterauth。
cluster_password = CHANGE_ME

# redis.conf 的 bind 地址。
bind_addr = 0.0.0.0

# ---------------------------------------------------------------------------
# 节点配置
# ---------------------------------------------------------------------------
# [node.X] 的 X 仅作标签，用于映射环境变量 NODE_X_*，不影响语义。
# 节点按文件中出现顺序处理。
# 至少需要 3 个节点（redis-cli --cluster create 要求至少 3 个 master）。

[node.a]
host     = 192.168.1.10
ssh_port = 22
ports    = 6379,6380,6381

[node.b]
host     = 192.168.1.11
ssh_port = 22
ports    = 6382,6383,6384
EOF
```

- [ ] **Step 2: Add `cluster.conf` to `.gitignore`**

Append these lines to the end of `.gitignore`:

```bash
cat >> .gitignore <<'EOF'

# Cluster config (contains cluster_password)
cluster.conf
EOF
```

- [ ] **Step 3: Verify the example parses conceptually (no secrets committed)**

Run: `git status --porcelain`
Expected: shows `?? cluster.conf.example` and `?? lib/conf.sh` only once
Task 2 lands; `cluster.conf` itself must never appear.

- [ ] **Step 4: Commit**

```bash
git add .gitignore cluster.conf.example
git commit -m "chore: add cluster.conf.example and ignore cluster.conf"
```

---

## Task 2: `lib/conf.sh` — core parser (comments, sections, globals)

**Files:**
- Create: `lib/conf.sh`
- Create: `tests/lib/conf.bats`

- [ ] **Step 1: Write the failing test file**

```bash
cat > tests/lib/conf.bats <<'BATSEOF'
load '../setup'
load_lib common
load_lib conf

setup() {
    CONF_TMP="$(mktemp -d)"
    export CONF_TMP
}

teardown() {
    rm -rf "$CONF_TMP"
}

write_conf() {
    cat > "$CONF_TMP/cluster.conf"
}

@test "parse_conf reads global keys and defaults" {
    write_conf <<'EOF'
redis_prefix     = /custom/redis
cluster_password = s3cret
bind_addr        = 127.0.0.1
[node.a]
host  = 10.0.0.1
ports = 6379,6380,6381
[node.b]
host  = 10.0.0.2
ports = 6382,6383
[node.c]
host  = 10.0.0.3
ports = 6383
EOF
    parse_conf "$CONF_TMP/cluster.conf"
    [ "$CONF_REDIS_PREFIX" = "/custom/redis" ]
    [ "$CONF_PASSWORD" = "s3cret" ]
    [ "$CONF_BIND_ADDR" = "127.0.0.1" ]
}

@test "parse_conf applies default prefix and bind_addr when absent" {
    write_conf <<'EOF'
cluster_password = pw
[node.a]
host  = h1
ports = 6379,6380,6381
[node.b]
host  = h2
ports = 6382,6383
EOF
    parse_conf "$CONF_TMP/cluster.conf"
    [ "$CONF_REDIS_PREFIX" = "/opt/software/redis" ]
    [ "$CONF_BIND_ADDR" = "0.0.0.0" ]
}

@test "parse_conf stores nodes in file order with group and envkey" {
    write_conf <<'EOF'
cluster_password = pw
[node.a]
host  = 10.0.0.1
ports = 6379,6380,6381
[node.worker-1]
host  = 10.0.0.2
ports = 6382,6383,6384
EOF
    parse_conf "$CONF_TMP/cluster.conf"
    [ "$CONF_NODE_COUNT" -eq 2 ]
    [ "${CONF_NODE_GROUP[1]}" = "a" ]
    [ "${CONF_NODE_ENVKEY[1]}" = "NODE_A" ]
    [ "${CONF_NODE_HOST[1]}" = "10.0.0.1" ]
    [ "${CONF_NODE_GROUP[2]}" = "worker-1" ]
    [ "${CONF_NODE_ENVKEY[2]}" = "NODE_WORKER_1" ]
    [ "${CONF_NODE_HOST[2]}" = "10.0.0.2" ]
}

@test "parse_conf defaults ssh_port to 22 when absent" {
    write_conf <<'EOF'
cluster_password = pw
[node.a]
host  = h1
ports = 6379,6380,6381
[node.b]
host  = h2
ports = 6382,6383
EOF
    parse_conf "$CONF_TMP/cluster.conf"
    [ "${CONF_NODE_SSH_PORT[1]}" = "22" ]
}

@test "parse_conf honours an explicit ssh_port" {
    write_conf <<'EOF'
cluster_password = pw
[node.a]
host     = h1
ssh_port = 2222
ports    = 6379
[node.b]
host  = h2
ports = 6380
[node.c]
host  = h3
ports = 6381
EOF
    parse_conf "$CONF_TMP/cluster.conf"
    [ "${CONF_NODE_SSH_PORT[1]}" = "2222" ]
}

@test "parse_conf normalises whitespace around keys, values and ports" {
    write_conf <<'EOF'
   cluster_password    =    pw
[node.a]
   host     =   10.0.0.1
   ports    =   6379 , 6380 ,6381
[node.b]
host  = h2
ports = 6382,6383
[node.c]
host  = h3
ports = 6383
EOF
    parse_conf "$CONF_TMP/cluster.conf"
    [ "$CONF_PASSWORD" = "pw" ]
    [ "${CONF_NODE_HOST[1]}" = "10.0.0.1" ]
    [ "${CONF_NODE_PORTS[1]}" = "6379,6380,6381" ]
}
BATSEOF
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/lib/conf.bats`
Expected: FAIL — `parse_conf: command not found`.

- [ ] **Step 3: Write `lib/conf.sh`**

```bash
cat > lib/conf.sh <<'CONFEOF'
#!/usr/bin/env bash
# lib/conf.sh — parse a cluster.conf file into shell variables and arrays.
#
# SAFETY: this parser NEVER sources, evals, or otherwise executes the config
# file. It only splits lines on the first '=' and assigns the result, so a
# config file containing shell code has no effect beyond its literal text.
#
# Outputs (see spec §3.2):
#   CONF_REDIS_PREFIX CONF_PASSWORD CONF_BIND_ADDR CONF_REPLICAS
#   CONF_NODE_COUNT
#   CONF_NODE_GROUP[i] CONF_NODE_ENVKEY[i] CONF_NODE_HOST[i]
#   CONF_NODE_SSH_PORT[i] CONF_NODE_PORTS[i]
#   CONF_UNKNOWN_KEYS
#
# Source from another script. Do not execute.

# conf_trim STRING -> STRING
# Strip leading and trailing whitespace (spaces, tabs, CR).
conf_trim() {
    local s="$1"
    s="${s//$'\r'/}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# conf_normalise_ports "6379 , 6380 ,6381" -> "6379,6380,6381"
# Split on commas, trim each element, drop empty ones, rejoin with commas.
conf_normalise_ports() {
    local raw="$1"
    local -a parts=()
    local out=""
    local p
    local old_ifs="$IFS"
    IFS=','
    # shellcheck disable=SC2206
    local -a raw_parts=($raw)
    IFS="$old_ifs"
    for p in "${raw_parts[@]}"; do
        p="$(conf_trim "$p")"
        [ -n "$p" ] || continue
        if [ -n "$out" ]; then out="$out,$p"; else out="$p"; fi
        parts+=("$p")
    done
    printf '%s' "$out"
}

# conf_envkey "worker-1" -> "NODE_WORKER_1"
conf_envkey() {
    local label="$1"
    local up="${label^^}"
    # Replace every character outside [A-Z0-9_] with _.
    local cleaned=""
    local i ch
    for (( i = 0; i < ${#up}; i++ )); do
        ch="${up:i:1}"
        case "$ch" in
            [A-Z0-9_]) cleaned="$cleaned$ch" ;;
            *)         cleaned="${cleaned}_" ;;
        esac
    done
    printf 'NODE_%s' "$cleaned"
}

# conf_die FILE LINE KEY
# Uniform parse error: always names the file and the offending key.
conf_die() {
    local file="$1" line="$2" key="$3"
    die "$file:$line: missing or invalid key '$key'"
}

# conf_record_unknown KEY
# Unknown keys are tolerated (typos must not be silently swallowed, but they
# must not abort the run either). They are collected and printed once.
conf_record_unknown() {
    local key="$1"
    [ -n "$key" ] || return 0
    if [ -z "$CONF_UNKNOWN_KEYS" ]; then
        CONF_UNKNOWN_KEYS="$key"
    else
        CONF_UNKNOWN_KEYS="$CONF_UNKNOWN_KEYS
$key"
    fi
}

# parse_conf FILE
# Populates the CONF_* variables described at the top of this file.
# Aborts (via die) on: missing file, malformed line, missing required key,
# or fewer than 3 nodes.
parse_conf() {
    local file="$1"
    local lineno=0
    local line trimmed key value

    [ -f "$file" ] || die "config file not found: $file"

    # Defaults
    CONF_REDIS_PREFIX="/opt/software/redis"
    CONF_PASSWORD=""
    CONF_BIND_ADDR="0.0.0.0"
    CONF_REPLICAS=1
    CONF_NODE_COUNT=0
    CONF_UNKNOWN_KEYS=""
    CONF_NODE_GROUP=()
    CONF_NODE_ENVKEY=()
    CONF_NODE_HOST=()
    CONF_NODE_SSH_PORT=()
    CONF_NODE_PORTS=()

    # "am I inside a node group, and which one"
    local in_node=0
    local cur=0
    local pending_host="" pending_ports="" pending_ssh_port=""

    _conf_flush_node() {
        [ "$in_node" = "1" ] || return 0
        # Required keys for the group that just ended.
        if [ -z "$pending_host" ]; then
            conf_die "$file" "$lineno" "host (in [node.$CONF_NODE_GROUP[$cur]])"
        fi
        if [ -z "$pending_ports" ]; then
            conf_die "$file" "$lineno" "ports (in [node.$CONF_NODE_GROUP[$cur]])"
        fi
        CONF_NODE_HOST[$cur]="$pending_host"
        CONF_NODE_PORTS[$cur]="$(conf_normalise_ports "$pending_ports")"
        CONF_NODE_SSH_PORT[$cur]="${pending_ssh_port:-22}"
        pending_host=""; pending_ports=""; pending_ssh_port=""
    }

    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        line="${line%$'\r'}"
        trimmed="$(conf_trim "$line")"

        # Blank or comment
        [ -z "$trimmed" ] && continue
        case "$trimmed" in \#*) continue ;; esac

        # Section header
        case "$trimmed" in
            \[*\]*)
                _conf_flush_node
                local label="${trimmed#\[}"
                label="${label%\]}"
                label="$(conf_trim "$label")"
                label="${label#node.}"
                if [ -z "$label" ]; then
                    die "$file:$lineno: empty section name; expected [node.NAME]"
                fi
                cur=$((cur + 1))
                CONF_NODE_GROUP[$cur]="$label"
                CONF_NODE_ENVKEY[$cur]="$(conf_envkey "$label")"
                in_node=1
                continue
                ;;
        esac

        # Key = Value
        case "$trimmed" in
            *=*) ;;
            *) die "$file:$lineno: expected 'key = value', got: $trimmed" ;;
        esac

        key="$(conf_trim "${trimmed%%=*}")"
        value="$(conf_trim "${trimmed#*=}")"
        [ -n "$key" ] || die "$file:$lineno: empty key"

        if [ "$in_node" = "1" ]; then
            case "$key" in
                host)     pending_host="$value" ;;
                ports)    pending_ports="$value" ;;
                ssh_port) pending_ssh_port="$value" ;;
                *)        conf_record_unknown "$key" ;;
            esac
        else
            case "$key" in
                redis_prefix)     CONF_REDIS_PREFIX="$value" ;;
                cluster_password) CONF_PASSWORD="$value" ;;
                bind_addr)        CONF_BIND_ADDR="$value" ;;
                replicas)         CONF_REPLICAS="$value" ;;
                *)                conf_record_unknown "$key" ;;
            esac
        fi
    done < "$file"

    _conf_flush_node
    unset -f _conf_flush_node

    CONF_NODE_COUNT="$cur"

    # Required global key
    if [ -z "$CONF_PASSWORD" ]; then
        conf_die "$file" "$lineno" "cluster_password"
    fi

    # `redis-cli --cluster create` requires at least 3 masters.
    #
    # COUNT INSTANCES, NOT NODE GROUPS. Each port is one cluster instance, so
    # the standard "A:6379,6380,6381 + B:6382,6383,6384" layout is 2 groups but
    # 6 instances. Counting groups would compute ceil(2/2)=1 master and wrongly
    # reject the canonical layout.
    CONF_TOTAL_INSTANCES=0
    local n
    for (( n = 1; n <= CONF_NODE_COUNT; n++ )); do
        local _ifs_save="$IFS"
        IFS=','
        local -a _pl=(${CONF_NODE_PORTS[$n]})
        IFS="$_ifs_save"
        CONF_TOTAL_INSTANCES=$(( CONF_TOTAL_INSTANCES + ${#_pl[@]} ))
    done

    # masters = ceil(instances / (1 + replicas)); replicas is fixed at 1 here.
    local masters=$(( (CONF_TOTAL_INSTANCES + CONF_REPLICAS) / (1 + CONF_REPLICAS) ))
    if [ "$masters" -lt 3 ]; then
        die "$file: $CONF_TOTAL_INSTANCES instance(s) configured -> only $masters master(s); redis-cli --cluster create requires at least 3 masters (with replicas=$CONF_REPLICAS you need at least 5 instances)"
    fi
}
CONFEOF
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/lib/conf.bats`
Expected: 6 tests pass.

- [ ] **Step 5: Syntax check**

Run: `bash -n lib/conf.sh`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add lib/conf.sh tests/lib/conf.bats
git commit -m "feat(conf): add INI-style cluster.conf parser"
```

---

## Task 3: `lib/conf.sh` — error handling, unknown keys, safety

**Files:**
- Modify: `tests/lib/conf.bats` (append tests)
- Modify: `lib/conf.sh` (only if a test reveals a gap)

- [ ] **Step 1: Append error-handling and safety tests**

```bash
cat >> tests/lib/conf.bats <<'BATSEOF'

@test "parse_conf dies when cluster_password is missing" {
    write_conf <<'EOF'
[node.a]
host  = h1
ports = 6379,6380,6381
[node.b]
host  = h2
ports = 6382,6383
EOF
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cluster_password"* ]]
}

@test "parse_conf dies when a node group has no host" {
    write_conf <<'EOF'
cluster_password = pw
[node.a]
ports = 6379
[node.b]
host  = h2
ports = 6380
[node.c]
host  = h3
ports = 6381
EOF
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"host"* ]]
}

@test "parse_conf dies when a node group has no ports" {
    write_conf <<'EOF'
cluster_password = pw
[node.a]
host = h1
[node.b]
host  = h2
ports = 6380
[node.c]
host  = h3
ports = 6381
EOF
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ports"* ]]
}

@test "parse_conf dies on a malformed line without an equals sign" {
    write_conf <<'EOF'
cluster_password = pw
this line has no equals
[node.a]
host  = h1
ports = 6379,6380,6381
[node.b]
host  = h2
ports = 6382,6383
EOF
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no equals"* ]]
}

@test "parse_conf dies when too few instances are configured for 3 masters" {
    write_conf <<'EOF'
cluster_password = pw
[node.a]
host  = h1
ports = 6379
[node.b]
host  = h2
ports = 6380
EOF
    run parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"at least 3 masters"* ]]
    [[ "$output" == *"2 instance(s)"* ]]
}

@test "parse_conf counts INSTANCES not node groups for the master threshold" {
    # Two groups but six ports: the canonical "A:6379-6381 + B:6382-6384"
    # layout must be accepted. Counting groups would compute ceil(2/2)=1
    # master and wrongly reject it.
    write_conf <<'EOF'
cluster_password = pw
[node.a]
host  = h1
ports = 6379,6380,6381
[node.b]
host  = h2
ports = 6382,6383,6384
EOF
    parse_conf "$CONF_TMP/cluster.conf"
    [ "$CONF_NODE_COUNT" -eq 2 ]
    [ "$CONF_TOTAL_INSTANCES" -eq 6 ]
}

@test "parse_conf dies when the config file does not exist" {
    run parse_conf "$CONF_TMP/nope.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found"* ]]
}

@test "parse_conf splits on the FIRST equals so values may contain equals" {
    write_conf <<'EOF'
cluster_password = pa=ss=word
[node.a]
host  = h1
ports = 6379,6380,6381
[node.b]
host  = h2
ports = 6382,6383
EOF
    parse_conf "$CONF_TMP/cluster.conf"
    [ "$CONF_PASSWORD" = "pa=ss=word" ]
}

@test "parse_conf collects unknown keys instead of failing" {
    write_conf <<'EOF'
cluster_password = pw
ssh_prot = 22
[node.a]
host   = h1
prot   = 6379
ports  = 6379
[node.b]
host  = h2
ports = 6380
[node.c]
host  = h3
ports = 6381
EOF
    parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -eq 0 ]
    [ "$CONF_UNKNOWN_KEYS" = "ssh_prot
prot" ]
}

@test "parse_conf does not execute shell code in the config" {
    write_conf <<'EOF'
cluster_password = pw
INJECTED = $(touch /tmp/conf-pwned-$$)
[node.a]
host  = h1
ports = 6379,6380,6381
[node.b]
host  = h2
ports = 6382,6383
EOF
    parse_conf "$CONF_TMP/cluster.conf"
    [ "$status" -eq 0 ]
    [ ! -e "/tmp/conf-pwned-$$" ]
    [[ "$CONF_UNKNOWN_KEYS" == *"INJECTED"* ]]
}
BATSEOF
```

- [ ] **Step 2: Run the tests**

Run: `bats tests/lib/conf.bats`
Expected: all tests pass. If the "does not execute shell code" test fails,
the parser is sourcing or evaluating the file — fix that before continuing.

- [ ] **Step 3: Verify the whole lib suite still passes**

Run: `bats tests/lib/*.bats`
Expected: all pass, no regressions in the other 7 lib test files.

- [ ] **Step 4: Commit**

```bash
git add lib/conf.sh tests/lib/conf.bats
git commit -m "test(conf): cover parse errors, unknown keys and injection safety"
```

---

## Task 4: Render contract tests (guards the D8 regression)

**Files:**
- Create: `tests/fixtures/redis.conf.template`
- Create: `tests/fixtures/systemd.service.template`
- Create: `tests/cluster_config_render.bats`

- [ ] **Step 1: Create fixtures mirroring the real templates**

```bash
cat > tests/fixtures/redis.conf.template <<'EOF'
# Test fixture: cluster instance config
port %PORT%
bind %BIND_ADDR%
requirepass %PASSWORD%
masterauth %PASSWORD%
cluster-enabled yes
cluster-config-file %REDIS_PREFIX%/cluster/%PORT%/nodes.conf
logfile %REDIS_PREFIX%/log/redis-%PORT%.log
dir /var/lib/redis/cluster/%PORT%
EOF

cat > tests/fixtures/systemd.service.template <<'EOF'
[Unit]
Description=Redis %PORT% (%NODE_NAME%)

[Service]
User=redis
EnvironmentFile=/etc/redis/cluster/auth.conf
ExecStart=%REDIS_PREFIX%/bin/redis-server /etc/redis/cluster/redis-%PORT%.conf
ReadWritePaths=-/var/lib/redis -/var/log/redis -/var/run/redis -%REDIS_PREFIX%/cluster -%REDIS_PREFIX%/log

[Install]
WantedBy=multi-user.target
EOF
```

> **`ReadWritePaths` 的 `-` 前缀是 2026-10-19 补上的**（原文没有 `-`）。
> systemd 里**不带 `-` 的条目是硬性要求**：路径不存在时单元直接以
> `status=226/NAMESPACE` 失败。`/var/log/redis` 没有任何代码创建它，
> 旧 E2E 底包恰好自带该目录而掩盖了它。修复见 `32ac923`。

- [ ] **Step 2: Write the contract tests**

```bash
cat > tests/cluster_config_render.bats <<'BATSEOF'
load 'setup'
load_lib config_gen
load_lib systemd

setup() {
    CONF_TEMPLATE="$REPO_ROOT/tests/fixtures/redis.conf.template"
    UNIT_TEMPLATE="$REPO_ROOT/tests/fixtures/systemd.service.template"
    PREFIX="/opt/software/redis"
    PASS="s3cret"
}

@test "rendered redis.conf carries the right port and password" {
    out="$(render_redis_conf "$CONF_TEMPLATE" 6379 "$PASS" "node-6379" "0.0.0.0" "$PREFIX")"
    [[ "$out" == *"port 6379"* ]]
    [[ "$out" == *"requirepass s3cret"* ]]
    [[ "$out" == *"masterauth s3cret"* ]]
}

@test "rendered redis.conf points cluster-config-file at REDIS_PREFIX" {
    out="$(render_redis_conf "$CONF_TEMPLATE" 6380 "$PASS" "node-6380" "0.0.0.0" "$PREFIX")"
    [[ "$out" == *"cluster-config-file /opt/software/redis/cluster/6380/nodes.conf"* ]]
}

@test "rendered redis.conf logfile lives under REDIS_PREFIX/log" {
    out="$(render_redis_conf "$CONF_TEMPLATE" 6381 "$PASS" "node-6381" "0.0.0.0" "$PREFIX")"
    [[ "$out" == *"logfile /opt/software/redis/log/redis-6381.log"* ]]
}

@test "a custom REDIS_PREFIX propagates into redis.conf" {
    out="$(render_redis_conf "$CONF_TEMPLATE" 6379 "$PASS" "node-6379" "0.0.0.0" "/custom/redis")"
    [[ "$out" == *"cluster-config-file /custom/redis/cluster/6379/nodes.conf"* ]]
    [[ "$out" == *"logfile /custom/redis/log/redis-6379.log"* ]]
    [[ "$out" != *"/opt/software/redis"* ]]
}

@test "rendered unit ExecStart uses REDIS_PREFIX/bin/redis-server" {
    out="$(render_systemd_unit "$UNIT_TEMPLATE" 6379 "node-6379" "$PASS" "$PREFIX")"
    [[ "$out" == *"ExecStart=/opt/software/redis/bin/redis-server /etc/redis/cluster/redis-6379.conf"* ]]
}

@test "unit ReadWritePaths covers cluster and log dirs (D8 regression)" {
    out="$(render_systemd_unit "$UNIT_TEMPLATE" 6379 "node-6379" "$PASS" "$PREFIX")"
    [[ "$out" == *"/opt/software/redis/cluster"* ]]
    [[ "$out" == *"/opt/software/redis/log"* ]]
    [[ "$out" == *"/var/lib/redis"* ]]
}

@test "config and unit agree on the port for every instance" {
    for p in 6379 6380 6381 6382 6383 6384; do
        conf="$(render_redis_conf "$CONF_TEMPLATE" "$p" "$PASS" "node-$p" "0.0.0.0" "$PREFIX")"
        unit="$(render_systemd_unit "$UNIT_TEMPLATE" "$p" "node-$p" "$PASS" "$PREFIX")"
        [[ "$conf" == *"port $p"* ]]
        [[ "$unit" == *"redis-$p.conf"* ]]
    done
}
BATSEOF
```

- [ ] **Step 3: Run the tests**

Run: `bats tests/cluster_config_render.bats`
Expected: 7 tests pass.

- [ ] **Step 4: Commit**

```bash
git add tests/fixtures/redis.conf.template tests/fixtures/systemd.service.template \
        tests/cluster_config_render.bats
git commit -m "test(config): add render contract tests guarding REDIS_PREFIX propagation"
```

---

## Task 5: `cluster-config.sh` skeleton — CLI, config loading, unknown-key notice

**Files:**
- Create: `cluster-config.sh`
- Create: `tests/cluster_config.bats`

- [ ] **Step 1: Write the failing tests**

```bash
cat > tests/cluster_config.bats <<'BATSEOF'
load 'setup'

setup() {
    CONF_TMP="$(mktemp -d)"
    cat > "$CONF_TMP/cluster.conf" <<'EOF'
cluster_password = pw
[node.a]
host  = 10.0.0.1
ports = 6379,6380,6381
[node.b]
host  = 10.0.0.2
ports = 6382,6383,6384
[node.c]
host  = 10.0.0.3
ports = 6385,6386,6387
EOF
}

teardown() {
    rm -rf "$CONF_TMP"
}

@test "cluster-config.sh parses without syntax errors" {
    run bash -n "$REPO_ROOT/cluster-config.sh"
    [ "$status" -eq 0 ]
}

@test "cluster-config.sh --help exits 0 and mentions Usage" {
    run bash "$REPO_ROOT/cluster-config.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "cluster-config.sh --help documents the env var prefix" {
    run bash "$REPO_ROOT/cluster-config.sh" --help
    [[ "$output" == *"NODE_"* ]]
}

@test "cluster-config.sh --help warns that re-running restarts instances" {
    run bash "$REPO_ROOT/cluster-config.sh" --help
    [[ "$output" == *"restart"* ]]
}

@test "cluster-config.sh dies when the config file is missing" {
    run bash "$REPO_ROOT/cluster-config.sh" --config "$CONF_TMP/absent.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found"* ]]
}

@test "cluster-config.sh dies with a parse error on a bad config" {
    printf 'cluster_password = pw\n[node.a]\nhost = h1\nports = 6379\n' > "$CONF_TMP/bad.conf"
    run bash "$REPO_ROOT/cluster-config.sh" --config "$CONF_TMP/bad.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"at least 3 masters"* ]]
}

@test "cluster-config.sh prints a notice for unknown keys" {
    cat > "$CONF_TMP/unknown.conf" <<'EOF'
cluster_password = pw
ssh_prot = 22
[node.a]
host  = 10.0.0.1
ports = 6379,6380,6381
[node.b]
host  = 10.0.0.2
ports = 6382,6383,6384
[node.c]
host  = 10.0.0.3
ports = 6385,6386,6387
EOF
    # Stop right after parsing: no reachable SSH hosts exist in unit tests.
    run bash "$REPO_ROOT/cluster-config.sh" --config "$CONF_TMP/unknown.conf" --dry-run
    [[ "$output" == *"ssh_prot"* ]]
}

@test "cluster-config.sh --dry-run prints the plan without touching any host" {
    run bash "$REPO_ROOT/cluster-config.sh" --config "$CONF_TMP/cluster.conf" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"10.0.0.1"* ]]
    [[ "$output" == *"6384"* ]]
    [[ "$output" == *"DRY-RUN"* ]]
}
BATSEOF
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/cluster_config.bats`
Expected: FAIL — `cluster-config.sh` does not exist.

- [ ] **Step 3: Write the skeleton**

```bash
cat > cluster-config.sh <<'MAINEOF'
#!/usr/bin/env bash
# cluster-config.sh — Configure and form a Redis Cluster on machines that
# already have the Redis binaries, the `redis` user and the required
# directories in place.
#
# Usage:
#   bash cluster-config.sh                       # read ./cluster.conf
#   bash cluster-config.sh --config FILE         # read FILE
#   bash cluster-config.sh --dry-run             # print the plan, change nothing
#   bash cluster-config.sh --help
#
# SSH credentials: environment variables take precedence, anything missing is
# asked for interactively. Variables are per node group, derived from the
# [node.X] label in the config:
#
#   NODE_A_SSH_USER  NODE_A_HOST  NODE_A_SSH_PORT  NODE_A_SSH_PASS
#   NODE_B_SSH_USER  NODE_B_HOST  NODE_B_SSH_PORT  NODE_B_SSH_PASS
#
# For [node.a] the prefix is NODE_A_; for [node.worker-1] it is NODE_WORKER_1_.
# NODE_<X>_HOST overrides the config's host. NODE_<X>_SSH_PORT defaults to 22,
# NODE_<X>_SSH_USER defaults to root, NODE_<X>_SSH_PASS is asked silently.
#
# Requires: bash 4+, sshpass, redis-cli, openssh-client.
#
# NOTE: re-running this script re-renders and re-deploys every redis.conf and
# systemd unit, then restarts the affected instances. Data is preserved and an
# already-healthy cluster is not recreated, but instances restart.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$REPO_ROOT/lib/common.sh"
# shellcheck source=lib/conf.sh
. "$REPO_ROOT/lib/conf.sh"
# shellcheck source=lib/ssh.sh
. "$REPO_ROOT/lib/ssh.sh"
# shellcheck source=lib/config_gen.sh
. "$REPO_ROOT/lib/config_gen.sh"
# shellcheck source=lib/systemd.sh
. "$REPO_ROOT/lib/systemd.sh"
# shellcheck source=lib/prompt.sh
. "$REPO_ROOT/lib/prompt.sh"
# shellcheck source=lib/cluster.sh
. "$REPO_ROOT/lib/cluster.sh"

CONF_TEMPLATE="$REPO_ROOT/config/redis.conf.template"
UNIT_TEMPLATE="$REPO_ROOT/config/redis-cluster.service.template"

CONF_FILE="./cluster.conf"
DRY_RUN=0

usage() {
    # Lines 2-27 are the header comment block; line 28 is blank and line 29
    # is `set -euo pipefail`, which must not be printed.
    sed -n '2,27p' "$0"
}

# === CLI ===
while [ $# -gt 0 ]; do
    case "$1" in
        --config) shift; [ $# -gt 0 ] || die "--config requires a file argument"
                 CONF_FILE="$1" ;;
        --config=*) CONF_FILE="${1#*=}" ;;
        --dry-run) DRY_RUN=1 ;;
        --help|-h) usage; exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
    shift
done

# === Step 1: parse config ===
log_info "[1/2] Reading config $CONF_FILE"
parse_conf "$CONF_FILE"

# Unknown keys are ignored rather than fatal, but a typo like `ssh_prot`
# would otherwise be silently swallowed, so surface them once here.
if [ -n "$CONF_UNKNOWN_KEYS" ]; then
    log_warn "unrecognised key(s) in $CONF_FILE — check for typos:"
    while IFS= read -r k; do
        [ -n "$k" ] && log_warn "  - $k"
    done <<< "$CONF_UNKNOWN_KEYS"
fi

REDIS_PREFIX="$CONF_REDIS_PREFIX"
REDIS_BIN="$REDIS_PREFIX/bin"
log_ok "Config OK: $CONF_NODE_COUNT node(s), $REDIS_REPLICAS replica(s) per master"

# === Step 2: plan / dry-run ===
log_info "[2/2] Resolved plan"
for (( i = 1; i <= CONF_NODE_COUNT; i++ )); do
    log_info "  ${CONF_NODE_GROUP[i]} (${CONF_NODE_ENVKEY[i]}) ${CONF_NODE_HOST[i]}:${CONF_NODE_SSH_PORT[i]} ports=[${CONF_NODE_PORTS[i]}]"
done

if [ "$DRY_RUN" = "1" ]; then
    echo
    log_ok "DRY-RUN complete — no changes were made"
    exit 0
fi

die "not implemented yet: credential collection and deployment (see spec section 4)"
MAINEOF
chmod +x cluster-config.sh
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/cluster_config.bats`
Expected: 8 tests pass.

- [ ] **Step 5: Verify the help output shows only the comment block**

Run: `bash cluster-config.sh --help`
Expected: prints the header comment from line 2 to line 27, ending with the
"re-running this script" note. It must **not** contain `set -euo pipefail`
or any shell code.

- [ ] **Step 6: Commit**

```bash
git add cluster-config.sh tests/cluster_config.bats
git commit -m "feat(cluster-config): add CLI, config loading and dry-run"
```

---

## Task 6: Credential collection (env-first, prompt for gaps)

**Files:**
- Modify: `cluster-config.sh`
- Modify: `tests/cluster_config.bats` (append tests)

- [ ] **Step 1: Append credential tests**

```bash
cat >> tests/cluster_config.bats <<'BATSEOF'

@test "fully provided env vars produce no interactive prompts" {
    cat > "$CONF_TMP/env.conf" <<'EOF'
cluster_password = pw
[node.a]
host  = 10.0.0.1
ports = 6379,6380,6381
[node.b]
host  = 10.0.0.2
ports = 6382,6383,6384
[node.c]
host  = 10.0.0.3
ports = 6385,6386,6387
EOF
    out="$(env PROMPT_NO_TTY=1 \
        NODE_A_SSH_USER=root NODE_A_HOST=10.0.0.1 NODE_A_SSH_PORT=22 NODE_A_SSH_PASS=pw1 \
        NODE_B_SSH_USER=root NODE_B_HOST=10.0.0.2 NODE_B_SSH_PORT=22 NODE_B_SSH_PASS=pw2 \
        NODE_C_SSH_USER=root NODE_C_HOST=10.0.0.3 NODE_C_SSH_PORT=22 NODE_C_SSH_PASS=pw3 \
        bash "$REPO_ROOT/cluster-config.sh" --config "$CONF_TMP/env.conf" --print-credentials 2>&1)"
    [[ "$out" != *"SSH user"* ]]
    [[ "$out" != *"SSH password"* ]]
    [[ "$out" == *"10.0.0.1"* ]]
}

@test "host from config is used when no env override is set" {
    cat > "$CONF_TMP/env2.conf" <<'EOF'
cluster_password = pw
[node.a]
host  = 10.9.9.9
ports = 6379,6380,6381
[node.b]
host  = 10.0.0.2
ports = 6382,6383,6384
[node.c]
host  = 10.0.0.3
ports = 6385,6386,6387
EOF
    out="$(env PROMPT_NO_TTY=1 \
        NODE_A_SSH_USER=root NODE_A_SSH_PORT=22 NODE_A_SSH_PASS=pw1 \
        NODE_B_SSH_USER=root NODE_B_SSH_PORT=22 NODE_B_SSH_PASS=pw2 \
        NODE_C_SSH_USER=root NODE_C_SSH_PORT=22 NODE_C_SSH_PASS=pw3 \
        bash "$REPO_ROOT/cluster-config.sh" --config "$CONF_TMP/env2.conf" --print-credentials 2>&1)"
    [[ "$out" == *"10.9.9.9"* ]]
}

@test "env HOST overrides the config host" {
    cat > "$CONF_TMP/env3.conf" <<'EOF'
cluster_password = pw
[node.a]
host  = 10.9.9.9
ports = 6379,6380,6381
[node.b]
host  = 10.0.0.2
ports = 6382,6383,6384
[node.c]
host  = 10.0.0.3
ports = 6385,6386,6387
EOF
    out="$(env PROMPT_NO_TTY=1 \
        NODE_A_SSH_USER=root NODE_A_SSH_PORT=22 NODE_A_SSH_PASS=pw1 NODE_A_HOST=1.2.3.4 \
        NODE_B_SSH_USER=root NODE_B_SSH_PORT=22 NODE_B_SSH_PASS=pw2 \
        NODE_C_SSH_USER=root NODE_C_SSH_PORT=22 NODE_C_SSH_PASS=pw3 \
        bash "$REPO_ROOT/cluster-config.sh" --config "$CONF_TMP/env3.conf" --print-credentials 2>&1)"
    [[ "$out" == *"1.2.3.4"* ]]
    [[ "$out" != *"10.9.9.9"* ]]
}
BATSEOF
```

- [ ] **Step 2: Run to verify the new tests fail**

Run: `bats tests/cluster_config.bats`
Expected: the 3 new tests FAIL — `--print-credentials` is not recognised yet.

- [ ] **Step 3: Add the credential resolver**

Replace the final `die "not implemented yet..."` line in `cluster-config.sh`
with the following, and add `--print-credentials` to the CLI case statement:

```bash
# === Credentials ===
# For each node: env var first, interactive prompt only for what is missing.
# Results land in CRED_USER[i] / CRED_HOST[i] / CRED_SSH_PORT[i] / CRED_PASS[i].
CRED_USER=() CRED_HOST=() CRED_SSH_PORT=() CRED_PASS=()

collect_credentials() {
    local i key env_user env_host env_port env_pass
    for (( i = 1; i <= CONF_NODE_COUNT; i++ )); do
        key="${CONF_NODE_ENVKEY[i]}"

        env_user="$(conf_env_get "${key}_SSH_USER")"
        env_host="$(conf_env_get "${key}_HOST")"
        env_port="$(conf_env_get "${key}_SSH_PORT")"
        env_pass="$(conf_env_get "${key}_SSH_PASS")"

        # host: config supplies the default; env overrides; prompt allows override
        if [ -n "$env_host" ]; then
            CRED_HOST[$i]="$env_host"
        else
            CRED_HOST[$i]="$(read_default "  ${CONF_NODE_GROUP[i]} host (override config: ${CONF_NODE_HOST[i]})" "${CONF_NODE_HOST[i]}")"
        fi

        if [ -n "$env_user" ]; then
            CRED_USER[$i]="$env_user"
        else
            CRED_USER[$i]="$(read_default "  ${CONF_NODE_GROUP[i]} SSH user" "root")"
        fi

        if [ -n "$env_port" ]; then
            CRED_SSH_PORT[$i]="$env_port"
        else
            CRED_SSH_PORT[$i]="$(read_default "  ${CONF_NODE_GROUP[i]} SSH port" "${CONF_NODE_SSH_PORT[i]}")"
        fi

        if [ -n "$env_pass" ]; then
            CRED_PASS[$i]="$env_pass"
        else
            CRED_PASS[$i]="$(read_secret "  ${CONF_NODE_GROUP[i]} SSH password")"
        fi

        [ -n "${CRED_HOST[$i]}" ]   || die "no host for node group ${CONF_NODE_GROUP[i]}"
        [ -n "${CRED_USER[$i]}" ]   || die "no SSH user for node group ${CONF_NODE_GROUP[i]}"
        [ -n "${CRED_SSH_PORT[$i]}" ] || die "no SSH port for node group ${CONF_NODE_GROUP[i]}"
    done
}

# conf_env_get VARNAME -> value, or empty if unset/empty.
# Indirect expansion without `set -u` blowing up on unset names.
conf_env_get() {
    local v="${!1:-}"
    printf '%s' "$v"
}

collect_credentials

if [ "$PRINT_CREDENTIALS" = "1" ]; then
    for (( i = 1; i <= CONF_NODE_COUNT; i++ )); do
        log_info "  ${CONF_NODE_GROUP[i]}: ${CRED_USER[$i]}@${CRED_HOST[$i]}:${CRED_SSH_PORT[$i]} (password: ${#CRED_PASS[$i]} chars)"
    done
    exit 0
fi

die "not implemented yet: preflight and deployment (see spec section 4)"
```

Also add the flag to the CLI block:

```bash
        --print-credentials) PRINT_CREDENTIALS=1 ;;
```

and initialise it next to `DRY_RUN`:

```bash
DRY_RUN=0
PRINT_CREDENTIALS=0
```

- [ ] **Step 4: Run the tests**

Run: `bats tests/cluster_config.bats`
Expected: all 11 tests pass.

- [ ] **Step 5: Commit**

```bash
git add cluster-config.sh tests/cluster_config.bats
git commit -m "feat(cluster-config): env-first credential resolution with interactive fallback"
```

---

## Task 7: Preflight (binaries + redis user) and directory creation

**Files:**
- Modify: `cluster-config.sh`

The preflight and directory-creation logic runs over real SSH, so it has no
meaningful unit test — a bats test could only assert that a hardcoded string
contains itself. Both paths are instead covered end-to-end by Task 11/12:
the E2E provisions the nodes, then runs the script, and a separate E2E case
deletes the `redis` user to prove preflight rejects it.

- [ ] **Step 1: Write the preflight function**

Replace the trailing `die "not implemented yet: preflight ..."` with:

```bash
# === Preflight ===
# Verifies the two things a human must have done: install the Redis binaries
# and create the `redis` system user. Directories are NOT checked here —
# spec §"职责边界" assigns their creation to this script (step 5), so
# checking them here would reject a correctly-prepared machine.
preflight_node() {
    local i="$1"
    local user="${CRED_USER[$i]}" pass="${CRED_PASS[$i]}"
    local host="${CRED_HOST[$i]}" port="${CRED_SSH_PORT[$i]}"

    log_info "  preflight ${CONF_NODE_GROUP[$i]} ($user@$host:$port)"

    ssh_check "$user" "$pass" "$host" "$port" \
        || die "cannot reach $user@$host:$port (check host, port and password)"

    # The remote script only echoes MISSING_* markers and always exits 0, so a
    # non-zero status from ssh_run means a transport failure, not a missing
    # prerequisite. Capture output with `if ! report=$(...)` so that `set -e`
    # does not abort before the report is inspected.
    local report
    if ! report="$(ssh_run "$user" "$pass" "$host" "$port" bash -s "$REDIS_PREFIX" <<'PREFLIGHT'
set -u
REDIS_PREFIX="$1"
for b in "$REDIS_PREFIX/bin/redis-server" "$REDIS_PREFIX/bin/redis-cli"; do
    [ -x "$b" ] || echo "MISSING_BIN: $b"
done
id redis >/dev/null 2>&1 || echo "MISSING_USER: redis"
PREFLIGHT
)"; then
        log_error "preflight failed on ${CONF_NODE_GROUP[$i]} ($host):"
        printf '%s\n' "$report" >&2
        die "fix the items above on $host, then re-run.
       Install Redis binaries into $REDIS_PREFIX/bin/ and create the 'redis'
       system user; this script creates directories but does not install
       software or create users."
    fi
}
```

- [ ] **Step 3: Wire up the call site**

Insert after the function:

```bash
log_info "[preflight] Verifying pre-provisioned state on all nodes..."
for (( i = 1; i <= CONF_NODE_COUNT; i++ )); do
    preflight_node "$i"
done
log_ok "Preflight passed on all nodes"
```

- [ ] **Step 4: Add the directory-creation function (new step 5)**

Insert after the preflight call site:

```bash
# === Create runtime directories ===
# mkdir -p is idempotent, so re-running only fills in what is missing.
# Redis refuses to start when its data directory is absent, which is why
# these live here rather than in the operator's checklist.
create_dirs() {
    local i="$1"
    local user="${CRED_USER[$i]}" pass="${CRED_PASS[$i]}"
    local host="${CRED_HOST[$i]}" port="${CRED_SSH_PORT[$i]}"

    local old_ifs="$IFS"
    IFS=','
    local -a port_list=(${CONF_NODE_PORTS[$i]})
    IFS="$old_ifs"

    local p
    for p in "${port_list[@]}"; do
        ssh_run "$user" "$pass" "$host" "$port" bash -s "$pass" "$p" "$REDIS_PREFIX" <<'DIRS'
set -e
SUDO_PASS="$1"
PORT="$2"
REDIS_PREFIX="$3"
_sudo() {
    if sudo -n true 2>/dev/null; then
        sudo -n "$@"
    elif [ -n "$SUDO_PASS" ]; then
        echo "$SUDO_PASS" | sudo -S -p '' "$@" 2>/dev/null
    else
        sudo "$@"
    fi
}
_sudo mkdir -p /etc/redis/cluster
_sudo mkdir -p "/var/lib/redis/cluster/$PORT"
_sudo mkdir -p "/var/run/redis/cluster/$PORT"
_sudo mkdir -p "$REDIS_PREFIX/cluster/$PORT"
_sudo mkdir -p "$REDIS_PREFIX/log"
_sudo chown -R redis:redis /etc/redis/cluster /var/lib/redis/cluster \
    /var/run/redis/cluster "$REDIS_PREFIX/cluster" "$REDIS_PREFIX/log"
DIRS
    done

    # Verify every per-port directory really exists. mkdir -p can succeed
    # while a path component is a file, so confirm rather than assume.
    local report
    if ! report="$(ssh_run "$user" "$pass" "$host" "$port" bash -s "$REDIS_PREFIX" <<'DIRCHECK'
set -u
REDIS_PREFIX="$1"
missing=""
for d in /etc/redis/cluster "$REDIS_PREFIX/log"; do
    [ -d "$d" ] || missing="$missing $d"
done
echo "$missing"
DIRCHECK
)"; then
        die "could not verify directories on $host"
    fi
    [ -z "$(conf_trim "$report")" ] || die "directory creation failed on $host:$report"
}

log_info "[dirs] Creating runtime directories..."
for (( i = 1; i <= CONF_NODE_COUNT; i++ )); do
    create_dirs "$i"
done
log_ok "Runtime directories created"
```

- [ ] **Step 5: Verify the new helpers are wired in the right order**

Run: `grep -n "preflight_node\|create_dirs\|deploy_auth" cluster-config.sh`
Expected: `preflight_node` is called before `create_dirs`, and `deploy_auth`
comes after `create_dirs`.

- [ ] **Step 6: Syntax check**

Run: `bash -n cluster-config.sh`
Expected: no output.

- [ ] **Step 7: Commit**

```bash
git add cluster-config.sh
git commit -m "feat(cluster-config): preflight binaries/user, then create runtime dirs"
```

---

## Task 8: Deploy `auth.conf` and rendered configs

**Files:**
- Modify: `cluster-config.sh`

- [ ] **Step 1: Add the auth deploy function**

Insert after the preflight loop:

```bash
# === Deploy auth.conf ===
# Content matches EnvironmentFile=/etc/redis/cluster/auth.conf in the unit
# template; ExecStop references it as $REDIS_PASSWORD.
deploy_auth() {
    local i="$1"
    local user="${CRED_USER[$i]}" pass="${CRED_PASS[$i]}"
    local host="${CRED_HOST[$i]}" port="${CRED_SSH_PORT[$i]}"

    # File content travels via scp, never as an SSH positional argument:
    # some sshd versions re-inject multi-line args as stdin and the remote
    # shell would try to execute the file content as commands.
    local tmpf
    tmpf="$(mktemp)"
    printf 'REDIS_PASSWORD=%s\n' "$CONF_PASSWORD" > "$tmpf"
    ssh_copy "$user" "$pass" "$host" "$port" "$tmpf" "/tmp/redis-cluster-auth.conf" \
        || { rm -f "$tmpf"; die "scp auth.conf to $host failed"; }
    rm -f "$tmpf"

    ssh_run "$user" "$pass" "$host" "$port" bash -s "$pass" <<'AUTHREMOTE'
set -e
SUDO_PASS="$1"
_sudo() {
    if sudo -n true 2>/dev/null; then
        sudo -n "$@"
    elif [ -n "$SUDO_PASS" ]; then
        echo "$SUDO_PASS" | sudo -S -p '' "$@" 2>/dev/null
    else
        sudo "$@"
    fi
}
# /etc/redis/cluster already exists: create_dirs (step 5) ran before this.
_sudo cp /tmp/redis-cluster-auth.conf /etc/redis/cluster/auth.conf
_sudo chown redis:redis /etc/redis/cluster/auth.conf
_sudo chmod 600 /etc/redis/cluster/auth.conf
rm -f /tmp/redis-cluster-auth.conf
AUTHREMOTE
    log_info "  ${CONF_NODE_GROUP[$i]}: auth.conf deployed"
}
```

- [ ] **Step 2: Add the render-and-deploy function**

```bash
# === Render and deploy redis.conf + systemd unit ===
# REDIS_PREFIX is threaded into BOTH templates so that
# cluster-config-file / logfile (redis.conf) and ExecStart / ReadWritePaths
# (unit) resolve to the same directories. If they disagree,
# ProtectSystem=strict makes the paths read-only and redis-server refuses
# to start — see docs/VERIFICATION.md D8.
deploy_configs() {
    local i="$1"
    local user="${CRED_USER[$i]}" pass="${CRED_PASS[$i]}"
    local host="${CRED_HOST[$i]}" port="${CRED_SSH_PORT[$i]}"
    local ports="${CONF_NODE_PORTS[$i]}"
    local p tmpf

    local old_ifs="$IFS"
    IFS=','
    local -a port_list=($ports)
    IFS="$old_ifs"

    for p in "${port_list[@]}"; do
        # redis.conf
        tmpf="$(mktemp)"
        render_redis_conf "$CONF_TEMPLATE" "$p" "$CONF_PASSWORD" "node-$p" "$CONF_BIND_ADDR" "$REDIS_PREFIX" > "$tmpf"
        ssh_copy "$user" "$pass" "$host" "$port" "$tmpf" "/tmp/redis-$p.conf" \
            || { rm -f "$tmpf"; die "scp redis-$p.conf to $host failed"; }
        rm -f "$tmpf"

        # systemd unit
        tmpf="$(mktemp)"
        render_systemd_unit "$UNIT_TEMPLATE" "$p" "node-$p" "$CONF_PASSWORD" "$REDIS_PREFIX" > "$tmpf"
        ssh_copy "$user" "$pass" "$host" "$port" "$tmpf" "/tmp/redis-$p.service" \
            || { rm -f "$tmpf"; die "scp redis-$p.service to $host failed"; }
        rm -f "$tmpf"

        ssh_run "$user" "$pass" "$host" "$port" bash -s "$pass" "$p" <<'DEPLOYREMOTE'
set -e
SUDO_PASS="$1"
PORT="$2"
_sudo() {
    if sudo -n true 2>/dev/null; then
        sudo -n "$@"
    elif [ -n "$SUDO_PASS" ]; then
        echo "$SUDO_PASS" | sudo -S -p '' "$@" 2>/dev/null
    else
        sudo "$@"
    fi
}
# Directories already exist: create_dirs (step 5) ran before this.
_sudo cp "/tmp/redis-${PORT}.conf" "/etc/redis/cluster/redis-${PORT}.conf"
_sudo chown redis:redis "/etc/redis/cluster/redis-${PORT}.conf"
_sudo chmod 640 "/etc/redis/cluster/redis-${PORT}.conf"
_sudo cp "/tmp/redis-${PORT}.service" "/etc/systemd/system/redis-${PORT}.service"
_sudo chmod 644 "/etc/systemd/system/redis-${PORT}.service"
rm -f "/tmp/redis-${PORT}.conf" "/tmp/redis-${PORT}.service"
DEPLOYREMOTE
        log_info "  ${CONF_NODE_GROUP[$i]}: redis-$p.conf + redis-$p.service deployed"
    done
}
```

- [ ] **Step 3: Wire the steps into the main flow**

Replace the trailing `die "not implemented yet..."` with:

```bash
log_info "[deploy] Deploying auth.conf and rendered configs..."
for (( i = 1; i <= CONF_NODE_COUNT; i++ )); do
    deploy_auth "$i"
    deploy_configs "$i"
done
log_ok "auth.conf, redis.conf and systemd units deployed"

die "not implemented yet: start, cluster create and health check (see spec section 4)"
```

- [ ] **Step 4: Syntax check and commit**

Run: `bash -n cluster-config.sh`
Expected: no output.

```bash
git add cluster-config.sh
git commit -m "feat(cluster-config): deploy auth.conf, redis.conf and systemd units"
```

---

## Task 9: Start instances and verify with PING

**Files:**
- Modify: `cluster-config.sh`

- [ ] **Step 1: Add the start-and-verify function**

Replace the trailing `die "not implemented yet..."` from Task 8 with:

```bash
# === Start and verify ===
start_and_verify() {
    local i="$1"
    local user="${CRED_USER[$i]}" pass="${CRED_PASS[$i]}"
    local host="${CRED_HOST[$i]}" port="${CRED_SSH_PORT[$i]}"

    local old_ifs="$IFS"
    IFS=','
    local -a port_list=(${CONF_NODE_PORTS[$i]})
    IFS="$old_ifs"

    local p
    for p in "${port_list[@]}"; do
        ssh_run "$user" "$pass" "$host" "$port" bash -s "$pass" "$p" "$REDIS_PREFIX" <<'STARTREMOTE'
set -e
SUDO_PASS="$1"
PORT="$2"
REDIS_PREFIX="$3"
_sudo() {
    if sudo -n true 2>/dev/null; then
        sudo -n "$@"
    elif [ -n "$SUDO_PASS" ]; then
        echo "$SUDO_PASS" | sudo -S -p '' "$@" 2>/dev/null
    else
        sudo "$@"
    fi
}
# Directories and ownership already handled by create_dirs (step 5).
_sudo systemctl daemon-reload
_sudo systemctl enable "redis-$PORT"
_sudo systemctl restart "redis-$PORT"
STARTREMOTE
    done

    # PING every instance; on failure dump the same diagnostics install.sh uses
    # (this is what pinpointed the D8 read-only-filesystem bug).
    for p in "${port_list[@]}"; do
        if ssh_run "$user" "$pass" "$host" "$port" \
                "$REDIS_BIN/redis-cli -a '$CONF_PASSWORD' -p $p PING" 2>/dev/null \
                | grep -qx PONG; then
            continue
        fi
        log_error "PING failed on $host:$p — collecting diagnostics..."
        ssh_run "$user" "$pass" "$host" "$port" bash -s "$pass" "$p" "$REDIS_PREFIX" <<'DIAG' >&2
SUDO_PASS="$1"
PORT="$2"
REDIS_PREFIX="$3"
_sudo() {
    if sudo -n true 2>/dev/null; then
        sudo -n "$@"
    elif [ -n "$SUDO_PASS" ]; then
        echo "$SUDO_PASS" | sudo -S -p '' "$@" 2>/dev/null
    else
        sudo "$@"
    fi
}
echo "==== systemctl status redis-$PORT.service ===="
_sudo systemctl status "redis-$PORT.service" --no-pager 2>&1 || true
echo ""
echo "==== journalctl -u redis-$PORT.service -n 30 ===="
_sudo journalctl -u "redis-$PORT.service" -n 30 --no-pager 2>&1 || true
echo ""
echo "==== /etc/redis/cluster/redis-$PORT.conf ===="
_sudo cat "/etc/redis/cluster/redis-$PORT.conf" 2>&1 || true
echo ""
echo "==== $REDIS_PREFIX/bin/ ===="
ls -la "$REDIS_PREFIX/bin/" 2>&1 || true
DIAG
        die "redis on $host:$p failed to start — see diagnostics above"
    done
    log_info "  ${CONF_NODE_GROUP[$i]}: all instances responding to PING"
}

log_info "[start] Starting instances..."
for (( i = 1; i <= CONF_NODE_COUNT; i++ )); do
    start_and_verify "$i"
done
log_ok "All instances responding to PING"

die "not implemented yet: cluster create and health check (see spec section 4)"
```

- [ ] **Step 2: Syntax check**

Run: `bash -n cluster-config.sh`
Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add cluster-config.sh
git commit -m "feat(cluster-config): start instances and verify with PING plus diagnostics"
```

---

## Task 10: Create the cluster and verify health

**Files:**
- Modify: `cluster-config.sh`

- [ ] **Step 1: Add cluster create and health check**

Replace the trailing `die "not implemented yet..."` from Task 9 with:

```bash
# === Create cluster ===
# Node list is built from the resolved credentials + config ports.
# NOTE: no `local` here — this code runs at script top level, not in a
# function, and bash rejects `local` outside functions (fatal under set -e).
BUILD_CREATE_ARGS=()
for (( i = 1; i <= CONF_NODE_COUNT; i++ )); do
    _ifs_save="$IFS"
    IFS=','
    _port_list=(${CONF_NODE_PORTS[$i]})
    IFS="$_ifs_save"
    for p in "${_port_list[@]}"; do
        BUILD_CREATE_ARGS+=("${CRED_HOST[$i]}:$p")
    done
done

# Query the first node's first port to decide whether to create.
FIRST_HOST="${CRED_HOST[1]}"
FIRST_SSH_PORT="${CRED_SSH_PORT[1]}"
FIRST_USER="${CRED_USER[1]}"
FIRST_PASS="${CRED_PASS[1]}"
_ifs_save="$IFS"
IFS=','
_first_ports=(${CONF_NODE_PORTS[1]})
IFS="$_ifs_save"
FIRST_REDIS_PORT="${_first_ports[0]}"

cluster_info="$(ssh_run "$FIRST_USER" "$FIRST_PASS" "$FIRST_HOST" "$FIRST_SSH_PORT" \
    "$REDIS_BIN/redis-cli -a '$CONF_PASSWORD' -p $FIRST_REDIS_PORT cluster info" 2>/dev/null || true)"

if printf '%s\n' "$cluster_info" | is_cluster_healthy; then
    log_ok "Cluster already healthy — skipping create"
else
    log_info "[cluster] Creating cluster with ${#BUILD_CREATE_ARGS[@]} instances..."
    if command -v redis-cli >/dev/null 2>&1; then
        redis-cli --cluster create "${BUILD_CREATE_ARGS[@]}" \
            --cluster-replicas "$CONF_REPLICAS" --cluster-yes \
            -a "$CONF_PASSWORD" \
            || die "redis-cli --cluster create failed"
    else
        log_warn "redis-cli not on control machine; running create from $FIRST_HOST"
        ssh_run "$FIRST_USER" "$FIRST_PASS" "$FIRST_HOST" "$FIRST_SSH_PORT" \
            "$REDIS_BIN/redis-cli --cluster create $(printf '%s ' "${BUILD_CREATE_ARGS[@]}) --cluster-replicas $CONF_REPLICAS --cluster-yes -a '$CONF_PASSWORD'" \
            || die "redis-cli --cluster create from $FIRST_HOST failed"
    fi
fi

# === Health check ===
# Right after create, masters may still be doing bus handshakes, so
# cluster_state can briefly read "fail". Retry with backoff.
log_info "[health] Verifying cluster health..."
health_ok=0
attempt=1
while [ "$attempt" -le 5 ]; do
    cluster_info="$(ssh_run "$FIRST_USER" "$FIRST_PASS" "$FIRST_HOST" "$FIRST_SSH_PORT" \
        "$REDIS_BIN/redis-cli -a '$CONF_PASSWORD' -p $FIRST_REDIS_PORT cluster info" 2>/dev/null || true)"
    if printf '%s\n' "$cluster_info" | is_cluster_healthy; then
        health_ok=1
        break
    fi
    [ "$attempt" -eq 5 ] && break
    log_warn "health check attempt $attempt/5 not ready; sleeping 3s"
    sleep 3
    attempt=$((attempt + 1))
done

[ "$health_ok" -eq 1 ] || die "cluster health check failed after 5 attempts:
$cluster_info"

log_ok "Cluster is healthy (attempt $attempt)"

# === Summary card ===
cat <<CARD

==========================================
 Redis Cluster READY
==========================================
CARD
for (( i = 1; i <= CONF_NODE_COUNT; i++ )); do
    echo "  ${CONF_NODE_GROUP[$i]}  ${CRED_HOST[$i]}  ports=[${CONF_NODE_PORTS[$i]}]"
done
cat <<CARD
  Connect:  redis-cli -c -a "<password>" -h ${FIRST_HOST} -p ${FIRST_REDIS_PORT}
  Password: cluster_password in $CONF_FILE
  Other:    status.sh  uninstall.sh  add-node.sh
==========================================
CARD
```

- [ ] **Step 2: Syntax check**

Run: `bash -n cluster-config.sh`
Expected: no output.

- [ ] **Step 3: Run the full unit suite to confirm no regressions**

Run: `bats tests/lib/*.bats tests/*.bats`
Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git add cluster-config.sh
git commit -m "feat(cluster-config): create cluster and verify health"
```

---

## Task 11: Docker E2E harness

**Files:**
- Create: `scripts/e2e-cluster-config.sh`
- Create: `tests/fixtures/Dockerfile.node.e2e`
- Create: `tests/fixtures/Dockerfile.control.e2e`

- [ ] **Step 1: Create the node image definition**

```bash
cat > tests/fixtures/Dockerfile.node.e2e <<'EOF'
FROM docker.m.daocloud.io/library/ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
        openssh-server systemd systemd-sysv sudo build-essential \
        gcc g++ make tar curl ca-certificates procps net-tools iproute2 \
    && rm -rf /var/lib/apt/lists/*
RUN echo 'root:TestPw123!' | chpasswd && \
    mkdir -p /var/run/sshd && \
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
RUN echo '* soft nofile 65535' >> /etc/security/limits.conf && \
    echo '* hard nofile 65535' >> /etc/security/limits.conf
VOLUME ["/sys/fs/cgroup"]
CMD ["/sbin/init"]
EOF
```

- [ ] **Step 2: Create the control image definition**

```bash
cat > tests/fixtures/Dockerfile.control.e2e <<'EOF'
FROM docker.m.daocloud.io/library/ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
        bash sshpass openssh-client redis-tools coreutils procps \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /repo
CMD ["/bin/bash"]
EOF
```

- [ ] **Step 3: Write the E2E driver**

```bash
cat > scripts/e2e-cluster-config.sh <<'E2EEOF'
#!/usr/bin/env bash
# e2e-cluster-config.sh — two-node Docker validation of cluster-config.sh.
#
# Prerequisite: Redis is already "installed" on both nodes (binaries in
# $REDIS_PREFIX/bin, redis user, directories). That is exactly the contract
# cluster-config.sh expects, so the source build is intentionally skipped —
# compiling Redis needs far more than the 2 vCPU / 2 GB this runs on.
#
# Usage: bash scripts/e2e-cluster-config.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
NET=rc-cfg-net
PASS='E2eClusterPw'
NODE_PW='TestPw123!'
PREFIX=/opt/software/redis

log()  { printf '\n=== %s ===\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

cleanup() {
    docker rm -f e2e-node-a e2e-node-b >/dev/null 2>&1 || true
    docker network rm "$NET"   >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

command -v docker >/dev/null || fail "docker not found"

log "Building images"
docker build -q -f "$REPO_ROOT/tests/fixtures/Dockerfile.node.e2e"   -t rc-e2e-node:local   "$REPO_ROOT" >/dev/null
docker build -q -f "$REPO_ROOT/tests/fixtures/Dockerfile.control.e2e" -t rc-e2e-control:local "$REPO_ROOT" >/dev/null

log "Starting nodes"
docker network create "$NET" >/dev/null
for n in a b; do
    docker rm -f "e2e-node-$n" >/dev/null 2>&1 || true
    docker run -d --name "e2e-node-$n" --network "$NET" --hostname "node-$n" \
        --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
        rc-e2e-node:local >/dev/null
done
sleep 20

A_IP="$(docker run --rm --network "$NET" rc-e2e-control:local \
    getent hosts node-a | awk '{print $1}')"
B_IP="$(docker run --rm --network "$NET" rc-e2e-control:local \
    getent hosts node-b | awk '{print $1}')"
[ -n "$A_IP" ] && [ -n "$B_IP" ] || fail "could not resolve node IPs"
log "node-a=$A_IP node-b=$B_IP"

log "Pre-provisioning nodes (binaries, redis user, directories)"
# NOTE: nodes must be addressed by IP, not hostname — CLUSTER MEET cannot
# resolve container hostnames in this network.
ssh_root() {
    local host="$1"; shift
    docker run --rm --network "$NET" -e SSHPASS="$NODE_PW" rc-e2e-control:local \
        sshpass -e ssh -o StrictHostKeyChecking=no root@"$host" "$@"
}
ssh_root "$A_IP" bash -s >/dev/null <<PRE
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends redis-server redis-tools
mkdir -p $PREFIX/bin $PREFIX/cluster $PREFIX/log /etc/redis/cluster \\
         /var/lib/redis/cluster /var/run/redis/cluster
cp -f "\$(command -v redis-server)" $PREFIX/bin/redis-server
cp -f "\$(command -v redis-cli)"    $PREFIX/bin/redis-cli
id redis >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin redis
systemctl stop redis-server 2>/dev/null || true
systemctl disable redis-server 2>/dev/null || true
chown -R redis:redis /etc/redis /var/lib/redis /var/run/redis $PREFIX/cluster $PREFIX/log
PRE
ssh_root "$B_IP" bash -s >/dev/null <<PRE
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends redis-server redis-tools
mkdir -p $PREFIX/bin $PREFIX/cluster $PREFIX/log /etc/redis/cluster \\
         /var/lib/redis/cluster /var/run/redis/cluster
cp -f "\$(command -v redis-server)" $PREFIX/bin/redis-server
cp -f "\$(command -v redis-cli)"    $PREFIX/bin/redis-cli
id redis >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin redis
systemctl stop redis-server 2>/dev/null || true
systemctl disable redis-server 2>/dev/null || true
chown -R redis:redis /etc/redis /var/lib/redis /var/run/redis $PREFIX/cluster $PREFIX/log
PRE
log "Pre-provisioning done"

log "Writing cluster.conf"
cat > "$WORK/cluster.conf" <<CONF
redis_prefix     = $PREFIX
cluster_password = $PASS
bind_addr        = 0.0.0.0

[node.a]
host     = $A_IP
ssh_port = 22
ports    = 6379,6380,6381

[node.b]
host     = $B_IP
ssh_port = 22
ports    = 6382,6383,6384
CONF

log "Running cluster-config.sh"
docker run --rm --network "$NET" \
    -e PROMPT_NO_TTY=1 \
    -e NODE_A_SSH_USER=root -e NODE_A_HOST="$A_IP" -e NODE_A_SSH_PORT=22 -e NODE_A_SSH_PASS="$NODE_PW" \
    -e NODE_B_SSH_USER=root -e NODE_B_HOST="$B_IP" -e NODE_B_SSH_PORT=22 -e NODE_B_SSH_PASS="$NODE_PW" \
    -v "$REPO_ROOT:/repo" -v "$WORK:/work" \
    rc-e2e-control:local bash -c "bash /repo/cluster-config.sh --config /work/cluster.conf" \
    2>&1 | tee "$WORK/install.log"

grep -q "Redis Cluster READY" "$WORK/install.log" || fail "cluster-config.sh did not print READY"

log "DoD1: all 6 instances PING"
for spec in "$A_IP:6379" "$A_IP:6380" "$A_IP:6381" \
            "$B_IP:6382" "$B_IP:6383" "$B_IP:6384"; do
    out="$(ssh_root "$A_IP" "$PREFIX/bin/redis-cli -a $PASS -h ${spec%:*} -p ${spec#*:} PING" | tr -d '\r')"
    [ "$out" = "PONG" ] || fail "PING $spec -> '$out'"
    echo "  OK $spec"
done

log "DoD2/3: cluster check + info"
ssh_root "$A_IP" "$PREFIX/bin/redis-cli -a $PASS --cluster check $A_IP:6379" | grep -E "All 16384 slots covered"
ssh_root "$A_IP" "$PREFIX/bin/redis-cli -a $PASS -h $A_IP -p 6379 cluster info" \
    | grep -E "cluster_state:ok|cluster_slots_assigned:16384|cluster_known_nodes:6"

log "DoD4: cross-machine read/write"
ssh_root "$A_IP" "$PREFIX/bin/redis-cli -a $PASS -c SET e2e:key from-A" >/dev/null
sleep 1
v="$(ssh_root "$B_IP" "$PREFIX/bin/redis-cli -a $PASS -c GET e2e:key" | tr -d '\r')"
[ "$v" = "from-A" ] || fail "B GET -> '$v'"
echo "  A->B OK"

ssh_root "$B_IP" "$PREFIX/bin/redis-cli -a $PASS -c SET e2e:key2 from-B" >/dev/null
sleep 1
v="$(ssh_root "$A_IP" "$PREFIX/bin/redis-cli -a $PASS -c GET e2e:key2" | tr -d '\r')"
[ "$v" = "from-B" ] || fail "A GET -> '$v'"
echo "  B->A OK"

log "DoD7: idempotent re-run"
docker run --rm --network "$NET" \
    -e PROMPT_NO_TTY=1 \
    -e NODE_A_SSH_USER=root -e NODE_A_HOST="$A_IP" -e NODE_A_SSH_PORT=22 -e NODE_A_SSH_PASS="$NODE_PW" \
    -e NODE_B_SSH_USER=root -e NODE_B_HOST="$B_IP" -e NODE_B_SSH_PORT=22 -e NODE_B_SSH_PASS="$NODE_PW" \
    -v "$REPO_ROOT:/repo" -v "$WORK:/work" \
    rc-e2e-control:local bash -c "bash /repo/cluster-config.sh --config /work/cluster.conf" \
    2>&1 | tee "$WORK/rerun.log"
grep -q "already healthy" "$WORK/rerun.log" || fail "re-run did not skip cluster create"
echo "  idempotency OK"

log "DoD5: kill a master, expect promotion"
victim_id="$(ssh_root "$A_IP" "$PREFIX/bin/redis-cli -a $PASS -h $A_IP -p 6379 cluster nodes" \
    | grep ",$A_IP:6379@" | awk '{print $1}')"
ssh_root "$A_IP" "systemctl stop redis-6379"
promoted=0
for _ in $(seq 1 12); do
    sleep 5
    if ssh_root "$A_IP" "$PREFIX/bin/redis-cli -a $PASS -h $A_IP -p 6380 cluster nodes" \
        | awk -v v="$victim_id" '$1==v && $3 ~ /master/ {found=1} END{exit !found}'; then
        promoted=1
        break
    fi
done
[ "$promoted" -eq 1 ] || fail "replica was not promoted within 60s"
echo "  promotion OK"

ssh_root "$A_IP" "systemctl start redis-6379"
sleep 8
ssh_root "$A_IP" "$PREFIX/bin/redis-cli -a $PASS -h $A_IP -p 6380 cluster info" | grep "cluster_state:ok"

log "E2E PASSED"
E2EEOF
chmod +x scripts/e2e-cluster-config.sh
```

- [ ] **Step 4: Syntax check**

Run: `bash -n scripts/e2e-cluster-config.sh`
Expected: no output.

- [ ] **Step 5: Commit (do not run yet — needs Docker and ~10 minutes)**

```bash
git add scripts/e2e-cluster-config.sh tests/fixtures/Dockerfile.node.e2e tests/fixtures/Dockerfile.control.e2e
git commit -m "test(e2e): docker two-node validation for cluster-config.sh"
```

---

## Task 12: Run the E2E and fix what it finds

**Files:**
- Modify: whatever the E2E exposes

- [ ] **Step 1: Run the E2E**

Run: `bash scripts/e2e-cluster-config.sh`
Expected: ends with `=== E2E PASSED ===`.

If Docker reports insufficient memory, reduce load rather than skipping the
test: the Redis binaries are pre-seeded, so no compilation happens.

- [ ] **Step 2: Fix any failures and re-run**

For each failure, fix the root cause in `cluster-config.sh` (or the harness if
the harness itself is wrong), then re-run until it passes.

- [ ] **Step 3: Confirm the full test suite is green**

Run: `bats tests/lib/*.bats tests/*.bats && bash tests/validate_libs.sh`
Expected: all pass.

- [ ] **Step 4: Commit fixes**

```bash
git add -A
git commit -m "fix(cluster-config): address E2E findings"
```

---

## Task 13: Documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/USAGE.md`

- [ ] **Step 1: Add a cluster-config section to README.md**

Insert before the `## 测试` section:

```markdown
## 集群配置（Redis 已安装）

若两台机器已装好 Redis 二进制、`redis` 用户与目录，可跳过 `install.sh`，
只用配置脚本完成组网：

```bash
cp cluster.conf.example cluster.conf
vim cluster.conf        # 填写 redis_prefix、cluster_password、节点与端口

# 交互式（缺什么问什么）
bash cluster-config.sh

# 或用环境变量免交互
NODE_A_SSH_USER=root NODE_A_HOST=10.0.0.1 NODE_A_SSH_PORT=22 NODE_A_SSH_PASS='...' \
NODE_B_SSH_USER=root NODE_B_HOST=10.0.0.2 NODE_B_SSH_PORT=22 NODE_B_SSH_PASS='...' \
bash cluster-config.sh

# 先看要做什么，不实际执行
bash cluster-config.sh --dry-run
```

环境变量按配置文件的分组名生成：`[node.a]` → `NODE_A_*`，`[node.worker-1]` → `NODE_WORKER_1_*`。
环境变量优先于交互提问；`NODE_<X>_HOST` 可覆盖配置文件里的 host。

**脚本不负责**（需预先准备）：编译安装 Redis、创建 `redis` 用户、创建目录。
脚本只在运行前**校验**它们是否存在，缺失时报错并指出具体项。

**重复执行**会重新渲染并覆盖所有配置，然后重启实例。数据不丢，
已健康的集群不会重建，但实例会短暂重启。
```

- [ ] **Step 2: Add the config reference to docs/USAGE.md**

Append a section documenting the config file format, all keys, defaults, and the
parser's safety guarantee (config content is never executed). Reuse the table
from `cluster.conf.example`.

- [ ] **Step 3: Verify the README snippet is accurate against the script**

Run: `bash cluster-config.sh --help`
Expected: the environment variable naming documented in README matches the
`--help` output exactly.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/USAGE.md
git commit -m "docs: document cluster-config.sh usage and config format"
```

---

## Task 14: Final integration check

**Files:**
- Modify: none

- [ ] **Step 1: Run every test layer**

```bash
bash tests/check_syntax.sh
bats tests/lib/*.bats tests/*.bats
bash tests/validate_libs.sh
```

Expected: `check_syntax.sh` FAIL=0, bats all pass, validate_libs PASS=50 FAIL=0.

- [ ] **Step 2: Verify the file tree**

Run: `find . -type f -not -path './.git/*' -not -path './docs/*' -not -name '*.tar.gz' | sort`

Expected to include (among the existing files):

```
./cluster-config.sh
./cluster.conf.example
./lib/conf.sh
./scripts/e2e-cluster-config.sh
./tests/lib/conf.bats
./tests/lib/preflight.bats
./tests/cluster_config.bats
./tests/cluster_config_render.bats
```

- [ ] **Step 3: Verify no existing script was modified**

Run: `git diff --stat HEAD~13 -- install.sh add-node.sh status.sh uninstall.sh`
Expected: empty output — those files must be untouched by this plan.

- [ ] **Step 4: Check the spec's DoD list**

Walk `docs/superpowers/specs/2026-10-13-redis-cluster-config-script-design.md`
§8 and tick each item with the evidence that satisfies it. Items 8–12 come from
the E2E run; the rest from the unit and contract tests.

- [ ] **Step 5: Commit any remaining cleanup**

```bash
git status --porcelain
git add -A && git commit -m "chore: integration cleanup" || echo "nothing to commit"
```

---

## Acceptance

This plan is complete when:

1. `bash tests/check_syntax.sh` reports `FAIL=0`
2. `bats tests/lib/*.bats tests/*.bats` reports all tests passing
3. `bash tests/validate_libs.sh` reports `PASS=50 FAIL=0`
4. `bash scripts/e2e-cluster-config.sh` prints `E2E PASSED`
5. `install.sh`, `add-node.sh`, `status.sh`, `uninstall.sh` are unmodified
6. Every DoD item in the spec's §8 is satisfied with recorded evidence

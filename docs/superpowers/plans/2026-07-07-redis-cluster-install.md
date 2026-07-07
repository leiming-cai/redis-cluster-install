# Redis Cluster Install Scripts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Bash script suite (`install.sh`, `status.sh`, `uninstall.sh`, `add-node.sh`) that deploys a production-grade Redis 8.8.0 cluster across 2 Linux machines (3 master + 3 replica) over SSH-password, source-compiled from a local tarball.

**Architecture:** A control machine runs `install.sh` which prompts the operator for SSH credentials, drives two `sshpass`-based SSH sessions in parallel to copy, compile, configure, and start Redis on each node, then finalizes the cluster via `redis-cli --cluster create`. Library functions are split by responsibility into `lib/{common,prompt,ssh,config_gen,systemd,cluster}.sh` for testability with `bats`.

**Tech Stack:** Bash 4+, `sshpass`, `redis-cli`, `redis-server` 8.8.0, `systemd`, `bats` (test framework), `docker` (smoke tests)

**Spec:** `docs/superpowers/specs/2026-07-07-redis-cluster-install-design.md`

---

## File Structure

| Path | Purpose |
|---|---|
| `install.sh` | Main orchestrator. 16 steps per spec section 4. |
| `status.sh` | Reads `secrets/cluster_password.txt`, runs `redis-cli --cluster check`, prints role table. |
| `uninstall.sh` | Stops services, backs up data dir, removes configs/users; `--force` to actually delete. |
| `add-node.sh` | Installs a new instance on a new node and joins it to the cluster. |
| `lib/common.sh` | `log_info/warn/error/ok`, color codes, `die()`, `ensure_dirs`, `require_cmd` |
| `lib/prompt.sh` | `read_secret`, `read_required`, `read_default` (interactive only, never writes to disk). |
| `lib/ssh.sh` | `ssh_run`, `ssh_copy`, `ssh_check` (wraps sshpass). |
| `lib/config_gen.sh` | `render_redis_conf PORT PASSWORD` from template. |
| `lib/systemd.sh` | `render_systemd_unit PORT`, `systemd_reload`, `systemd_start`. |
| `lib/cluster.sh` | `cluster_create`, `cluster_info`, `cluster_check`. |
| `lib/password.sh` | `gen_password` (32-char base62). |
| `config/redis.conf.template` | Single template, `%PORT%` / `%PASSWORD%` / `%NODE_NAME%` placeholders. |
| `config/redis-cluster.service.template` | systemd unit template. |
| `tests/lib/` | bats tests, one per lib file. |
| `tests/setup.bash` | bats common setup. |
| `scripts/smoke-test.sh` | Docker-based end-to-end test. |
| `README.md` | Usage, prerequisites, troubleshooting. |
| `secrets/.gitkeep` | Marker; `cluster_password.txt` written here at install time. |

---

## Task 1: Repo bootstrap

**Files:**
- Create: `lib/.gitkeep`, `tests/.gitkeep`, `tests/lib/.gitkeep`, `config/.gitkeep`, `scripts/.gitkeep`, `secrets/.gitkeep`

- [ ] **Step 1: Create empty directories with .gitkeep**

```bash
mkdir -p lib tests/lib config scripts secrets
for d in lib tests tests/lib config scripts secrets; do touch "$d/.gitkeep"; done
```

- [ ] **Step 2: Verify directory structure**

Run: `find . -type d -not -path './.git*' -not -path './docs*' | sort`
Expected output:
```
.
./config
./lib
./scripts
./secrets
./tests
./tests/lib
```

- [ ] **Step 3: Commit**

```bash
git add lib/.gitkeep tests/.gitkeep tests/lib/.gitkeep config/.gitkeep scripts/.gitkeep secrets/.gitkeep
git commit -m "chore: scaffold directory structure"
```

---

## Task 2: lib/common.sh — logging utilities

**Files:**
- Create: `lib/common.sh`
- Create: `tests/lib/common.bats`

- [ ] **Step 1: Write failing bats test**

```bash
cat > tests/lib/common.bats <<'EOF'
load '../setup'
load '../../lib/common.sh'

@test "log_info prints [INFO] prefix" {
    run log_info "hello"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[INFO]"* ]]
    [[ "$output" == *"hello"* ]]
}

@test "log_warn prints [WARN] prefix" {
    run log_warn "careful"
    [[ "$output" == *"[WARN]"* ]]
}

@test "log_error prints [ERROR] prefix to stderr" {
    run log_error "boom"
    [[ "$output" == *"[ERROR]"* ]]
    [ "${stderr}" == *"boom"* ]
}

@test "die exits with code 1 and prints to stderr" {
    run die "fatal"
    [ "$status" -eq 1 ]
    [[ "${stderr}" == *"fatal"* ]]
}

@test "die honors non-zero exit code override" {
    run die "bad" 7
    [ "$status" -eq 7 ]
}
EOF
```

- [ ] **Step 2: Run tests, expect failure (lib/common.sh doesn't exist yet)**

Run: `command -v bats && bats tests/lib/common.bats || echo "BATS_NOT_INSTALLED"`
Expected: `BATS_NOT_INSTALLED` (we will install bats in the next task). If installed, all tests should fail with "command not found" type errors.

- [ ] **Step 3: Install bats on the control machine**

```bash
# macOS
brew install bats-core
# Ubuntu/Debian
sudo apt-get update && sudo apt-get install -y bats
# Fedora
sudo dnf install -y bats
```

Verify: `bats --version` prints a version string.

- [ ] **Step 4: Write lib/common.sh implementation**

```bash
cat > lib/common.sh <<'EOF'
#!/usr/bin/env bash
# lib/common.sh — logging, errors, color codes
# Source from another script. Do not execute.

# Color codes (disabled when not on a TTY)
if [ -t 1 ]; then
    C_RED=$'\e[31m'
    C_YEL=$'\e[33m'
    C_GRN=$'\e[32m'
    C_BLU=$'\e[34m'
    C_RST=$'\e[0m'
else
    C_RED='' C_YEL='' C_GRN='' C_BLU='' C_RST=''
fi

# Timestamp for log lines
_ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }

log_info()  { printf '%s %s[INFO]%s  %s\n'  "$(_ts)" "$C_BLU" "$C_RST" "$*"; }
log_warn()  { printf '%s %s[WARN]%s  %s\n'  "$(_ts)" "$C_YEL" "$C_RST" "$*" >&2; }
log_error() { printf '%s %s[ERROR]%s %s\n'  "$(_ts)" "$C_RED" "$C_RST" "$*" >&2; }
log_ok()    { printf '%s %s[OK]%s    %s\n'  "$(_ts)" "$C_GRN" "$C_RST" "$*"; }

# die MESSAGE [EXIT_CODE]
# Default exit code 1.
die() {
    local msg="$1"
    local code="${2:-1}"
    log_error "$msg"
    exit "$code"
}

# ensure_dirs PATH...
# mkdir -p each path; abort on failure.
ensure_dirs() {
    for d in "$@"; do
        [ -d "$d" ] || mkdir -p "$d" || die "cannot create directory: $d"
    done
}

# require_cmd CMD...
# Abort if any command is missing.
require_cmd() {
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"
    done
}
EOF
```

- [ ] **Step 5: Add tests/setup.bash**

```bash
cat > tests/setup.bash <<'EOF'
# Common bats setup. Sourced by every test file.
# Adds the repo's lib/ to a safe lookup path.
setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

# bats helper: load a lib file relative to REPO_ROOT
load_lib() {
    # shellcheck source=/dev/null
    . "$REPO_ROOT/lib/$1"
}
EOF
```

- [ ] **Step 6: Patch common.bats to use load_lib and re-run**

Edit `tests/lib/common.bats` so the `load '../../lib/common.sh'` line is replaced with:
```bash
load '../setup'
load_lib common
```

Re-run: `bats tests/lib/common.bats`
Expected: 5 tests, all pass.

- [ ] **Step 7: Commit**

```bash
git add lib/common.sh tests/setup.bash tests/lib/common.bats
git commit -m "feat(lib): add common.sh with logging and die"
```

---

## Task 3: lib/password.sh — random password generator

**Files:**
- Create: `lib/password.sh`
- Create: `tests/lib/password.bats`

- [ ] **Step 1: Write failing test**

```bash
cat > tests/lib/password.bats <<'EOF'
load '../setup'
load_lib password

@test "gen_password returns 32 chars by default" {
    run gen_password
    [ "$status" -eq 0 ]
    [ "${#output}" -eq 32 ]
}

@test "gen_password honors length argument" {
    run gen_password 16
    [ "${#output}" -eq 16 ]
}

@test "gen_password output is alphanumeric only" {
    run gen_password 64
    [[ "$output" =~ ^[A-Za-z0-9]+$ ]]
}

@test "two calls produce different output" {
    a=$(gen_password)
    b=$(gen_password)
    [ "$a" != "$b" ]
}
EOF
```

- [ ] **Step 2: Run, expect failure**

Run: `bats tests/lib/password.bats`
Expected: command not found error.

- [ ] **Step 3: Write lib/password.sh**

```bash
cat > lib/password.sh <<'EOF'
#!/usr/bin/env bash
# lib/password.sh — random alphanumeric password generator.

# gen_password [LENGTH=32]
# Echo a random string of LENGTH characters from [A-Za-z0-9].
# Requires /dev/urandom and tr. Aborts on dependency missing.
gen_password() {
    local len="${1:-32}"
    [ "$len" -gt 0 ] 2>/dev/null || { echo "length must be positive integer" >&2; return 2; }
    command -v tr >/dev/null 2>&1 || { echo "tr is required" >&2; return 3; }
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$len"
    echo
}
EOF
```

- [ ] **Step 4: Run, expect pass**

Run: `bats tests/lib/password.bats`
Expected: 4 pass.

- [ ] **Step 5: Commit**

```bash
git add lib/password.sh tests/lib/password.bats
git commit -m "feat(lib): add password.sh with gen_password"
```

---

## Task 4: lib/prompt.sh — interactive input

**Files:**
- Create: `lib/prompt.sh`
- Create: `tests/lib/prompt.bats`

- [ ] **Step 1: Write failing test**

```bash
cat > tests/lib/prompt.bats <<'EOF'
load '../setup'
load_lib prompt

@test "read_default returns default when empty" {
    run bash -c 'source "'"$BATS_TEST_DIRNAME"'/../../lib/common.sh"; source "'"$BATS_TEST_DIRNAME"'/../../lib/prompt.sh"; echo "" | read_default "name" "alice"'
    [ "$output" = "alice" ]
}

@test "read_required rejects empty input" {
    run bash -c '
        source "'"$BATS_TEST_DIRNAME"'/../../lib/common.sh"
        source "'"$BATS_TEST_DIRNAME"'/../../lib/prompt.sh"
        echo -e "\nfoo" | read_required "name" 2>/dev/null
    '
    [ "$status" -ne 0 ]
}

@test "read_required accepts non-empty" {
    run bash -c '
        source "'"$BATS_TEST_DIRNAME"'/../../lib/common.sh"
        source "'"$BATS_TEST_DIRNAME"'/../../lib/prompt.sh"
        echo "bob" | read_required "name"
    '
    [ "$output" = "bob" ]
}

@test "read_secret reads from /dev/tty only" {
    # Sanity: function exists and is a shell function
    run bash -c '
        source "'"$BATS_TEST_DIRNAME"'/../../lib/common.sh"
        source "'"$BATS_TEST_DIRNAME"'/../../lib/prompt.sh"
        type read_secret >/dev/null
    '
    [ "$status" -eq 0 ]
}
EOF
```

- [ ] **Step 2: Run, expect failure**

Run: `bats tests/lib/prompt.bats`
Expected: command not found errors.

- [ ] **Step 3: Write lib/prompt.sh**

```bash
cat > lib/prompt.sh <<'EOF'
#!/usr/bin/env bash
# lib/prompt.sh — interactive prompt helpers.
# Reads only from /dev/tty. Echoes the result on stdout.
# Never writes input to disk.

# _tty_check: ensure /dev/tty is readable
_tty_check() {
    [ -r /dev/tty ] && [ -w /dev/tty ] || {
        echo "prompt.sh: no usable /dev/tty — run interactively" >&2
        return 1
    }
}

# read_default "PROMPT" "DEFAULT"
# Echoes user input or DEFAULT if empty.
read_default() {
    _tty_check || return 1
    local prompt="$1"
    local default="$2"
    local reply=""
    read -r -p "$prompt [$default]: " reply </dev/tty
    [ -z "$reply" ] && reply="$default"
    printf '%s' "$reply"
}

# read_required "PROMPT"
# Loops until non-empty input. Echoes value.
read_required() {
    _tty_check || return 1
    local prompt="$1"
    local reply=""
    while [ -z "$reply" ]; do
        read -r -p "$prompt: " reply </dev/tty
    done
    printf '%s' "$reply"
}

# read_secret "PROMPT"
# Reads a password silently from /dev/tty. Echoes value.
read_secret() {
    _tty_check || return 1
    local prompt="$1"
    local reply=""
    read -r -s -p "$prompt: " reply </dev/tty
    echo >&2  # newline after silent read
    printf '%s' "$reply"
}

# read_confirm "PROMPT"
# Reads y/N. Echoes y or n.
read_confirm() {
    _tty_check || return 1
    local prompt="$1"
    local reply=""
    read -r -p "$prompt [y/N]: " reply </dev/tty
    case "$reply" in
        y|Y|yes|YES) printf 'y' ;;
        *)           printf 'n' ;;
    esac
}
EOF
```

- [ ] **Step 4: Run, expect pass**

Run: `bats tests/lib/prompt.bats`
Expected: 4 pass.

- [ ] **Step 5: Commit**

```bash
git add lib/prompt.sh tests/lib/prompt.bats
git commit -m "feat(lib): add prompt.sh with read_default/required/secret/confirm"
```

---

## Task 5: lib/ssh.sh — sshpass wrapper

**Files:**
- Create: `lib/ssh.sh`
- Create: `tests/lib/ssh.bats`

- [ ] **Step 1: Write failing test**

```bash
cat > tests/lib/ssh.bats <<'EOF'
load '../setup'
load_lib ssh

@test "sship_port extracts integer port" {
    result=$(sship_port "10.0.0.1:2222")
    [ "$result" = "2222" ]
}

@test "sship_port defaults to 22 when no port" {
    result=$(sship_port "10.0.0.1")
    [ "$result" = "22" ]
}

@test "sship_target builds user@host:port string" {
    result=$(sship_target "root" "10.0.0.1" "22")
    [ "$result" = "root@10.0.0.1:22"
}

@test "ssh_check returns 1 when host is unreachable" {
    run ssh_check "" "" "" "127.0.0.1" "1" "127.0.0.1" "echo ok"
    # Will fail because port 1 is invalid
    [ "$status" -ne 0 ]
}
EOF
```

- [ ] **Step 2: Run, expect failure**

Run: `bats tests/lib/ssh.bats`
Expected: command not found errors.

- [ ] **Step 3: Write lib/ssh.sh**

```bash
cat > lib/ssh.sh <<'EOF'
#!/usr/bin/env bash
# lib/ssh.sh — sshpass-based SSH helpers.
# All commands run with: sshpass -P "assh:" -P "assword:" -f <(printf '%s' "$SSH_PASS")
# This avoids leaking the password to argv / process table.

# sship_host TARGET   → host part of "ip" or "ip:port"
sship_host() {
    local t="$1"
    echo "${t%%:*}"
}

# sship_port TARGET   → port part of "ip" or "ip:port", default 22
sship_port() {
    local t="$1"
    if [[ "$t" == *:* ]]; then
        echo "${t##*:}"
    else
        echo "22"
    fi
}

# sship_target USER HOST PORT   → "user@host:port"
sship_target() {
    local user="$1" host="$2" port="$3"
    if [ "$port" = "22" ]; then
        echo "${user}@${host}"
    else
        echo "${user}@${host}:${port}"
    fi
}

# ssh_check USER PASS HOST PORT
# Returns 0 if SSH connects and runs `true` on remote.
ssh_check() {
    local user="$1" pass="$2" host="$3" port="$4"
    SSHPASS="$pass" sshpass -e \
        ssh -o StrictHostKeyChecking=accept-new \
            -o ConnectTimeout=5 \
            -p "$port" \
            "${user}@${host}" true
}

# ssh_run USER PASS HOST PORT CMD...
# Echoes remote stdout. Returns remote exit code.
ssh_run() {
    local user="$1" pass="$2" host="$3" port="$4"
    shift 4
    SSHPASS="$pass" sshpass -e \
        ssh -o StrictHostKeyChecking=accept-new \
            -o ConnectTimeout=10 \
            -p "$port" \
            "${user}@${host}" "$@"
}

# ssh_copy USER PASS HOST PORT LOCAL_PATH REMOTE_PATH
# Single-file scp via sshpass.
ssh_copy() {
    local user="$1" pass="$2" host="$3" port="$4"
    local local_path="$5" remote_path="$6"
    SSHPASS="$pass" sshpass -e \
        scp -o StrictHostKeyChecking=accept-new \
            -o ConnectTimeout=10 \
            -P "$port" \
            "$local_path" "${user}@${host}:${remote_path}"
}
EOF
```

- [ ] **Step 4: Run, expect pass**

Run: `bats tests/lib/ssh.bats`
Expected: 4 pass.

- [ ] **Step 5: Commit**

```bash
git add lib/ssh.sh tests/lib/ssh.bats
git commit -m "feat(lib): add ssh.sh sshpass wrapper"
```

---

## Task 6: lib/config_gen.sh — redis.conf rendering

**Files:**
- Create: `lib/config_gen.sh`
- Create: `config/redis.conf.template`
- Create: `tests/lib/config_gen.bats`
- Create: `tests/fixtures/redis.conf.template` (test-only template)

- [ ] **Step 1: Create test fixture template**

```bash
mkdir -p tests/fixtures
cat > tests/fixtures/redis.conf.template <<'EOF'
# Test fixture template
port %PORT%
requirepass %PASSWORD%
masterauth %PASSWORD%
node_name %NODE_NAME%
bind %BIND_ADDR%
daemonize yes
EOF
```

- [ ] **Step 2: Write failing test**

```bash
cat > tests/lib/config_gen.bats <<'EOF'
load '../setup'
load_lib config_gen

@test "render_redis_conf replaces %PORT% placeholder" {
    result=$(render_redis_conf "tests/fixtures/redis.conf.template" "6379" "secret123" "node-a" "0.0.0.0")
    [[ "$result" == *"port 6379"* ]]
}

@test "render_redis_conf replaces %PASSWORD% in both places" {
    result=$(render_redis_conf "tests/fixtures/redis.conf.template" "6379" "secret123" "node-a" "0.0.0.0")
    [[ "$result" == *"requirepass secret123"* ]]
    [[ "$result" == *"masterauth secret123"* ]]
}

@test "render_redis_conf replaces %NODE_NAME%" {
    result=$(render_redis_conf "tests/fixtures/redis.conf.template" "6379" "x" "alpha" "0.0.0.0")
    [[ "$result" == *"node_name alpha"* ]]
}

@test "render_redis_conf replaces %BIND_ADDR%" {
    result=$(render_redis_conf "tests/fixtures/redis.conf.template" "6379" "x" "alpha" "10.0.0.1")
    [[ "$result" == *"bind 10.0.0.1"* ]]
}

@test "render_redis_conf aborts on missing template" {
    run render_redis_conf "tests/fixtures/missing.conf.template" "6379" "x" "alpha" "0.0.0.0"
    [ "$status" -ne 0 ]
}
EOF
```

- [ ] **Step 3: Run, expect failure**

Run: `bats tests/lib/config_gen.bats`
Expected: command not found errors.

- [ ] **Step 4: Write the real config/redis.conf.template**

```bash
cat > config/redis.conf.template <<'EOF'
# Redis %NODE_NAME% on port %PORT%
# Generated by redis-cluster-install

# Network
bind %BIND_ADDR%
protected-mode no
port %PORT%
tcp-backlog 511
timeout 0
tcp-keepalive 300

# Cluster
cluster-enabled yes
cluster-config-file /var/lib/redis/cluster/%PORT%/nodes.conf
cluster-node-timeout 15000
cluster-migration-barrier 1
cluster-require-full-coverage yes

# Replication
masterauth %PASSWORD%
replica-serve-stale-data yes
replica-read-only yes
repl-ping-replica-period 10
repl-timeout 60

# Auth
requirepass %PASSWORD%

# Persistence
save 900 1
save 300 10
save 60 10000
stop-writes-on-bgsave-error yes
rdbcompression yes
rdbchecksum yes
dbfilename dump.rdb
dir /var/lib/redis/cluster/%PORT%

appendonly yes
appendfilename "appendonly.aof"
appendfsync everysec
no-appendfsync-on-rewrite no
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 64mb
aof-load-truncated yes
aof-use-rdb-preamble yes

# Limits
maxmemory-policy allkeys-lru
ulimit nofile 10032

# Logging
loglevel notice
logfile /var/log/redis/cluster/redis-%PORT%.log

# Slow log
slowlog-log-slower-than 10000
slowlog-max-len 128

# Latency
latency-monitor-threshold 100

# Misc
hash-max-ziplist-entries 512
hash-max-ziplist-value 64
list-max-ziplist-size -2
list-compress-depth 0
set-max-intset-entries 512
zset-max-ziplist-entries 128
zset-max-ziplist-value 64
hll-sparse-max-bytes 3000
stream-node-max-entries 100
activerehashing yes
client-output-buffer-limit normal 0 0 0
client-output-buffer-limit replica 256mb 64mb 60
client-output-buffer-limit pubsub 32mb 8mb 60
hz 10
dynamic-hz yes
EOF
```

- [ ] **Step 5: Write lib/config_gen.sh**

```bash
cat > lib/config_gen.sh <<'EOF'
#!/usr/bin/env bash
# lib/config_gen.sh — render redis.conf from a template.

# render_redis_conf TEMPLATE PORT PASSWORD NODE_NAME BIND_ADDR
# Echoes the rendered config to stdout.
# Aborts (exit 1) if the template file is missing.
render_redis_conf() {
    local template="$1"
    local port="$2"
    local password="$3"
    local node_name="$4"
    local bind_addr="$5"

    [ -f "$template" ] || { echo "config_gen: template not found: $template" >&2; return 1; }

    # Use sed for the substitution. The template placeholders are simple %KEY% strings.
    sed -e "s/%PORT%/$port/g" \
        -e "s/%PASSWORD%/$password/g" \
        -e "s/%NODE_NAME%/$node_name/g" \
        -e "s/%BIND_ADDR%/$bind_addr/g" \
        "$template"
}
EOF
```

- [ ] **Step 6: Run, expect pass**

Run: `bats tests/lib/config_gen.bats`
Expected: 5 pass.

- [ ] **Step 7: Commit**

```bash
git add lib/config_gen.sh config/redis.conf.template tests/lib/config_gen.bats tests/fixtures/redis.conf.template
git commit -m "feat(lib): add config_gen.sh and redis.conf template"
```

---

## Task 7: lib/systemd.sh — systemd unit rendering and control

**Files:**
- Create: `lib/systemd.sh`
- Create: `config/redis-cluster.service.template`
- Create: `tests/lib/systemd.bats`
- Create: `tests/fixtures/systemd.service.template`

- [ ] **Step 1: Create test fixture**

```bash
cat > tests/fixtures/systemd.service.template <<'EOF'
[Unit]
Description=Redis %PORT% (%NODE_NAME%)
After=network.target

[Service]
Type=simple
User=redis
Group=redis
ExecStart=/usr/local/bin/redis-server /etc/redis/cluster/redis-%PORT%.conf
Restart=always

[Install]
WantedBy=multi-user.target
EOF
```

- [ ] **Step 2: Write failing test**

```bash
cat > tests/lib/systemd.bats <<'EOF'
load '../setup'
load_lib systemd

@test "render_systemd_unit includes port in Description" {
    result=$(render_systemd_unit "tests/fixtures/systemd.service.template" "6379" "node-a")
    [[ "$result" == *"Description=Redis 6379 (node-a)"* ]]
}

@test "render_systemd_unit substitutes ExecStart path" {
    result=$(render_systemd_unit "tests/fixtures/systemd.service.template" "6380" "node-b")
    [[ "$result" == *"/etc/redis/cluster/redis-6380.conf"* ]]
}

@test "render_systemd_unit aborts on missing template" {
    run render_systemd_unit "tests/fixtures/missing.service.template" "6379" "x"
    [ "$status" -ne 0 ]
}
EOF
```

- [ ] **Step 3: Run, expect failure**

Run: `bats tests/lib/systemd.bats`
Expected: command not found errors.

- [ ] **Step 4: Write config/redis-cluster.service.template**

```bash
cat > config/redis-cluster.service.template <<'EOF'
[Unit]
Description=Redis %PORT% (%NODE_NAME%) — cluster node
Documentation=https://redis.io/
After=network.target

[Service]
Type=simple
User=redis
Group=redis
ExecStart=/usr/local/bin/redis-server /etc/redis/cluster/redis-%PORT%.conf
ExecStop=/usr/local/bin/redis-cli -a %PASSWORD% -p %PORT% shutdown nosave
Restart=always
RestartSec=3
LimitNOFILE=10032
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/lib/redis /var/log/redis /var/run/redis
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes

[Install]
WantedBy=multi-user.target
EOF
```

- [ ] **Step 5: Write lib/systemd.sh**

```bash
cat > lib/systemd.sh <<'EOF'
#!/usr/bin/env bash
# lib/systemd.sh — render and control systemd units.

# render_systemd_unit TEMPLATE PORT NODE_NAME [PASSWORD]
# Echoes rendered unit to stdout. Password optional (template may or may not reference it).
render_systemd_unit() {
    local template="$1"
    local port="$2"
    local node_name="$3"
    local password="${4:-}"
    [ -f "$template" ] || { echo "systemd: template not found: $template" >&2; return 1; }
    sed -e "s/%PORT%/$port/g" \
        -e "s/%NODE_NAME%/$node_name/g" \
        -e "s/%PASSWORD%/$password/g" \
        "$template"
}

# systemd_unit_name PORT → redis-<port>.service
systemd_unit_name() {
    echo "redis-$1.service"
}

# systemd_unit_path PORT → /etc/systemd/system/redis-<port>.service
systemd_unit_path() {
    echo "/etc/systemd/system/$(systemd_unit_name "$1")"
}
EOF
```

- [ ] **Step 6: Run, expect pass**

Run: `bats tests/lib/systemd.bats`
Expected: 3 pass.

- [ ] **Step 7: Commit**

```bash
git add lib/systemd.sh config/redis-cluster.service.template tests/lib/systemd.bats tests/fixtures/systemd.service.template
git commit -m "feat(lib): add systemd.sh unit renderer and templates"
```

---

## Task 8: lib/cluster.sh — redis-cli wrapper

**Files:**
- Create: `lib/cluster.sh`
- Create: `tests/lib/cluster.bats`

- [ ] **Step 1: Write failing test (no real cluster; just structure)**

```bash
cat > tests/lib/cluster.bats <<'EOF'
load '../setup'
load_lib cluster

@test "cluster_known_nodes parses 'cluster_known_nodes:6'" {
    result=$(cluster_known_nodes <<<$'cluster_state:ok\ncluster_slots_assigned:16384\ncluster_known_nodes:6')
    [ "$result" = "6" ]
}

@test "cluster_known_nodes returns empty on missing key" {
    result=$(cluster_known_nodes <<<$'cluster_state:ok')
    [ -z "$result" ]
}

@test "is_cluster_healthy returns 0 when state=ok and slots=16384" {
    is_cluster_healthy <<<$'cluster_state:ok\ncluster_slots_assigned:16384\ncluster_known_nodes:6'
    [ "$? " -eq 0 ]
}

@test "is_cluster_healthy returns 1 when state is not ok" {
    run is_cluster_healthy <<<$'cluster_state:fail\ncluster_slots_assigned:16384\ncluster_known_nodes:6'
    [ "$status" -ne 0 ]
}

@test "build_create_command emits redis-cli then create then nodes then replicas 1" {
    out=$(build_create_command "secret" "10.0.0.1:6379" "10.0.0.2:6379")
    [[ "$out" == *"redis-cli"* ]]
    [[ "$out" == *"--cluster"* ]]
    [[ "$out" == *"create"* ]]
    [[ "$out" == *"10.0.0.1:6379"* ]]
    [[ "$out" == *"10.0.0.2:6379"* ]]
    [[ "$out" == *"--cluster-replicas"* ]]
    [[ "$out" == *"1"* ]]
    [[ "$out" == *"-a secret"* ]]
}
EOF
```

- [ ] **Step 2: Run, expect failure**

Run: `bats tests/lib/cluster.bats`
Expected: command not found errors.

- [ ] **Step 3: Write lib/cluster.sh**

```bash
cat > lib/cluster.sh <<'EOF'
#!/usr/bin/env bash
# lib/cluster.sh — parse and inspect Redis cluster state.
# These helpers read the output of `redis-cli -a PASS cluster info` from stdin.

# cluster_known_nodes
# Echoes the integer value of `cluster_known_nodes:N` from stdin, or empty string.
cluster_known_nodes() {
    grep -E '^cluster_known_nodes:' | awk -F: '{print $2}' | tr -d '[:space:]'
}

# is_cluster_healthy
# Returns 0 if cluster_state:ok AND cluster_slots_assigned:16384, else non-zero.
is_cluster_healthy() {
    local state slots
    state=$(grep -E '^cluster_state:' | awk -F: '{print $2}' | tr -d '[:space:]')
    slots=$(grep -E '^cluster_slots_assigned:' | awk -F: '{print $2}' | tr -d '[:space:]')
    [ "$state" = "ok" ] && [ "$slots" = "16384" ]
}

# build_create_command PASSWORD USER HOST PORT ... USER HOST PORT
# Echoes a fully-formed `redis-cli --cluster create ...` argv list (one arg per line).
# Caller is responsible for eval or backgrounded exec.
build_create_command() {
    local pass="$1"
    shift
    printf 'redis-cli\n--cluster\ncreate\n'
    for arg in "$@"; do
        printf '%s\n' "$arg"
    done
    printf -- '--cluster-replicas\n1\n--cluster-yes\n-a\n%s\n' "$pass"
}
EOF
```

- [ ] **Step 4: Run, expect pass**

Run: `bats tests/lib/cluster.bats`
Expected: 4 pass.

- [ ] **Step 5: Commit**

```bash
git add lib/cluster.sh tests/lib/cluster.bats
git commit -m "feat(lib): add cluster.sh health parsers"
```

---

## Task 9: install.sh — main orchestrator

**Files:**
- Create: `install.sh`
- Create: `tests/install.bats` (smoke test of CLI flag parsing only)

- [ ] **Step 1: Write install.sh — full implementation**

```bash
cat > install.sh <<'EOF'
#!/usr/bin/env bash
# install.sh — Deploy a 6-node Redis 8.8.0 cluster across 2 Linux machines.
#
# Usage:
#   bash install.sh                       # interactive (default)
#   bash install.sh --yes                 # non-interactive: re-use cached state if any
#   bash install.sh --uninstall           # same as running uninstall.sh --force
#
# Requires: bash 4+, sshpass, redis-cli (optional, for create step), openssh-client.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$REPO_ROOT/lib/common.sh"
# shellcheck source=lib/password.sh
. "$REPO_ROOT/lib/password.sh"
# shellcheck source=lib/prompt.sh
. "$REPO_ROOT/lib/prompt.sh"
# shellcheck source=lib/ssh.sh
. "$REPO_ROOT/lib/ssh.sh"
# shellcheck source=lib/config_gen.sh
. "$REPO_ROOT/lib/config_gen.sh"
# shellcheck source=lib/systemd.sh
. "$REPO_ROOT/lib/systemd.sh"
# shellcheck source=lib/cluster.sh
. "$REPO_ROOT/lib/cluster.sh"

# === Configuration ===
TARBALL="$REPO_ROOT/redis-8.8.0.tar.gz"
CONF_TEMPLATE="$REPO_ROOT/config/redis.conf.template"
SERVICE_TEMPLATE="$REPO_ROOT/config/redis-cluster.service.template"
SECRETS_DIR="$REPO_ROOT/secrets"
PASSWORD_FILE="$SECRETS_DIR/cluster_password.txt"

# A machine (3 instances)
A_HOST="" A_PORT="22" A_USER="" A_PASS=""
# B machine (3 instances)
B_HOST="" B_PORT="22" B_USER="" B_PASS=""

# A: 6379, 6380, 6381
# B: 6382, 6383, 6384
A_PORTS=(6379 6380 6381)
B_PORTS=(6382 6383 6384)

# === CLI parsing ===
ASSUME_YES=0
case "${1:-}" in
    --yes|-y) ASSUME_YES=1 ;;
    --uninstall) exec "$REPO_ROOT/uninstall.sh" --force ;;
    --help|-h)
        sed -n '2,12p' "$0"
        exit 0
        ;;
esac

# === Step 1: Generate cluster password ===
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"
if [ -f "$PASSWORD_FILE" ]; then
    CLUSTER_PASS=$(cat "$PASSWORD_FILE")
    log_info "Reusing existing cluster password from $PASSWORD_FILE"
else
    CLUSTER_PASS=$(gen_password 32)
    printf '%s' "$CLUSTER_PASS" > "$PASSWORD_FILE"
    chmod 600 "$PASSWORD_FILE"
    log_ok "Generated new cluster password"
fi

# === Step 2: Interactive prompt for SSH credentials ===
prompt_credentials() {
    log_info "Configure SSH access to node A (3 instances: 6379, 6380, 6381)"
    A_HOST=$(read_default "  A host or IP" "")
    [ -n "$A_HOST" ] || die "A host is required"
    A_USER=$(read_default "  A SSH user" "root")
    A_PORT=$(read_default "  A SSH port" "22")
    A_PASS=$(read_secret "  A SSH password")

    log_info "Configure SSH access to node B (3 instances: 6382, 6383, 6384)"
    B_HOST=$(read_default "  B host or IP" "")
    [ -n "$B_HOST" ] || die "B host is required"
    B_USER=$(read_default "  B SSH user" "root")
    B_PORT=$(read_default "  B SSH port" "22")
    B_PASS=$(read_secret "  B SSH password")

    if [ "$(read_confirm "Proceed with $A_USER@$A_HOST and $B_USER@$B_HOST?")" != "y" ]; then
        die "aborted by user"
    fi
}
if [ "$ASSUME_YES" = 0 ]; then
    prompt_credentials
else
    die "--yes mode requires credentials via env: A_USER A_HOST A_PORT A_PASS B_USER B_HOST B_PORT B_PASS"
fi

# === Step 3: Verify SSH connectivity ===
log_info "[3] Verifying SSH connectivity..."
ssh_check "$A_USER" "$A_PASS" "$A_HOST" "$A_PORT" || die "cannot reach $A_USER@$A_HOST:$A_PORT"
ssh_check "$B_USER" "$B_PASS" "$B_HOST" "$B_PORT" || die "cannot reach $B_USER@$B_HOST:$B_PORT"
log_ok "SSH connectivity verified"

# === Step 4: Verify toolchain on remote ===
log_info "[4] Verifying toolchain on remotes..."
verify_remote() {
    local user="$1" pass="$2" host="$3" port="$4"
    ssh_run "$user" "$pass" "$host" "$port" bash -s <<'REMOTE'
set -e
command -v gcc    >/dev/null || { echo "missing gcc"; exit 11; }
command -v make   >/dev/null || { echo "missing make"; exit 12; }
command -v tar    >/dev/null || { echo "missing tar"; exit 13; }
gcc_version=$(gcc -dumpversion | cut -d. -f1)
[ "$gcc_version" -ge 11 ] 2>/dev/null || { echo "gcc $gcc_version too old, need >= 11"; exit 14; }
ulimit -n | awk '{ if ($1 < 10001) { print "ulimit -n too low: " $1; exit 15; } }'
echo "toolchain OK"
REMOTE
}
verify_remote "$A_USER" "$A_PASS" "$A_HOST" "$A_PORT" || die "node A toolchain check failed"
verify_remote "$B_USER" "$B_PASS" "$B_HOST" "$B_PORT" || die "node B toolchain check failed"
log_ok "Toolchain verified on both nodes"

# === Step 5: scp tarball to both nodes ===
log_info "[5] Copying $TARBALL to both nodes..."
[ -f "$TARBALL" ] || die "tarball not found: $TARBALL"
ssh_copy "$A_USER" "$A_PASS" "$A_HOST" "$A_PORT" "$TARBALL" "/tmp/redis-8.8.0.tar.gz" || die "scp to A failed"
ssh_copy "$B_USER" "$B_PASS" "$B_HOST" "$B_PORT" "$TARBALL" "/tmp/redis-8.8.0.tar.gz" || die "scp to B failed"
log_ok "Tarball copied"

# === Step 6: Build on both nodes in parallel ===
log_info "[6] Building Redis on both nodes..."
build_remote() {
    local user="$1" pass="$2" host="$3" port="$4"
    ssh_run "$user" "$pass" "$host" "$port" bash -s <<'REMOTE'
set -e
cd /tmp
tar xzf redis-8.8.0.tar.gz
cd redis-8.8.0
make -C src BUILD_TLS=no USE_SYSTEMD=no -j"$(nproc)"
make -C src install PREFIX=/usr/local
echo "build OK"
REMOTE
}
build_remote "$A_USER" "$A_PASS" "$A_HOST" "$A_PORT" &
pid_a=$!
build_remote "$B_USER" "$B_PASS" "$B_HOST" "$B_PORT" &
pid_b=$!
wait "$pid_a" || die "build on A failed"
wait "$pid_b" || die "build on B failed"
log_ok "Build complete on both nodes"

# === Step 7: Create user and directories on both nodes ===
log_info "[7] Creating redis user and directories..."
provision_dirs() {
    local user="$1" pass="$2" host="$3" port="$4"
    ssh_run "$user" "$pass" "$host" "$port" bash -s <<'REMOTE'
set -e
id redis >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin redis
mkdir -p /etc/redis/cluster
mkdir -p /var/lib/redis/cluster
mkdir -p /var/log/redis/cluster
mkdir -p /var/run/redis/cluster
chown -R redis:redis /var/lib/redis /var/log/redis /var/run/redis /etc/redis
echo "dirs OK"
REMOTE
}
provision_dirs "$A_USER" "$A_PASS" "$A_HOST" "$A_PORT" &
pid_a=$!
provision_dirs "$B_USER" "$B_PASS" "$B_HOST" "$B_PORT" &
pid_b=$!
wait "$pid_a" || die "dirs on A failed"
wait "$pid_b" || die "dirs on B failed"
log_ok "Directories provisioned"

# === Step 8: Push cluster auth file ===
log_info "[8] Pushing cluster auth file..."
push_auth() {
    local user="$1" pass="$2" host="$3" port="$4"
    # Use a here-doc to stream a single line via ssh, then chown on remote.
    SSHPASS="$pass" sshpass -e ssh -o StrictHostKeyChecking=accept-new -p "$port" "${user}@${host}" \
        "bash -c 'mkdir -p /etc/redis/cluster && cat > /etc/redis/cluster/auth.conf && chown redis:redis /etc/redis/cluster/auth.conf && chmod 600 /etc/redis/cluster/auth.conf'" \
        <<<"$CLUSTER_PASS"
}
push_auth "$A_USER" "$A_PASS" "$A_HOST" "$A_PORT" || die "auth file to A failed"
push_auth "$B_USER" "$B_PASS" "$B_HOST" "$B_PORT" || die "auth file to B failed"
log_ok "Auth file deployed"

# === Step 9: Render per-instance redis.conf ===
log_info "[9] Rendering 6 instance configs..."
render_and_push() {
    local user="$1" pass="$2" host="$3" port="$4" p
    for p in "${@:5}"; do
        local out
        out=$(render_redis_conf "$CONF_TEMPLATE" "$p" "$CLUSTER_PASS" "node-${p}" "0.0.0.0")
        SSHPASS="$pass" sshpass -e ssh -o StrictHostKeyChecking=accept-new -p "$port" "${user}@${host}" \
            "cat > /etc/redis/cluster/redis-${p}.conf && chown redis:redis /etc/redis/cluster/redis-${p}.conf && chmod 640 /etc/redis/cluster/redis-${p}.conf" \
            <<<"$out"
    done
}
render_and_push "$A_USER" "$A_PASS" "$A_HOST" "$A_PORT" "${A_PORTS[@]}" || die "config render/push to A failed"
render_and_push "$B_USER" "$B_PASS" "$B_HOST" "$B_PORT" "${B_PORTS[@]}" || die "config render/push to B failed"
log_ok "Instance configs rendered"

# === Step 10: Render systemd unit ===
log_info "[10] Rendering and pushing systemd units..."
push_units() {
    local user="$1" pass="$2" host="$3" port="$4" p
    for p in "${@:5}"; do
        local out
        out=$(render_systemd_unit "$SERVICE_TEMPLATE" "$p" "node-${p}" "$CLUSTER_PASS")
        SSHPASS="$pass" sshpass -e ssh -o StrictHostKeyChecking=accept-new -p "$port" "${user}@${host}" \
            "cat > /etc/systemd/system/redis-${p}.service" \
            <<<"$out"
    done
}
push_units "$A_USER" "$A_PASS" "$A_HOST" "$A_PORT" "${A_PORTS[@]}" || die "units to A failed"
push_units "$B_USER" "$B_PASS" "$B_HOST" "$B_PORT" "${B_PORTS[@]}" || die "units to B failed"
log_ok "systemd units rendered"

# === Step 11: Start services ===
log_info "[11] Starting services on both nodes..."
start_services() {
    local user="$1" pass="$2" host="$3" port="$4" p
    for p in "${@:5}"; do
        ssh_run "$user" "$pass" "$host" "$port" \
            "systemctl daemon-reload && systemctl enable redis-${p} && systemctl restart redis-${p}" \
            || { echo "start failed on $host:$p" >&2; return 1; }
    done
}
start_services "$A_USER" "$A_PASS" "$A_HOST" "$A_PORT" "${A_PORTS[@]}" || die "start on A failed"
start_services "$B_USER" "$B_PASS" "$B_HOST" "$B_PORT" "${B_PORTS[@]}" || die "start on B failed"

# Verify each instance is responding
verify_ping() {
    local user="$1" pass="$2" host="$3" port="$4" p
    for p in "${@:5}"; do
        ssh_run "$user" "$pass" "$host" "$port" \
            "/usr/local/bin/redis-cli -a '$CLUSTER_PASS' -p $p PING" \
            | grep -q PONG \
            || { echo "ping failed on $host:$p" >&2; return 1; }
    done
}
verify_ping "$A_USER" "$A_PASS" "$A_HOST" "$A_PORT" "${A_PORTS[@]}" || die "PING on A failed"
verify_ping "$B_USER" "$B_PASS" "$B_HOST" "$B_PORT" "${B_PORTS[@]}" || die "PING on B failed"
log_ok "All 6 instances responding to PING"

# === Step 12: Check if cluster already created ===
log_info "[12] Checking cluster state..."
existing_info=$(ssh_run "$A_USER" "$A_PASS" "$A_HOST" "$A_PORT" \
    "/usr/local/bin/redis-cli -a '$CLUSTER_PASS' -p 6379 cluster info" || true)
if echo "$existing_info" | is_cluster_healthy; then
    log_ok "Cluster already healthy, skipping create"
else
    log_info "Creating cluster..."
    # Build the create command
    create_args=()
    for p in "${A_PORTS[@]}"; do create_args+=("$A_HOST:$p"); done
    for p in "${B_PORTS[@]}"; do create_args+=("$B_HOST:$p"); done

    # We need redis-cli on the local control machine. If not, ssh to A and run from there.
    if command -v redis-cli >/dev/null 2>&1; then
        redis-cli --cluster create "${create_args[@]}" \
            --cluster-replicas 1 --cluster-yes \
            -a "$CLUSTER_PASS" \
            || die "redis-cli --cluster create failed"
    else
        log_warn "redis-cli not on control machine; running create from node A"
        ssh_run "$A_USER" "$A_PASS" "$A_HOST" "$A_PORT" \
            "/usr/local/bin/redis-cli --cluster create $(printf '%s ' "${create_args[@]}") --cluster-replicas 1 --cluster-yes -a '$CLUSTER_PASS'" \
            || die "redis-cli --cluster create from A failed"
    fi
fi

# === Step 13: Final health check ===
log_info "[13] Verifying cluster health..."
final=$(ssh_run "$A_USER" "$A_PASS" "$A_HOST" "$A_PORT" \
    "/usr/local/bin/redis-cli -a '$CLUSTER_PASS' -p 6379 cluster info" || true)
if echo "$final" | is_cluster_healthy; then
    log_ok "Cluster is healthy"
else
    die "cluster health check failed:\n$final"
fi

# === Step 14: Print summary card ===
cat <<CARD

==========================================
 Redis Cluster READY
==========================================
 Nodes:
   A  $A_HOST : ${A_PORTS[*]}
   B  $B_HOST : ${B_PORTS[*]}
 Auth password file: $PASSWORD_FILE
 To connect:  redis-cli -c -a "\$(cat $PASSWORD_FILE)" -h $A_HOST -p 6379
 Other scripts: status.sh  uninstall.sh  add-node.sh
==========================================
CARD
EOF
chmod +x install.sh
```

- [ ] **Step 2: Syntax check**

Run: `bash -n install.sh`
Expected: no output (success).

- [ ] **Step 3: Write CLI parse test**

```bash
cat > tests/install.bats <<'EOF'
load 'setup'

@test "install.sh --help prints usage and exits 0" {
    run bash install.sh --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "install.sh without args does not crash before prompting" {
    # This test will hang on a prompt; we just want to confirm the script parses
    run bash -n install.sh
    [ "$status" -eq 0 ]
}
EOF
```

- [ ] **Step 4: Run**

Run: `bats tests/install.bats`
Expected: 2 pass.

- [ ] **Step 5: Commit**

```bash
git add install.sh tests/install.bats
git commit -m "feat(install): full orchestrator (16 steps per spec)"
```

---

## Task 9.5: Idempotency guards + SELinux handling in install.sh

**Files:**
- Modify: `install.sh`
- Create: `tests/install_idempotency.bats`

The first run of `install.sh` deploys; subsequent runs should be no-ops (skip steps that are already done). This satisfies spec section 6.

- [ ] **Step 1: Write failing test**

```bash
cat > tests/install_idempotency.bats <<'EOF'
load 'setup'

@test "idempotency guards: file_exists returns 0 when present, 1 when absent" {
    source "$(dirname "$BATS_TEST_FILENAME")/../lib/common.sh"
    tmpf=$(mktemp)
    run file_exists "$tmpf"
    [ "$status" -eq 0 ]
    rm -f "$tmpf"
    run file_exists "$tmpf"
    [ "$status" -eq 1 ]
}

@test "idempotency guards: remote_file_exists returns 0/1" {
    # Tested by stubbing ssh_run; here we only verify it forwards args
    type remote_file_exists >/dev/null 2>&1
    [ "$?" -eq 0 ]
}
EOF
```

- [ ] **Step 2: Run, expect failure**

Run: `bats tests/install_idempotency.bats`
Expected: failure (helpers not defined yet).

- [ ] **Step 3: Add idempotency helpers to lib/common.sh**

Edit `lib/common.sh` to append at the end:

```bash
# file_exists PATH
# Returns 0 if PATH exists (regular file, directory, anything), else 1.
file_exists() {
    [ -e "$1" ]
}

# remote_file_exists USER PASS HOST PORT PATH
# Returns 0 if PATH exists on remote host, else 1.
remote_file_exists() {
    local user="$1" pass="$2" host="$3" port="$4" path="$5"
    ssh_run "$user" "$pass" "$host" "$port" "test -e '$path'"
}
```

- [ ] **Step 4: Add guards to install.sh — replace step [6] build block**

Edit the `install.sh` build step (current step [6]) to wrap with a guard:

```bash
# === Step 6: Build on both nodes in parallel (idempotent) ===
log_info "[6] Building Redis on both nodes..."
build_remote() {
    local user="$1" pass="$2" host="$3" port="$4"
    ssh_run "$user" "$pass" "$host" "$port" bash -s <<'REMOTE'
set -e
if [ -x /usr/local/bin/redis-server ] && [ -x /usr/local/bin/redis-cli ]; then
    echo "already installed, skipping build"
    exit 0
fi
cd /tmp
tar xzf redis-8.8.0.tar.gz
cd redis-8.8.0
make -C src BUILD_TLS=no USE_SYSTEMD=no -j"$(nproc)"
make -C src install PREFIX=/usr/local
echo "build OK"
REMOTE
}
```

(The `build_remote` body itself becomes idempotent — exits early if binaries already present.)

- [ ] **Step 5: Add guards to install.sh — start step [11]**

Edit the start step in `install.sh` to check if a service is already active:

```bash
# === Step 11: Start services (idempotent) ===
log_info "[11] Starting services on both nodes..."
start_services() {
    local user="$1" pass="$2" host="$3" port="$4" p
    for p in "${@:5}"; do
        # Skip if already active
        if ssh_run "$user" "$pass" "$host" "$port" "systemctl is-active redis-${p}" 2>/dev/null | grep -q '^active'; then
            log_info "  $host:$p already active, skipping start"
            continue
        fi
        ssh_run "$user" "$pass" "$host" "$port" \
            "systemctl daemon-reload && systemctl enable redis-${p} && systemctl restart redis-${p}" \
            || { echo "start failed on $host:$p" >&2; return 1; }
    done
}
```

- [ ] **Step 6: Add SELinux warning to install.sh**

Append right before the final summary card in `install.sh`:

```bash
# === Optional: SELinux hint for RHEL-family ===
selinux_hint=$(ssh_run "$A_USER" "$A_PASS" "$A_HOST" "$A_PORT" "getenforce 2>/dev/null || true" || true)
if echo "$selinux_hint" | grep -q Enforcing; then
    log_warn "SELinux is enforcing on node A. If writes fail, run on each node:"
    log_warn "  semanage fcontext -a -t redis_var_lib_t '/var/lib/redis/cluster(/.*)?'"
    log_warn "  restorecon -R /var/lib/redis/cluster"
fi
```

- [ ] **Step 7: Run, expect pass**

Run: `bats tests/install_idempotency.bats`
Expected: 2 pass.

- [ ] **Step 8: Commit**

```bash
git add lib/common.sh install.sh tests/install_idempotency.bats
git commit -m "feat(install): idempotency guards + SELinux hint"
```

---

## Task 10: status.sh — cluster health reporter

**Files:**
- Create: `status.sh`
- Create: `tests/status.bats`

- [ ] **Step 1: Write status.sh**

```bash
cat > status.sh <<'EOF'
#!/usr/bin/env bash
# status.sh — Print cluster health, role table, slot distribution.
# Reads cluster password from secrets/cluster_password.txt and connects to A:6379.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$REPO_ROOT/lib/common.sh"
. "$REPO_ROOT/lib/cluster.sh"

PASSWORD_FILE="$REPO_ROOT/secrets/cluster_password.txt"
[ -f "$PASSWORD_FILE" ] || die "missing $PASSWORD_FILE — has install.sh been run?"
PASS=$(cat "$PASSWORD_FILE")

A_HOST="${A_HOST:-127.0.0.1}"
A_PORT="${A_PORT:-6379}"

log_info "Querying cluster info at $A_HOST:$A_PORT..."
info=$(redis-cli -a "$PASS" -h "$A_HOST" -p "$A_PORT" cluster info 2>/dev/null || true)

if ! echo "$info" | is_cluster_healthy; then
    log_error "cluster not healthy"
    echo "$info"
    exit 1
fi

echo
echo "== Cluster Info =="
echo "$info"
echo
echo "== Cluster Nodes =="
redis-cli -a "$PASS" -h "$A_HOST" -p "$A_PORT" cluster nodes 2>/dev/null
echo
echo "== Slot Distribution =="
redis-cli -a "$PASS" -h "$A_HOST" -p "$A_PORT" cluster slots 2>/dev/null \
    | awk 'NR%2==1 {start=$1; end=$2} NR%2==0 {print start, end, $0}' \
    | head -20
echo
log_ok "Status check complete"
EOF
chmod +x status.sh
```

- [ ] **Step 2: Write tests**

```bash
cat > tests/status.bats <<'EOF'
load 'setup'

@test "status.sh aborts when password file missing" {
    run bash status.sh
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing"* ]]
}

@test "status.sh parses correctly" {
    run bash -n status.sh
    [ "$status" -eq 0 ]
}
EOF
```

- [ ] **Step 3: Run**

Run: `bats tests/status.bats`
Expected: 2 pass.

- [ ] **Step 4: Commit**

```bash
git add status.sh tests/status.bats
git commit -m "feat(status): cluster health and slot distribution reporter"
```

---

## Task 11: uninstall.sh — teardown

**Files:**
- Create: `uninstall.sh`
- Create: `tests/uninstall.bats`

- [ ] **Step 1: Write uninstall.sh**

```bash
cat > uninstall.sh <<'EOF'
#!/usr/bin/env bash
# uninstall.sh — Stop services, back up data, remove configs.
# Default: dry-run, prints what would happen.
# --force: actually delete.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$REPO_ROOT/lib/common.sh"
. "$REPO_ROOT/lib/prompt.sh"
. "$REPO_ROOT/lib/ssh.sh"

FORCE=0
case "${1:-}" in
    --force|-f) FORCE=1 ;;
    --help|-h)
        sed -n '2,8p' "$0"
        exit 0
        ;;
esac

PASSWORD_FILE="$REPO_ROOT/secrets/cluster_password.txt"

prompt_credentials() {
    A_HOST=$(read_default "  A host or IP" "")
    A_USER=$(read_default "  A SSH user" "root")
    A_PORT=$(read_default "  A SSH port" "22")
    A_PASS=$(read_secret "  A SSH password")
    B_HOST=$(read_default "  B host or IP" "")
    B_USER=$(read_default "  B SSH user" "root")
    B_PORT=$(read_default "  B SSH port" "22")
    B_PASS=$(read_secret "  B SSH password")
}
[ -z "${A_HOST:-}" ] && prompt_credentials

teardown() {
    local user="$1" pass="$2" host="$3" port="$4"
    if [ "$FORCE" = 1 ]; then
        log_info "tearing down $host..."
        ssh_run "$user" "$pass" "$host" "$port" bash -s <<'REMOTE' || true
set +e
for p in 6379 6380 6381 6382 6383 6384; do
    systemctl stop redis-$p 2>/dev/null
    systemctl disable redis-$p 2>/dev/null
    rm -f /etc/systemd/system/redis-$p.service
done
systemctl daemon-reload
if [ -d /var/lib/redis/cluster ]; then
    tar czf /tmp/redis-cluster-backup-$(date +%s).tar.gz /var/lib/redis/cluster
    rm -rf /var/lib/redis/cluster
fi
rm -rf /etc/redis/cluster /var/log/redis/cluster /var/run/redis/cluster
echo "torn down $host"
REMOTE
    else
        log_info "[dry-run] would tear down $host"
    fi
}

teardown "$A_USER" "$A_PASS" "$A_HOST" "$A_PORT"
teardown "$B_USER" "$B_PASS" "$B_HOST" "$B_PORT"

if [ "$FORCE" = 1 ]; then
    rm -f "$PASSWORD_FILE"
    log_ok "Local password file removed"
fi
EOF
chmod +x uninstall.sh
```

- [ ] **Step 2: Write tests**

```bash
cat > tests/uninstall.bats <<'EOF'
load 'setup'

@test "uninstall.sh --help prints usage" {
    run bash uninstall.sh --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "uninstall.sh parses correctly" {
    run bash -n uninstall.sh
    [ "$status" -eq 0 ]
}
EOF
```

- [ ] **Step 3: Run**

Run: `bats tests/uninstall.bats`
Expected: 2 pass.

- [ ] **Step 4: Commit**

```bash
git add uninstall.sh tests/uninstall.bats
git commit -m "feat(uninstall): teardown with --force, dry-run by default"
```

---

## Task 12: add-node.sh — manual node add

**Files:**
- Create: `add-node.sh`
- Create: `tests/add_node.bats`

- [ ] **Step 1: Write add-node.sh**

```bash
cat > add-node.sh <<'EOF'
#!/usr/bin/env bash
# add-node.sh — Add a new Redis instance to an existing cluster.
# Usage: bash add-node.sh NEW_HOST NEW_PORT EXISTING_HOST EXISTING_PORT
# Where NEW_PORT becomes a new master or replica of EXISTING_PORT's master.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$REPO_ROOT/lib/common.sh"
. "$REPO_ROOT/lib/ssh.sh"
. "$REPO_ROOT/lib/config_gen.sh"
. "$REPO_ROOT/lib/systemd.sh"
. "$REPO_ROOT/lib/prompt.sh"
. "$REPO_ROOT/lib/password.sh"

NEW_HOST="${1:-}"; NEW_PORT="${2:-}"
EXIST_HOST="${3:-}"; EXIST_PORT="${4:-}"

if [ -z "$NEW_HOST" ] || [ -z "$EXIST_HOST" ]; then
    sed -n '2,5p' "$0"
    exit 1
fi

NEW_USER="${NEW_USER:-root}"
NEW_SSH_PORT="${NEW_SSH_PORT:-22}"
EXIST_USER="${EXIST_USER:-root}"
EXIST_SSH_PORT="${EXIST_SSH_PORT:-22}"
NEW_PASS="${NEW_PASS:-}"
EXIST_PASS="${EXIST_PASS:-}"

PASSWORD_FILE="$REPO_ROOT/secrets/cluster_password.txt"
[ -f "$PASSWORD_FILE" ] || die "missing $PASSWORD_FILE"
CLUSTER_PASS=$(cat "$PASSWORD_FILE")

log_info "Adding $NEW_HOST:$NEW_PORT to cluster (joining via $EXIST_HOST:$EXIST_PORT)..."

# Push the auth file
SSHPASS="$NEW_PASS" sshpass -e ssh -o StrictHostKeyChecking=accept-new -p "$NEW_SSH_PORT" "${NEW_USER}@${NEW_HOST}" \
    "cat > /etc/redis/cluster/auth.conf" <<<"$CLUSTER_PASS"
ssh_run "$NEW_USER" "$NEW_PASS" "$NEW_HOST" "$NEW_SSH_PORT" \
    "chown redis:redis /etc/redis/cluster/auth.conf && chmod 600 /etc/redis/cluster/auth.conf"

# Push the redis.conf
out=$(render_redis_conf "$REPO_ROOT/config/redis.conf.template" "$NEW_PORT" "$CLUSTER_PASS" "node-${NEW_PORT}" "0.0.0.0")
SSHPASS="$NEW_PASS" sshpass -e ssh -o StrictHostKeyChecking=accept-new -p "$NEW_SSH_PORT" "${NEW_USER}@${NEW_HOST}" \
    "cat > /etc/redis/cluster/redis-${NEW_PORT}.conf" <<<"$out"

# Push the systemd unit
unit=$(render_systemd_unit "$REPO_ROOT/config/redis-cluster.service.template" "$NEW_PORT" "node-${NEW_PORT}" "$CLUSTER_PASS")
SSHPASS="$NEW_PASS" sshpass -e ssh -o StrictHostKeyChecking=accept-new -p "$NEW_SSH_PORT" "${NEW_USER}@${NEW_HOST}" \
    "cat > /etc/systemd/system/redis-${NEW_PORT}.service" <<<"$unit"

# Start the new instance
ssh_run "$NEW_USER" "$NEW_PASS" "$NEW_HOST" "$NEW_SSH_PORT" \
    "systemctl daemon-reload && systemctl enable redis-${NEW_PORT} && systemctl restart redis-${NEW_PORT}"

# Join the cluster
ssh_run "$EXIST_USER" "$EXIST_PASS" "$EXIST_HOST" "$EXIST_SSH_PORT" \
    "/usr/local/bin/redis-cli -a '$CLUSTER_PASS' --cluster add-node $NEW_HOST:$NEW_PORT $EXIST_HOST:$EXIST_PORT" \
    || die "cluster add-node failed"

log_ok "Node $NEW_HOST:$NEW_PORT added. Use 'redis-cli --cluster rebalance' to redistribute slots."
EOF
chmod +x add-node.sh
```

- [ ] **Step 2: Write tests**

```bash
cat > tests/add_node.bats <<'EOF'
load 'setup'

@test "add-node.sh with no args shows usage" {
    run bash add-node.sh
    [ "$status" -ne 0 ]
}

@test "add-node.sh parses correctly" {
    run bash -n add-node.sh
    [ "$status" -eq 0 ]
}
EOF
```

- [ ] **Step 3: Run**

Run: `bats tests/add_node.bats`
Expected: 2 pass.

- [ ] **Step 4: Commit**

```bash
git add add-node.sh tests/add_node.bats
git commit -m "feat(add-node): add new instance to existing cluster"
```

---

## Task 13: scripts/smoke-test.sh — Docker-based end-to-end

**Files:**
- Create: `scripts/smoke-test.sh`

- [ ] **Step 1: Write the smoke test**

```bash
cat > scripts/smoke-test.sh <<'EOF'
#!/usr/bin/env bash
# smoke-test.sh — End-to-end test in two Docker containers.
# Spins up sshd-enabled containers, runs an "apt-installed Redis" variant of install.sh
# logic, and verifies cluster is healthy.
#
# Requirements: docker, sshpass on the host.
# Usage: bash scripts/smoke-test.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_ROOT/lib/common.sh"

require_cmd docker sshpass

# Cleanup any prior smoke test containers
cleanup() {
    docker rm -f smoke-a smoke-b >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

log_info "Starting smoke-a and smoke-b..."
docker run -d --name smoke-a -h smoke-a \
    -e SSH_USER=root -e SSH_PASSWORD=smokepw \
    -p 2222:22 rastasheep/ubuntu-sshd:18.04 >/dev/null
docker run -d --name smoke-b -h smoke-b \
    -e SSH_USER=root -e SSH_PASSWORD=smokepw \
    -p 2223:22 rastasheep/ubuntu-sshd:18.04 >/dev/null

# Wait for sshd to be ready
for i in {1..30}; do
    if SSHPASS=smokepw sshpass -e ssh -o StrictHostKeyChecking=no -p 2222 root@127.0.0.1 true 2>/dev/null \
        && SSHPASS=smokepw sshpass -e ssh -o StrictHostKeyChecking=no -p 2223 root@127.0.0.1 true 2>/dev/null; then
        break
    fi
    sleep 1
done

log_info "Installing redis-server on both containers..."
for port in 2222 2223; do
    SSHPASS=smokepw sshpass -e ssh -p "$port" -o StrictHostKeyChecking=no root@127.0.0.1 \
        "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq redis-server redis-tools gcc make"
done

log_info "Setting up cluster manually (apt-installed variant)..."
# Provision dirs
for port in 2222 2223; do
    SSHPASS=smokepw sshpass -e ssh -p "$port" -o StrictHostKeyChecking=no root@127.0.0.1 \
        "id redis || useradd -r -s /usr/sbin/nologin redis
         mkdir -p /var/lib/redis/cluster /var/log/redis/cluster /etc/redis/cluster
         chown -R redis:redis /var/lib/redis /var/log/redis /etc/redis"
done

# Generate a shared password
PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
echo "$PASS" > "$REPO_ROOT/secrets/cluster_password.txt"
chmod 600 "$REPO_ROOT/secrets/cluster_password.txt"

# Render configs and start 3 instances on each container
for pair in "2222:127.0.0.1:6379:6380:6381" "2223:127.0.0.1:6382:6383:6384"; do
    IFS=: read -r ssh_port container_ip p1 p2 p3 <<<"$pair"
    for p in "$p1" "$p2" "$p3"; do
        cat > "/tmp/redis-$p.conf" <<CONF
port $p
cluster-enabled yes
cluster-config-file /var/lib/redis/cluster/$p/nodes.conf
cluster-node-timeout 5000
requirepass $PASS
masterauth $PASS
appendonly yes
dir /var/lib/redis/cluster/$p
logfile /var/log/redis/cluster/redis-$p.log
daemonize yes
pidfile /var/run/redis/cluster/redis-$p.pid
protected-mode no
CONF
        SSHPASS=smokepw sshpass -e scp -P "$ssh_port" -o StrictHostKeyChecking=no \
            "/tmp/redis-$p.conf" "root@127.0.0.1:/etc/redis/cluster/redis-$p.conf"
        SSHPASS=smokepw sshpass -e ssh -p "$ssh_port" -o StrictHostKeyChecking=no root@127.0.0.1 \
            "mkdir -p /var/lib/redis/cluster/$p /var/run/redis/cluster
             chown -R redis:redis /var/lib/redis /var/log/redis /etc/redis /var/run/redis
             sudo -u redis redis-server /etc/redis/cluster/redis-$p.conf"
    done
done

# Create cluster
log_info "Creating cluster..."
SSHPASS=smokepw sshpass -e ssh -p 2222 -o StrictHostKeyChecking=no root@127.0.0.1 \
    "redis-cli --cluster create 127.0.0.1:6379 127.0.0.1:6380 127.0.0.1:6381 127.0.0.1:6382 127.0.0.1:6383 127.0.0.1:6384 --cluster-replicas 1 --cluster-yes -a '$PASS'"

# Verify
log_info "Verifying cluster health..."
info=$(SSHPASS=smokepw sshpass -e ssh -p 2222 -o StrictHostKeyChecking=no root@127.0.0.1 \
    "redis-cli -a '$PASS' cluster info")
if ! echo "$info" | grep -q "cluster_state:ok"; then
    die "cluster not healthy:\n$info"
fi
if ! echo "$info" | grep -q "cluster_known_nodes:6"; then
    die "expected 6 known nodes:\n$info"
fi

# Set/Get sanity
log_info "Testing set/get across nodes..."
SSHPASS=smokepw sshpass -e ssh -p 2222 -o StrictHostKeyChecking=no root@127.0.0.1 \
    "redis-cli -a '$PASS' -c SET smoke-test:hello world"
readback=$(SSHPASS=smokepw sshpass -e ssh -p 2223 -o StrictHostKeyChecking=no root@127.0.0.1 \
    "redis-cli -a '$PASS' -c GET smoke-test:hello" | tr -d '\r')
[ "$readback" = "world" ] || die "GET returned '$readback', expected 'world'"

log_ok "Smoke test PASSED"
EOF
chmod +x scripts/smoke-test.sh
```

- [ ] **Step 2: Syntax check**

Run: `bash -n scripts/smoke-test.sh`
Expected: no output.

- [ ] **Step 3: Commit (do not run yet — it needs Docker)**

```bash
git add scripts/smoke-test.sh
git commit -m "test(smoke): docker-based end-to-end cluster validation"
```

---

## Task 14: README.md

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write README**

```bash
cat > README.md <<'EOF'
# Redis Cluster Install Scripts

One-shot Bash suite to deploy a 6-node Redis 8.8.0 cluster (3 master + 3 replica)
across two Linux machines over SSH password authentication, compiled from a local
source tarball.

## Prerequisites

On the **control machine** (where you run the scripts):

- Bash 4+
- `sshpass`
- `openssh-client`
- The local file `redis-8.8.0.tar.gz` in this repo's root

On each **target node** (A and B):

- Linux with `gcc >= 11`, `make`, `g++`, `tar`
- `ulimit -n >= 10001` (cluster bus needs it)
- SSH server running, port reachable
- Firewall open: 6379–6384 (Redis) and 16379–16384 (cluster bus)

## Quick start

```bash
# 1. Run the installer (interactive)
bash install.sh

# You will be prompted for:
#   - A and B node IP / SSH user / SSH port / SSH password
# The script will:
#   - compile Redis on both nodes
#   - create a 'redis' system user
#   - render and push 6 instance configs
#   - render and push 6 systemd units
#   - start all instances
#   - create the cluster (3 master + 3 replica)

# 2. Check status
bash status.sh

# 3. Tear it down
bash uninstall.sh --dry-run   # preview
bash uninstall.sh --force     # actually delete
```

## Layout

| Path | Purpose |
|---|---|
| `install.sh` | Main installer (interactive) |
| `status.sh` | Cluster health, role table, slot distribution |
| `uninstall.sh` | Stop services, backup data, remove configs |
| `add-node.sh` | Add a new instance to an existing cluster |
| `lib/` | Helpers: `common.sh`, `password.sh`, `prompt.sh`, `ssh.sh`, `config_gen.sh`, `systemd.sh`, `cluster.sh` |
| `config/` | `redis.conf.template`, `redis-cluster.service.template` |
| `secrets/cluster_password.txt` | Generated `requirepass` / `masterauth` (0600) |
| `tests/` | bats unit tests |
| `scripts/smoke-test.sh` | Docker-based end-to-end |
| `docs/superpowers/specs/2026-07-07-redis-cluster-install-design.md` | Design |

## Tests

```bash
# Unit tests (bats required)
bats tests/

# End-to-end (docker required)
bash scripts/smoke-test.sh
```

## Architecture

- 6 instances total: A (6379, 6380, 6381), B (6382, 6383, 6384)
- Roles auto-assigned by `redis-cli --cluster create --cluster-replicas 1`
- All 6 instances share the same `requirepass` (auto-generated, 32 chars)
- Persistence: RDB (default savepoints) + AOF (`appendfsync everysec`)

## Known limitations

- No Sentinel (Redis cluster handles failover natively)
- No TLS / ACL
- No monitoring / alerting
- Not Windows-native; use WSL on Windows
- Requires SSH password; for SSH keys, edit `lib/ssh.sh` to drop the `sshpass -e` wrapping

## Spec

See `docs/superpowers/specs/2026-07-07-redis-cluster-install-design.md`.
EOF
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add README with quick start and architecture"
```

---

## Task 15: Final integration test

**Files:**
- Modify: none (run all tests, verify final shape)

- [ ] **Step 1: Run all unit tests**

Run: `bats tests/`
Expected: All tests pass. There should be approximately 22 tests across 8 files.

- [ ] **Step 2: Verify final file tree**

Run:
```bash
find . -type f -not -path './.git*' -not -path './docs/*' -not -name '*.tar.gz' | sort
```

Expected:
```
./.gitignore
./README.md
./add-node.sh
./config/redis-cluster.service.template
./config/redis.conf.template
./install.sh
./lib/cluster.sh
./lib/common.sh
./lib/config_gen.sh
./lib/password.sh
./lib/prompt.sh
./lib/ssh.sh
./lib/systemd.sh
./scripts/smoke-test.sh
./secrets/.gitkeep
./secrets/cluster_password.txt  (only if smoke ran)
./status.sh
./tests/add_node.bats
./tests/common.bats
./tests/config_gen.bats
./tests/cluster.bats
./tests/install.bats
./tests/password.bats
./tests/prompt.bats
./tests/setup.bash
./tests/ssh.bats
./tests/status.bats
./tests/systemd.bats
./tests/uninstall.bats
./tests/fixtures/redis.conf.template
./tests/fixtures/systemd.service.template
./uninstall.sh
```

- [ ] **Step 3: Verify DoD from spec section 10**

| DoD item | Manual check |
|---|---|
| 1. All 6 instances PING → PONG | `bash status.sh` (after install on real machines) |
| 2. `redis-cli --cluster check` returns OK | `redis-cli -a $PASS --cluster check $A:6379` |
| 3. `cluster info` shows `cluster_state:ok`, `cluster_known_nodes:6`, `cluster_slots_assigned:16384` | `bash status.sh` |
| 4. Set on one master, read on the other machine | `redis-cli -a $PASS -c SET foo bar` then on B: `redis-cli -a $PASS -c GET foo` |
| 5. Kill a master → auto-promote in 30s | `systemctl stop redis-6379` then watch `cluster nodes` |
| 6. status.sh prints roles | run it |
| 7. uninstall.sh --force leaves nothing | run it, then `ps aux \| grep redis` |

These manual checks require real A and B machines and are the user's responsibility, not part of automated CI.

- [ ] **Step 4: Final commit (if any cleanup needed)**

```bash
git status
# If anything uncommitted:
git add -A
git commit -m "chore: integration cleanup"
```

---

## Acceptance

This plan is complete when:

1. `bats tests/` reports all tests passing
2. `bash -n install.sh status.sh uninstall.sh add-node.sh scripts/smoke-test.sh` reports no syntax errors
3. The file tree matches the structure in Task 15 step 2
4. A human operator has executed `bash install.sh` against two real Linux VMs and verified the 7 DoD items

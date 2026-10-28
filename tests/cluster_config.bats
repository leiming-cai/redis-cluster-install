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

@test "cluster-config.sh --help prints the header only, no shell code" {
    # --help is `sed` over the script's own comment block. If the range that
    # block is selected by ever drifts, this is what notices: an operator
    # reads `set -euo pipefail` as help text.
    run bash "$REPO_ROOT/cluster-config.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"cluster-config.sh"* ]]
    [[ "$output" != *"set -euo pipefail"* ]]
    [[ "$output" != *"REPO_ROOT"* ]]
    [[ "$output" != *"HELP-START"* ]]
    [[ "$output" != *"HELP-END"* ]]
    [[ "$output" != *"die "* ]]
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

@test "cluster-config.sh --config=FILE is accepted as well as --config FILE" {
    run bash "$REPO_ROOT/cluster-config.sh" "--config=$CONF_TMP/cluster.conf" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"10.0.0.3"* ]]
}

@test "cluster-config.sh rejects an unknown argument" {
    run bash "$REPO_ROOT/cluster-config.sh" --nope
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown argument"* ]]
    [[ "$output" == *"--help"* ]]
}

@test "cluster-config.sh rejects --config with no value" {
    run bash "$REPO_ROOT/cluster-config.sh" --config
    [ "$status" -ne 0 ]
    [[ "$output" == *"--config requires a file argument"* ]]
}

# === Credential resolution (Task 6) ===
#
# `</dev/null` is load-bearing, not decoration: with PROMPT_NO_TTY=1 the
# prompt helpers read stdin, and a test whose stdin is an inherited
# terminal would block forever on `read`. /dev/null makes "no input
# available" deterministic, which is what read_default already falls back
# to for its default value.

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
        bash "$REPO_ROOT/cluster-config.sh" --config "$CONF_TMP/env.conf" --print-credentials </dev/null 2>&1)"
    [[ "$out" != *"SSH user"* ]]
    [[ "$out" != *"SSH password"* ]]
    [[ "$out" == *"a: root@10.0.0.1:22"* ]]
    [[ "$out" == *"b: root@10.0.0.2:22"* ]]
    [[ "$out" == *"c: root@10.0.0.3:22"* ]]
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
    # No NODE_A_HOST: the config value is the default the prompt offers.
    out="$(env PROMPT_NO_TTY=1 \
        NODE_A_SSH_USER=root NODE_A_SSH_PORT=22 NODE_A_SSH_PASS=pw1 \
        NODE_B_SSH_USER=root NODE_B_HOST=10.0.0.2 NODE_B_SSH_PORT=22 NODE_B_SSH_PASS=pw2 \
        NODE_C_SSH_USER=root NODE_C_HOST=10.0.0.3 NODE_C_SSH_PORT=22 NODE_C_SSH_PASS=pw3 \
        bash "$REPO_ROOT/cluster-config.sh" --config "$CONF_TMP/env2.conf" --print-credentials </dev/null 2>&1)"
    [[ "$out" == *"a: root@10.9.9.9:22"* ]]
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
        NODE_B_SSH_USER=root NODE_B_HOST=10.0.0.2 NODE_B_SSH_PORT=22 NODE_B_SSH_PASS=pw2 \
        NODE_C_SSH_USER=root NODE_C_HOST=10.0.0.3 NODE_C_SSH_PORT=22 NODE_C_SSH_PASS=pw3 \
        bash "$REPO_ROOT/cluster-config.sh" --config "$CONF_TMP/env3.conf" --print-credentials </dev/null 2>&1)"
    # Assert on the resolved credential line, NOT on the config host being
    # absent from the whole output: step 2 echoes CONF_NODE_HOST for every
    # node, so a global `!= 10.9.9.9` can never hold.
    [[ "$out" == *"a: root@1.2.3.4:22"* ]]
}

@test "missing password with no terminal names the env var to set" {
    # No NODE_A_SSH_PASS and stdin is /dev/null, so read_secret hits EOF.
    # Under `set -e` a bare `VAR="$(read_secret ...)"` assignment would abort
    # the script with no output at all; it must fail with a usable message.
    # `|| rc=$?` keeps errexit from killing the test body before the
    # assertions can run, which is what bats would otherwise do here.
    rc=0
    out="$(env PROMPT_NO_TTY=1 \
        NODE_A_SSH_USER=root NODE_A_HOST=10.0.0.1 NODE_A_SSH_PORT=22 \
        NODE_B_SSH_USER=root NODE_B_HOST=10.0.0.2 NODE_B_SSH_PORT=22 NODE_B_SSH_PASS=pw2 \
        NODE_C_SSH_USER=root NODE_C_HOST=10.0.0.3 NODE_C_SSH_PORT=22 NODE_C_SSH_PASS=pw3 \
        bash "$REPO_ROOT/cluster-config.sh" --config "$CONF_TMP/cluster.conf" --print-credentials </dev/null 2>&1)" || rc=$?
    [ "$rc" -ne 0 ]
    [[ "$out" == *"NODE_A_SSH_PASS"* ]]
    [[ "$out" == *"no terminal"* ]]
}

# --- the two-phase assembly ----------------------------------------------
#
# `redis-cli --cluster create --cluster-replicas 1` picks the master/replica
# roles itself, and its pick is not spread across hosts (measured: 6 instances
# on 2 hosts ended up with all 3 masters on one host, and killing that host
# left the cluster with no quorum). The script therefore creates the masters
# with 0 replicas and attaches every replica explicitly.

@test "cluster-config.sh assembles the cluster in two phases" {
    run cat "$REPO_ROOT/cluster-config.sh"
    [ "$status" -eq 0 ]
    # The masters are created on their own ...
    [[ "$output" == *"--cluster-replicas 0"* ]]
    # ... and the replicas are attached one by one.
    [[ "$output" == *"--cluster-slave"* ]]
    # The old single-command form must be gone. Assert the INVOCATION, not the
    # text: the file deliberately quotes "--cluster-replicas 1" in a comment
    # explaining why it is not used.
    [[ "$output" != *'--cluster-replicas "$CONF_REPLICAS"'* ]]
}

@test "cluster-config.sh sources the topology planner" {
    run grep -c 'lib/topology.sh' "$REPO_ROOT/cluster-config.sh"
    [ "$output" -ge 1 ]
}

@test "cluster-config.sh prints which host the cluster cannot survive losing" {
    run cat "$REPO_ROOT/cluster-config.sh"
    [[ "$output" == *"STOPS serving"* ]]
    [[ "$output" == *"keeps serving"* ]]
}

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

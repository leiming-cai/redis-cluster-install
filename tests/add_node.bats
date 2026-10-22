load 'setup'
. "$REPO_ROOT/tests/helpers/remote_sandbox.sh"

SANDBOX=""

teardown() {
    [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"
    SANDBOX=""
}

@test "add-node.sh with no args shows usage" {
    run bash add-node.sh
    [ "$status" -ne 0 ]
}

@test "add-node.sh parses correctly" {
    run bash -n add-node.sh
    [ "$status" -eq 0 ]
}

# The remote script runs under `set -e`, and `chown` exits non-zero when an
# operand does not exist. add-node.sh used to chown /var/log/redis, which no
# deployment path creates, so on a host without the distro redis package the
# whole remote script aborted at the chown -- before systemctl ran, so the
# instance was never started. The error was invisible whenever sudo needed a
# password, because _sudo's password branch sends stderr to /dev/null.
#
# This runs the REAL remote body (extracted from add-node.sh) in a sandbox
# where no /var/log/redis exists, and checks that it gets all the way to
# starting the service.
@test "add-node.sh's remote setup reaches systemctl when /var/log/redis is absent" {
    sandbox="$(mktemp -d)"
    export SANDBOX="$sandbox"
    install_remote_sandbox "$sandbox"

    # The files add-node.sh scp's to the target before running the remote
    # scripts. The sandbox's sudo shim redirects /tmp into the sandbox, so
    # these have to live there too.
    mkdir -p "$sandbox/tmp"
    : > "$sandbox/tmp/redis-cluster-auth.conf"
    : > "$sandbox/tmp/redis-6379.conf"
    : > "$sandbox/tmp/redis-6379.service"

    # /etc/systemd/system exists on any systemd host; the sandbox has to
    # provide it, because the unit is copied straight into it.
    mkdir -p "$sandbox/etc/systemd/system"

    # install.sh puts redis-cli under the prefix; the last remote body runs
    # it to join the cluster. A stub is enough: the point of this test is
    # whether the scripts get that far, not what the cluster does.
    mkdir -p "$sandbox/opt/software/redis/bin"
    cat > "$sandbox/opt/software/redis/bin/redis-cli" <<'STUB'
#!/usr/bin/env bash
echo "redis-cli $*"
exit 0
STUB
    chmod +x "$sandbox/opt/software/redis/bin/redis-cli"

    # The point of the test: nothing creates this one.
    [ ! -e "$sandbox/var/log/redis" ] || {
        echo "the sandbox must not contain /var/log/redis" >&2
        false
    }

    n="$(add_node_remote_bodies "$REPO_ROOT/add-node.sh" "$sandbox")"
    [ "$n" -ge 4 ] || {
        echo "expected at least 4 remote bodies in add-node.sh, found $n" >&2
        false
    }

    # Run every remote body, in order, with the positional arguments the
    # script passes them: password, port, prefix. Bodies that use only $1
    # simply ignore the rest.
    i=1
    combined=""
    while [ "$i" -le "$n" ]; do
        run bash "$sandbox/body-$i.sh" "" 6379 /opt/software/redis
        [ "$status" -eq 0 ] || {
            echo "remote body $i failed:" >&2
            echo "$output" >&2
            false
        }
        # `run` overwrites $output each time, so accumulate across bodies.
        combined="$combined$output"$'\n'
        i=$((i + 1))
    done

    [[ "$combined" == *"systemctl daemon-reload"* ]]
    [[ "$combined" == *"systemctl enable redis-6379"* ]]
    [[ "$combined" == *"systemctl restart redis-6379"* ]]
}

# The shape behind the bug above: every absolute path add-node.sh chowns must
# be one it also creates. A path that is named but never created is a
# guaranteed non-zero exit from chown, and under `set -e` that kills the
# remote script.
@test "add-node.sh never chowns a directory it does not create" {
    # Absolute path literals in the chown commands.
    chowned="$(grep -E 'chown -R redis:redis' add-node.sh \
        | tr ' ' '\n' | tr -d '"' | sed 's/\${.*//' \
        | grep '^/' | sort -u)"
    [ -n "$chowned" ] || {
        echo "expected add-node.sh to chown at least one absolute path" >&2
        false
    }

    # Absolute path literals in the mkdir commands, with the per-port suffix
    # stripped, so a chown of a parent directory still matches what mkdir -p
    # created.
    created="$(grep -E 'mkdir -p' add-node.sh \
        | tr ' ' '\n' | tr -d '"' | sed 's/\${.*//' \
        | grep '^/' | sort -u)"
    [ -n "$created" ] || {
        echo "expected add-node.sh to mkdir at least one absolute path" >&2
        false
    }

    for p in $chowned; do
        ok=0
        for c in $created; do
            case "$c" in
                "$p"|"$p"/*) ok=1; break ;;
            esac
        done
        [ "$ok" -eq 1 ] || {
            echo "add-node.sh chowns '$p' but never creates it; chown exits non-zero" >&2
            echo "  created paths: $(echo $created)" >&2
            false
        }
    done
}

#!/usr/bin/env bash
# Helpers for exercising the remote scripts that add-node.sh runs over ssh.
#
# The remote bodies are extracted from add-node.sh and executed locally, in a
# sandbox, so their behaviour is actually observed rather than inferred from
# the text. Two shims make that safe:
#
#   sudo      -- stands in for the real sudo: it drops sudo's own flags and
#                rewrites every absolute path into $SANDBOX, so nothing outside
#                the sandbox is touched. It also maps the "redis:redis" owner
#                onto the current user, because chowning to another user needs
#                root and CI runs these tests as an unprivileged user.
#   systemctl -- records the call and succeeds, so a test can SEE whether the
#                remote script ever got as far as starting the service.
#
# Nothing here needs root, and nothing here touches the real filesystem.

# Extract every <<'REMOTE' body of $1 into $2/body-N.sh, in the order they
# appear. The bodies are the remote scripts add-node.sh sends over ssh.
add_node_remote_bodies() {
    local src="$1" outdir="$2"
    mkdir -p "$outdir"
    local n=0 ln end
    while IFS=: read -r ln _; do
        n=$((n + 1))
        end="$(tail -n +"$ln" "$src" | grep -n '^REMOTE$' | head -1 | cut -d: -f1)"
        end=$((end + ln - 1))
        sed -n "$((ln + 1)),$((end - 1))p" "$src" > "$outdir/body-$n.sh"
    done < <(grep -n "<<'REMOTE'" "$src")
    printf '%s\n' "$n"
}

# Create the shims in $1 (a directory) and export a PATH that prefers them.
install_remote_sandbox() {
    local dir="$1"
    mkdir -p "$dir/bin"

    cat > "$dir/bin/sudo" <<'SHIM'
#!/usr/bin/env bash
# Stand-in for sudo. Drop sudo's flags, then redirect absolute paths into the
# sandbox. The owner argument is mapped onto the current user so that a real
# chown (still the real chown) can succeed without root.
args=()
while [ $# -gt 0 ]; do
    case "$1" in
        -n|-S) shift ;;
        -p) shift 2 ;;
        --) shift; break ;;
        -*) shift ;;
        *) break ;;
    esac
done
for a in "$@"; do
    case "$a" in
        redis:redis) args+=("$(id -un):$(id -gn)") ;;
        /*)          args+=("$SANDBOX$a") ;;
        *)           args+=("$a") ;;
    esac
done
exec "${args[@]}"
SHIM

    cat > "$dir/bin/systemctl" <<'SHIM'
#!/usr/bin/env bash
echo "systemctl $*"
exit 0
SHIM

    chmod +x "$dir/bin/sudo" "$dir/bin/systemctl"
    PATH="$dir/bin:$PATH"
    export PATH
}

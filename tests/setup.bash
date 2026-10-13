# Common bats setup. Sourced by every test file.
# Exposes $REPO_ROOT and a load_lib helper for relative lib sourcing.

# REPO_ROOT must be computed at LOAD time, not inside setup().
#
# bats loads a .bats file in two phases:
#   1. load phase — `load '...'` and top-level statements run BEFORE setup().
#   2. run phase  — setup() runs, then each @test body.
#
# Test files call `load_lib cluster` at the top level (load phase), so a
# REPO_ROOT assigned only inside setup() is still empty at that moment and
# load_lib resolved to /lib/cluster.
#
# Test files live at two different depths:
#   <repo>/tests/*.bats        (1 level below the repo root)
#   <repo>/tests/lib/*.bats    (2 levels below the repo root)
# so a fixed number of ".." is wrong for one of them. Walk up until we find
# the marker file that identifies the repository root.
_bats_find_repo_root() {
    local d
    d="$(cd "${BATS_TEST_DIRNAME:-$(dirname "${BATS_TEST_FILENAME:-$0}")}" && pwd)"
    while [ "$d" != "/" ]; do
        if [ -f "$d/lib/common.sh" ]; then
            printf '%s\n' "$d"
            return 0
        fi
        d="$(dirname "$d")"
    done
    # Fallback: assume <repo>/tests or <repo>/tests/lib layout.
    cd "${BATS_TEST_DIRNAME:-.}/../.." && pwd
}

REPO_ROOT="$(_bats_find_repo_root)"
unset -f _bats_find_repo_root
export REPO_ROOT

setup() {
    export REPO_ROOT
}

# bats helper: load a lib file relative to REPO_ROOT.
# The .sh suffix is appended automatically: the lib files are named
# cluster.sh / common.sh / ... but tests call `load_lib cluster`.
load_lib() {
    local name="$1"
    case "$name" in
        *.sh) ;;
        *) name="${name}.sh" ;;
    esac
    # shellcheck source=/dev/null
    . "$REPO_ROOT/lib/$name"
}

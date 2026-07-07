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

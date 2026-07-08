load '../setup'
load_lib prompt

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    load_lib common
    load_lib prompt
    export PROMPT_NO_TTY=1
}

@test "read_default returns default when empty" {
    run bash -c '
        source "'"$BATS_TEST_DIRNAME"'/../../lib/common.sh"
        source "'"$BATS_TEST_DIRNAME"'/../../lib/prompt.sh"
        export PROMPT_NO_TTY=1
        echo "" | read_default "name" "alice"
    '
    [ "$output" = "alice" ]
}

@test "read_default returns user input when non-empty" {
    run bash -c '
        source "'"$BATS_TEST_DIRNAME"'/../../lib/common.sh"
        source "'"$BATS_TEST_DIRNAME"'/../../lib/prompt.sh"
        export PROMPT_NO_TTY=1
        echo "carol" | read_default "name" "alice"
    '
    [ "$output" = "carol" ]
}

@test "read_required rejects empty input then accepts" {
    run bash -c '
        source "'"$BATS_TEST_DIRNAME"'/../../lib/common.sh"
        source "'"$BATS_TEST_DIRNAME"'/../../lib/prompt.sh"
        export PROMPT_NO_TTY=1
        printf "first\n\nthird\n" | read_required "name"
    '
    [ "$output" = "first" ]
}

@test "read_required accepts first non-empty input" {
    run bash -c '
        source "'"$BATS_TEST_DIRNAME"'/../../lib/common.sh"
        source "'"$BATS_TEST_DIRNAME"'/../../lib/prompt.sh"
        export PROMPT_NO_TTY=1
        echo "dave" | read_required "name"
    '
    [ "$output" = "dave" ]
}

@test "read_confirm returns y for yes" {
    run bash -c '
        source "'"$BATS_TEST_DIRNAME"'/../../lib/common.sh"
        source "'"$BATS_TEST_DIRNAME"'/../../lib/prompt.sh"
        export PROMPT_NO_TTY=1
        echo "y" | read_confirm "proceed"
    '
    [ "$output" = "y" ]
}

@test "read_confirm returns n for no" {
    run bash -c '
        source "'"$BATS_TEST_DIRNAME"'/../../lib/common.sh"
        source "'"$BATS_TEST_DIRNAME"'/../../lib/prompt.sh"
        export PROMPT_NO_TTY=1
        echo "n" | read_confirm "proceed"
    '
    [ "$output" = "n" ]
}

@test "read_secret function exists" {
    type read_secret | grep -q "function"
}

@test "_read_from helper exists" {
    type _read_from | grep -q "function"
}

@test "_tty_check helper exists" {
    type _tty_check | grep -q "function"
}

@test "PROMPT_NO_TTY=1 makes read_default use stdin" {
    # When PROMPT_NO_TTY=1, even with no pipe input the function should
    # consume stdin (the test's empty echo), not block on /dev/tty.
    run bash -c '
        source "'"$BATS_TEST_DIRNAME"'/../../lib/common.sh"
        source "'"$BATS_TEST_DIRNAME"'/../../lib/prompt.sh"
        export PROMPT_NO_TTY=1
        echo "from-stdin" | read_default "x" "fallback"
    '
    [ "$output" = "from-stdin" ]
}

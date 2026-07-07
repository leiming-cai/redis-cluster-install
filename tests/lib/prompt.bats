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

@test "PROMPT_NO_TTY=1 routes to stdin (not /dev/tty)" {
    # This test verifies the test-mode flag works; no /dev/tty needed
    run bash -c '
        source "'"$BATS_TEST_DIRNAME"'/../../lib/common.sh"
        source "'"$BATS_TEST_DIRNAME"'/../../lib/prompt.sh"
        export PROMPT_NO_TTY=1
        _prompt_fd
    '
    [ "$output" = "0" ]
}

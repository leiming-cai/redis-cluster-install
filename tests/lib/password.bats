load '../setup'
load_lib password

# The three assertions below used to fail with no explanation of WHAT came
# back. A failing test that cannot show its input is a test that sends the
# next person to the wrong place -- and this one failed only on CI, where
# nobody could see why. The diagnostic prints the LENGTH and the characters
# that are not [A-Za-z0-9]; it never prints the password itself.
gen_password_residue() {
    printf '%s' "$1" | LC_ALL=C tr -d 'A-Za-z0-9' | cat -A | head -20
}

# The whole captured output, with every alphanumeric masked, so the STRUCTURE
# is visible without printing a password.
gen_password_shape() {
    printf '%s' "$1" | LC_ALL=C tr 'A-Za-z0-9' 'X' | cat -A | head -20
}

@test "gen_password returns 32 chars by default" {
    run gen_password
    [ "$status" -eq 0 ]
    [ "${#output}" -eq 32 ] || {
        echo "length=${#output}" >&2
        echo "non-alphanumeric residue:" >&2
        gen_password_residue "$output" >&2
        echo "whole output, alphanumerics masked:" >&2
        gen_password_shape "$output" >&2
        false
    }
}

@test "gen_password honors length argument" {
    run gen_password 16
    [ "${#output}" -eq 16 ] || {
        echo "length=${#output}" >&2
        echo "non-alphanumeric residue:" >&2
        gen_password_residue "$output" >&2
        false
    }
}

@test "gen_password output is alphanumeric only" {
    run gen_password 64
    [[ "$output" =~ ^[A-Za-z0-9]+$ ]] || {
        echo "length=${#output}" >&2
        echo "non-alphanumeric residue:" >&2
        gen_password_residue "$output" >&2
        false
    }
}

@test "two calls produce different output" {
    a=$(gen_password)
    b=$(gen_password)
    [ "$a" != "$b" ]
}

# Every production script here runs under `set -euo pipefail`, so the library
# has to work under those options -- not only under whatever the test shell
# happens to use.
#
# The implementation used to be
#     tr -dc 'A-Za-z0-9' </dev/urandom | head -c N
# which pipes an INFINITE stream into head. head closes the pipe after N
# characters, and then:
#   * the writer is killed by SIGPIPE, so the pipeline's status is 141 and
#     `set -e` aborts the caller before it can use the password, and
#   * on a coreutils build that reports the error rather than dying silently,
#     "tr: write error: Broken pipe" lands in the captured output -- so the
#     password arrives with 44 characters of noise attached.
# The second symptom made this test fail only on CI, where nobody could see
# why: the assertion said the length was wrong and nothing else.
@test "gen_password works under the shell options the production scripts use" {
    run bash -c 'set -euo pipefail; . "$1/lib/password.sh"; gen_password 32' _ "$REPO_ROOT"
    [ "$status" -eq 0 ] || {
        echo "status=$status (141 means the writer was killed by SIGPIPE)" >&2
        gen_password_shape "$output" >&2
        false
    }
    [ "${#output}" -eq 32 ] || {
        echo "length=${#output}" >&2
        echo "non-alphanumeric residue:" >&2
        gen_password_residue "$output" >&2
        false
    }
    [[ "$output" =~ ^[A-Za-z0-9]+$ ]] || {
        echo "non-alphanumeric residue:" >&2
        gen_password_residue "$output" >&2
        false
    }
}

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

@test "gen_password returns 32 chars by default" {
    run gen_password
    [ "$status" -eq 0 ]
    [ "${#output}" -eq 32 ] || {
        echo "length=${#output}" >&2
        echo "non-alphanumeric residue:" >&2
        gen_password_residue "$output" >&2
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

load '../setup'
load_lib password

@test "gen_password returns 32 chars by default" {
    run gen_password
    [ "$status" -eq 0 ]
    [ "${#output}" -eq 32 ]
}

@test "gen_password honors length argument" {
    run gen_password 16
    [ "${#output}" -eq 16 ]
}

@test "gen_password output is alphanumeric only" {
    run gen_password 64
    [[ "$output" =~ ^[A-Za-z0-9]+$ ]]
}

@test "two calls produce different output" {
    a=$(gen_password)
    b=$(gen_password)
    [ "$a" != "$b" ]
}

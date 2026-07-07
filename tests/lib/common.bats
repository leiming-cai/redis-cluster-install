load '../setup'
load_lib common

@test "log_info prints [INFO] prefix" {
    run log_info "hello"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[INFO]"* ]]
    [[ "$output" == *"hello"* ]]
}

@test "log_warn prints [WARN] prefix" {
    run log_warn "careful"
    [[ "$output" == *"[WARN]"* ]]
}

@test "log_error prints [ERROR] prefix to stderr" {
    run log_error "boom"
    [[ "$output" == *"[ERROR]"* ]]
    [ "${stderr}" == *"boom"* ]
}

@test "die exits with code 1 and prints to stderr" {
    run die "fatal"
    [ "$status" -eq 1 ]
    [[ "${stderr}" == *"fatal"* ]]
}

@test "die honors non-zero exit code override" {
    run die "bad" 7
    [ "$status" -eq 7 ]
}
